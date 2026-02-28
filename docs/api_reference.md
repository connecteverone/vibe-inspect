# Agent API Reference

This document describes the current local agent HTTP/WS surface exposed by `desktop/src/server.rs`.

## Base URL

Typical local endpoint:

```text
http://127.0.0.1:58888
```

## Auth

Accepted auth headers for command and websocket upgrade:
- `x-agent-token: <AUTH_TOKEN>`
- `Authorization: Bearer <AUTH_TOKEN>`

Optional client metadata:
- `x-client-id: <CLIENT_ID>`
- `x-client-name: <CLIENT_NAME>`

For WebSocket flows, short-lived ticket auth is also supported:
- `ws_ticket` query parameter or `x-ws-ticket` header

## Routes

| Route | Method | Purpose |
| --- | --- | --- |
| `/health` | `GET` | Liveness check |
| `/command` | `POST` | Command envelope entrypoint |
| `/pairing/confirm` | `POST` | Confirm pairing session |
| `/vnc/{session_id}` | `GET` (WS upgrade) | VNC session socket |
| `/terminal/{session_id}` | `GET` (WS upgrade) | Terminal stream socket |

## Command Envelope

All commands use:

```json
{
  "request_id": "req-123",
  "command": "ping",
  "payload": {}
}
```

Common response shape:

```json
{
  "request_id": "req-123",
  "status": "ok",
  "payload": {},
  "error": null
}
```

## Supported Commands

### `ping`

Request:

```json
{
  "request_id": "req-ping-1",
  "command": "ping",
  "payload": {}
}
```

### `identity`

Returns device identity, transport hints, and remote capabilities.

Request:

```json
{
  "request_id": "req-identity-1",
  "command": "identity",
  "payload": {}
}
```

### `ws_ticket`

Issues one-time short-lived websocket credentials (session scope requires `session_id`).

Request:

```json
{
  "request_id": "req-ticket-1",
  "command": "ws_ticket",
  "payload": {
    "scope": "terminal_ws",
    "session_id": "<SESSION_ID>"
  }
}
```

### `terminal`

Actions include:
- `list`
- `start`
- `poll`
- `status`
- `input`
- `resize`
- `rename`
- `stop`
- `kill`
- `keepalive`
- `delete`

Example request:

```json
{
  "request_id": "req-term-list-1",
  "command": "terminal",
  "payload": {
    "action": "list"
  }
}
```

`input` supports UTF-8 bytes via base64:

```json
{
  "request_id": "req-term-input-1",
  "command": "terminal",
  "payload": {
    "action": "input",
    "session_id": "<SESSION_ID>",
    "input_b64": "<BASE64_BYTES>"
  }
}
```

### `vnc`

Actions include:
- `displays`
- `start`
- `stop`

Example:

```json
{
  "request_id": "req-vnc-start-1",
  "command": "vnc",
  "payload": {
    "action": "start",
    "display_index": 0,
    "width": 1280,
    "height": 720
  }
}
```

### `roi`

Actions include:
- `start`
- `stop`

`start` requires framebuffer/screen sizes.

### `remote`

Actions include:
- `start`
- `stop`
- `status`

Example:

```json
{
  "request_id": "req-remote-start-1",
  "command": "remote",
  "payload": {
    "action": "start",
    "display_index": 0
  }
}
```

### `api`

Proxy HTTP request through desktop agent.

```json
{
  "request_id": "req-api-1",
  "command": "api",
  "payload": {
    "method": "GET",
    "url": "https://example.com/health",
    "headers": {}
  }
}
```

## WebSocket Auth Patterns

### Terminal WS

Path:

```text
/terminal/{session_id}
```

Auth options:
- `x-agent-token` header
- `Authorization: Bearer ...` header
- `ws_ticket=<token>` query parameter

### VNC WS

Path:

```text
/vnc/{session_id}
```

Optional VNC session token is sent as query param:
- `token=<vnc_session_token>`

## Error Model

When `status` is `error`, response includes:

```json
{
  "error": {
    "code": "invalid_payload",
    "message": "Human-readable message",
    "details": {}
  }
}
```

Common auth-oriented codes:
- `unauthorized`
- `rate_limited`
- `client_blocked`

Common payload/command codes:
- `missing_payload`
- `invalid_payload`
- `unsupported_action`
- `unknown_command`
