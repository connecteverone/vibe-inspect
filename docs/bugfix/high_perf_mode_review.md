# High Performance Mode Optimization

Date: 2026-02-01
Scope: Mobile VNC client + Desktop agent (VNC + ROI)

## Goals
- Make High Performance truly high throughput: target 5–10ms sampling.
- Avoid "line-by-line" refresh on large changes (tile-by-tile visible repaint).
- Keep memory stable during long-running ROI sessions.

## Verified Root Causes (before changes)
1) High Performance interval too large on mobile.
- UI range and default were 16–33ms or larger (mobile-side), which made high perf feel slower.

2) ROI tiles painted one-by-one on mobile.
- Each ROI tile triggered `setState`, producing visible incremental refresh (appears line-by-line).

3) ROI stream cadence limited by fixed sleep on desktop.
- ROI loop slept on a fixed interval, reducing tile refresh rate when zoomed.

4) ROI chunk buffers could grow without cleanup.
- Partial datagram buffers had no TTL.

5) Trackpad gesture parity gaps.
- Horizontal scrolling and pinch zoom were not wired end-to-end.

## Changes Applied

### Desktop agent (VNC + ROI)
- High Performance sampling clamp tightened to 5–10ms.
  - `desktop/src/vnc.rs`: `DEFAULT_HIGH_PERF_FRAME_INTERVAL_MS = 10`, min/max 5..10.
- Capture loop backpressure to avoid queue saturation.
  - `desktop/src/vnc.rs`: adaptive `send_backoff_ms` added.
- Frame update queue size increased to 4.
  - `desktop/src/vnc.rs`: `mpsc::channel::<FrameUpdate>(4)`.
- Horizontal scroll support via Shift + wheel fallback.
  - `desktop/src/vnc.rs`: masks 0x40/0x80 map to Shift+scroll.
- ROI loop cadence/budget made adaptive by zoom.
  - `desktop/src/quic/mod.rs`: `resolve_roi_interval`, `resolve_roi_budget` tuned.
- ROI tile order prioritized from center-out to reduce visible scanlines.
  - `desktop/src/roi/tiles.rs`: tile coords sorted by distance to viewport center.

### Mobile client (VNC + ROI)
- High Performance interval range changed to 5–10ms.
  - `mobile/lib/main.dart`: `_highPerfIntervalMs = 10`, slider min/max 5..10.
- Trackpad pinch zoom support + debounce commit.
  - `mobile/lib/main.dart`: `_handleTrackpadPanZoomUpdate` updates zoom.
- Horizontal scrolling support (client + server mask).
  - `mobile/lib/main.dart`: `_handleScrollDelta` uses dx + dy.
  - `mobile/lib/vnc_client.dart`: `sendScroll` accepts deltaX/deltaY.
- ROI batching to avoid per-tile repaint.
  - `mobile/lib/main.dart`: pending tile buffer + 16ms batch flush.
- ROI cache capacity is now adaptive to zoom.
  - `mobile/lib/main.dart`: `_roiCacheLimit()`.
- ROI chunk buffer TTL + max buffer cap.
  - `mobile/lib/roi/roi_client.dart`: cleanup with TTL and capacity.

## Expected Behavior After Changes
- High Performance targets 5–10ms sampling without falling behind; backpressure prevents runaway CPU.
- Large-screen changes no longer repaint strictly top-to-bottom; ROI updates appear more concurrent.
- Trackpad gestures (horizontal scroll + pinch zoom) work end-to-end.
- ROI memory usage stabilizes over time.

## Follow-up (optional)
- Add explicit metrics in debug panel: dropped frames, ROI tile rate, backpressure state.
- Consider configurable ROI tile size for large viewports.

