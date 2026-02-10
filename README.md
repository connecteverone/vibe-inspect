# Vibe Inspect

[![Terminal Cross-OS Guardrails](https://github.com/<OWNER>/vibe-inspect/actions/workflows/terminal-cross-os.yml/badge.svg)](https://github.com/<OWNER>/vibe-inspect/actions/workflows/terminal-cross-os.yml)

## Project Structure
- `mobile/`: Flutter mobile client scaffold
- `desktop/`: Rust/Tauri desktop agent scaffold
- `scripts/`: helper scripts for Flutter verification

## Dependency Installs
### Flutter (mobile)
- `flutter pub add collection`
- `flutter pub add cupertino_icons`
- `flutter pub add sqflite`
- `flutter pub add flutter_secure_storage`
- `flutter pub get`
Local timeline history uses SQLite with a secure key stored in the device keychain.

### Rust/Tauri (desktop)
- `cargo add tauri`
- `cargo add tauri-build --build`

## Verification
- `./scripts/flutter_test.sh`
- `./scripts/flutter_analyze.sh`

## Terminal Daemon Management
- `terminald` should be started through native service managers when possible.
- Linux: `systemctl --user` services (labels from `VIBE_TERMINALD_SYSTEMD_SERVICE` / `VIBE_TERMINALD_SERVICE`).
- macOS: `launchd` agents (labels from `VIBE_TERMINALD_LAUNCHD_LABEL` / `VIBE_TERMINALD_SERVICE`).
- Windows: service manager `sc` (service names from `VIBE_TERMINALD_WINDOWS_SERVICE` / `VIBE_TERMINALD_SERVICE`).
- Fallback: if no managed service is available, start `terminald` as a direct background process.

## Negative Case (Analyze)
If `collection` is removed from `mobile/pubspec.yaml`, `flutter analyze` fails with
`Target of URI doesn't exist: 'package:collection/collection.dart'.`

## iOS FFI Symbol Guardrail (Must Read)
- RustDesk mobile bridge uses `DynamicLibrary.process().lookup(...)` on iOS.
- Release linking can dead-strip unreferenced C ABI symbols and cause runtime errors like `Failed to lookup symbol`.
- Keep iOS linker keep-list (`OTHER_LDFLAGS[sdk=iphoneos*]` with `-Wl,-u,_<symbol>`) in sync for **Debug / Release / Profile**.
- Before release install, run:
  - `cd mobile && flutter build ios --release --no-codesign`
  - `cd mobile && nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"`

Full guardrail and checklist: `docs/remote_rustdesk_integration.md` (section `iOS FFI symbol retention guardrail`).
