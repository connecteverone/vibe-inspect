# RustDesk Integration Context (2026-02-03)

This document captures the current integration assumptions and the minimal
scaffolding added to the codebase to support a RustDesk-backed remote engine.

## Scope
- PC: integrate RustDesk backend as the primary remote engine.
- Mobile: integrate a remote control UI that talks to the backend.
- Legacy VNC stays in the codebase but its entry is hidden by default.
- Transport constraint: QUIC-only (no WS) for remote-control data plane.

## License
- RustDesk is AGPL-3.0 (see `third_party/rustdesk/LICENCE`).
- Any direct code integration must comply with AGPL obligations.

## Current repo touchpoints
- HTTP command server: `desktop/src/server.rs`
- VNC stack: `desktop/src/vnc.rs`, `mobile/lib/vnc_client.dart`
- ROI QUIC: `desktop/src/roi`, `mobile/lib/roi`
- Mobile entry point: `mobile/lib/app/agent_workspace.dart`

## RustDesk code references (from submodule)
- Encoder selection: `third_party/rustdesk/src/server/video_service.rs`
- VRAM (texture) encoding: `third_party/rustdesk/libs/scrap/src/common/vram.rs`
- HW RAM encoder: `third_party/rustdesk/libs/scrap/src/common/hwcodec.rs`
- Android MediaCodec: `third_party/rustdesk/libs/scrap/src/common/mediacodec.rs`

## Current integration scaffolding
- Remote backend abstraction: `desktop/src/remote_engine/`
- RustDesk backend placeholder: `desktop/src/remote_engine/rustdesk.rs`
- Remote command endpoint: `desktop/src/server.rs` (`command=remote`)
- Mobile UI entry (remote): `mobile/lib/remote/remote_session_screen.dart`
- Legacy VNC entry gate: `kEnableLegacyVnc` (`mobile/lib/app/feature_flags.dart`)
- Mobile RustDesk bridge: `mobile/lib/remote/rustdesk_bridge.dart`
- RustDesk mobile QUIC bridge + C ABI: `third_party/rustdesk/src/quic_bridge.rs`
- RustDesk display sizing helper: `third_party/rustdesk/src/flutter.rs` (`session_get_display_size`)

## Integration strategy (QUIC-only)
1) Use RustDesk core in-process (do NOT spawn the rustdesk UI/service binaries).
2) Adapt QUIC streams to RustDesk's `hbb_common::Stream` by wrapping QUIC bi-streams in `FramedStream` (no WS).
3) Use RustDesk's `server::Connection::start` for host-side session logic over QUIC.
4) Mobile bridge uses RustDesk core via C ABI shims (avoid FRB version conflict with `flutter_quic`).

## Session flow (target)
1) Mobile calls `/command` with `remote.start`.
2) Desktop returns `session_id`, `backend`, and connect hints (RustDesk id + temporary password).
3) Mobile opens QUIC stream A → sends JSON `remote` hello → receives `ready`.
4) Mobile opens QUIC stream B → RustDesk protocol runs over stream B.
5) Desktop pushes video frames + input control through RustDesk `Connection` and `video_service`.

## Planned code touchpoints
- QUIC adapter: `third_party/rustdesk/libs/hbb_common/src/stream.rs`
- QUIC framing: new module in `third_party/rustdesk/libs/hbb_common/src/` (mirrors `tcp.rs`)
- Desktop host bridge: `desktop/src/remote_engine/rustdesk.rs`
- QUIC server plumbing: `desktop/src/quic/` (route RustDesk sessions)
- Mobile controller: `mobile/lib/remote/` + RustDesk C ABI bridge (`rustdesk_bridge.dart`)

## Risks / guardrails
- Avoid `rustdesk::start_server` in-process: it can call `std::process::exit`.
- Keep VNC unchanged; legacy path stays feature-gated.
- Keep ROI input mapping: ROI uses screen native coords; input uses framebuffer coords.

## Hardware codec (H264/H265) notes
- Build-time: RustDesk hwcodec relies on vcpkg-provided FFmpeg + libyuv/libvpx/aom.
- If you want H264/H265 hardware encoding, build with `--features rustdesk-hwcodec` and set `VCPKG_ROOT` to your vcpkg root (e.g. `/Users/mac/vcpkg`).
- Mobile hard-decode requirements:
  - Android: build RustDesk with `--features flutter,hwcodec,mediacodec` (MediaCodec required).
  - iOS: build RustDesk with `--features flutter,hwcodec` (VideoToolbox required).
- iOS hardware decode enablement:
  - `third_party/hwcodec` now compiles `cpp/common/platform/mac/mac.mm` for iOS.
  - `ffmpeg_ram::decode::available_decoders()` includes VideoToolbox entries on iOS.
  - `scrap::hwcodec::HwCodecConfig::get()` uses available decoders on iOS to prefer hardware.
  - `HwRamDecoder::try_get()` skips software fallback on iOS to enforce hardware decode only.
- Current blocker with ffmpeg 8.x + hwcodec:
  - `FF_PROFILE_H264_HIGH` / `FF_PROFILE_HEVC_MAIN` missing without including `libavcodec/avcodec.h`.
  - `AVFrame::key_frame` removed; use `AV_FRAME_FLAG_KEY` instead.
- To proceed, patch the `hwcodec` crate or pin ffmpeg to a compatible version.

## iOS FFI symbol retention guardrail

### Why this matters
- Dart uses `DynamicLibrary.process().lookup(...)` to bind RustDesk C ABI symbols.
- iOS release linking may dead-strip symbols that are not directly referenced by ObjC/Swift.
- Typical runtime symptom: `Failed to lookup symbol` (for example `rustdesk_set_direct_only`).

### Mandatory rules
1) Keep all RustDesk C ABI entrypoints in `Runner` `OTHER_LDFLAGS[sdk=iphoneos*]` with `-Wl,-u,_<symbol>`.
2) Update **Debug / Release / Profile** together; do not only change one build config.
3) When adding a new C ABI function used by Dart FFI, update two places in the same change:
   - iOS linker keep-list (`project.pbxproj`)
   - Dart lookup initialization (`mobile/lib/remote/rustdesk_bridge_native.dart`)
4) For non-critical / compatibility symbols, Dart must use guarded lookup (optional bind + fallback), not hard fail.

### Build-time verification (required)
```bash
cd mobile
flutter build ios --release --no-codesign
nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"
```

Pass criteria:
- `nm` output contains all required FFI symbols.
- Missing any required symbol is a release blocker.

### Regression checklist (PR review)
- [ ] `project.pbxproj` keep-list contains newly added FFI symbols.
- [ ] Dart bridge initializes new symbols (or guarded optional lookup if intended).
- [ ] iOS release build + `nm` symbol check recorded in PR notes.

## Next steps (immediate)
1) Add rustdesk dependency (path) + feature gate in desktop.
2) Wire host session start to `rustdesk::server::Connection::start`.
3) Implement mobile QUIC connect shim (C ABI) + RGBA pull loop.
4) Add input mapping (touch → RustDesk mouse JSON).
