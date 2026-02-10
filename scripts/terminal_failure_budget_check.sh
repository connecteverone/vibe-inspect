#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/desktop"
VIBE_CTL_BIN="${VIBE_CTL_BIN:-$DESKTOP_DIR/target/debug/vibe-ctl}"

MAX_DROPPED_CHUNKS_TOTAL="${MAX_DROPPED_CHUNKS_TOTAL:-0}"
MAX_WS_BACKPRESSURE_EVENTS_TOTAL="${MAX_WS_BACKPRESSURE_EVENTS_TOTAL:-0}"
MIN_WS_BACKPRESSURE_EVENTS_TOTAL="${MIN_WS_BACKPRESSURE_EVENTS_TOTAL:-0}"
MAX_PAUSE_DURATION_P95_MS="${MAX_PAUSE_DURATION_P95_MS:-0}"
MIN_RECONNECT_SUCCESS_RATE_PERCENT="${MIN_RECONNECT_SUCCESS_RATE_PERCENT:-0}"

if [[ ! -x "$VIBE_CTL_BIN" ]]; then
  echo "[terminal-budget] vibe-ctl binary missing, building..."
  (cd "$DESKTOP_DIR" && cargo build -q --bin vibe-ctl)
fi

DEBUG_OUTPUT="$($VIBE_CTL_BIN debug)"

extract_metric() {
  local key="$1"
  local value
  value="$(printf '%s\n' "$DEBUG_OUTPUT" | awk -F': ' -v prefix="$key" '$1 == prefix {print $2}' | tail -n 1)"
  if [[ -z "$value" ]]; then
    echo "[terminal-budget] missing metric: $key" >&2
    exit 1
  fi
  printf '%s' "$value"
}

ACTIVE_SESSIONS="$(extract_metric "active_sessions")"
ACTIVE_CONNECTIONS="$(extract_metric "active_connections")"
DROPPED_CHUNKS_TOTAL="$(extract_metric "dropped_chunks_total")"
WS_BACKPRESSURE_EVENTS_TOTAL="$(extract_metric "ws_backpressure_events_total")"
WS_AUTH_ATTEMPTS_TOTAL="$(extract_metric "ws_auth_attempts_total")"
WS_AUTH_SUCCESS_TOTAL="$(extract_metric "ws_auth_success_total")"
RECONNECT_SUCCESS_RATE_PERCENT="$(extract_metric "reconnect_success_rate_percent")"
PAUSE_DURATION_P95_MS="$(extract_metric "pause_duration_p95_ms")"
PAUSE_DURATION_P50_MS="$(extract_metric "pause_duration_p50_ms")"
PAUSE_DURATION_SAMPLES_TOTAL="$(extract_metric "pause_duration_samples_total")"

echo "[terminal-budget] active_sessions=$ACTIVE_SESSIONS"
echo "[terminal-budget] active_connections=$ACTIVE_CONNECTIONS"
echo "[terminal-budget] dropped_chunks_total=$DROPPED_CHUNKS_TOTAL"
echo "[terminal-budget] ws_backpressure_events_total=$WS_BACKPRESSURE_EVENTS_TOTAL"
echo "[terminal-budget] ws_auth_attempts_total=$WS_AUTH_ATTEMPTS_TOTAL"
echo "[terminal-budget] ws_auth_success_total=$WS_AUTH_SUCCESS_TOTAL"
echo "[terminal-budget] reconnect_success_rate_percent=$RECONNECT_SUCCESS_RATE_PERCENT"
echo "[terminal-budget] pause_duration_p50_ms=$PAUSE_DURATION_P50_MS"
echo "[terminal-budget] pause_duration_p95_ms=$PAUSE_DURATION_P95_MS"
echo "[terminal-budget] pause_duration_samples_total=$PAUSE_DURATION_SAMPLES_TOTAL"

if (( WS_AUTH_SUCCESS_TOTAL > WS_AUTH_ATTEMPTS_TOTAL )); then
  echo "[terminal-budget] FAIL: ws_auth_success_total=$WS_AUTH_SUCCESS_TOTAL > ws_auth_attempts_total=$WS_AUTH_ATTEMPTS_TOTAL" >&2
  exit 1
fi

if (( PAUSE_DURATION_P95_MS < PAUSE_DURATION_P50_MS )); then
  echo "[terminal-budget] FAIL: pause_duration_p95_ms=$PAUSE_DURATION_P95_MS < pause_duration_p50_ms=$PAUSE_DURATION_P50_MS" >&2
  exit 1
fi

if (( WS_AUTH_ATTEMPTS_TOTAL > 0 )); then
  EXPECTED_RECONNECT_SUCCESS_RATE="$((WS_AUTH_SUCCESS_TOTAL * 100 / WS_AUTH_ATTEMPTS_TOTAL))"
  if (( RECONNECT_SUCCESS_RATE_PERCENT != EXPECTED_RECONNECT_SUCCESS_RATE )); then
    echo "[terminal-budget] FAIL: reconnect_success_rate_percent=$RECONNECT_SUCCESS_RATE_PERCENT expected=$EXPECTED_RECONNECT_SUCCESS_RATE" >&2
    exit 1
  fi
fi

if (( DROPPED_CHUNKS_TOTAL > MAX_DROPPED_CHUNKS_TOTAL )); then
  echo "[terminal-budget] FAIL: dropped_chunks_total=$DROPPED_CHUNKS_TOTAL > $MAX_DROPPED_CHUNKS_TOTAL" >&2
  exit 1
fi

if (( WS_BACKPRESSURE_EVENTS_TOTAL > MAX_WS_BACKPRESSURE_EVENTS_TOTAL )); then
  echo "[terminal-budget] FAIL: ws_backpressure_events_total=$WS_BACKPRESSURE_EVENTS_TOTAL > $MAX_WS_BACKPRESSURE_EVENTS_TOTAL" >&2
  exit 1
fi

if (( WS_BACKPRESSURE_EVENTS_TOTAL < MIN_WS_BACKPRESSURE_EVENTS_TOTAL )); then
  echo "[terminal-budget] FAIL: ws_backpressure_events_total=$WS_BACKPRESSURE_EVENTS_TOTAL < $MIN_WS_BACKPRESSURE_EVENTS_TOTAL" >&2
  exit 1
fi

if (( MAX_PAUSE_DURATION_P95_MS > 0 && PAUSE_DURATION_P95_MS > MAX_PAUSE_DURATION_P95_MS )); then
  echo "[terminal-budget] FAIL: pause_duration_p95_ms=$PAUSE_DURATION_P95_MS > $MAX_PAUSE_DURATION_P95_MS" >&2
  exit 1
fi

if (( RECONNECT_SUCCESS_RATE_PERCENT < MIN_RECONNECT_SUCCESS_RATE_PERCENT )); then
  echo "[terminal-budget] FAIL: reconnect_success_rate_percent=$RECONNECT_SUCCESS_RATE_PERCENT < $MIN_RECONNECT_SUCCESS_RATE_PERCENT" >&2
  exit 1
fi

echo "[terminal-budget] PASS"
