use super::{RemoteBackend, RemoteBackendKind, RemoteCapabilities, RemoteQuicContext, RemoteSessionInfo, RemoteStartRequest, RemoteStatus};
use crate::remote_media::{protocol, FrameMeta, RoiRect, VideoCodec};
use crate::roi::RoiCapturer;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use enigo::{Enigo, MouseButton, MouseControllable};
use rand::{distributions::Alphanumeric, Rng};
use serde::Deserialize;
use std::collections::HashMap;
use std::io::Write;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Notify;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone)]
struct MediaSession {
    token: String,
    display_index: Option<usize>,
    width: Option<u32>,
    height: Option<u32>,
}

#[derive(Default)]
pub struct MediaBackend {
    running: bool,
    last_error: Option<String>,
    sessions: HashMap<String, MediaSession>,
}

impl MediaBackend {
    pub fn new() -> Self {
        Self {
            running: false,
            last_error: None,
            sessions: HashMap::new(),
        }
    }

    fn new_session_id(&self) -> String {
        let suffix: String = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(10)
            .map(char::from)
            .collect();
        format!("mv2-{suffix}")
    }

    fn new_token(&self) -> String {
        rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(12)
            .map(char::from)
            .collect()
    }
}

impl RemoteBackend for MediaBackend {
    fn kind(&self) -> RemoteBackendKind {
        RemoteBackendKind::MediaV2
    }

    fn capabilities(&self) -> RemoteCapabilities {
        RemoteCapabilities {
            h264: false,
            h265: false,
            av1: false,
            zero_copy: false,
        }
    }

    fn start(&mut self, request: RemoteStartRequest) -> Result<RemoteSessionInfo, String> {
        let session_id = self.new_session_id();
        let token = self.new_token();
        self.sessions.insert(
            session_id.clone(),
            MediaSession {
                token: token.clone(),
                display_index: request.display_index,
                width: request.width,
                height: request.height,
            },
        );
        self.running = true;
        self.last_error = None;
        Ok(RemoteSessionInfo {
            session_id,
            backend: RemoteBackendKind::MediaV2,
            connect_uri: None,
            token: Some(token),
            display_index: request.display_index,
            width: request.width,
            height: request.height,
            quic_port: None,
            codec_preference: None,
            hwcodec: Some(false),
            capabilities: Some(self.capabilities()),
        })
    }

    fn stop(&mut self, session_id: &str) -> Result<(), String> {
        self.sessions.remove(session_id);
        if self.sessions.is_empty() {
            self.running = false;
        }
        Ok(())
    }

    fn status(&self) -> RemoteStatus {
        RemoteStatus {
            backend: RemoteBackendKind::MediaV2,
            running: self.running,
            last_error: self.last_error.clone(),
        }
    }

    fn validate_session(&self, session_id: &str, token: &str) -> bool {
        self.sessions
            .get(session_id)
            .map(|session| session.token == token)
            .unwrap_or(false)
    }

    fn handle_quic_stream(
        &mut self,
        connection: quinn::Connection,
        mut send: quinn::SendStream,
        mut recv: quinn::RecvStream,
        context: RemoteQuicContext,
        _token: String,
    ) -> Result<(), String> {
        let connection = Arc::new(connection);
        let session = self
            .sessions
            .get(&context.session_id)
            .cloned()
            .ok_or_else(|| "session not found".to_string())?;

        if media_v2_debug_enabled() {
            eprintln!(
                "media_v2 session: id={} display={:?} fallback={}x{}",
                context.session_id,
                session.display_index,
                session.width.unwrap_or(1280),
                session.height.unwrap_or(720)
            );
        }

        let roi_state = Arc::new(Mutex::new(None::<RoiRect>));
        let roi_state_ctrl = roi_state.clone();

        let latest_frame = Arc::new(Mutex::new(None::<(FrameMeta, Option<RoiRect>, Vec<u8>)>));
        let notify_frame = Arc::new(Notify::new());
        let running = Arc::new(AtomicBool::new(true));

        let display_index = session.display_index;
        let fallback_width = session.width.unwrap_or(1280);
        let fallback_height = session.height.unwrap_or(720);

        let latest_frame_capture = Arc::clone(&latest_frame);
        let notify_capture = Arc::clone(&notify_frame);
        let running_capture = Arc::clone(&running);
        std::thread::spawn(move || {
            let mut capturer = match RoiCapturer::new(display_index, fallback_width, fallback_height) {
                Ok(c) => c,
                Err(err) => {
                    eprintln!("media_v2 capture init failed: {err}");
                    return;
                }
            };
            if media_v2_debug_enabled() {
                eprintln!(
                    "media_v2 capture ready: display={:?} fallback={}x{}",
                    display_index,
                    fallback_width,
                    fallback_height
                );
            }
            let mut seq: u32 = 0;
            let mut frames: u64 = 0;
            while running_capture.load(Ordering::Relaxed) {
                if !running_capture.load(Ordering::Relaxed) {
                    break;
                }
                if let Some(frame) = capturer.capture() {
                    frames += 1;
                    if media_v2_debug_enabled() {
                        if frames == 1 {
                            eprintln!(
                                "media_v2 first frame: {}x{} bytes={}",
                                frame.width,
                                frame.height,
                                frame.data.len()
                            );
                        } else if frames % 120 == 0 {
                            eprintln!("media_v2 capture frames={frames}");
                        }
                    }
                    let roi = roi_state.lock().ok().and_then(|guard| *guard);
                    let (data, width, height, roi_used): (
                        Vec<u8>,
                        usize,
                        usize,
                        Option<RoiRect>,
                    ) = if let Some(roi) = roi {
                        crop_rgba(&frame.data, frame.width, frame.height, roi)
                            .map(|data| (data, roi.w as usize, roi.h as usize, Some(roi)))
                            .unwrap_or((frame.data, frame.width, frame.height, None))
                    } else {
                        (frame.data, frame.width, frame.height, None)
                    };
                    let meta = FrameMeta {
                        seq,
                        timestamp_ms: now_millis(),
                        width: width.min(u16::MAX as usize) as u16,
                        height: height.min(u16::MAX as usize) as u16,
                        keyframe: true,
                    };
                    seq = seq.wrapping_add(1);
                    if let Ok(mut guard) = latest_frame_capture.lock() {
                        *guard = Some((meta, roi_used, data));
                    }
                    notify_capture.notify_one();
                } else {
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
        });

        let latest_frame_send = Arc::clone(&latest_frame);
        let notify_send = Arc::clone(&notify_frame);
        let running_send = Arc::clone(&running);
        let connection_for_send = Arc::clone(&connection);
        tokio::spawn(async move {
            let _connection = connection_for_send;
            let mut sent: u64 = 0;
            loop {
                notify_send.notified().await;
                if !running_send.load(Ordering::Relaxed) {
                    break;
                }
                loop {
                    let next = {
                        let mut guard = match latest_frame_send.lock() {
                            Ok(guard) => guard,
                            Err(_) => break,
                        };
                        guard.take()
                    };
                    let Some((meta, roi, data)) = next else { break };
                    let (payload, extra_flags) = compress_rgba_if_needed(&data);
                    let header = protocol::encode_header(
                        &meta,
                        VideoCodec::RawRgba,
                        roi,
                        payload.len() as u32,
                        extra_flags,
                    );
                    if send.write_all(&header).await.is_err() {
                        running_send.store(false, Ordering::Relaxed);
                        notify_send.notify_one();
                        return;
                    }
                    if send.write_all(&payload).await.is_err() {
                        running_send.store(false, Ordering::Relaxed);
                        notify_send.notify_one();
                        return;
                    }
                    if send.flush().await.is_err() {
                        running_send.store(false, Ordering::Relaxed);
                        notify_send.notify_one();
                        return;
                    }
                    sent += 1;
                    if media_v2_debug_enabled() {
                        if sent == 1 {
                            eprintln!("media_v2 first frame sent: bytes={}", payload.len());
                        } else if sent % 120 == 0 {
                            eprintln!("media_v2 sent frames={sent}");
                        }
                    }
                }
            }
        });

        let running_recv = Arc::clone(&running);
        let notify_recv = Arc::clone(&notify_frame);
        let connection_for_recv = Arc::clone(&connection);
        tokio::spawn(async move {
            let _connection = connection_for_recv;
            let mut buffer = Vec::new();
            loop {
                let mut len_buf = [0u8; 4];
                if recv.read_exact(&mut len_buf).await.is_err() {
                    break;
                }
                let len = u32::from_be_bytes(len_buf) as usize;
                if len == 0 {
                    continue;
                }
                buffer.resize(len, 0);
                if recv.read_exact(&mut buffer).await.is_err() {
                    break;
                }
                if let Ok(msg) = serde_json::from_slice::<ControlMessage>(&buffer) {
                    match msg.r#type.as_str() {
                        "roi_set" => {
                            if let Some(rect) = msg.roi_rect() {
                                if let Ok(mut guard) = roi_state_ctrl.lock() {
                                    *guard = Some(rect);
                                }
                                if media_v2_debug_enabled() {
                                    eprintln!(
                                        "media_v2 roi_set: x={} y={} w={} h={}",
                                        rect.x, rect.y, rect.w, rect.h
                                    );
                                }
                            }
                        }
                        "roi_clear" => {
                            if let Ok(mut guard) = roi_state_ctrl.lock() {
                                *guard = None;
                            }
                            if media_v2_debug_enabled() {
                                eprintln!("media_v2 roi_clear");
                            }
                        }
                        "mouse" => {
                            if let Some(event) = msg.mouse_event() {
                                if media_v2_debug_enabled() {
                                    eprintln!(
                                        "media_v2 mouse: action={} button={:?} x={} y={}",
                                        event.action, event.button, event.x, event.y
                                    );
                                }
                                handle_mouse_event(event, &roi_state_ctrl);
                            }
                        }
                        _ => {}
                    }
                }
            }
            running_recv.store(false, Ordering::Relaxed);
            notify_recv.notify_one();
        });

        Ok(())
    }
}

#[derive(Debug, Deserialize)]
struct ControlMessage {
    #[serde(rename = "type")]
    r#type: String,
    x: Option<i32>,
    y: Option<i32>,
    w: Option<i32>,
    h: Option<i32>,
    action: Option<String>,
    button: Option<String>,
}

impl ControlMessage {
    fn roi_rect(&self) -> Option<RoiRect> {
        let x = self.x?;
        let y = self.y?;
        let w = self.w?;
        let h = self.h?;
        if w <= 0 || h <= 0 {
            return None;
        }
        Some(RoiRect {
            x: x.max(0) as u16,
            y: y.max(0) as u16,
            w: w.max(1) as u16,
            h: h.max(1) as u16,
        })
    }

    fn mouse_event(&self) -> Option<MouseEvent> {
        let action = self.action.clone()?;
        let x = self.x?;
        let y = self.y?;
        Some(MouseEvent {
            action,
            button: self.button.clone(),
            x,
            y,
        })
    }
}

struct MouseEvent {
    action: String,
    button: Option<String>,
    x: i32,
    y: i32,
}

fn handle_mouse_event(event: MouseEvent, roi: &Arc<Mutex<Option<RoiRect>>>) {
    let mut enigo = Enigo::new();
    let (mut x, mut y) = (event.x as f64, event.y as f64);
    if let Ok(guard) = roi.lock() {
        if let Some(rect) = *guard {
            x += rect.x as f64;
            y += rect.y as f64;
        }
    }
    enigo.mouse_move_to(x.round() as i32, y.round() as i32);
    match event.action.as_str() {
        "down" => {
            if let Some(btn) = parse_button(event.button.as_deref()) {
                enigo.mouse_down(btn);
            }
        }
        "up" => {
            if let Some(btn) = parse_button(event.button.as_deref()) {
                enigo.mouse_up(btn);
            }
        }
        _ => {}
    }
}

fn parse_button(button: Option<&str>) -> Option<MouseButton> {
    match button.unwrap_or("left") {
        "left" => Some(MouseButton::Left),
        "right" => Some(MouseButton::Right),
        "middle" => Some(MouseButton::Middle),
        _ => None,
    }
}

fn crop_rgba(data: &[u8], width: usize, height: usize, roi: RoiRect) -> Option<Vec<u8>> {
    let roi_w = roi.w as usize;
    let roi_h = roi.h as usize;
    if roi_w == 0 || roi_h == 0 || width == 0 || height == 0 {
        return None;
    }
    let x = roi.x as usize;
    let y = roi.y as usize;
    if x + roi_w > width || y + roi_h > height {
        return None;
    }
    let mut out = vec![0u8; roi_w * roi_h * 4];
    let src_stride = width * 4;
    let dst_stride = roi_w * 4;
    for row in 0..roi_h {
        let src_start = (y + row) * src_stride + x * 4;
        let src_end = src_start + dst_stride;
        let dst_start = row * dst_stride;
        out[dst_start..dst_start + dst_stride].copy_from_slice(&data[src_start..src_end]);
    }
    Some(out)
}

fn compress_rgba_if_needed(data: &[u8]) -> (Vec<u8>, u8) {
    if !zlib_enabled() {
        return (data.to_vec(), 0);
    }
    if data.len() < 64 * 1024 {
        return (data.to_vec(), 0);
    }
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
    if encoder.write_all(data).is_err() {
        return (data.to_vec(), 0);
    }
    match encoder.finish() {
        Ok(payload) if payload.len() < data.len() => (payload, protocol::FLAG_ZLIB),
        _ => (data.to_vec(), 0),
    }
}

fn zlib_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| match std::env::var("MEDIA_V2_ZLIB") {
        Ok(value) => value != "0",
        Err(_) => true,
    })
}

fn media_v2_debug_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| match std::env::var("MEDIA_V2_DEBUG") {
        Ok(value) => value == "1" || value.eq_ignore_ascii_case("true"),
        Err(_) => false,
    })
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
