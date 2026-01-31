# ROI Alignment & Tear Fix Plan

## Summary
When zooming, ROI tiles sometimes drift or tear relative to the VNC base layer. A deep code audit shows the root cause is a deterministic coordinate mapping mismatch between the VNC scaler and the ROI tile inverse mapping, compounded by ROI request center drift and occasional framebuffer size desync. This document defines a deterministic, math-consistent fix and an implementation plan.

## Implementation Status (as of 2026-01-31)
- Phase 1: Completed (integer ceil inverse mapping + unit test)
- Phase 2: Completed (clamped ROI request center + ROI resync on framebuffer change)
- Phase 3: Completed (pixel-snap translation for zoomed rendering)

## Completion Checklist (Done)
- Desktop: ROI inverse mapping uses integer ceil math aligned with VNC sampling.
- Desktop: Unit test validates mapping correctness across multiple scale ratios.
- Mobile: ROI request center uses clamped render center.
- Mobile: ROI session resyncs on framebuffer size changes with debounce.
- Mobile: Zoomed rendering uses pixel-snapped translation to reduce shimmer.

## Problem Statement
- User-visible symptom: When zoomed, ROI tiles do not align with the VNC base, causing tearing or offsets, especially near edges.
- Constraints:
  - ROI tiles must overlay the VNC framebuffer without changing input mapping.
  - ROI must tolerate downscaled VNC streams and native-resolution ROI capture.
  - Solutions must be derived from the current local codebase and not assumptions.

## Evidence & Code Context (Local)
1) VNC scaler is nearest-neighbor, floor-based
- `desktop/src/vnc.rs::scale_bgra()`
  - Mapping: `src_x = x * src_width / dst_width` (integer division)
  - This defines the authoritative logical -> physical sampling rule.

2) ROI tiles map physical -> logical using floor + ceil + round
- `desktop/src/roi/tiles.rs::build_tiles()`
  - `logical_left = floor(x / scale_x)`
  - `logical_right = ceil((x + tile_w) / scale_x)`
  - `logical_w = round(logical_right - logical_left)`
- This is mathematically inconsistent with the VNC scaler’s floor mapping and can shift logical tile positions by 1px under non-integer scale ratios.

3) ROI request center differs from render center at edges
- `mobile/lib/main.dart::_sendRoiRequest()` uses `_cameraCenter`.
- Rendering uses `_clampedCameraCenter(viewSize)`.
- When clamping occurs (edge pans), ROI requests drift outside the visible camera center, producing offsets.

4) ROI session framebuffer size can diverge from actual frames
- `mobile/lib/main.dart::_handleFrame()` updates `_frameSize` and clears ROI cache but does not enforce ROI session consistency.
- When the VNC stream changes resolution (auto-resize or display changes), ROI can continue with stale framebuffer dimensions.

## Root Causes
1) **Deterministic math mismatch** between VNC floor sampling and ROI inverse mapping.
2) **Center drift** due to ROI requests using unclamped camera coordinates.
3) **Frame size desync** between ROI session info and actual frame size in edge cases.

## Fix Strategy (Deterministic & Root-Cause Oriented)
### A) Align ROI inverse mapping with VNC sampling (Primary fix)
- Replace float/round logic in `desktop/src/roi/tiles.rs` with integer ceil mapping consistent with `scale_bgra()`.
- For a physical pixel range `[x0, x1)`, logical bounds become:
  - `logical_left  = ceil(x0 * fb / phys)`
  - `logical_right = ceil(x1 * fb / phys)`
- This guarantees ROI tiles cover the exact logical pixels that VNC’s floor sampler references.

### B) Clamp ROI request center to render center
- Use `_clampedCameraCenter(viewSize)` in `_sendRoiRequest()`.
- Ensures the ROI capture window is centered exactly on what the user sees.

### C) Enforce ROI session framebuffer consistency on size changes
- When `_frameSize` changes, compare ROI session framebuffer size.
- If mismatch, restart ROI session with updated dimensions (debounced).
- Prevents persistent misalignment after VNC resize or display changes.

### D) (Optional) Pixel-snap ROI overlay (Secondary refinement)
- Snap ROI layer translation to device pixel boundaries to avoid sub-pixel jitter.
- Consider after A/B/C if any residual tearing persists.

## Implementation Plan
### Phase 1 — Correctness Foundations
1) Replace ROI inverse mapping math with integer ceil mapping.
2) Add a unit test for mapping correctness vs. VNC floor sampler.

### Phase 2 — Client Alignment
3) Clamp ROI request center to the render center.
4) Restart ROI session when framebuffer size changes (debounced).

### Phase 3 — Stability & Visual Refinement (Optional)
5) Pixel-snap ROI overlay translation if residual shimmer exists.

## Verification Plan
- **Unit Test**: Validate logical bounds computed from physical tiles match VNC sampling rule on multiple scale ratios.
- **Manual Validation**:
  - Zoom + pan to edges, verify ROI alignment with base.
  - Trigger VNC resize (rotate device, change zoom threshold) and verify ROI restarts with new framebuffer size.
- **Metrics/Logs**:
  - Log ROI session restart reason and new framebuffer size.
  - Capture before/after screenshots for QA.

## Risks & Mitigations
- Risk: ROI tile coverage off-by-one after change.
  - Mitigation: add unit test using exact integer mapping.
- Risk: Frequent ROI restarts on noisy size changes.
  - Mitigation: debounce restart (e.g., 250–500ms).

## Out of Scope
- Replacing the ROI protocol or stream transport.
- Changing VNC base rendering or input mapping semantics.

## Implementation Notes
- Ensure all math is integer-based and uses u64 to avoid overflow.
- Keep tile logical sizes >= 1 and clamped to framebuffer bounds.
- Preserve existing ROI cache behavior; invalidate only when sizes change.
