# VNC High Performance Review

Date: 2026-02-01
Scope: VNC module only (mobile client + desktop agent)

## Verified Issues (confirmed in code before changes)
1) Desktop high-perf forced full-frame updates when idle.
- File: `desktop/src/vnc.rs`
- Impact: high CPU/bandwidth and lower effective FPS during high-perf mode.

2) Desktop frame channel too small and no backpressure on send failures.
- File: `desktop/src/vnc.rs`
- Impact: dropped updates + wasted capture work under load, hurting 5-10ms targets.

3) Desktop ignored horizontal scroll mask bits (0x40/0x80).
- File: `desktop/src/vnc.rs`
- Impact: horizontal trackpad scrolling had no effect.

4) Mobile VNC client API mismatch for scroll.
- File: `mobile/lib/vnc_client.dart` vs `mobile/lib/main.dart`
- Impact: `sendScroll` expected `delta`, call site passed `deltaX/deltaY` (compile/runtime break).

5) Mobile horizontal scroll path incomplete.
- Files: `mobile/lib/vnc_client.dart`, `mobile/lib/main.dart`
- Impact: horizontal scroll deltas were generated but never sent to server.

6) Mobile Tight-JPEG batching dropped frames when updates overlapped.
- File: `mobile/lib/vnc_client.dart`
- Impact: only the latest update ID would trigger `onFrame`; if a newer update arrived before earlier JPEGs decoded, some rectangles would never render, appearing as missing blocks.

7) Trackpad hover events were ignored (fullscreen + landscape).
- File: `mobile/lib/main.dart`
- Impact: hardware trackpad/mouse movement does not emit PointerMove unless pressed, so cursor never moves when using hover-only input.

8) Fullscreen landscape touch input behaved like a relative trackpad.
- File: `mobile/lib/main.dart`
- Impact: users may expect absolute positioning when touching the screen, but trackpad semantics were preserved.
9) Fullscreen landscape zoom changes did not reset trackpad pointer state.
- File: `mobile/lib/main.dart`
- Impact: after dragging the zoom bar, any stale pointer tracking state could block subsequent cursor moves until a full reset (symptom: cursor stops moving).

## Changes Applied

### Desktop (agent)
- High-perf capture loop now uses `min(active_interval, high_perf_interval)`.
- Removed idle full-frame pushes in high-perf; keepalives are empty updates only.
- Added lightweight send backoff when the frame channel is full.
- Increased frame channel size from 2 to 4.
- Added horizontal scroll handling (mask 0x40/0x80 -> `mouse_scroll_x`).

### Mobile (client)
- Updated `sendScroll` API to accept `deltaX/deltaY`.
- Emit both vertical (0x10/0x20) and horizontal (0x40/0x80) wheel masks.
- Track pending Tight-JPEG decode per framebuffer update (map of counts), so every update that finishes triggers a frame render even when updates overlap.
- Handle PointerHover events for trackpad/mouse movement so fullscreen landscape works with external trackpads.
- Fullscreen landscape overlay now uses `Listener(behavior: opaque)` and `GestureDetector(behavior: opaque)` so the transparent overlay reliably receives touch events.
- After zoom bar commits in fullscreen landscape, schedule a pointer reset to clear stale trackpad state before the next cursor move.
- (Reverted) Do not override fullscreen landscape touch into absolute positioning because it breaks the on-screen trackpad; keep relative trackpad semantics.

## Verified As Already Present
- Tight JPEG rect batching (single onFrame after all JPEG rects in a framebuffer update), which prevents line-by-line repaint on large JPEG updates.

## Plan / Follow-ups
1) Validate horizontal scroll direction mapping on macOS/Windows/Linux.
2) Add debug counters for dropped frames/backoff to tune 5-10ms behavior.
3) Benchmark CPU/bandwidth with high-perf on/off across ZRLE/Tight/Zlib.
