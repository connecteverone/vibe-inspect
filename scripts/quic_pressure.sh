#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export QUIC_PORT="${QUIC_PORT:-5001}"
export CERT_PATH="${CERT_PATH:-$ROOT/target/quic_pressure_cert.der}"
export DURATION="${DURATION:-20}"
export WARMUP="${WARMUP:-2}"
export PPS="${PPS:-2000}"
export SIZE="${SIZE:-1200}"
export CONNECTIONS="${CONNECTIONS:-4}"
export LOG_INTERVAL="${LOG_INTERVAL:-2}"

"$ROOT/scripts/quic_bench.sh"
