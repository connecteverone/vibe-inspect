#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUSTDESK_DIR="${ROOT_DIR}/third_party/rustdesk"

usage() {
  cat <<'EOF'
Usage: scripts/build_rustdesk_mobile.sh <target>

Targets:
  android-arm64   Build Android arm64 (mediacodec + hwcodec)
  android-arm     Build Android armv7 (mediacodec + hwcodec)
  android-x64     Build Android x86_64 (mediacodec)
  android-x86     Build Android x86 (mediacodec)
  ios-arm64       Build iOS device (hwcodec)
  ios-x64         Build iOS simulator (auto-selects x86_64 or arm64-sim, hwcodec)
  all-android     Build all Android ABIs

Environment requirements:
  - ANDROID_NDK_HOME/ANDROID_NDK_ROOT for Android builds
  - cargo + cargo-ndk installed for Android builds
EOF
}

target="${1:-}"
if [[ -z "${target}" ]]; then
  usage
  exit 1
fi

run_in_rustdesk() {
  (cd "${RUSTDESK_DIR}" && bash "$@")
}

case "${target}" in
  android-arm64)
    run_in_rustdesk "flutter/ndk_arm64.sh"
    ;;
  android-arm)
    run_in_rustdesk "flutter/ndk_arm.sh"
    ;;
  android-x64)
    run_in_rustdesk "flutter/ndk_x64.sh"
    ;;
  android-x86)
    run_in_rustdesk "flutter/ndk_x86.sh"
    ;;
  ios-arm64)
    run_in_rustdesk "flutter/ios_arm64.sh"
    ;;
  ios-x64)
    run_in_rustdesk "flutter/ios_x64.sh"
    ;;
  all-android)
    run_in_rustdesk "flutter/ndk_arm64.sh"
    run_in_rustdesk "flutter/ndk_arm.sh"
    run_in_rustdesk "flutter/ndk_x64.sh"
    run_in_rustdesk "flutter/ndk_x86.sh"
    ;;
  *)
    usage
    exit 1
    ;;
esac
