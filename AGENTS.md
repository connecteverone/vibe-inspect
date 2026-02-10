# AGENTS

## Verification
- `cd mobile && flutter test`
- `cd mobile && flutter analyze`
- `./scripts/flutter_test.sh`
- `./scripts/flutter_analyze.sh`
## Browser UI Check
- `cd mobile && flutter build web`
- `cd mobile/build/web && python3 -m http.server 8030 --bind 127.0.0.1`

## iOS FFI Symbol Guardrail
- RustDesk iOS bridge uses `DynamicLibrary.process().lookup(...)`; release dead-strip can remove required C ABI symbols.
- When changing RustDesk FFI symbols or iOS linker flags, keep `OTHER_LDFLAGS[sdk=iphoneos*]` symbol keep-list aligned for Debug/Release/Profile.
- Before shipping iOS release, verify symbols are retained:
  - `cd mobile && flutter build ios --release --no-codesign`
  - `cd mobile && nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"`
- Reference: `docs/remote_rustdesk_integration.md` section `iOS FFI symbol retention guardrail`.
