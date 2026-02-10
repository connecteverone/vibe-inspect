#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/desktop"
VIBE_CTL_BIN="${VIBE_CTL_BIN:-$DESKTOP_DIR/target/debug/vibe-ctl}"
LAUNCHD_LABEL="${VIBE_TERMINALD_LAUNCHD_LABEL:-com.vibeinspect.terminald}"

if [[ ! -x "$VIBE_CTL_BIN" ]]; then
  echo "[terminald-health] vibe-ctl missing, building..."
  (cd "$DESKTOP_DIR" && cargo build -q --bin vibe-ctl)
fi

os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"

echo "[terminald-health] os=$os_name"

ensure_native_service_running() {
  case "$os_name" in
    darwin)
      if ! command -v launchctl >/dev/null 2>&1; then
        echo "[terminald-health] launchctl not found" >&2
        return 1
      fi
      local uid target
      uid="$(id -u)"
      target="gui/$uid/$LAUNCHD_LABEL"
      if ! launchctl print "$target" >/tmp/terminald_launchctl.$$ 2>&1; then
        echo "[terminald-health] launchd target missing, try auto-start via vibe-ctl"
        "$VIBE_CTL_BIN" debug >/dev/null
      else
        if ! rg -q "state = running" /tmp/terminald_launchctl.$$; then
          echo "[terminald-health] launchd target not running, kickstart"
          launchctl kickstart -k "$target" || true
        fi
      fi
      rm -f /tmp/terminald_launchctl.$$
      ;;
    linux)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user start "${VIBE_TERMINALD_SYSTEMD_SERVICE:-vibe-inspect-terminald.service}" >/dev/null 2>&1 || true
      fi
      "$VIBE_CTL_BIN" debug >/dev/null
      ;;
    *)
      "$VIBE_CTL_BIN" debug >/dev/null
      ;;
  esac
}

extract_metric() {
  local output="$1"
  local key="$2"
  printf '%s\n' "$output" | awk -F': ' -v prefix="$key" '$1 == prefix {print $2}' | tail -n 1
}

ensure_native_service_running
DEBUG_OUTPUT="$($VIBE_CTL_BIN debug)"

auth_attempts="$(extract_metric "$DEBUG_OUTPUT" "ws_auth_attempts_total")"
auth_success="$(extract_metric "$DEBUG_OUTPUT" "ws_auth_success_total")"
reconnect_rate="$(extract_metric "$DEBUG_OUTPUT" "reconnect_success_rate_percent")"
active_connections="$(extract_metric "$DEBUG_OUTPUT" "active_connections")"

if [[ -z "$auth_attempts" || -z "$auth_success" || -z "$reconnect_rate" || -z "$active_connections" ]]; then
  echo "[terminald-health] missing required metrics" >&2
  exit 1
fi

if (( auth_success > auth_attempts )); then
  echo "[terminald-health] FAIL auth_success > auth_attempts ($auth_success > $auth_attempts)" >&2
  exit 1
fi

if (( reconnect_rate < 0 || reconnect_rate > 100 )); then
  echo "[terminald-health] FAIL reconnect rate out of bounds: $reconnect_rate" >&2
  exit 1
fi

if (( active_connections < 1 )); then
  echo "[terminald-health] FAIL active_connections < 1: $active_connections" >&2
  exit 1
fi

echo "[terminald-health] active_connections=$active_connections"
echo "[terminald-health] ws_auth_attempts_total=$auth_attempts"
echo "[terminald-health] ws_auth_success_total=$auth_success"
echo "[terminald-health] reconnect_success_rate_percent=$reconnect_rate"
echo "[terminald-health] PASS"
