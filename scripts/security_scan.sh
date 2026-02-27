#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

patterns=(
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'AIza[0-9A-Za-z_\-]{35}'
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-[A-Za-z0-9]{20,}'
  '-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----'
)

found=0
for pattern in "${patterns[@]}"; do
  if git grep -nE "$pattern" -- . >/tmp/vibe_inspect_secret_hits 2>/dev/null; then
    if [[ $found -eq 0 ]]; then
      echo "Potential high-confidence secrets detected:" >&2
    fi
    found=1
    cat /tmp/vibe_inspect_secret_hits >&2
  fi
done
rm -f /tmp/vibe_inspect_secret_hits

if [[ $found -eq 1 ]]; then
  echo "Secret scan failed." >&2
  exit 1
fi

echo "Secret scan passed: no high-confidence secrets in tracked files."
