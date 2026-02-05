#!/usr/bin/env python3
import argparse
import asyncio
import json
import os
import ssl
import struct
import time
from typing import Optional
from urllib.request import Request, urlopen

from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration


def load_auth_token(path: Optional[str]) -> str:
    if path:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data.get("auth_token", "")
    home = os.path.expanduser("~")
    default_path = os.path.join(
        home,
        "Library",
        "Application Support",
        "com.vibe.vibe-inspect",
        "agent_identity.json",
    )
    with open(default_path, "r", encoding="utf-8") as f:
        data = json.load(f)
        return data.get("auth_token", "")


def command_request(host: str, port: int, auth_token: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = Request(
        f"http://{host}:{port}/command",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-agent-token": auth_token,
        },
        method="POST",
    )
    with urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if data.get("status") != "ok":
        raise RuntimeError(f"command failed: {data}")
    return data.get("payload") or {}


def fetch_identity(host: str, port: int, auth_token: str) -> dict:
    payload = {
        "request_id": f"bench-identity-{int(time.time() * 1000)}",
        "command": "identity",
        "payload": {},
    }
    return command_request(host, port, auth_token, payload)


def start_remote_session(host: str, port: int, auth_token: str) -> dict:
    payload = {
        "request_id": f"bench-remote-{int(time.time() * 1000)}",
        "command": "remote",
        "payload": {
            "action": "start",
            "session_id": f"bench-{int(time.time())}",
        },
    }
    return command_request(host, port, auth_token, payload)


def stop_remote_session(host: str, port: int, auth_token: str, session_id: str) -> None:
    payload = {
        "request_id": f"bench-remote-stop-{int(time.time() * 1000)}",
        "command": "remote",
        "payload": {
            "action": "stop",
            "session_id": session_id,
        },
    }
    _ = command_request(host, port, auth_token, payload)


async def read_json(reader) -> dict:
    length_bytes = await reader.readexactly(4)
    if not length_bytes:
        return {}
    length = struct.unpack(">I", length_bytes)[0]
    if length == 0:
        return {}
    payload = await reader.readexactly(length)
    return json.loads(payload.decode("utf-8"))


async def bench_remote_quic(
    host: str,
    quic_port: int,
    server_name: str,
    session_id: str,
    token: str,
    auth_token: str,
    duration: float,
    read_chunk: int,
):
    configuration = QuicConfiguration(
        is_client=True,
        verify_mode=ssl.CERT_NONE,
    )
    configuration.server_name = server_name

    t0 = time.perf_counter()
    stream_future: asyncio.Future = asyncio.get_event_loop().create_future()

    def on_stream(reader, writer):
        if not stream_future.done():
            stream_future.set_result((reader, writer))

    async with connect(
        host,
        quic_port,
        configuration=configuration,
        stream_handler=on_stream,
    ) as client:
        t_connect = time.perf_counter()
        ctrl_reader, ctrl_writer = await client.create_stream()
        hello = {
            "type": "remote",
            "session_id": session_id,
            "token": token,
            "auth_token": auth_token,
            "client_id": "bench",
            "client_name": "remote-bench",
        }
        hello_bytes = json.dumps(hello).encode("utf-8")
        ctrl_writer.write(struct.pack(">I", len(hello_bytes)) + hello_bytes)
        await ctrl_writer.drain()
        ready = await read_json(ctrl_reader)
        t_ready = time.perf_counter()
        if ready.get("status") != "ready":
            raise RuntimeError(f"remote ready failed: {ready}")

        if ready.get("data_stream") == "server_bi":
            try:
                data_reader, _ = await asyncio.wait_for(stream_future, timeout=5.0)
            except asyncio.TimeoutError as exc:
                raise RuntimeError("timeout waiting for server data stream") from exc
        else:
            data_reader, _ = await client.create_stream()
        t_first = None
        total_bytes = 0
        deadline = time.perf_counter() + duration
        while time.perf_counter() < deadline:
            timeout = max(0.0, deadline - time.perf_counter())
            if timeout <= 0:
                break
            try:
                chunk = await asyncio.wait_for(data_reader.read(read_chunk), timeout=timeout)
            except asyncio.TimeoutError:
                break
            if not chunk:
                await asyncio.sleep(0.01)
                continue
            if t_first is None:
                t_first = time.perf_counter()
            total_bytes += len(chunk)

    return {
        "connect_ms": (t_connect - t0) * 1000.0,
        "ready_ms": (t_ready - t0) * 1000.0,
        "first_data_ms": (t_first - t_ready) * 1000.0 if t_first else None,
        "bytes": total_bytes,
        "duration_s": duration,
        "throughput_kbps": (total_bytes / 1024.0) / duration if duration > 0 else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Remote QUIC benchmark")
    parser.add_argument("--host", default="127.0.0.1", help="Agent host")
    parser.add_argument("--command-port", type=int, default=58888, help="Agent HTTP port")
    parser.add_argument("--quic-port", type=int, default=0, help="QUIC port override")
    parser.add_argument("--server-name", default="vibe-inspect", help="QUIC TLS server name")
    parser.add_argument("--auth-token-path", default=None, help="Path to agent_identity.json")
    parser.add_argument("--session-id", default=None, help="Remote session id override")
    parser.add_argument("--token", default=None, help="Remote token override")
    parser.add_argument("--duration", type=float, default=3.0, help="Read duration seconds")
    parser.add_argument("--read-chunk", type=int, default=65536, help="Read chunk size")
    parser.add_argument(
        "--no-stop",
        action="store_true",
        help="Do not send remote.stop after benchmark",
    )
    args = parser.parse_args()

    auth_token = load_auth_token(args.auth_token_path)
    if not auth_token:
        raise RuntimeError("auth_token missing; check agent_identity.json")

    identity = fetch_identity(args.host, args.command_port, auth_token)
    quic_port = args.quic_port or identity.get("roi_quic_port") or 0
    if not quic_port:
        raise RuntimeError("quic port missing (identity.roi_quic_port)")

    session_id = args.session_id
    token = args.token
    started = False
    session_payload = None
    if not session_id or not token:
        session_payload = start_remote_session(args.host, args.command_port, auth_token)
        session_info = session_payload.get("session") if isinstance(session_payload, dict) else None
        if not isinstance(session_info, dict):
            session_info = {}
        session_id = session_payload.get("session_id") or session_info.get("session_id")
        token = session_payload.get("token") or session_info.get("token")
        started = True
    if not session_id or not token:
        raise RuntimeError("session_id/token missing")

    print(f"remote session: {session_id}")
    print(f"quic port: {quic_port}")

    stats = asyncio.run(
        bench_remote_quic(
            args.host,
            quic_port,
            args.server_name,
            session_id,
            token,
            auth_token,
            args.duration,
            args.read_chunk,
        )
    )

    print("bench result:")
    print(json.dumps(stats, indent=2))

    if started and not args.no_stop:
        stop_remote_session(args.host, args.command_port, auth_token, session_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
