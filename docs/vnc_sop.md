# VNC SOP

## Goals
- Keep image quality lossless while improving bandwidth efficiency.
- Prefer compression/encodings that are widely supported by VNC clients and servers.
- Fail safe to Raw encoding on compatibility issues.

## Encoding Negotiation
- Client advertises preferred encodings in order: ZRLE, Tight, Zlib, CopyRect, Raw.
- Server selects the first supported encoding in the list.
- Only send encodings explicitly requested by the client.
- Compression level pseudo-encodings: `-256` to `-247` (Tight compression 0-9).
- Quality level pseudo-encodings: `-32` to `-23` (Tight JPEG quality 0-9).

## Compression Settings
- Zlib compression is lossless; quality is unchanged.
- Tight compression levels follow the client pseudo-encoding request (0-9).
- Tight JPEG is optional and only used when explicitly enabled by client.

## Change Detection
- Send full-frame on first update or when client requests non-incremental update.
- Otherwise, compute the smallest bounding rectangle that changed.
- If the update looks like a vertical scroll and the client supports CopyRect, send a CopyRect + exposed strip update.
- If the changed area is large (>= 85% of screen), send full-frame to reduce overhead.

## Compatibility Matrix
- Supported encodings: Raw, Zlib, CopyRect, ZRLE, Tight (lossless), Tight JPEG (optional).
- Unsupported encodings: Hextile.
- If unsupported encoding is negotiated, fall back to Raw.

## Error Handling & Recovery
- Client validates rectangle bounds and payload lengths before applying updates.
- Client closes the session if it receives invalid rectangles or decode errors.
- Server respects incremental vs full update requests.
- On HiDPI displays, map input coordinates to the logical input space (e.g., macOS Retina).
- Optional overrides: set `VNC_INPUT_SCALE`, `VNC_INPUT_SCALE_X`, `VNC_INPUT_SCALE_Y` if cursor alignment is off.
- Optional offsets for multi-monitor or unusual coordinates: `VNC_INPUT_OFFSET_X`, `VNC_INPUT_OFFSET_Y`.

## Operational Checklist
- Verify that client and server agree on encodings after handshake.
- Confirm that zlib frames decode successfully on mobile and web targets.
- Monitor frame rate and bandwidth during real use.
- If compression introduces latency, reduce compression level or fall back to Raw.

## Troubleshooting
- Black frame or frozen image: ensure first update is full-frame.
- Frequent disconnects: inspect WebSocket stability and client/server logs.
- High bandwidth: verify Zlib is selected and change detection is enabled.
