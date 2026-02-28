# Developer Guide

This guide explains how the repository is organized, where core runtime entry points live, and how to work safely in an open-source workflow.

## Project Purpose

Vibe Inspect provides a mobile-first remote operations workspace:
- desktop agent exposes pairing + command + session channels
- mobile client drives terminal and remote display workflows
- transport/remote experiments (VNC/ROI/RustDesk/QUIC) share the same auth model

## Repository Map

| Path | Responsibility |
| --- | --- |
| `mobile/` | Flutter app: pairing UI, workspace screens, terminal and remote clients |
| `desktop/` | Rust agent: local HTTP/WS server, command routing, remote engines |
| `desktop/src/bin/terminald.rs` | Terminal daemon binary |
| `desktop/src/bin/vibe-ctl.rs` | CLI for terminald operations |
| `scripts/` | verification, benchmark, and safety scripts |
| `docs/` | architecture/spec/design and operational docs |
| `third_party/rustdesk/` | upstream RustDesk submodule dependency |

## Key Entry Points

### Mobile

- `mobile/lib/main.dart`
  - App bootstrap and theme.
  - Includes pairing, terminal, VNC, ROI, and remote session parts.
- `mobile/lib/app/agent_workspace.dart`
  - Main workspace flow after pairing.
  - Launches terminal/API/VNC/remote sessions.
- `mobile/lib/remote/remote_session_screen.dart`
  - RustDesk-backed remote session lifecycle and QUIC handshake.
- `mobile/lib/vnc/*`
  - VNC session UI, input mapping, ROI interaction.

### Desktop

- `desktop/src/main.rs`
  - Tauri app bootstrap and command registration.
- `desktop/src/server.rs`
  - Local HTTP + WebSocket server routes:
    - `POST /command`
    - `POST /pairing/confirm`
    - `GET /vnc/{session_id}`
    - `GET /terminal/{session_id}`
    - `GET /health`
- `desktop/src/command.rs`
  - Command envelope handlers (`ping`, `api`, `terminal`, `vnc`).
- `desktop/src/pairing.rs`
  - Pairing session lifecycle, token issuance, auth state, client management.
- `desktop/src/terminal.rs`
  - Terminal command adapter and terminald socket bridge.
- `desktop/src/remote_engine/*`
  - Remote backend abstraction and RustDesk backend integration.

## Runtime Data Flow (High Level)

1. Mobile receives pairing payload from desktop QR session.
2. Mobile confirms pairing (`/pairing/confirm`) and stores auth token.
3. Mobile issues command envelope to `/command`.
4. Desktop agent routes command to terminal/VNC/remote/ROI handlers.
5. For realtime streams, mobile upgrades to WebSocket/QUIC paths using token or short-lived `ws_ticket`.

Detailed payload examples:
- `api_reference.md`

## Command Envelope Shape

Every command request uses the same shape:

```json
{
  "request_id": "req-123",
  "command": "terminal",
  "payload": {
    "action": "list"
  }
}
```

Auth headers accepted by `/command`:
- `x-agent-token: <AUTH_TOKEN>`
- or `Authorization: Bearer <AUTH_TOKEN>`

Optional client metadata:
- `x-client-id`
- `x-client-name`

## Developer Workflow

### Setup

```bash
git submodule update --init --recursive
cd mobile && flutter pub get
```

### Required verification

```bash
cd mobile && flutter test
cd mobile && flutter analyze
./scripts/flutter_test.sh
./scripts/flutter_analyze.sh
```

### Browser UI smoke

```bash
cd mobile && flutter build web
cd mobile/build/web && python3 -m http.server 8030 --bind 127.0.0.1
```

### Secret scan before push/release

```bash
./scripts/security_scan.sh
```

## iOS RustDesk FFI Guardrail

When touching RustDesk FFI symbol names or iOS linker flags, ensure release symbols are retained:

```bash
cd mobile && flutter build ios --release --no-codesign
cd mobile && nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"
```

Reference: `remote_rustdesk_integration.md` section `iOS FFI symbol retention guardrail`.

## Open-Source Hygiene Rules

- Never commit real keys, passwords, or production tokens.
- Keep examples sanitized (`<AUTH_TOKEN>`, `<SESSION_ID>`).
- Treat `.gitignore` and `SECURITY.md` as release gates, not optional docs.
- Run secret scan before publishing branches/tags.
