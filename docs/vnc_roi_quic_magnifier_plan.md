# VNC ROI Magnifier over QUIC DATAGRAM - Technical Plan

## 0. Summary
We will implement a dual-channel streaming architecture:
- **Base layer**: existing VNC over WebSocket/TCP (low-res full frame).
- **ROI layer**: high-res **Region of Interest (ROI)** tiles delivered over **QUIC DATAGRAM** (UDP semantics).

User experience:
- When zooming, the UI immediately performs local scale of the base layer.
- As ROI tiles arrive, they replace the scaled pixels for crisp detail.
- Continuous (infinite) zoom supported; ROI only improves fidelity, not coordinate mapping.

This plan is designed for correctness of input mapping, high perceived responsiveness, and scalability across macOS/Windows/Android/iOS.

## 0.1 Implementation Status (as of 2026-01-31)
- Desktop agent: QUIC server is live, ROI sessions are validated, tiles are captured from the native display, chunked, and sent via QUIC DATAGRAM (`ROI1` header).
- Desktop agent: QUIC endpoint is created inside the Tokio runtime, logs ROI start/ready/request/close, and reports the actual bound port (including ephemeral fallback). Auto-restart is disabled while sessions are active to avoid ROI drops.
- Mobile app: QUIC DATAGRAM client implemented via `flutter_quic` (FRB + Quinn). ROI control stream and datagram receive path are wired; overlay pipeline is active.
- Mobile app: ROI send stream is retained after writes (prevents immediate QUIC close). ROI requests fire immediately after connect and when view size is unknown a frame-size fallback is used.
- Zoom UX: continuous zoom slider is enabled; when zoom > 1.01 the base layer uses `FilterQuality.none` to reduce blur.
- iOS: `flutter_quic` is vendored and uses a global Tokio runtime for stability.

### Dev/Test Notes
- `ROI_FAKE_CAPTURE=1` forces the agent to use a synthetic frame (no screen-capture permission required). Used by `quic::tests::quic_roi_handshake_and_datagram`.
- Use ROI logs to validate lifecycle: `ROI start`, `ROI QUIC accepted/hello/ready`, `ROI request`, `ROI QUIC closed`.

## 0.2 Recent Stability Fixes (2026-01-31)
- Fixed ROI QUIC send stream lifetime on mobile so the server does not close immediately after handshake.
- Added ROI lifecycle logs on desktop for diagnosis and verification.
- Removed server auto-restart during active sessions to prevent VNC/ROI disconnect loops.
- Ensured QUIC port updates propagate when the server binds to an ephemeral port.

## 1. Context From Current Code (Local Inspection)
### Desktop Agent (Rust)
- VNC session uses WebSocket `/vnc/{session_id}` (TCP).
- Capture path uses `scrap::Capturer` to read **native screen pixels**, then **scales to session.width/height** if needed.
- Input mapping uses `session.width/height` to map pointer coordinates to real screen coordinates (critical).

Implication:
- **We must not change the logical framebuffer size to ROI**, or pointer mapping will drift.

### Mobile Client (Flutter)
- `_frameSize` from VNC handshake is the authoritative logical framebuffer size.
- Input mapping and pointer normalization rely on `_frameSize`.
- Current zoom is a local render transform (does not change server).

Implication:
- **ROI is a visual overlay only**. Pointer mapping must remain based on VNC framebuffer size.

## 2. Goals
- Sharp text when zoomed in (true pixels from agent).
- Continuous zoom (no discrete stops required).
- Low latency in ROI refresh (loss-tolerant).
- Maintain correct cursor mapping (no drift).
- Architected with clean modules and clear abstractions.

## 3. Non-Goals
- Replace VNC with a new protocol end-to-end.
- Lossy compression for ROI (initially).
- Server-driven UI; this remains client-side composition.

## 4. Constraints & Invariants
- Logical framebuffer size must remain **full screen resolution** for input correctness.
- ROI overlay **must not** change coordinate mapping.
- ROI transport is **loss-tolerant** and **non-blocking**.
- No blocking dependency on ROI; base VNC must remain functional alone.

## 5. High-Level Architecture
```
Mobile
 ├─ VNC Client (TCP) ............. Base layer (low-res full frame)
 └─ QUIC DATAGRAM Client ......... ROI tiles (high-res)

Desktop Agent
 ├─ VNC Server (TCP) ............. Existing
 └─ QUIC DATAGRAM Server ......... New ROI service
```

### Data Flow
1) Mobile requests VNC session as today.
2) Mobile requests ROI session via new command API:
   - receives QUIC endpoint + token
3) Mobile sends ROI requests (center, zoom, viewport, prefetch radius).
4) Agent sends ROI tiles via QUIC DATAGRAM.
5) Mobile overlays ROI tiles; if missing, falls back to base layer.

## 6. ROI Protocol Design

### 6.1 Control Plane (Reliable Stream on QUIC)
Use QUIC stream within the same connection for handshake and requests.

**ROI_START (client -> agent)**
- session_id
- vnc_session_id
- client_id
- desired_tile_size
- capabilities (lz4/zlib/raw)

**ROI_READY (agent -> client)**
- roi_session_id
- framebuffer_size (logical)
- screen_size (physical)
- max_datagram_size
- quic_port

**ROI_REQUEST (client -> agent)**
- center_x, center_y (logical framebuffer coords)
- zoom (float)
- viewport_w, viewport_h
- prefetch_radius
- priority_hint

**ROI_HINT (client -> agent)**
- velocity
- direction

### 6.2 Data Plane (QUIC DATAGRAM)
Each datagram carries **one tile or tile chunk**.

Header (fixed size, little-endian):
- roi_session_id (u64)
- frame_id (u32)
- tile_x (u16)
- tile_y (u16)
- tile_w (u16)
- tile_h (u16)
- scale_level (u8)  // typically 1 for native
- codec (u8)        // 0=raw,1=zlib,2=lz4
- chunk_index (u8)
- chunk_count (u8)
- payload_len (u16)

Payload:
- compressed tile pixels (BGRA or RGBX)

#### Implemented Header v1 (Code: `desktop/src/quic/mod.rs`)
Magic: `ROI1` (bytes 0..3), little-endian.

Fields (28 bytes total):
- magic: 4 bytes
- frame_id: u32
- logical_x: u16
- logical_y: u16
- logical_w: u16
- logical_h: u16
- pixel_w: u16
- pixel_h: u16
- scale_level: u8 (currently always 1)
- codec: u8 (0=raw, 1=zlib)
- chunk_index: u16
- chunk_count: u16
- payload_len: u16

Notes:
- `logical_*` are in framebuffer coordinates (VNC logical size).
- `pixel_*` are in native capture pixels (screen size).
- Chunks are reassembled client-side before decoding.

### 6.3 Datagram Sizing
- Must respect `max_datagram_size` reported by QUIC.
- If payload > max size, split into chunks with same tile header.

## 7. Tile Engine & Prefetch Strategy

### 7.1 Tile Grid
- Tile size: 64x64 or 128x128 (experiment-driven).
- Grid over **full logical framebuffer** (not ROI only).

### 7.2 Prefetch Rings
- ROI center is cursor position or viewport center.
- Preload tiles in concentric rings around center:
  - Ring0: immediate focus (highest priority)
  - Ring1: near ring (medium priority)
  - Ring2: far ring (low priority)

### 7.3 Change Detection
- Per-tile hash (XXH3/BLAKE3) to skip unchanged tiles.
- Only encode/send tiles whose hash changed or expired.

### 7.4 Scheduling
- Priority queue based on ring + movement direction.
- Budgeted per-frame tile send count.

## 8. Rendering Pipeline (Mobile)

Layered composition:
1) Base layer: VNC image (low-res)
2) ROI layer: tile overlay (high-res)

Rules:
- If ROI tile missing -> show base layer scaled.
- If ROI tile present -> overlay.
- Continuous zoom applies to both layers (ROI retains fidelity).

Coordinate mapping:
- All ROI tile positions are in **logical framebuffer space**.
- Pointer input is still computed from VNC framebuffer size.

## 9. Compression & Performance

- Raw: fastest, large bandwidth.
- Zlib: lossless, CPU heavy.
- LZ4: fast compression, moderate ratio.

Heuristic:
- Small tiles -> raw
- Large or busy tiles -> lz4/zlib

CPU budget:
- ROI encoding should be done in worker threads.
- Limit total encoding time per frame window.

## 10. Security & Auth

- QUIC uses TLS by default.
- ROI token must be short-lived and bound to client_id.
- Rate limits per client/session.

## 11. Code Architecture (Proposed)

### Desktop Agent (Rust)
```
desktop/src/vnc/
  capture.rs
  encode.rs
  input.rs
  session.rs

desktop/src/roi/
  roi_session.rs
  roi_tiles.rs
  roi_prefetch.rs
  roi_codec.rs

desktop/src/quic/
  quic_server.rs
  quic_protocol.rs
```

Key abstractions:
- `RoiSession`: handles ROI lifecycle, token, config
- `TileGrid`: maps framebuffer coords -> tile coords
- `TileScheduler`: selects tiles to send
- `DatagramEncoder`: packs tiles -> datagrams

### Mobile App (Flutter)
```
mobile/lib/vnc/
  vnc_client.dart
  vnc_renderer.dart
  input_mapper.dart

mobile/lib/roi/
  roi_client.dart
  roi_tile_cache.dart
  roi_renderer.dart
  roi_controller.dart

mobile/lib/zoom/
  zoom_controller.dart
```

Key abstractions:
- `RoiClient`: QUIC session + datagram parsing
- `RoiTileCache`: LRU + ring buffer
- `RoiRenderer`: custom painter / layer composition
- `ZoomController`: continuous slider + inertia

## 12. API Changes

Add new agent commands:
- `roi_start` -> returns QUIC endpoint + token
- `roi_stop`
- `roi_update` (optional)

## 13. Implementation Plan

### Phase 0: Feasibility (1-2 weeks)
- QUIC server on desktop, datagram echo
- Flutter FFI PoC (QUIC client) or plugin

### Phase 1: ROI Data Pipeline (2-4 weeks)
- Tile generation on desktop
- ROI overlay rendering on mobile
- Basic ROI request protocol

### Phase 2: Prefetch & Scheduling (2-3 weeks)
- Ring prefetch
- Directional priority
- Tile hash / diff

### Phase 3: Performance & Stability (2-4 weeks)
- Compression strategy
- Chunking for MTU
- Telemetry

### Phase 4: Productization (1-2 weeks)
- Feature flags
- Documentation and dev tools

## 14. Testing Strategy

Desktop:
- Unit tests for tile mapping, datagram packing
- Load test for encoding throughput

Mobile:
- Rendering correctness (tile overlay alignment)
- Input mapping validation (no cursor drift)

Network:
- Simulated packet loss and jitter
- MTU-size validation

## 15. Metrics & Observability
- ROI first tile latency
- ROI tile miss rate
- CPU encode time
- Bandwidth usage (base vs ROI)
- Datagram drop ratio

## 16. Open Questions
- Tile size (64 vs 128)
- Compression defaults (zlib vs lz4)
- QUIC client integration approach in Flutter (FFI vs plugin)
- Fallback plan if QUIC is blocked

---

This document is the baseline plan for implementing the ROI magnifier with QUIC DATAGRAM while preserving input correctness and maintaining modular architecture.
