# Remote v2 (QUIC-only) Architecture

## Goals
- QUIC-only transport. No WS.
- Low latency; drop backlog.
- ROI zoom is in *screen native* coordinates; input stays in *framebuffer* coordinates.
- VNC/RustDesk remain optional (feature-flag), not default.

## Layers
1) Transport (QUIC)
- Control stream (bi-directional): auth, capabilities, ROI, input, stats.
- Video stream (uni or bi): encoded frames only.
- Optional stats stream (uni): server->client perf.

2) Media (capture/encode/decode)
- Capture: platform native (macOS: ScreenCaptureKit/CGDisplayStream; Windows: DXGI; Linux: X11/Wayland).
- Convert: RGBA -> NV12/I420 (libyuv).
- Encode: hwcodec (H264 baseline default); fallback software. Raw RGBA + zlib for bring-up.
- Decode: iOS VideoToolbox / Android MediaCodec / desktop ffmpeg.

3) Input & ROI
- Input mapping uses framebuffer size.
- ROI uses screen native size; cursor-centered zoom.
- ROI change triggers keyframe + new display meta.

## Protocol (v2)
### Control messages (CBOR or protobuf)
- `hello` {client_id, client_name, version}
- `auth` {session_id, token, auth_token?}
- `ready` {server_caps, codec_caps, display_info[]}
- `roi_set` {display, x, y, w, h, scale}
- `roi_ack` {display, seq}
- `input` {type, payload}
- `refresh` {display}
- `stats` {rtt_ms, decode_ms, queue_ms, fps}

### Video frame header (binary)
```
magic(2) = 0x56 0x32  // "V2"
version(1)
flags(1)  // keyframe, has_roi, zlib
seq(4)
timestamp_ms(8)
codec(1)  // 1=h264,2=h265,3=av1
width(2)
height(2)
roi_x(2)
roi_y(2)
roi_w(2)
roi_h(2)
payload_len(4)
```
Payload: raw RGBA (optionally zlib) or Annex-B NAL units (H264 baseline).

## Scheduling
- Capture -> encode -> send runs on dedicated threads.
- Only latest frame kept (bounded channel size 1).
- If encoder busy, drop intermediate frames.
- Force IDR on ROI change / refresh.

## Observability
- Per-frame timestamps server->client.
- Debug counters: capture ms, encode ms, send queue depth, decode ms.

## Rollout
- Keep VNC and RustDesk as optional engines.
- Default path: QUIC Media v2.
- Feature flags in mobile & desktop to switch.
