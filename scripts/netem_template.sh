#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s)"
LOSS="${LOSS:-1%}"
RTT_MS="${RTT_MS:-30}"
JITTER_MS="${JITTER_MS:-5}"
IFACE="${IFACE:-lo0}"
ACTION="${ACTION:-show}" # show | apply | clear

if [[ "$OS" == "Linux" ]]; then
  IFACE="${IFACE:-lo}"
  case "$ACTION" in
    apply)
      sudo tc qdisc replace dev "$IFACE" root netem delay "${RTT_MS}ms" "${JITTER_MS}ms" loss "$LOSS"
      ;;
    clear)
      sudo tc qdisc del dev "$IFACE" root netem || true
      ;;
    show|*)
      tc qdisc show dev "$IFACE"
      ;;
  esac
  exit 0
fi

if [[ "$OS" == "Darwin" ]]; then
  cat <<EOF
macOS dummynet template (run manually, requires sudo):

  sudo dnctl pipe 1 config delay ${RTT_MS}ms plr ${LOSS%\%}
  echo "dummynet in quick on ${IFACE} proto udp from any to any pipe 1" | sudo pfctl -Ef -

Clear rules:
  sudo pfctl -F all -f /etc/pf.conf
  sudo dnctl -q flush

Note: adjust ${IFACE} if needed (e.g. lo0, en0). This template does not auto-apply.
EOF
  exit 0
fi

echo "Unsupported OS: $OS"
