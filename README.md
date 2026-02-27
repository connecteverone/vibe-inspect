# Vibe Inspect

Vibe Inspect is an open-source remote operations workspace.

It combines a Flutter mobile client and a Rust desktop agent so you can:
- pair to a desktop agent securely
- inspect and drive terminal sessions from mobile
- use remote desktop channels (RustDesk/VNC paths in this repo)
- run diagnostics, transport checks, and reliability verification

## What This Project Is For

Vibe Inspect focuses on **operational visibility and control** for developer machines and lab hosts:
- remote troubleshooting
- terminal-centric workflows on mobile
- controlled remote input/streaming experiments
- protocol and stability validation for QUIC-based paths

## Repository Layout

- `mobile/`: Flutter application (UI, pairing, terminal/remote client flows)
- `desktop/`: Rust agent and transport/runtime services
- `scripts/`: verification and bench scripts
- `docs/`: architecture notes, integration and operational docs
- `third_party/rustdesk/`: upstream submodule dependency

## Quick Start

### 1. Clone and initialize submodules

```bash
git clone https://github.com/connecteverone/vibe-inspect.git
cd vibe-inspect
git submodule update --init --recursive
```

### 2. Mobile setup

```bash
cd mobile
flutter pub get
```

### 3. Verify before changes

```bash
cd mobile && flutter test
cd mobile && flutter analyze
./scripts/flutter_test.sh
./scripts/flutter_analyze.sh
```

### 4. Optional web smoke build

```bash
cd mobile && flutter build web
cd mobile/build/web && python3 -m http.server 8030 --bind 127.0.0.1
```

## Security and Open-Source Hygiene

- This repository is intended for public/open-source usage.
- Do not commit keys, passwords, private tokens, or certificate material.
- Local artifacts and secret-prone files are ignored via `.gitignore`.
- Run secret checks before publishing:

```bash
./scripts/security_scan.sh
```

See [SECURITY.md](SECURITY.md) for reporting and handling policy.

## Additional Docs

- `docs/remote_rustdesk_integration.md`
- `docs/remote_arch_v2.md`
- `docs/terminald_service_management.md`
- `docs/terminal_compatibility_matrix.md`

## iOS FFI Symbol Retention Guardrail

RustDesk iOS bridge symbols must be retained in release linking when using
`DynamicLibrary.process().lookup(...)`.

Before shipping iOS release builds:

```bash
cd mobile && flutter build ios --release --no-codesign
cd mobile && nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"
```

Details: `docs/remote_rustdesk_integration.md` section
`iOS FFI symbol retention guardrail`.
