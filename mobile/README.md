# Vibe Inspect Mobile

Flutter client for the Vibe Inspect remote operations workspace.

## Scope

The mobile app is responsible for:
- pairing with desktop agent (QR/manual flows)
- terminal workspace and stream interaction
- VNC + ROI remote display control
- RustDesk-backed remote session UX
- local storage for sessions/events

## Key Directories

| Path | Responsibility |
| --- | --- |
| `lib/main.dart` | App bootstrap, theme, and major feature parts |
| `lib/app/` | Pairing, workspace, terminal, API explorer screens/logic |
| `lib/vnc/` | VNC session UI, input mapping, ROI interactions |
| `lib/remote/` | RustDesk bridge, remote session control, keyboard/trackpad UX |
| `lib/roi/` | ROI models, renderer, QUIC client |
| `lib/storage/` | local storage abstraction |
| `test/` | widget/unit tests for terminal, trackpad, keyboard, VNC behavior |

## Setup

```bash
cd mobile
flutter pub get
```

## Run Checks

```bash
cd mobile && flutter test
cd mobile && flutter analyze
```

Wrapper scripts from repo root:

```bash
./scripts/flutter_test.sh
./scripts/flutter_analyze.sh
```

## Browser UI Smoke Check

```bash
cd mobile && flutter build web
cd mobile/build/web && python3 -m http.server 8030 --bind 127.0.0.1
```

## iOS Release Guardrail (RustDesk FFI)

```bash
cd mobile && flutter build ios --release --no-codesign
cd mobile && nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"
```

This prevents required FFI symbols from being dead-stripped in release builds.
