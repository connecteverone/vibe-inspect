# Terminal Daemon + vibe-ctl Full Design (WebSocket-first)

## Overview
We will build a dedicated terminal daemon (`terminald`) that owns PTY session lifecycle and output buffers. A standalone CLI (`vibe-ctl`) provides tmux-like commands (ls, attach, send, resize, stop). The desktop agent becomes a thin client to terminald and continues to serve mobile using the same payload shape, keeping mobile changes minimal. terminald uses WebSocket for all control and streaming; the desktop agent may continue to expose existing HTTP/WS endpoints for mobile compatibility.

## Goals
- Sessions survive PC Agent restarts.
- terminald control + streaming over WebSocket; desktop agent retains legacy API shape for mobile/desktop UI.
- `vibe-ctl` CLI with tmux-like UX and low learning cost.
- Cross-platform support (macOS, Windows, Linux).
- Maintain current payload compatibility for desktop/mobile UI (schema-level compatibility).

## Architecture

```
 +---------------------+         +-------------------+         +-----------------------+
 |  vibe-ctl (CLI)     | <-----> | terminald (daemon)| <-----> | PTY + shell process   |
 +---------------------+   WS    +-------------------+         +-----------------------+
          ^                                   ^
          |                                   |
          |                                   v
 +---------------------+         +-----------------------+
 | desktop agent       | <-----> | terminald WS client   |
 +---------------------+         +-----------------------+
          ^
          |
 +---------------------+
 | mobile client       |
 +---------------------+
```

## Component Responsibilities

### terminald
- Owns PTY lifecycle and shell processes.
- Maintains output buffer, sequence numbers, vt100 parser, snapshot state.
- Serves WebSocket API for both request/response and streaming updates.
- Persists session summaries for listing after reconnects.

### vibe-ctl
- Standalone CLI client to terminald.
- Provides tmux-like commands and attach/detach UX.
- Uses WebSocket for all operations.

### desktop agent
- No PTY ownership; proxies requests to terminald.
- Keeps existing mobile/desktop payload shape intact.
- Optionally auto-starts terminald if not running.

### mobile client
- Unchanged: uses desktop agent API, does not depend on terminald.

## Runtime Model
- terminald is long-lived and independent of desktop agent.
- If desktop agent restarts, sessions remain in terminald.
- terminald can be launched on demand or as a background service.
- terminald listens on localhost only; auth token required for all WS connections.

## WebSocket Protocol (Primary)

### Connection Discovery
terminald writes a discovery file in the OS config directory so any client can find it. The intent is to avoid manual configuration while keeping the auth token local to the machine.

Path (examples):
- macOS: `~/Library/Application Support/VibeInspect/terminald.json`
- Linux: `~/.config/vibe-inspect/terminald.json`
- Windows: `%APPDATA%\\VibeInspect\\terminald.json`

Schema:
```json
{
  "ws_url": "ws://127.0.0.1:7078/ws",
  "token": "base64_or_hex",
  "version": "1.0",
  "pid": 12345,
  "created_at": 1700000000,
  "capabilities": ["attach", "poll", "notifications"]
}
```

Field notes:
- `ws_url`: WebSocket endpoint. By default terminald binds to localhost only (`127.0.0.1`) and rejects non-localhost connections unless explicitly configured otherwise.
- `token`: Auth token required on every connection.
- `version`: Protocol version for compatibility checks.
- `pid`: terminald process ID for basic health verification.
- `created_at`: Unix timestamp (seconds) when the discovery file was created.
- `capabilities`: Feature flags for clients (attach, poll, notifications, etc).

Clients may override discovery via environment variables (useful for CI or alternate configs):
- `VIBE_CTL_ENDPOINT` (WS URL override)
- `VIBE_CTL_TOKEN` (auth token override)
- `VIBE_CTL_CONFIG` (path to discovery file)

### Connection
- Localhost WebSocket endpoint (TCP by default; optional UDS on supported OSes).
- Client must send an `auth` message immediately after connect.
- All subsequent messages are JSON.
- If `auth` is not received within 3 seconds, the server should reply with an auth error and then close the socket.
- Server rejects non-localhost connections by default.

### Message Envelope
All messages are JSON objects. There are three top-level `type`s:
- `req`: request/response RPC
- `res`: response to a request
- `event`: server push event (clients must ignore unknown `event` values)

Request:
```json
{
  "type": "req",
  "id": "uuid",
  "action": "auth|start|list|attach|detach|poll|input|resize|rename|stop|keepalive",
  "session_id": "optional (required for session-scoped actions)",
  "payload": {}
}
```
The `payload` only contains action-specific parameters; `session_id` lives at the request envelope level.

Response:
```json
{
  "type": "res",
  "id": "uuid",
  "ok": true,
  "data": { ... },
  "error": null
}
```

Event (push):
```json
{
  "type": "event",
  "event": "terminal_payload|session_update|heartbeat|stream_paused|stream_resumed|session_warning",
  "session_id": "optional",
  "data": { ... }
}
```

### Protocol Versioning
- The protocol uses semantic versioning `major.minor`.
- `terminald` includes its `version` and `capabilities` in the `auth` response.
- Clients must refuse to operate if major version differs.
- Minor version differences should be handled by feature detection via `capabilities`.

### Auth
Client sends:
```json
{ "type": "req", "id": "uuid", "action": "auth", "payload": { "token": "..." } }
```
Server replies with `ok: true` or `ok: false` and an error code.
If auth fails or times out, the server should include a helpful error message before closing the connection; clients may reconnect and retry.
On success, server may include `server_info`:
```json
{
  "type": "res",
  "id": "uuid",
  "ok": true,
  "data": {
    "server_info": {
      "version": "1.0",
      "server_time": 1700000000,
      "capabilities": ["attach", "poll", "notifications"]
    }
  }
}
```

### Actions
For session-scoped actions (`attach`, `detach`, `poll`, `input`, `resize`, `rename`, `stop`, `keepalive`), `session_id` is required in the request envelope.

#### list
Request payload: `{}`  
Response data: `{ "sessions": [{ id, label, status, created_at, last_activity }] }`

#### start
Payload:
```json
{
  "label": "build",
  "cols": 120,
  "rows": 40,
  "working_dir": "/path",
  "env": { "KEY": "VALUE" }
}
```
Response data includes `session_id` and initial payload.

#### attach
Payload:
```json
{ "since": 0, "notify_since": 0 }
```
Server starts streaming `terminal_payload` events for this session. Multiple clients may attach.

#### detach
Payload:
```json
{ }
```
Server stops sending events for that session to this socket.

#### poll
Payload:
```json
{ "since": 12, "limit": 200, "notify_since": 0 }
```
Response data is a `terminal_payload` object (see below).

#### input
Payload:
```json
{ "data": "ls -la\n" }
```
Optional binary support:
```json
{ "data_b64": "AAECAw==", "encoding": "base64" }
```

#### resize
Payload:
```json
{ "cols": 120, "rows": 40 }
```

#### rename
Payload:
```json
{ "label": "new-name" }
```

#### stop
Payload:
```json
{ "force": false }
```

#### keepalive
Payload:
```json
{ }
```

### terminal_payload (Compatibility Shape)
This object is emitted as `event: terminal_payload` and as `poll` response data. It matches current desktop payloads at the schema level to keep UI stable:
```json
{
  "type": "terminal",
  "action": "poll|stream|start|input|resize|rename|stop|keepalive",
  "status": "running|exited|killed|error",
  "session_id": "abc",
  "output": [{ "seq": 13, "data": "...", "ts": 1700000000 }],
  "next_seq": 14,
  "first_seq": 1,
  "truncated": false,
  "snapshot": "...optional...",
  "exit_code": null,
  "last_activity": 1700000000,
  "label": "build",
  "notification_next_seq": 2,
  "notifications": []
}
```

### Sequencing + Snapshot Rules
- Server increments `seq` for each output chunk.
- Client sends `since`; server returns only newer chunks.
- `next_seq` is the next expected sequence number (last delivered `seq` + 1).
- If buffer truncated, server sets `truncated: true` and includes `snapshot`.
- Snapshot is vt100-rendered screen state plus cursor state.
- Clients must reset local output state on `truncated: true`.

### Errors
Errors are returned in response as:
```json
{ "code": "session_not_found", "message": "Session not found." }
```
Error codes align with existing desktop errors (`missing_input`, `resize_failed`, `pty_error`, etc.).

Common error codes:
- `invalid_auth`, `auth_required`
- `session_not_found`, `session_exists`, `session_ended`
- `missing_input`, `missing_size`, `invalid_size`
- `invalid_label`
- `write_failed`, `resize_failed`, `pty_error`, `spawn_error`
- `state_locked`, `invalid_request`, `unsupported_action`
- `client_backpressure`, `payload_too_large`

### Ordering and Backpressure
- For each session, outputs are strictly ordered by `seq`.
- If the server drops old chunks, it will set `truncated: true` and include a `snapshot`.
- Clients must reset local state when `truncated` is true.
- Per-connection send queues are bounded; if a client cannot keep up, the server should:
  1) emit `event: stream_paused` with a reason,
  2) drop intermediate chunks and send a `snapshot`,
  3) resume with `event: stream_resumed` once caught up.
- If the client remains far behind after repeated pauses/snapshots, the server may close the connection with error `client_backpressure`.

### Attach Semantics (Subscriptions)
- Each WebSocket connection maintains a set of subscribed `session_id`s.
- `attach` adds a subscription and immediately emits a `terminal_payload` event with:
  - `output` since `since`
  - `truncated` and `snapshot` if necessary
- If truncation occurs, the server should also emit `event: session_warning` with a `buffer_truncated` reason.
- `detach` removes the subscription.
- Multiple sockets may attach to the same session; fan-out is supported.
- Default max subscriptions per socket: `4` (configurable).

### Reconnect Strategy
- Clients should persist `next_seq` and `notification_next_seq`.
- On reconnect, call `attach` with last seen `since` and `notify_since`.
- If `truncated: true`, clients must drop local buffer and apply `snapshot`.

### Heartbeats
- WebSocket ping/pong is used for transport keepalive.
- Server may emit `event: heartbeat` every 15s when idle.

### Warnings (Gentle Degradation)
- The server may emit `event: session_warning` with a `reason` (e.g., `buffer_truncated`, `payload_truncated`, `payload_too_large`, `idle_expiring`, `slow_consumer`) and human-readable `message`.
- These warnings are advisory; clients should surface them non-blockingly and continue.

### Stream Pause/Resume
- `event: stream_paused` data: `{ reason, retry_after_ms? }`
- `event: stream_resumed` data: `{}` (indicates streaming has resumed)

### Event Payload Schemas (Simplified)
`session_warning` data:
```json
{
  "reason": "buffer_truncated|payload_truncated|payload_too_large|idle_expiring|slow_consumer",
  "message": "human readable summary",
  "session_id": "abc",
  "ts": 1700000000,
  "detail": { "retry_after_ms": 1000 }
}
```

`stream_paused` data:
```json
{
  "reason": "slow_consumer|backpressure",
  "retry_after_ms": 1000
}
```

`stream_resumed` data:
```json
{}
```

### Client UX Guidelines (Non-Blocking)
- `session_warning` should be surfaced as a small, dismissible notice; never block input.
- `idle_expiring` should include remaining time and offer a one-click `keepalive`.
- `buffer_truncated`/`payload_truncated` should explain that older output was dropped and that the screen state is preserved by snapshot.
- `payload_too_large` should suggest reducing output volume (e.g., redirect to file) and retrying.
- `slow_consumer`/`stream_paused` should show a subtle "stream paused" indicator; resume clears it.

### Event JSON Schemas (Detailed)
`session_warning` event (data object):
```json
{
  "type": "object",
  "required": ["reason", "message", "ts"],
  "properties": {
    "reason": {
      "type": "string",
      "enum": ["buffer_truncated", "payload_truncated", "payload_too_large", "idle_expiring", "slow_consumer"]
    },
    "message": { "type": "string", "minLength": 1 },
    "session_id": { "type": "string" },
    "ts": { "type": "number" },
    "detail": { "type": "object" }
  },
  "additionalProperties": true
}
```

`stream_paused` event (data object):
```json
{
  "type": "object",
  "required": ["reason"],
  "properties": {
    "reason": { "type": "string", "enum": ["slow_consumer", "backpressure"] },
    "retry_after_ms": { "type": "number" }
  },
  "additionalProperties": true
}
```

`stream_resumed` event (data object):
```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": true
}
```

### Client UI Interaction Examples
- `session_warning: idle_expiring` -> show inline banner with countdown and a "Keep Alive" button (sends `keepalive`); auto-dismiss on success.
- `session_warning: buffer_truncated` -> show small toast: "Old output trimmed; view restored from snapshot."
- `session_warning: payload_too_large` -> show toast with suggestion: "Output too large; consider redirecting output to a file and retry."
- `stream_paused` -> show subtle status pill "Stream paused"; hide it on `stream_resumed`.
- `slow_consumer` -> show a single warning per session; do not spam repeated notices.

### UI Component Guidance (Placement, Timing, Priority, A11y)
- Placement:
  - Inline banner: top of terminal view, inside the scroll container but pinned (does not move with output).
  - Toast: bottom-left of terminal view (avoid covering input line).
  - Status pill: right side of terminal header or toolbar.
- Timing:
  - Inline banners persist until the condition clears or user dismisses.
  - Toast duration 4-6 seconds; for `payload_too_large` allow manual dismiss and keep visible 8-10 seconds.
  - Status pill stays visible while paused; disappears within 300ms of `stream_resumed`.
- Priority:
  - `payload_too_large` > `idle_expiring` > `buffer_truncated` > `slow_consumer`.
  - Show at most one inline banner at a time; queue lower priority notices as toasts.
  - Do not show the same warning more than once per 30 seconds per session.
- Accessibility:
  - Provide short, non-technical copy for screen readers (e.g., "Terminal output trimmed; screen restored.").
  - Use aria-live="polite" for toasts and status pills.
  - Buttons must be keyboard reachable; include an accessible label (e.g., "Keep session alive").

### Field-Level Spec (Normative)
Unknown fields must be ignored for forward compatibility. The server may reject requests with unknown `type` or `action` values, but should not fail solely because extra fields are present.
Clients must ignore unknown fields in responses and events.

Request (`type=req`):
- `id` (string, required): UUID for correlating response.
- `action` (string, required): one of listed actions.
- `session_id` (string, optional): required for session-specific actions.
- `payload` (object, required): action-specific params.

Response (`type=res`):
- `id` (string, required): matches request id.
- `ok` (bool, required).
- `data` (object, optional): present when `ok=true`.
- `error` (object, optional): present when `ok=false`.

Error object:
- `code` (string, required).
- `message` (string, required).
- `detail` (object, optional).

terminal_payload fields:
- `type` = `terminal` (string, required)
- `action` (string, required)
- `status` (string, required)
- `session_id` (string, required)
- `output` (array, required; may be empty)
- `next_seq` (number, required)
- `first_seq` (number|null, required)
- `truncated` (bool, required)
- `snapshot` (string|null, optional)
- `exit_code` (number|null, required)
- `last_activity` (number, required)
- `label` (string, required)
- `notification_next_seq` (number, required)
- `notifications` (array, optional)

Output chunk:
- `seq` (number, required, monotonic per session)
- `data` (string, required; UTF-8)
- `ts` (number, required; unix seconds)

Notification:
- `id` (string, required)
- `session_id` (string, required)
- `message` (string, required)
- `level` (string, required; `info|warning|error`)
- `created_at` (number, required)
- `source` (string, required)
- `seq` (number, required)

### Action Schemas (Detailed)
Unless specified, actions return `terminal_payload` in `res.data`. Actions that return non-terminal payloads explicitly define their response shapes below. For session-scoped actions, `session_id` is supplied in the request envelope, not inside `payload`.

`auth`:
- payload: `{ token: string }`
- response: `{ server_info }`

`list`:
- payload: `{}`
- response: `{ sessions: [{ id, label, status, created_at, last_activity }] }`

`start`:
- payload:
  - `label` (string, optional; if empty or omitted, server auto-generates)
  - `cols` (number, optional; default 120)
  - `rows` (number, optional; default 32)
  - `working_dir` (string, optional; default HOME)
  - `env` (object, optional; merged into process env)
- response:
  - `session_id`
  - `payload` (terminal_payload with `action=start`)

`attach`:
- payload:
  - `since` (number, optional; default 0)
  - `notify_since` (number, optional; default 0)
- response: `{ attached: true }` and begins push events on this socket

`detach`:
- payload: `{}`
- response: `{ detached: true }` and stops push events for this session on this socket

`poll`:
- payload:
  - `since` (number, optional; default 0)
  - `limit` (number, optional; default 800)
  - `notify_since` (number, optional; default 0)
- response: `terminal_payload`

`input`:
- payload:
  - `data` (string, optional) OR `data_b64` (string, optional)
  - `encoding` (string, optional; `base64`)
- response: `terminal_payload` (may be empty output)

`resize`:
- payload:
  - `cols` (number, required)
  - `rows` (number, required)
- response: `terminal_payload`

`rename`:
- payload: `{ label: string }`
- response: `terminal_payload`

`stop`:
- payload: `{ force?: boolean }`
- response: `terminal_payload` with final status and exit_code

`keepalive`:
- payload: `{}`
- response: `terminal_payload` (resets idle timer)

### Idempotency
- `list`, `poll`, `keepalive`, `resize` (same size), `rename` (same label) are idempotent.
- `start` is not idempotent (new session each call).
- `attach` is idempotent per `(socket, session_id)`; repeated calls are no-ops.
- `detach` is idempotent per `(socket, session_id)`; repeated calls are no-ops.

### Limits and Defaults (configurable)
These defaults mirror current desktop implementation for compatibility:
- Default size: `cols=120`, `rows=32`
- Size bounds: `cols` 10..400, `rows` 4..200
- Output buffer: `512 KB` per session (byte-based)
- Output limit per poll/stream tick: `800` chunks
- Notification queue limit: `200`
- Snapshot scrollback: `0` (screen only)
- Max WS message size: `1 MB` (server rejects larger)
- Max auth handshake time: `3s`
- Heartbeat interval: `15s`
- Max sessions per token: `200`
- Max attached sockets per session: `8`
- Max subscriptions per socket: `4`
- Max label length: `80`
- Max env entries: `64` (key/value max 4 KB each)
- Idle TTL: `24h` (sessions auto-cleaned when idle)
- Idle warning lead time: `10m` before cleanup via `session_warning` (configurable)
- Max payload bytes per `terminal_payload`: `900 KB` (keep under WS limit)
  - This is the estimated data-body limit; serialized JSON must remain < `max_ws_message_size`.

### Validation Rules
- `cols`/`rows` outside bounds -> `invalid_size`.
- `label` length > max -> `invalid_label`.
- `rename` with empty `label` -> `invalid_label`.
- Missing `session_id` on session actions -> `missing_session`.
- `data` missing on `input` -> `missing_input`.
- Both `data` and `data_b64` present -> `invalid_request`.

### Payload Size Enforcement
- Server must ensure every `terminal_payload` stays under `max_ws_message_size`.
- If output chunks + snapshot exceed the limit:
  1) Drop oldest output chunks from the payload.
  2) If still too large, send `truncated: true` with only `snapshot` and emit `event: session_warning` with reason `payload_truncated`.
  3) If snapshot alone exceeds the limit, emit `event: session_warning` with reason `payload_too_large` and close the connection.

### Data Encoding
- All text is UTF-8.
- `input` uses UTF-8 text by default; `data_b64` supports raw bytes.
- Snapshot is UTF-8 (vt100-formatted).

### Security Considerations
- Localhost-only binding by default.
- Token-based auth from discovery file.
- File permissions on discovery and token are user-only.
- Optional allowlist for CLI origin if needed.

### Compatibility Guarantees
- `terminal_payload` schema remains stable across minor versions.
- New fields are added in a backwards-compatible manner.
- Clients must ignore unknown fields.

## Session Model
- `id`, `label`, `status`
- `created_at`, `last_activity`, `exit_code`
- `buffer` (bounded by bytes; keeps output chunks with seq)
- `next_seq`, `notification_next_seq`
- `vt100` parser for screen snapshots
- Notification cache keeps `warning/error` lines with a short TTL (default 300s).

## PTY Spawn and Environment
- Shell selection mirrors current desktop behavior:
  - macOS/Linux: `$SHELL` if set, else `/bin/zsh` or `/bin/bash` fallback
  - Windows: `COMSPEC` (cmd.exe) or PowerShell if configured
- Environment:
  - Inherit parent env by default.
  - Apply `env` overrides from `start`.
  - Ensure `TERM=xterm-256color` if not set.
  - Set `COLORTERM=truecolor`.
- Working directory:
  - Use `working_dir` if provided; else default to user HOME.
- UTF-8:
  - Ensure `LANG`/`LC_CTYPE` are UTF-8 where possible.

## Backward Compatibility with Existing UI
- `terminal_payload` remains schema-compatible with current desktop/mobile parsing.
- Desktop agent continues to expose the same UI API; no client-side schema changes required.
- Mobile/desktop clients can continue to use `poll` or WebSocket streaming as before.

## CLI: vibe-ctl (tmux-like UX)

### Commands
- `vibe-ctl ls`  
  List sessions (id, label, status, last activity).
- `vibe-ctl new -s <name> [--cwd <dir>] [--cols N --rows N]`  
  Create a session; prints id.
- `vibe-ctl a -t <id>` / `vibe-ctl attach -t <id>`  
  Attach with live output; detach key `Ctrl-b d`.
- `vibe-ctl send -t <id> "<cmd>\n"`  
  Send input without attach.
- `vibe-ctl resize -t <id> --cols N --rows N`
- `vibe-ctl rename -t <id> <label>`
- `vibe-ctl stop -t <id> [--force]`  
  Stop session gracefully (use `--force` only when needed). `kill` is an alias.

### Attach Behavior
- Switch terminal to raw mode.
- Stream output events and print to stdout.
- Forward keystrokes as `input` actions.
- `Ctrl-b d` triggers detach (configurable).

### User Learning Cost (tmux-style)
- Command names and abbreviations mirror tmux.
- Attach/detach semantics are identical.
- No panes/splits initially, reducing complexity.

### CLI Flags (Detailed)
- Global:
  - `--endpoint <ws_url>` override discovery URL
  - `--token <token>` override auth token
  - `--config <path>` discovery file path
  - `--json` output machine-readable JSON for `ls`
- `new`:
  - `-s, --name <label>`
  - `--cwd <dir>`
  - `--cols <n>` `--rows <n>`
  - `--env KEY=VALUE` (repeatable)
- `attach`:
  - `-t, --target <id>`
  - `--read-only` (no input)
  - `--detach-key <keys>` (default `Ctrl-b d`)
  - `--no-raw` (for debugging)
- `send`:
  - `-t, --target <id>`
  - `--file <path>` (send file contents)
- `resize`:
  - `-t, --target <id>`
  - `--cols <n>` `--rows <n>`
- `rename`:
  - `-t, --target <id>`
  - `<label>`
- `stop` (alias: `kill`):
  - `-t, --target <id>`
  - `--force`

### CLI Examples
```bash
vibe-ctl ls
vibe-ctl new -s build --cwd ~/repo --cols 140 --rows 40
vibe-ctl attach -t abc
vibe-ctl send -t abc "npm test\n"
vibe-ctl resize -t abc --cols 120 --rows 50
vibe-ctl rename -t abc "release-build"
vibe-ctl stop -t abc
```

## Client Interaction Flows (Detailed)

### 1) vibe-ctl ls
1) Read discovery file for `ws_url` and `token`.
2) Connect WebSocket.
3) Send `auth`.
4) Send `list`.
5) Print sessions.

### 2) vibe-ctl new + attach
1) Connect + auth.
2) Send `start` with size/env/cwd.
3) Receive response with session id.
4) Send `attach` for that session.
5) Enter raw mode, forward keystrokes as `input`.
6) On detach key, send `detach`, restore TTY.

### 3) Desktop agent proxy (mobile)
1) Mobile calls desktop agent `start`.
2) Desktop agent sends `start` to terminald.
3) Desktop agent returns session id to mobile.
4) Mobile connects to desktop agent WebSocket; agent proxies stream from terminald.

## Wire Examples (End-to-End)

### Connect + Auth + List
Client -> server:
```json
{ "type": "req", "id": "1", "action": "auth", "payload": { "token": "abc" } }
```
Server -> client:
```json
{ "type": "res", "id": "1", "ok": true, "data": { "server_info": { "version": "1.0", "capabilities": ["attach","poll"] } } }
```
Client -> server:
```json
{ "type": "req", "id": "2", "action": "list", "payload": {} }
```
Server -> client:
```json
{ "type": "res", "id": "2", "ok": true, "data": { "sessions": [{ "id": "abc", "label": "build", "status": "running", "created_at": 1700, "last_activity": 1701 }] } }
```

### Start + Attach + Input + Detach
Client -> server:
```json
{ "type": "req", "id": "3", "action": "start", "payload": { "label": "build", "cols": 120, "rows": 40 } }
```
Server -> client:
```json
{ "type": "res", "id": "3", "ok": true, "data": { "session_id": "abc", "payload": { "type": "terminal", "action": "start", "status": "running", "session_id": "abc", "output": [], "next_seq": 1, "first_seq": null, "truncated": false, "exit_code": null, "last_activity": 1700, "label": "build", "notification_next_seq": 0, "notifications": [] } } }
```
Client -> server:
```json
{ "type": "req", "id": "4", "action": "attach", "session_id": "abc", "payload": { "since": 0, "notify_since": 0 } }
```
Server -> client (push event):
```json
{ "type": "event", "event": "terminal_payload", "session_id": "abc", "data": { "type": "terminal", "action": "stream", "status": "running", "session_id": "abc", "output": [{ "seq": 1, "data": "hello\n", "ts": 1700 }], "next_seq": 2, "first_seq": 1, "truncated": false, "snapshot": null, "exit_code": null, "last_activity": 1700, "label": "build", "notification_next_seq": 0, "notifications": [] } }
```
Client -> server:
```json
{ "type": "req", "id": "5", "action": "input", "session_id": "abc", "payload": { "data": "ls -la\n" } }
```
Client -> server:
```json
{ "type": "req", "id": "6", "action": "detach", "session_id": "abc", "payload": {} }
```

## Implementation Notes for vibe-ctl
- Use a single WebSocket connection per CLI invocation.
- `attach` requires async IO for both stdin and WS events.
- On Windows, raw mode should use `termios` equivalent (e.g. `crossterm`).
- Detach key handling is local in CLI (does not depend on tmux).
- On attach, listen for `SIGWINCH` and send `resize` events automatically.
- Detach key sequence: `Ctrl-b` then `d` within 1 second (configurable).
- For paste, send raw bytes as UTF-8; if binary needed, use `data_b64`.

## Performance and Concurrency Model
- One PTY reader task per session.
- One writer per session; inputs are serialized to preserve ordering.
- Each WS connection has a bounded outgoing queue to prevent memory growth.
- Snapshot generation uses the vt100 parser state (O(screen size)).
- Output buffering uses byte-size trimming to `MAX_BUFFER_BYTES`.
- Polling frequency is client-driven; stream is server-pushed at fixed tick (e.g., 80ms).
- For high-throughput output, server batches chunks per tick to reduce WS overhead.

## Performance Targets (Initial)
- Support 100 concurrent sessions on a typical developer machine.
- Maintain <100ms median latency for stream updates under moderate load.
- Avoid unbounded memory growth; total memory per session bounded by buffers.
- WS CPU utilization stays linear with output volume and number of clients.

## Backpressure Algorithm (Deterministic)
- Each connection has a bounded outgoing queue sized by bytes (default 2 MB).
- When enqueueing a new `terminal_payload` would exceed the bound:
  1) Emit `event: stream_paused` and drop intermediate queued payloads for that session.
  2) Enqueue a single `terminal_payload` with `truncated: true` and `snapshot`.
  3) When the queue falls below the low-water mark, emit `event: stream_resumed`.
  4) If still over limit after repeated pauses, close the connection with `client_backpressure`.
- This guarantees memory bounds and provides a deterministic, gentle recovery path.

## State Machines

### Session State (daemon)
States: `running`, `exited`, `killed`, `error`
Transitions:
- `start` -> `running`
- `running` + child exit -> `exited` (exit_code set)
- `running` + stop(force=false) -> graceful terminate -> `exited` (exit_code set)
- `running` + stop(force=true) -> immediate kill -> `killed`
- spawn error -> `error`
- IO error -> `error`
Terminal states (`exited|killed|error`) reject input/resize with `session_ended`.

### Connection State (client)
States: `disconnected`, `connecting`, `authenticating`, `ready`, `attaching`, `attached`
Transitions:
- `connecting` -> `authenticating` -> `ready`
- `ready` -> `attaching` -> `attached`
- `attached` -> `ready` (detach)
- any -> `disconnected` (socket close)

## Formal Schemas (JSON Schema, simplified)

### Request (`type=req`)
```json
{
  "type": "object",
  "required": ["type","id","action","payload"],
  "properties": {
    "type": { "const": "req" },
    "id": { "type": "string", "minLength": 1 },
    "action": { "type": "string" },
    "session_id": { "type": "string" },
    "payload": { "type": "object" }
  },
  "additionalProperties": true
}
```

### Response (`type=res`)
```json
{
  "type": "object",
  "required": ["type","id","ok"],
  "properties": {
    "type": { "const": "res" },
    "id": { "type": "string" },
    "ok": { "type": "boolean" },
    "data": { "type": "object" },
    "error": {
      "type": "object",
      "required": ["code","message"],
      "properties": {
        "code": { "type": "string" },
        "message": { "type": "string" },
        "detail": { "type": "object" }
      }
    }
  },
  "additionalProperties": true
}
```

### Event (`type=event`)
```json
{
  "type": "object",
  "required": ["type","event","data"],
  "properties": {
    "type": { "const": "event" },
    "event": { "type": "string" },
    "session_id": { "type": "string" },
    "data": { "type": "object" }
  },
  "additionalProperties": true
}
```

### terminal_payload
```json
{
  "type": "object",
  "required": ["type","action","status","session_id","output","next_seq","first_seq","truncated","exit_code","last_activity","label","notification_next_seq"],
  "properties": {
    "type": { "const": "terminal" },
    "action": { "type": "string" },
    "status": { "type": "string" },
    "session_id": { "type": "string" },
    "output": { "type": "array" },
    "next_seq": { "type": "number" },
    "first_seq": {},
    "truncated": { "type": "boolean" },
    "snapshot": {},
    "exit_code": {},
    "last_activity": { "type": "number" },
    "label": { "type": "string" },
    "notification_next_seq": { "type": "number" },
    "notifications": { "type": "array" }
  },
  "additionalProperties": true
}
```

## Sequence Diagrams (Text)

### Attach Flow
1) Client connects -> auth.
2) Client sends `attach` with `since`.
3) Server sends initial `terminal_payload`.
4) Server pushes incremental payloads on new output.

### Resize Flow
1) Client detects terminal size change.
2) Client sends `resize`.
3) Server resizes PTY + vt100 parser and replies with payload.

### Reconnect Flow
1) Client reconnects, sends `attach` with last `since`.
2) If server buffer truncated, it sends snapshot with `truncated: true`.
3) Client resets local output and applies snapshot.

## Observability
- Structured logs for session lifecycle events (start, stop, exit, error).
- Metrics:
  - active_sessions, active_connections
  - output_bytes_total, dropped_chunks_total
  - ws_backpressure_events_total
  - median_stream_latency_ms
- Optional debug command in `vibe-ctl` to print server_info and metrics.

## Test Matrix (Must Pass)
- Start/attach/detach/reattach across daemon and agent restarts.
- High output burst ( > 5 MB ) triggers truncation and snapshot recovery.
- Resize while output streaming.
- Multiple concurrent attachments to the same session.
- Backpressure triggers snapshot or connection close deterministically.
- Windows/macOS/Linux smoke tests for raw mode attach.

## Acceptance Criteria (No Regression)
- Existing desktop/mobile terminal views render output correctly using payloads.
- Sessions remain active after desktop agent restart.
- `vibe-ctl attach` behavior matches tmux detach semantics.

## Expected Targets (Explicit)
- Latency: median < 100ms, p95 < 250ms for stream updates under moderate load.
- Throughput: handle 5 MB/s aggregated output without crash; truncation allowed but must recover via snapshot.
- Stability: no memory growth over 24h with idle sessions at max limits.
- Compatibility: payload compatibility with current desktop/mobile UI (no schema changes required).
- UX: `vibe-ctl` detach key works on macOS/Linux/Windows.

## Detailed Test Plan

### Unit Tests
1) Buffer truncation:
   - Write > 512 KB data.
   - Expect `truncated: true` and snapshot on next poll.
2) Seq ordering:
   - Ensure `seq` is monotonic and gaps are handled.
3) UTF-8 handling:
   - Partial UTF-8 sequences across chunk boundaries reassemble correctly.
4) Resize logic:
   - vt100 parser resizes and snapshot remains valid.

### Integration Tests
1) Start -> attach -> input -> output echo.
2) Detach -> reattach -> resume output with `since`.
3) Multi-attach:
   - Two clients attach to same session and receive output.
4) Backpressure:
   - Slow client triggers `truncated` snapshot or disconnect.
5) Persisted summaries:
   - Restart daemon, ensure `list` contains previous summaries marked exited.

### Manual Test Checklist
Why: these checks confirm sessions survive desktop agent restarts and that the mobile UI remains compatible with the existing payload schema.

1) Desktop agent restart (session continuity):
   - Start a session via `vibe-ctl new -s build --cwd ~/repo --cols 140 --rows 40` and attach.
   - Restart the desktop agent process/app while the session is active.
   - Expected: `vibe-ctl ls` shows the same session id, `vibe-ctl attach -t <id>` resumes output, and the session keeps running in terminald.
2) Mobile compatibility (payload + controls):
   - Start a session from the mobile UI and verify output streaming.
   - Resize the terminal and send input; ensure output continues without UI errors.
   - Expected: no schema-related warnings, and the session id matches the one listed by `vibe-ctl ls`.
3) CLI raw mode:
   - Verify detach key (`Ctrl-b d`) returns to shell and SIGWINCH resize updates the session.

## Acceptance Checklist (Ship Gate)
- [ ] WS protocol matches schema; auth required on all connections.
- [ ] All test matrix items pass.
- [ ] Performance targets met in local benchmark.
- [ ] No regression in mobile or desktop UI.
- [ ] Backpressure path verified with truncation recovery.

## Failure Modes and Recovery
- If `terminald` is not reachable, CLI/agent return `connection_failed`.
- If a client misses output (buffer truncated), server sends a snapshot.
- If a session exits, server sets `status` and includes `exit_code`; no further input accepted.
- If a session is idle past `idle_ttl`, server may auto-clean it and send `session_update`.

## Desktop Agent Integration
- Replace direct PTY management with a WebSocket client to terminald.
- Keep all payloads in current shape for mobile UI compatibility.
- Agent can proxy the stream WebSocket to mobile or re-emit payloads.
- Auto-start terminald if not running (configurable).

## Code-Level Mapping (from current desktop implementation)
Reuse the existing logic with minimal change by extracting a shared `terminal_core` module:
- `start_session` -> `terminal_core::start_session`
- `poll_session` -> `terminal_core::poll_session`
- `input_session` -> `terminal_core::input_session`
- `resize_session` -> `terminal_core::resize_session`
- `stop_session` -> `terminal_core::stop_session`
- `list_terminal_sessions` -> `terminal_core::list_terminal_sessions`
- `run_terminal_stream` + `serve_terminal_socket` -> terminald WS server
- `build_session_payload` shared for compatibility

## Reliability / Resilience
- Sessions live in terminald; agent restarts do not terminate PTYs.
- Output buffer bounded by bytes to avoid memory growth.
- Idle session cleanup based on inactivity policy.
- Crash safety: if terminald stops, sessions are lost (same as today); future restart policy can be added.

### Persistence (Session Summaries)
- Store session summaries (id/label/status/created_at/last_activity) in a JSON file.
- Write is atomic: `write tmp -> fsync -> rename`.
- On startup, terminald loads summaries for `list` even if sessions are gone; stale entries are marked `exited` and removed on cleanup.

### Daemon Lifecycle
- On startup: load config, create discovery file, open WS listener.
- On shutdown: stop accepting new connections, flush summaries, optionally terminate sessions (configurable: `graceful_shutdown`).
- On crash: sessions die; summaries indicate `error` on next startup.

## Extensibility
- Multi-pane support: add `pane_id` and map sessions to multiple PTYs.
- Recording/replay: persist output chunks with seq to disk.
- Multi-user sharing: allow multiple attachments with read-only flags.
- Profiles: per-session presets for shell/env/working dir.

## Collaboration Workstreams (parallelizable)
- terminal_core extraction: move session logic to shared module.
- terminald server: WS server, auth, session management.
- vibe-ctl: CLI UI, raw mode attach, detach key handling.
- desktop agent proxy: map existing HTTP/WS endpoints to terminald.
- tests: buffer truncation, snapshot correctness, reconnect/attach flows.
