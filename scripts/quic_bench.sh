#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${QUIC_PORT:-5000}"
CERT_PATH="${CERT_PATH:-$ROOT/target/quic_bench_cert.der}"
DURATION="${DURATION:-10}"
WARMUP="${WARMUP:-1}"
PPS="${PPS:-1000}"
SIZE="${SIZE:-1200}"
CONNECTIONS="${CONNECTIONS:-1}"
LOG_INTERVAL="${LOG_INTERVAL:-2}"

mkdir -p "$(dirname "$CERT_PATH")"

cargo run -p desktop --bin quic_bench -- \
  server \
  --bind "127.0.0.1:${PORT}" \
  --cert-out "$CERT_PATH" \
  --log-interval-secs "$LOG_INTERVAL" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT

sleep 1

cargo run -p desktop --bin quic_bench -- \
  client \
  --addr "127.0.0.1:${PORT}" \
  --cert "$CERT_PATH" \
  --duration-secs "$DURATION" \
  --warmup-secs "$WARMUP" \
  --pps "$PPS" \
  --size "$SIZE" \
  --connections "$CONNECTIONS"
