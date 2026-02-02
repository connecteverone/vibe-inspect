# VNC over QUIC - fast path design notes

Goal: design a QUIC-based remote desktop transport with aggressive latency/quality tradeoffs and an upgrade path from VNC/RFB.

Status: research notes + initial architecture sketch.
Current implementation (as of 2026-02-02): base VNC/RFB runs over WebSocket/TCP; QUIC is used for ROI tiles and an experimental VNC-over-QUIC stream (client falls back to WS if QUIC fails).

## Why QUIC (quick recap)
- QUIC provides encrypted, multiplexed streams with low-latency setup and supports connection migration. See RFC 9000 and RFC 9001.
- QUIC DATAGRAMs (RFC 9221) allow unreliable delivery inside the same QUIC connection, which is a good fit for time-sensitive video and input.
- HTTP/3 (RFC 9114) and WebTransport enable a browser client path if needed.

## Research summary (papers and specs)

### QUIC specs and extensions
- RFC 9000: QUIC transport (streams, multiplexing, migration).
  https://www.rfc-editor.org/rfc/rfc9000
- RFC 9001: QUIC TLS 1.3 handshake.
  https://www.rfc-editor.org/rfc/rfc9001
- RFC 9002: QUIC loss detection and congestion control.
  https://www.rfc-editor.org/rfc/rfc9002
- RFC 9221: QUIC DATAGRAM extension for unreliable delivery.
  https://www.rfc-editor.org/rfc/rfc9221
- RFC 9114: HTTP/3 over QUIC.
  https://www.rfc-editor.org/rfc/rfc9114
- W3C WebTransport (draft): browser API for streams + datagrams over HTTP/3.
  https://www.w3.org/TR/webtransport/

### Media over QUIC / real-time media on QUIC
- Media over QUIC Transport (MoQ): working group drafts for low-latency media delivery over QUIC/WebTransport.
  https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport
- RTP over QUIC (RoQ): RTP/RTCP encapsulation over QUIC with real-time congestion control considerations.
  https://datatracker.ietf.org/doc/html/draft-ietf-avtcore-rtp-over-quic
- Perkins & Ott: Real-time audio-visual media transport over QUIC (TUM entry).
  https://portal.fis.tum.de/en/publications/real-time-audio-visual-media-transport-over-quic/
- Engelbart & Ott: Congestion control for real-time media over QUIC (TUM entry).
  https://portal.fis.tum.de/en/publications/congestion-control-for-real-time-media-over-quic/

### Screen updates over QUIC (VNC-adjacent)
- Eghbal & Lu (2025): Lower-Latency Screen Updates over QUIC with FEC (VNC rectangles, partial ordering).
  https://www.mdpi.com/1999-5903/17/7/297

### Related remote desktop / low-latency transports (non-QUIC but relevant ideas)
- Microsoft RDP-UDP: reliable + unreliable modes plus FEC (RDPEUDP spec).
  https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeudp/fe211d97-92dd-47e6-8fa3-b23f2c1a5af9
- Microsoft RDP-UDP2: UDP transport for A/V with rate control (RDPEUDP2 spec).
  https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeudp2/9db34630-e880-4bfd-9d8d-50bc044c3288
- PCoIP overview: UDP transport with selective reliability for different data types.
  https://anyware.hp.com/web-help/pcoip/session_planning_guide/2023.06/
- RDP Shortpath: UDP transport with TCP fallback (Azure Virtual Desktop doc).
  https://learn.microsoft.com/es-es/azure/virtual-desktop/rdp-shortpath

## Open-source projects to study (protocols and implementations)

### VNC/RFB stack
- LibVNCServer/LibVNCClient (C libraries for VNC/RFB).
  https://github.com/LibVNC/libvncserver
- TigerVNC (high-performance VNC client/server).
  https://github.com/TigerVNC/tigervnc
- noVNC (browser VNC client, supports H.264 VNC encoding).
  https://github.com/novnc/noVNC

### Remote desktop / streaming (non-QUIC but useful ideas)
- RustDesk (open source remote desktop, peer-to-peer + relay model).
  https://github.com/rustdesk/rustdesk
- FreeRDP (RDP client/library).
  https://github.com/FreeRDP/FreeRDP
- Apache Guacamole (clientless gateway for VNC/RDP/SSH).
  https://guacamole.apache.org/
- Sunshine (self-hosted game streaming server).
  https://github.com/LizardByte/Sunshine
- Moonlight clients and core library (GameStream protocol).
  https://github.com/moonlight-stream

### Commercial precedent: QUIC in remote desktop
- Splashtop supports end-to-end QUIC connections (best-effort, with fallback).
  https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/9305390384923-Enable-end-to-end-QUIC-connection

### QUIC stacks to evaluate
- MsQuic (C, cross-platform, performance-focused).
  https://github.com/microsoft/msquic
- quiche (Rust/C API, Cloudflare).
  https://github.com/cloudflare/quiche
- ngtcp2 (C/C++, IETF QUIC).
  https://github.com/ngtcp2/ngtcp2
- mvfst (C++, Meta/Facebook).
  https://github.com/facebook/mvfst
- lsquic (C, LiteSpeed).
  https://github.com/litespeedtech/lsquic
- quic-go (Go, production-ready).
  https://github.com/quic-go/quic-go
- aioquic (Python).
  https://github.com/aiortc/aioquic
- picoquic (C).
  https://github.com/private-octopus/picoquic

## Benchmarking + stack selection (notes)

### Benchmarks to use
Goal: separate "compatibility/feature coverage" from "performance under controlled loss".

- QUIC Interop Runner (best for compatibility + feature coverage).
  https://interop.isc.heia-fr.ch/
  https://github.com/quic-interop/quic-interop-runner
- QUIC Network Simulator (best for performance under controlled loss/RTT/bw).
  https://github.com/quic-interop/quic-network-simulator
- Implementation-specific dashboards (trend tracking; not cross-impl).
  https://microsoft.github.io/msquic/detailed.html

Recommendation:
- Use Interop Runner to verify Quinn’s protocol compatibility and extensions.
- Use QUIC Network Simulator to compare latency/jitter under loss for ROI + VNC streams.
- Add a local VNC/ROI micro-benchmark (FPS, encode latency, input-to-photon) for regressions.

### Candidate stacks (shortlist)
- MsQuic: performance focused; QUIC DATAGRAM support; official Windows/Linux support.
  https://microsoft.github.io/msquic/msquicdocs/docs/API.html
  https://learn.microsoft.com/en-us/gaming/gdk/docs/features/console/networking/game-mesh/msquic-intro-networking
  https://microsoft.github.io/msquic/msquicdocs/docs/Release.html
- quic-go: production-ready; QUIC extensions incl. RFC 9221; HTTP/3 + HTTP Datagrams; WebTransport; note current DATAGRAM path is not optimized for high throughput.
  https://quic-go.net/
  https://quic-go.net/docs/quic/
  https://quic-go.net/docs/http3/
  https://quic-go.net/docs/http3/datagrams/
  https://quic-go.net/docs/webtransport/
  https://quic-go.net/docs/quic/datagrams/
- ngtcp2 + nghttp3: C transport with QUIC DATAGRAM extension; HTTP/3 + QPACK and SETTINGS_H3_DATAGRAM; optional AVX2.
  https://github.com/ngtcp2/ngtcp2
  https://github.com/ngtcp2/nghttp3
- lsquic: C stack; HTTP/3 + QUIC extensions including RFC 9221.
  https://fossies.org/dox/lsquic-4.3.0/index.html
- quiche: QUIC transport + HTTP/3; widely deployed in Cloudflare's edge.
  https://github.com/cloudflare/quiche

### Rust-first stack recommendation (desktop/client)
Given a Rust desktop stack, prioritize Rust-native QUIC libraries and only drop to C/C++ if you need a very specific feature or performance characteristic.

- Quinn (default pick for Rust desktop): pure Rust; async-friendly; supports application-layer datagrams; tested on Linux/macOS/Windows.
  https://github.com/quinn-rs/quinn
  https://quinn-rs.github.io/quinn/quinn.html
- s2n-quic (performance-focused Rust, Linux-leaning): Rust QUIC from AWS; supports Linux/macOS/Windows but Linux requires kernel >= 5.0 for GSO; datagram support is present behind an unstable provider feature.
  https://github.com/aws/s2n-quic
  https://docs.rs/crate/s2n-quic/latest/features
- quiche (Rust API over a C core): low-level QUIC + HTTP/3; strong performance heritage (Cloudflare) but integration is lower-level and less Rust-native than Quinn.
  https://docs.quic.tech/quiche/
  https://docs.quic.tech/quiche/h3/index.html
- neqo (Mozilla, Rust): used by Firefox; server is explicitly described as experimental and not optimized for production use.
  https://github.com/mozilla/neqo

If you need HTTP/3 on top of a Rust QUIC transport, the `h3` crate supports multiple QUIC implementations (Quinn, s2n-quic, MsQuic).
  https://lib.rs/crates/h3
  https://lib.rs/crates/h3-quinn

If you need browser-compatible WebTransport in Rust (for a web client or gateway), `wtransport` and `web_transport_quinn` wrap Quinn and expose streams + datagrams.
  https://docs.rs/wtransport
  https://docs.rs/web-transport-quinn/latest/web_transport_quinn/index.html

### Decision: use Quinn (Rust)
We are standardizing on Quinn for both desktop and mobile QUIC transport.
- Desktop already uses Quinn for ROI QUIC: `desktop/src/quic/mod.rs`
- Mobile QUIC client uses `flutter_quic`, which wraps Quinn: `mobile/third_party/flutter_quic/README.md`

## What we did NOT find
- No widely used or actively maintained open-source project that explicitly implements "VNC over QUIC" or "RFB over QUIC" showed up in the initial survey (as of 2026-02-02). There may be private implementations or small prototypes; worth a deeper search later.

## Code inventory (relevant to QUIC + VNC + ROI)

### Desktop (agent)
- VNC input mapping + mouse injection: `desktop/src/vnc.rs` (see `handle_pointer_event`).
- ROI QUIC server (datagrams + zlib): `desktop/src/quic/mod.rs`.
- ROI session metadata + tokens: `desktop/src/roi/session.rs`.
- ROI tiling + cache: `desktop/src/roi/tiles.rs`.
- ROI command wiring / port selection: `desktop/src/server.rs`, `desktop/src/pairing.rs`.

### Mobile (client)
- VNC RFB client (WebSocket transport): `mobile/lib/vnc_client.dart`.
- VNC QUIC transport (VNC-over-QUIC stream): `mobile/lib/vnc/vnc_quic_transport.dart`.
- ROI QUIC client + datagram reassembly: `mobile/lib/roi/roi_quic_client.dart`,
  `mobile/lib/roi/roi_client.dart`, `mobile/lib/roi/roi_protocol.dart`.
- Zoom/ROI policy + trackpad input mapping: `mobile/lib/vnc/vnc_session_roi.dart`,
  `mobile/lib/vnc/vnc_session_input.dart`.
- Cursor rendering offset tests: `mobile/test/vnc_canvas_offset_test.dart`.

## Architecture options

### Option A: "RFB over QUIC" (least invasive)
- Keep RFB/VNC semantics.
- Map RFB message types onto QUIC streams (reliable) + QUIC DATAGRAMs (unreliable) for visual updates.
- Pros: faster compatibility with existing VNC servers/clients.
- Cons: RFB message format is not tuned for video; still needs heavy optimization for high FPS / high motion.

### Option B: "New protocol + VNC gateway" (best performance)
- Build a new QUIC-based protocol optimized for remote desktop + game streaming.
- Provide a VNC gateway that translates RFB to the new protocol for backward compatibility.
- Pros: highest performance potential; can design for ROI, codecs, partial reliability.
- Cons: more engineering effort and more surface area.

### Option C: "Browser first" (WebTransport)
- Use WebTransport (HTTP/3) for web clients.
- Keep the same transport semantics (streams + datagrams) but route through browser APIs.
- Pros: zero-install client.
- Cons: browser constraints, server complexity.

## Proposed fast path protocol design (sketch)

### Connection layout (single QUIC connection)
- Control stream (reliable): session setup, auth, capability negotiation, QoS feedback, keyframe requests.
- Input stream (reliable, low-latency): keyboard/mouse/controller events; allow event coalescing.
- Clipboard + file transfer stream (reliable).
- Video plane (unreliable): QUIC DATAGRAMs carrying encoded video frames or frame chunks.
- Audio plane (unreliable or reliable depending on user settings).

### Datagram plan (VNC fast path)
Goal: move framebuffer updates (and future codecs) onto QUIC DATAGRAMs while keeping
input/control reliable and low-latency.

Planned datagram channels:
- `video_delta`: inter-frame updates (drop on loss).
- `video_keyframe`: keyframes or intra blocks (higher priority).
- `roi_tile`: ROI tiles (current design already uses this for magnifier).

Datagram header v1 (little-endian unless noted):
```
offset  size  field
0       4     magic "VQC1"
4       1     version
5       1     channel (video_delta=1, video_keyframe=2, roi_tile=3)
6       1     flags (bitfield: keyframe, compressed, has_fec, ...)
7       1     codec (raw=0, zlib=1, tight=2, h264=3, h265=4, av1=5)
8       4     seq (u32)
12      4     frame_id (u32)
16      2     chunk_index (u16)
18      2     chunk_count (u16)
20      2     payload_len (u16)
22      N     payload bytes
```

Rules:
- Keep datagrams <= `connection.max_datagram_size()` (default 1200) to avoid IP fragmentation.
- Chunk large frames; drop incomplete delta frames, request keyframe via control stream.
- Backpressure handling: if `send_datagram` blocks, reduce bitrate/quality or drop updates.

### Reliability policy
- Use unreliable delivery for video (drop late packets, avoid head-of-line blocking).
- Retransmit only keyframe metadata or critical control frames.
- Optional FEC for keyframe chunks or small blocks (inspired by RDP-UDP FEC).

### Scheduling and prioritization
- Input events are highest priority. Avoid starvation by reserving bandwidth.
- Video is adaptive: drop frames when queue grows, never increase latency to chase loss.
- Consider multiple datagram priorities: keyframe > delta > auxiliary.

### Congestion control + rate adaptation
- Use QUIC loss/CC baseline (RFC 9002) but allow pluggable CC (CUBIC/BBR-like or delay-based).
- Tie encoder bitrate to CC feedback + app-level latency budget.
- Use short target queues (1-2 frames) for interactive mode.

### Encoding/compression strategy
- Prefer hardware encoders: H.264 baseline for compatibility, H.265/AV1 optional.
- ROI: higher quality on cursor region or changed rectangles.
- Use adaptive resolution / dynamic scaling under loss or high RTT.
- Consider splitting into tiles for parallel encode and selective update.

### Backward compatibility
- Build a VNC gateway that accepts RFB and emits the new QUIC protocol.
- Keep a "legacy" mode that maps RFB messages over reliable QUIC streams only.

## Non-regression requirements (must keep behavior identical)

### Virtual trackpad + input semantics (mobile)
- Trackpad surface moves cursor (relative movement). See `_movePointerBy` and `_setPointerPosition` in `mobile/lib/vnc/vnc_session_input.dart`.
- Fast double tap on the virtual trackpad sends left-click (`_handleTrackpadPointerUp` -> `_sendClick(1)` in `mobile/lib/vnc/vnc_session_input.dart`).
- Trackpad click bar remains (left/right button hold). See `_buildTrackpadClickBar` in `mobile/lib/vnc/vnc_session_ui.dart`.
- Pointer calibration & drift controls must remain intact.

### ROI magnifier behavior (mobile + desktop)
- ROI is used to keep zoomed content sharp when VNC stream is lower resolution.
- ROI session is activated only when zoom > `_roiZoomThreshold` and disabled below it.
- ROI transport is QUIC DATAGRAMs; decoding expects ROI1 header and optional zlib.
- Must preserve ROI request frequency and cache behavior to avoid stutter.

### Layout/modes (mobile)
- Non-fullscreen mode.
- Fullscreen + portrait.
- Fullscreen + landscape (with overlay controls + trackpad).

### Desktop input mapping
- The VNC pointer coordinates must keep the current scaling/calibration path in
  `desktop/src/vnc.rs` (`handle_pointer_event`).

## Behavior freeze + cross-reference map
This section is the safety net for refactors. Every item below must be preserved
exactly; if it changes, update this doc and the acceptance tests together.

### Input + cursor (mobile -> desktop)
- Invariant: trackpad moves cursor by relative delta and sends VNC pointer events.
  - Mobile: `_movePointerBy`, `_setPointerPosition`, `_sendPointerEvent` in `mobile/lib/vnc/vnc_session_input.dart`.
  - Desktop: `handle_pointer_event` in `desktop/src/vnc.rs`.
- Invariant: double-tap on the virtual trackpad triggers left-click.
  - Mobile: `_handleTrackpadPointerUp` -> `_sendClick(1)` in `mobile/lib/vnc/vnc_session_input.dart`.
  - Fullscreen landscape overlay also triggers double-tap via `onDoubleTap` in `mobile/lib/vnc/vnc_session_ui.dart`.
- Invariant: trackpad click bar holds left/right buttons (press/hold/release).
  - Mobile: `_buildTrackpadClickBar` in `mobile/lib/vnc/vnc_session_ui.dart`.

### ROI magnifier (visual-only)
- Invariant: ROI is only a visual overlay and never changes input mapping.
  - Mobile: `_sendPointerEvent` uses `_frameSize` and calibration only in `mobile/lib/vnc/vnc_session_input.dart`.
  - Desktop: `handle_pointer_event` uses session logical sizes.
- Invariant: ROI session only active when zoom > `_roiZoomThreshold`.
  - Mobile: `_applyRoiZoomPolicy` in `mobile/lib/vnc/vnc_session_roi.dart`.
- Invariant: ROI tiles use ROI1 header + optional zlib, reassembled client-side.
  - Desktop: `send_tile_datagrams` in `desktop/src/quic/mod.rs`.
  - Mobile: `decodeRoiDatagram` in `mobile/lib/roi/roi_protocol.dart`.

### ROI control stream (JSON)
- Invariant: length-prefixed JSON framing (4-byte big-endian length).
  - Desktop: `read_json_message` / `send_json_message` in `desktop/src/quic/mod.rs`.
  - Mobile: `_sendControl` / `_readReady` in `mobile/lib/roi/roi_quic_client.dart`.
- Invariant: `RoiHello`, `RoiReady`, `RoiRequest` field sets are stable.
  - See protocol contract section below.

### Layout modes (mobile)
- Invariant: non-fullscreen, fullscreen portrait, fullscreen landscape all work.
  - Mobile: `_buildVncCanvas`, `_buildFullscreenPortrait`, `_buildFullscreenLandscape`.

### Error surfaces (ROI)
- ROI command errors originate in `desktop/src/server.rs` (`invalid_payload`,
  `missing_payload`, `unsupported_action`).
- ROI port errors originate in `desktop/src/pairing.rs` / `desktop/src/server.rs`
  (`roi_quic_port_busy`, `roi_quic_port_unavailable`).
- Mobile surfaces ROI errors via `_presentAgentFailure` (`mobile/lib/vnc/vnc_widgets.dart`)
  and `_roiLastError` (`mobile/lib/vnc/vnc_session_roi.dart`);
  ROI failures must not block base VNC.

## Implementation plan (phased)

### Phase 0: research + prototype
- Pick a QUIC library and build a packet echo with streams + DATAGRAM.
- Implement a minimal VNC gateway that forwards raw frames over QUIC DATAGRAM.
- Create a latency test harness: synthetic frames, loss emulation, RTT control.

### Phase 0.5: baseline datagram bench
- Add QUIC datagram echo benchmark (local) with RTT/loss stats.
- Add pressure script to compare p50/p95/p99 latency under load.

### Phase 1: video fast path
- Add H.264 encode/decode pipeline (hardware when available).
- Implement frame chunking and keyframe management.
- Add app-level loss recovery for keyframes only.

### Phase 2: adaptive control
- Implement rate controller: use RTT, loss, and queue length.
- Implement ROI and tile-based updates.
- Add configurable quality profiles (low latency vs. high quality).

### Phase 3: browser client
- Integrate WebTransport in a web client.
- Implement bridging between native QUIC and WebTransport sessions.

## Compatibility checklist (pre-merge)
- Trackpad double-tap -> left-click still works.
- Trackpad cursor movement still updates remote pointer with no drift.
- ROI only activates when zoom > threshold; no ROI traffic at default zoom.
- ROI tiles render sharply during zoom (no blur regression).
- Non-fullscreen + fullscreen portrait + fullscreen landscape all render controls and inputs.
- VNC QUIC fallback to WebSocket works on handshake errors and timeouts.

## Acceptance tests (manual)
Run these after any transport/protocol/refactor work to ensure the required behaviors still pass.

### Input + trackpad
- Open VNC session in non-fullscreen mode.
- Move on-screen trackpad -> cursor moves on remote (relative motion).
- Double-tap on trackpad surface -> left-click on remote (verify click pulse).
- Trackpad click bar left/right -> button hold/release works.
- External mouse/trackpad hover (desktop/mobile) still moves cursor when enabled.

### ROI + zoom clarity
- At default zoom (<= _roiZoomThreshold): ROI is not connected, no ROI tiles.
- Zoom in (> _roiZoomThreshold): ROI session starts; tiles render crisp detail.
- Zoom reset to default: ROI session stops; base stream continues.
- Induce ROI failure (disable QUIC port): app stays responsive, base VNC still works.
- Induce VNC QUIC failure: client falls back to WebSocket and continues streaming.

### Layout modes
- Non-fullscreen mode: trackpad and zoom controls present and functional.
- Fullscreen portrait: trackpad visible; zoom bar works; input OK.
- Fullscreen landscape: overlay controls + trackpad surface work; input OK.

### Cursor drift
- Run existing tests: `mobile/test/vnc_canvas_offset_test.dart` ensures cursor offsets stay within tolerance.

## Protocol contracts (authoritative)

### Schema source files (single source of truth)
- Desktop QUIC protocol: `desktop/src/quic/protocol.rs`
- Desktop ROI error codes: `desktop/src/roi/errors.rs`
- Mobile ROI protocol: `mobile/lib/roi/roi_protocol.dart`
- Mobile ROI errors: `mobile/lib/roi/roi_errors.dart`
- Mobile ROI models: `mobile/lib/roi/roi_models.dart`
- Mobile VNC QUIC transport: `mobile/lib/vnc/vnc_quic_transport.dart`
- Mobile VNC datagrams: `mobile/lib/vnc/vnc_datagram.dart`
- VNC session metadata: `desktop/src/server.rs` (payload), `mobile/lib/app/agent_models.dart`

### ROI QUIC control stream (JSON over length-prefixed stream)
Encoding: 4-byte big-endian length prefix + JSON payload.

- Client -> Server: `RoiHello`
```json
{
  "session_id": "roi-session-id",
  "token": "opaque-token"
}
```

- Server -> Client: `RoiReady`
```json
{
  "status": "ready",
  "session_id": "roi-session-id",
  "max_datagram_size": 1232,
  "quic_port": 4242,
  "display_index": 0,
  "framebuffer_width": 1920,
  "framebuffer_height": 1080,
  "screen_width": 1920,
  "screen_height": 1080
}
```

- Client -> Server: `RoiRequest`
```json
{
  "center_x": 960.0,
  "center_y": 540.0,
  "zoom": 1.5,
  "viewport_width": 1280.0,
  "viewport_height": 720.0,
  "prefetch_radius": 420.0
}
```

Source of truth: `desktop/src/quic/mod.rs`, `mobile/lib/roi/roi_quic_client.dart`.

### ROI QUIC datagrams (binary)
Header layout (little-endian unless noted). Size = 28 bytes.

```
offset  size  field
0       4     magic ASCII "ROI1"
4       4     frame_id (u32)
8       2     logical_x (u16)
10      2     logical_y (u16)
12      2     logical_w (u16)
14      2     logical_h (u16)
16      2     pixel_w (u16)
18      2     pixel_h (u16)
20      1     scale_level (u8)
21      1     codec (u8) 0=raw, 1=zlib
22      2     chunk_index (u16)
24      2     chunk_count (u16)
26      2     payload_len (u16)
28      N     payload bytes
```

Source of truth: `desktop/src/quic/mod.rs` (writer), `mobile/lib/roi/roi_protocol.dart` (reader).

### VNC QUIC control stream (JSON over length-prefixed stream)
Encoding: 4-byte big-endian length prefix + JSON payload. Handshake + input/control
stay on the QUIC stream; framebuffer updates are sent via QUIC DATAGRAMs (no stream fallback).

Note: the current implementation reuses the ROI QUIC port for VNC (`quic_port` in the
VNC start payload maps to `roi_quic_port` in pairing state).

- Client -> Server: `VncHello`
```json
{
  "type": "vnc",
  "session_id": "vnc-session-id",
  "token": "opaque-token",
  "auth_token": "agent-token",
  "client_id": "optional-client-id",
  "client_name": "optional-client-name"
}
```

- Server -> Client: `VncReady`
```json
{
  "status": "ready",
  "session_id": "vnc-session-id"
}
```

- Server -> Client (error): `VncError`
```json
{
  "status": "error",
  "code": "unauthorized",
  "message": "Missing or invalid agent token.",
  "retry_after": 1234567890
}
```

Source of truth: `desktop/src/quic/protocol.rs`, `desktop/src/quic/mod.rs`,
`mobile/lib/vnc/vnc_quic_transport.dart`.

### VNC QUIC datagrams (framebuffer updates)
Header layout (little-endian unless noted). Size = 22 bytes.

```
offset  size  field
0       4     magic ASCII "VQC1"
4       1     version (1)
5       1     channel (1=video_delta, 2=video_keyframe, 3=roi_tile)
6       1     flags (bitfield: keyframe, compressed, has_fec)
7       1     codec (0=rfb, 1=zlib, 2=tight, 3=h264, 4=h265, 5=av1)
8       4     seq (u32)
12      4     frame_id (u32)
16      2     chunk_index (u16)
18      2     chunk_count (u16)
20      2     payload_len (u16)
22      N     payload bytes
```

Reassembly:
- Receiver buffers chunks per `(seq, frame_id, channel)` and emits payload only when complete.
- Incomplete frames are dropped (no stream fallback).

Source of truth: `desktop/src/quic/protocol.rs`,
`desktop/src/vnc.rs` (sender),
`mobile/lib/vnc/vnc_datagram.dart` (decoder/reassembly).

### VNC (RFB over QUIC or WebSocket)
- Mobile VNC prefers QUIC when available; it falls back to WebSocket on failure.
- QUIC: control/input over stream, framebuffer updates over datagrams.
- WebSocket: all RFB bytes on the WS stream.
- Coordinate mapping and button masks must remain unchanged.
Source of truth: `mobile/lib/vnc_client.dart`, `desktop/src/vnc.rs`.

## Data flow (end-to-end)
1) Mobile receives VNC frames via QUIC if available; otherwise WebSocket (RFB).
2) When zoom > `_roiZoomThreshold`, mobile starts ROI QUIC session.
3) Desktop ROI QUIC server streams tiles as QUIC DATAGRAMs.
4) Mobile reassembles tiles, decodes (zlib if needed), renders ROI overlay.
5) Trackpad input -> pointer calibration -> VNC pointer events.

## Error model and handling

### Error categories
- Transport: QUIC/UDP errors, disconnects, timeouts.
- Protocol: invalid/missing fields, unexpected sizes, unsupported codec.
- Session: invalid token, unknown session id, ROI session not started.
- Resource: port unavailable, capture init failure, decoding failure.

### Error payloads (agent -> mobile)
Existing ROI-related error codes (from desktop):
- `roi_quic_port_busy`
- `roi_quic_port_unavailable`

VNC QUIC control errors (from desktop):
- `unauthorized` (missing/invalid auth token)
- `rate_limited` (too many invalid tokens)
- `client_blocked` (client disabled)
- `state_locked` (pairing state unavailable)
- `invalid_session` (bad session id/token)

### Handling strategy
- Never crash on bad ROI datagrams; drop and continue.
- On ROI timeout (>4s since last tile), schedule reconnect.
- If ROI fails, fall back to base VNC stream without blocking input.
- All errors must surface a user-friendly message and log a structured error.

## Benchmarks + pressure scripts (local)
Local micro-bench is implemented in `desktop/src/bin/quic_bench.rs`.

Scripts:
- `scripts/quic_bench.sh`: single-server + single-client baseline.
- `scripts/quic_pressure.sh`: multi-connection pressure defaults.

Metrics:
- `sent/recv/loss`: datagram loss ratio.
- `rtt_us`: p50/p95/p99 latency (microseconds).
- `recv_mbps`: approximate throughput on the receive side.

### Network emulation (loss/RTT/jitter)
Template script: `scripts/netem_template.sh`

Linux (tc netem):
- `ACTION=apply IFACE=eth0 LOSS=1% RTT_MS=30 JITTER_MS=5 ./scripts/netem_template.sh`
- `ACTION=clear IFACE=eth0 ./scripts/netem_template.sh`

macOS (dummynet template):
- `./scripts/netem_template.sh` (prints commands to run manually with `sudo`)

## Architecture + maintainability rules (hard requirements)
- No single file should exceed a few thousand lines. Split by domain.
- Modules must have clear ownership and minimal coupling.
- Protocols must have a single source of truth (schema + encoder/decoder).
- All public structs/enums must be documented with intent and invariants.
- Error types are structured; no stringly-typed error handling.

### Refactors in progress (file size limits)
- `mobile/lib/main.dart` now delegates to parts (no single giant file):
  - VNC parts:
    - `mobile/lib/vnc/vnc_session_screen.dart` (session state + build)
    - `mobile/lib/vnc/vnc_session_input.dart` (pointer/trackpad + input)
    - `mobile/lib/vnc/vnc_session_roi.dart` (ROI session + tiles)
    - `mobile/lib/vnc/vnc_session_ui.dart` (dialogs + UI helpers)
    - `mobile/lib/vnc/vnc_widgets.dart` (VNC widgets)
  - App parts:
    - `mobile/lib/app/pairing.dart`
    - `mobile/lib/app/qr_scanner.dart`
    - `mobile/lib/app/agent_workspace.dart`
    - `mobile/lib/app/api_explorer.dart`
    - `mobile/lib/app/terminal_workspace.dart`
    - `mobile/lib/app/terminal_workspace_logic.dart`
    - `mobile/lib/app/terminal_workspace_stream.dart`
    - `mobile/lib/app/terminal_session.dart`
    - `mobile/lib/app/agent_models.dart`
- Desktop QUIC/ROI stays in `desktop/src/quic` and `desktop/src/roi`.

## Documentation consistency checklist
- Protocol fields and types match the code definitions above.
- Any change to ROI datagram format updates both Rust writer and Dart reader.
- Any change to zoom/ROI policy updates both `mobile/lib/vnc/vnc_session_roi.dart` and this doc.
- Any new error code is added to the error table + user-facing message map.

## Metrics to track
- End-to-end input latency (p50/p95).
- Video frame latency and jitter.
- Effective bitrate vs. target bitrate.
- Frame drop rate, keyframe recovery time.
- CPU/GPU usage on both ends.

## Open questions
- Do we need partial reliability beyond QUIC DATAGRAM (e.g., partial frame retransmit)?
- How much of RFB semantics should be preserved vs. replaced?
- What is the minimum viable subset for a prototype demo?
- Browser client scope: full fidelity or limited to admin use?
