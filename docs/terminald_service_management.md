# terminald Service Management

This project prefers native service managers to start `terminald`.

## Strategy
- First try a platform-native service manager.
- If no service is configured/available, fallback to starting `terminald` as a background process.

## Linux (systemd user service)
- Command path: `systemctl --user start <service>`
- Service candidates (in order):
  1. `VIBE_TERMINALD_SYSTEMD_SERVICE`
  2. `VIBE_TERMINALD_SERVICE`
  3. `vibe-inspect-terminald.service`
  4. `terminald.service`

## macOS (launchd)
- Command path:
  1. `launchctl kickstart -k gui/<uid>/<label>` or `user/<uid>/<label>`
  2. If missing, auto-generate LaunchAgent plist and `launchctl bootstrap gui/<uid> <plist>`
  3. Retry `kickstart`
- Label candidates (in order):
  1. `VIBE_TERMINALD_LAUNCHD_LABEL`
  2. `VIBE_TERMINALD_SERVICE`
  3. `com.vibeinspect.terminald`
  4. `com.vibe-inspect.terminald`
- Plist path defaults to: `~/Library/LaunchAgents/<label>.plist`
- Override plist path with: `VIBE_TERMINALD_LAUNCHD_PLIST`

## Windows (SCM)
- Command path: `sc start <service>`
- Service candidates (in order):
  1. `VIBE_TERMINALD_WINDOWS_SERVICE`
  2. `VIBE_TERMINALD_SERVICE`
  3. `VibeInspectTerminald`
  4. `terminald`

## Binary Resolution
- If `VIBE_TERMINALD_BIN` is set, use it.
- Otherwise resolve sibling binary next to current executable.
- Otherwise rely on PATH (`terminald` / `terminald.exe`).

## Backpressure Safety Tuning
- `VIBE_TERMINALD_MAX_SEND_QUEUE_BYTES`: max outbound WS queue bytes (default `2097152`).
- `VIBE_TERMINALD_LOW_WATER_MARK_BYTES`: resume threshold bytes (default min of `1048576` and `max-1`).
- Guardrails:
  - `max` must be `>= 65536`, otherwise default is used.
  - `low` must satisfy `0 < low < max`, otherwise default is used.

## Runtime Health Checks
- Service + metrics health check:
  - `./scripts/terminald_service_health_check.sh`
- Failure budget check (stream/backpressure/auth/reconnect metrics):
  - `./scripts/terminal_failure_budget_check.sh`
- macOS manual verification:
  - `launchctl print gui/$(id -u)/com.vibeinspect.terminald`
  - `desktop/target/debug/vibe-ctl debug`
