# Desktop Agent (Rust)

The `desktop/` workspace contains the local agent runtime and terminal binaries used by Vibe Inspect.

## Components

| Binary/Module | Purpose |
| --- | --- |
| `src/main.rs` | Tauri desktop app entry point |
| `src/server.rs` | Local HTTP + WebSocket agent server |
| `src/bin/vnc_headless.rs` | Headless command/VNC/ROI server (no Tauri UI) |
| `src/bin/terminald.rs` | Terminal daemon WebSocket server |
| `src/bin/vibe-ctl.rs` | CLI client for `terminald` |

## Local Development

### 1. Build and check

```bash
cd desktop
cargo check
```

### 2. Run headless agent server

```bash
cd desktop
cargo run --bin vnc_headless -- --port 58888 --quic-port 58889
```

The process prints:
- `HTTP_PORT`
- `QUIC_PORT`
- `AUTH_TOKEN`

Use those values from a separate terminal:

```bash
export AGENT_URL="http://127.0.0.1:58888"
export AUTH_TOKEN="<AUTH_TOKEN>"
curl -sS "$AGENT_URL/health"
```

### 3. Run terminal daemon and CLI

```bash
cd desktop
cargo run --bin terminald
```

In another shell:

```bash
cd desktop
cargo run --bin vibe-ctl -- defaults
cargo run --bin vibe-ctl -- ls
```

## Agent API Surface (Current)

HTTP routes:
- `POST /command`
- `POST /pairing/confirm`
- `GET /vnc/{session_id}`
- `GET /terminal/{session_id}`
- `GET /health`

Command envelope includes:
- `ping`
- `api`
- `terminal`
- `vnc`
- `roi`
- `remote`
- `ws_ticket`

## Related Docs

- [Developer Guide](../docs/developer_guide.md)
- [Agent API Reference](../docs/api_reference.md)
- [Agent Connection Spec v1.1](../docs/agent-connection-v1.1-spec.md)
- [terminald Service Management](../docs/terminald_service_management.md)
- [RustDesk Integration Context](../docs/remote_rustdesk_integration.md)

## Open-Source Safety

- Never commit real tokens/keys/passwords.
- Keep command examples sanitized with placeholders.
- Run secret scan before pushing:

```bash
cd ..
./scripts/security_scan.sh
```
