# VNC Input + ROI Context (2026-02-01)

## Summary
The mobile client treats the VNC framebuffer as the authoritative logical coordinate space for input, then uses ROI tiles as a visual-only overlay that follows the same camera/zoom math. The desktop agent maps incoming VNC pointer events from that logical framebuffer into OS coordinates using display/input calibration. ROI is delivered over QUIC on a fixed, configured port and should never alter input mapping or VNC framebuffer sizing. Recent fixes tightened ROI alignment (clamped request center, resync on size changes, pixel-snapped translation) and QUIC port enforcement; these are the most regression-sensitive paths.

## Files reviewed
- `mobile/lib/main.dart`
- `mobile/lib/vnc_client.dart`
- `mobile/lib/roi/roi_renderer.dart`
- `desktop/src/vnc.rs`
- `desktop/src/server.rs`
- `desktop/src/quic/mod.rs`

## Input pipeline (mobile -> desktop)
1) Pointer state is maintained in framebuffer space (`_frameSize`) and updated via trackpad/drag logic (`_setPointerPosition`). The pointer position is clamped to `_frameSize` and calibrated via `_applyInputCalibration` before being sent to the server.
2) `_sendPointerEvent` uses the calibrated pointer and sends `sendPointer(x, y, mask)` to `VncRfbClient`, then requests incremental frames. Input scaling is derived from `_frameSize` and calibration values, not ROI data.
3) `VncRfbClient` negotiates the VNC framebuffer size during handshake (`serverWidth`, `serverHeight`) and streams frames. The mobile side uses incoming frame sizes to keep `_frameSize` current, which drives the input coordinate limits.
4) On desktop, `handle_pointer_event` in `desktop/src/vnc.rs` scales the incoming VNC coordinates using the session’s logical `width`/`height` and maps them into the calibrated input space (`input_width`, `input_height`, `input_scale`, `input_origin`) before injecting OS mouse events.

## ROI pipeline (desktop -> mobile)
1) The mobile client starts an ROI session after VNC is established by sending a `roi` command with the VNC framebuffer dimensions (`framebufferWidth`, `framebufferHeight`) and screen size metadata.
2) The QUIC ROI server (`desktop/src/quic/mod.rs`) accepts a connection, validates the ROI session, and responds with `RoiReady`, including the authoritative framebuffer size and the configured QUIC port.
3) Mobile ROI requests (`_sendRoiRequest`) are driven by the same camera/zoom math as the VNC view: the center is clamped via `_clampedCameraCenter(viewSize)`, and the viewport is derived from `baseScale * zoom`. Requests include `center`, `zoom`, `viewportWidth`, `viewportHeight`, and `prefetchRadius`.
4) ROI tiles are rendered as an overlay (`RoiRenderer.paintTile`) using framebuffer coordinates and the same translation/scale used for the base VNC layer. This keeps ROI strictly visual and aligned to the framebuffer grid.
5) When the VNC framebuffer size changes, `_maybeResyncRoiForFrame` restarts the ROI session with updated dimensions to avoid mismatched ROI captures.

## Recent-fix-sensitive areas (avoid regressions)
- **ROI request center clamping**: `_sendRoiRequest` uses `_clampedCameraCenter` to prevent drift during edge pans; reverting to raw `_cameraCenter` causes visible offsets.
- **ROI resync on framebuffer changes**: `_handleFrame` triggers `_maybeResyncRoiForFrame` to keep ROI session dimensions aligned after VNC resize.
- **Pixel-snapped translation at zoom**: `_calculateTranslation` snaps translations to device pixels when zoomed to prevent shimmer between the base frame and ROI overlay.
- **Strict QUIC port binding**: `start_local_server` and `start_quic_server` fail if the configured ROI port cannot be bound (no fallback/auto-assign).
- **Logical framebuffer input mapping**: `handle_pointer_event` relies on the VNC session width/height; changes to `_frameSize` or session dimensions must preserve input correctness.

## Invariants (must hold)
- **Logical framebuffer size is authoritative for input**: pointer coordinates are scaled from the VNC framebuffer (`_frameSize` / `session.width`/`session.height`) and then calibrated. ROI dimensions never drive input.
- **ROI is visual-only**: ROI tiles are an overlay; they must not alter input scaling, session dimensions, or calibration.
- **Configured QUIC port only**: ROI QUIC must bind to the configured port; if the port is unavailable, startup fails and the client reports the configured port (no fallback to ephemeral ports).

## Scenario: zoom=2.0 + edge pan expected behavior
- User sets zoom to `2.0` and pans toward the right/bottom edge of the desktop.
- The camera center is clamped to the visible bounds (`_clampedCameraCenter`), and ROI requests use that same clamped center.
- The ROI viewport size is computed from the base scale and zoom; ROI tiles are painted using the same translation/scale as the VNC base layer.
- Result: ROI tiles align with the VNC base (no drift or tearing at the edge), and input remains mapped to the logical framebuffer even while the overlay updates.

## Validation intent (why this matters)
- These paths were recently tightened to prevent ROI drift and port misconfiguration; any changes should re-check the zoom+edge-pan case and ROI reconnect behavior after frame size changes.
- When touching these areas, re-run the standard Flutter tests/analysis and confirm the QUIC port behavior by starting the agent with a known ROI port.
