#!/usr/bin/env python3
import argparse
import asyncio
import ipaddress
import json
import os
import socket
import ssl
import struct
import sys
import time
from contextlib import asynccontextmanager
from typing import Optional
from urllib.request import Request, urlopen

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.quic.connection import QuicConnection
from aioquic.quic.configuration import QuicConfiguration


@asynccontextmanager
async def connect_quic(
    host: str,
    port: int,
    configuration: QuicConfiguration,
):
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None

    if ip and ip.version == 4:
        loop = asyncio.get_event_loop()
        infos = await loop.getaddrinfo(
            host,
            port,
            type=socket.SOCK_DGRAM,
            family=socket.AF_INET,
        )
        addr = infos[0][4]
        if configuration.server_name is None:
            configuration.server_name = host
        connection = QuicConnection(configuration=configuration)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("0.0.0.0", 0))
        transport, protocol = await loop.create_datagram_endpoint(
            lambda: QuicConnectionProtocol(connection),
            sock=sock,
        )
        try:
            protocol.connect(addr, transmit=True)
            await protocol.wait_connected()
            yield protocol
        finally:
            protocol.close()
            await protocol.wait_closed()
            transport.close()
    else:
        async with connect(host, port, configuration=configuration) as client:
            yield client


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


def start_vnc_session(
    host: str,
    port: int,
    auth_token: str,
    width: Optional[int],
    height: Optional[int],
    high_perf_interval_ms: Optional[int],
) -> dict:
    payload = {
        "request_id": f"bench-{int(time.time() * 1000)}",
        "command": "vnc",
        "payload": {
            "action": "start",
            "session_id": f"bench-{int(time.time())}",
        },
    }
    if width:
        payload["payload"]["width"] = width
    if height:
        payload["payload"]["height"] = height
    if high_perf_interval_ms:
        payload["payload"]["high_perf_interval_ms"] = high_perf_interval_ms
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
    return data["payload"]


async def read_exact(reader, size: int) -> bytes:
    data = await reader.readexactly(size)
    return data


async def bench_vnc_quic(
    host: str,
    quic_port: int,
    server_name: str,
    session_id: str,
    token: str,
    auth_token: str,
    encoding: str,
    iterations: int,
    incremental: bool,
    width_hint: int,
    height_hint: int,
):
    configuration = QuicConfiguration(
        is_client=True,
        verify_mode=ssl.CERT_NONE,
    )
    configuration.server_name = server_name
    async with connect_quic(
        host,
        quic_port,
        configuration,
    ) as client:
        reader, writer = await client.create_stream()
        hello = {
            "type": "vnc",
            "session_id": session_id,
            "token": token,
            "auth_token": auth_token,
            "client_id": "bench",
            "client_name": "vnc-bench",
        }
        hello_bytes = json.dumps(hello).encode("utf-8")
        writer.write(struct.pack(">I", len(hello_bytes)) + hello_bytes)
        await writer.drain()
        ready_len = struct.unpack(">I", await read_exact(reader, 4))[0]
        if ready_len:
            ready_payload = await read_exact(reader, ready_len)
            ready = json.loads(ready_payload.decode("utf-8"))
            if ready.get("status") != "ready":
                raise RuntimeError(f"quic ready failed: {ready}")

        version = await read_exact(reader, 12)
        writer.write(version)
        await writer.drain()

        sec_types = await read_exact(reader, 2)
        if sec_types[0] == 0:
            raise RuntimeError("server returned no security types")
        writer.write(b"\x01")
        await writer.drain()

        sec_result = await read_exact(reader, 4)
        if any(b != 0 for b in sec_result):
            raise RuntimeError("security negotiation failed")

        writer.write(b"\x01")  # shared
        await writer.drain()

        server_init = await read_exact(reader, 24)
        width = struct.unpack(">H", server_init[0:2])[0]
        height = struct.unpack(">H", server_init[2:4])[0]
        bits_per_pixel = server_init[4]
        bytes_per_pixel = bits_per_pixel // 8
        name_len = struct.unpack(">I", server_init[20:24])[0]
        if name_len:
            _ = await read_exact(reader, name_len)

        if width_hint > 0:
            width = width_hint
        if height_hint > 0:
            height = height_hint

        if encoding == "raw":
            encodings = [0, -239]
        else:
            encodings = [6, -239]
        payload = bytearray(4 + len(encodings) * 4)
        payload[0] = 2
        payload[2] = (len(encodings) >> 8) & 0xFF
        payload[3] = len(encodings) & 0xFF
        offset = 4
        for enc in encodings:
            payload[offset:offset + 4] = struct.pack(">i", enc)
            offset += 4
        writer.write(payload)
        await writer.drain()

        for i in range(iterations):
            req = struct.pack(">BBHHHH", 3, 1 if incremental else 0, 0, 0, width, height)
            start = time.perf_counter()
            writer.write(req)
            await writer.drain()
            t_first = None
            while True:
                message_type = await read_exact(reader, 1)
                if message_type == b"\x00":
                    _ = await read_exact(reader, 1)  # padding
                    rect_count = struct.unpack(">H", await read_exact(reader, 2))[0]
                    t_first = time.perf_counter()
                    break
            total_bytes = 0
            for _ in range(rect_count):
                header = await read_exact(reader, 12)
                x, y, w, h = struct.unpack(">HHHH", header[:8])
                encoding = struct.unpack(">i", header[8:12])[0]
                if encoding == -239:
                    pixel_bytes = w * h * bytes_per_pixel
                    mask_stride = (w + 7) // 8
                    mask_bytes = mask_stride * h
                    await read_exact(reader, pixel_bytes + mask_bytes)
                    total_bytes += pixel_bytes + mask_bytes
                elif encoding == 0:
                    raw_len = w * h * bytes_per_pixel
                    await read_exact(reader, raw_len)
                    total_bytes += raw_len
                elif encoding == 6:
                    zlen = struct.unpack(">I", await read_exact(reader, 4))[0]
                    await read_exact(reader, zlen)
                    total_bytes += zlen
                else:
                    raise RuntimeError(f"unsupported encoding {encoding}")
            end = time.perf_counter()
            ms = (end - start) * 1000.0
            ttfb_ms = (t_first - start) * 1000.0 if t_first else 0.0
            payload_ms = (end - t_first) * 1000.0 if t_first else 0.0
            print(
                f"iter={i + 1} rects={rect_count} bytes={total_bytes} latency_ms={ms:.2f} ttfb_ms={ttfb_ms:.2f} payload_ms={payload_ms:.2f}",
                flush=True,
            )


def main():
    parser = argparse.ArgumentParser(description="QUIC VNC bench")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=58888, help="HTTP command port")
    parser.add_argument("--quic-port", type=int, default=5000, help="QUIC port")
    parser.add_argument("--auth-token", default="")
    parser.add_argument("--identity", default="", help="Path to agent_identity.json")
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--height", type=int, default=0)
    parser.add_argument("--high-perf-interval-ms", type=int, default=0)
    parser.add_argument("--server-name", default="vibe-inspect")
    parser.add_argument("--encoding", choices=["zlib", "raw"], default="zlib")
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--incremental", action="store_true")
    args = parser.parse_args()

    auth_token = args.auth_token
    if not auth_token:
        auth_token = load_auth_token(args.identity or None)
    if not auth_token:
        raise RuntimeError("auth token missing")

    session = start_vnc_session(
        args.host,
        args.port,
        auth_token,
        args.width or None,
        args.height or None,
        args.high_perf_interval_ms or None,
    )
    session_id = session["session_id"]
    token = session["token"]
    quic_port = int(session.get("quic_port") or args.quic_port)
    width_hint = int(session.get("width") or args.width or 0)
    height_hint = int(session.get("height") or args.height or 0)

    asyncio.run(
        bench_vnc_quic(
            args.host,
            quic_port,
            args.server_name,
            session_id,
            token,
            auth_token,
            args.encoding,
            args.iterations,
            args.incremental,
            width_hint,
            height_hint,
        )
    )


if __name__ == "__main__":
    main()
