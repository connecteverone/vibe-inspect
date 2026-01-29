use axum::extract::ws::{Message, WebSocket};
use enigo::{Enigo, KeyboardControllable, Key, MouseButton, MouseControllable};
use flate2::write::ZlibEncoder;
use flate2::Compression;
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use rfb_encodings::{PixelFormat, zrle::encode_zrle};
use scrap::{Capturer, Display};
use std::collections::HashMap;
use std::io::{ErrorKind, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use std::env;

const RFB_VERSION: &[u8] = b"RFB 003.008\n";
const VNC_NAME: &str = "Vibe Inspect Agent";
const MAX_FRAME_RATE_MS: u64 = 120;
const ENCODING_RAW: i32 = 0;
const ENCODING_COPYRECT: i32 = 1;
const ENCODING_ZLIB: i32 = 6;
const ENCODING_TIGHT: i32 = 7;
const ENCODING_ZRLE: i32 = 16;
const DIFF_FULL_THRESHOLD: f32 = 0.85;
const COPYRECT_MATCH_THRESHOLD: f32 = 0.92;
const ENCODING_COMPRESS_LEVEL_BASE: i32 = -256;
const ENCODING_QUALITY_LEVEL_BASE: i32 = -32;
const TIGHT_JPEG_MIN_AREA: usize = 20000;

#[derive(Clone)]
pub struct VncSessionInfo {
    pub session_id: String,
    pub token: String,
    pub ws_path: String,
    pub width: u32,
    pub height: u32,
    pub display_index: usize,
}

#[derive(Clone)]
pub struct VncDisplayInfo {
    pub index: usize,
    pub width: u32,
    pub height: u32,
    pub is_primary: bool,
}

#[derive(Clone)]
struct VncSession {
    token: String,
    width: u32,
    height: u32,
    screen_width: u32,
    screen_height: u32,
    input_width: u32,
    input_height: u32,
    input_origin_x: f64,
    input_origin_y: f64,
    display_index: usize,
}

#[derive(Clone, Debug)]
enum RectUpdate {
    Pixels { rect: Rect, data: Vec<u8> },
    CopyRect { rect: Rect, src_x: u16, src_y: u16 },
}

type FrameUpdate = Vec<RectUpdate>;

#[derive(Clone, Copy, Debug)]
struct EncodingPreferences {
    encoding: i32,
    tight_compression: u8,
    tight_quality: Option<u8>,
    allow_jpeg: bool,
    copyrect_supported: bool,
}

#[derive(Clone, Copy, Debug)]
struct Rect {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
}

pub struct VncManager {
    sessions: HashMap<String, VncSession>,
}

impl VncManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    pub fn start_session(
        &mut self,
        session_id: String,
        width: Option<u32>,
        height: Option<u32>,
        display_index: Option<usize>,
    ) -> Result<VncSessionInfo, String> {
        let (display, display_index) = resolve_display(display_index)?;
        let screen_width = display.width() as u32;
        let screen_height = display.height() as u32;
        let (input_width, input_height, input_origin_x, input_origin_y) =
            resolve_input_dimensions(screen_width, screen_height, Some(display_index));
        let (target_width, target_height) = resolve_target_dimensions(
            screen_width,
            screen_height,
            width,
            height,
        );
        let token = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(24)
            .map(char::from)
            .collect::<String>();
        let session = VncSession {
            token: token.clone(),
            width: target_width,
            height: target_height,
            screen_width,
            screen_height,
            input_width,
            input_height,
            input_origin_x,
            input_origin_y,
            display_index,
        };
        self.sessions.insert(session_id.clone(), session);
        Ok(VncSessionInfo {
            session_id: session_id.clone(),
            token,
            ws_path: format!("/vnc/{session_id}"),
            width: target_width,
            height: target_height,
            display_index,
        })
    }

    pub fn stop_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    fn get_session(&self, session_id: &str, token: &str) -> Option<VncSession> {
        self.sessions
            .get(session_id)
            .and_then(|session| if session.token == token { Some(session.clone()) } else { None })
    }
}

pub fn list_displays() -> Result<Vec<VncDisplayInfo>, String> {
    let displays = Display::all()
        .map_err(|error| format!("Unable to list displays: {error}"))?;
    let mut result = Vec::with_capacity(displays.len());
    for (index, display) in displays.into_iter().enumerate() {
        result.push(VncDisplayInfo {
            index,
            width: display.width() as u32,
            height: display.height() as u32,
            is_primary: index == 0,
        });
    }
    Ok(result)
}

fn resolve_display(display_index: Option<usize>) -> Result<(Display, usize), String> {
    if let Some(index) = display_index {
        let mut displays = Display::all()
            .map_err(|error| format!("Unable to list displays: {error}"))?;
        if index >= displays.len() {
            return Err(format!("Display index {index} is out of range."));
        }
        let display = displays.swap_remove(index);
        return Ok((display, index));
    }
    let display = Display::primary()
        .map_err(|error| format!("Unable to access primary display: {error}"))?;
    Ok((display, 0))
}

pub async fn serve_vnc_socket(
    socket: WebSocket,
    manager: Arc<Mutex<VncManager>>,
    session_id: String,
    token: String,
) {
    let session = {
        let manager = manager.lock().unwrap();
        manager.get_session(&session_id, &token)
    };

    let Some(session) = session else {
        let mut socket = socket;
        let _ = socket
            .send(Message::Close(None))
            .await;
        return;
    };

    if let Err(error) = run_vnc_session(socket, session).await {
        eprintln!("VNC session error: {error}");
    }
}

async fn run_vnc_session(socket: WebSocket, session: VncSession) -> Result<(), String> {
    let (mut sender, mut receiver) = socket.split();
    let mut buffer = Vec::new();

    sender
        .send(Message::Binary(RFB_VERSION.to_vec().into()))
        .await
        .map_err(|error| format!("Failed to send RFB version: {error}"))?;

    let client_version = read_exact(&mut receiver, &mut buffer, 12).await?;
    if client_version != RFB_VERSION {
        return Err("Unsupported RFB client version".to_string());
    }

    sender
        .send(Message::Binary(vec![1, 1].into()))
        .await
        .map_err(|error| format!("Failed to send security types: {error}"))?;

    let security_choice = read_exact(&mut receiver, &mut buffer, 1).await?;
    if security_choice[0] != 1 {
        return Err("Unsupported VNC security type".to_string());
    }

    sender
        .send(Message::Binary(vec![0, 0, 0, 0].into()))
        .await
        .map_err(|error| format!("Failed to send security result: {error}"))?;

    let _client_init = read_exact(&mut receiver, &mut buffer, 1).await?;

    let server_init = build_server_init(session.width, session.height);
    sender
        .send(Message::Binary(server_init.into()))
        .await
        .map_err(|error| format!("Failed to send server init: {error}"))?;

    let ready_for_updates = Arc::new(AtomicBool::new(false));
    let force_full = Arc::new(AtomicBool::new(true));
    let running = Arc::new(AtomicBool::new(true));
    let copyrect_supported = Arc::new(AtomicBool::new(false));
    let (frame_tx, mut frame_rx) = tokio::sync::mpsc::channel::<FrameUpdate>(2);
    let (input_tx, input_rx) = std::sync::mpsc::channel::<InputEvent>();
    let _capture_handle = spawn_capture_thread(
        session.clone(),
        ready_for_updates.clone(),
        force_full.clone(),
        running.clone(),
        copyrect_supported.clone(),
        frame_tx,
    );
    let _input_handle = spawn_input_thread(session.clone(), running.clone(), input_rx);
    let mut encoding_prefs = EncodingPreferences {
        encoding: ENCODING_ZLIB,
        tight_compression: 6,
        tight_quality: None,
        allow_jpeg: false,
        copyrect_supported: false,
    };

    loop {
        tokio::select! {
            Some(update) = frame_rx.recv() => {
                let message = build_framebuffer_update(update, &encoding_prefs)?;
                if sender.send(Message::Binary(message.into())).await.is_err() {
                    break;
                }
            }
            maybe_message = receiver.next() => {
                let Some(message) = maybe_message else {
                    break;
                };
                match message {
                    Ok(Message::Binary(data)) => {
                        buffer.extend_from_slice(&data);
                        while let Some(event) = parse_client_message(&mut buffer) {
                            match event {
                                ClientMessage::FramebufferUpdateRequest { incremental, .. } => {
                                    ready_for_updates.store(true, Ordering::SeqCst);
                                    if !incremental {
                                        force_full.store(true, Ordering::SeqCst);
                                    }
                                }
                                ClientMessage::PointerEvent { mask, x, y } => {
                                    let _ = input_tx.send(InputEvent::Pointer { mask, x, y });
                                }
                                ClientMessage::KeyEvent { down, keysym } => {
                                    let _ = input_tx.send(InputEvent::Key { down, keysym });
                                }
                                ClientMessage::SetEncodings { encodings } => {
                                    encoding_prefs = parse_encoding_preferences(&encodings);
                                    copyrect_supported.store(
                                        encoding_prefs.copyrect_supported,
                                        Ordering::Relaxed,
                                    );
                                }
                                ClientMessage::SetPixelFormat | ClientMessage::ClientCutText => {}
                            }
                        }
                    }
                    Ok(Message::Close(_)) => break,
                    Ok(Message::Ping(payload)) => {
                        let _ = sender.send(Message::Pong(payload)).await;
                    }
                    _ => {}
                }
            }
        }
    }

    running.store(false, Ordering::SeqCst);
    Ok(())
}

fn build_server_init(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(24 + VNC_NAME.len());
    bytes.extend_from_slice(&(width as u16).to_be_bytes());
    bytes.extend_from_slice(&(height as u16).to_be_bytes());
    bytes.extend_from_slice(&default_pixel_format());
    bytes.extend_from_slice(&(VNC_NAME.len() as u32).to_be_bytes());
    bytes.extend_from_slice(VNC_NAME.as_bytes());
    bytes
}

fn default_pixel_format() -> [u8; 16] {
    let mut format = [0u8; 16];
    format[0] = 32;
    format[1] = 24;
    format[2] = 0;
    format[3] = 1;
    format[4..6].copy_from_slice(&255u16.to_be_bytes());
    format[6..8].copy_from_slice(&255u16.to_be_bytes());
    format[8..10].copy_from_slice(&255u16.to_be_bytes());
    format[10] = 16;
    format[11] = 8;
    format[12] = 0;
    format
}

fn capture_frame(capturer: &mut Capturer, session: &VncSession) -> Option<Vec<u8>> {
    match capturer.frame() {
        Ok(frame) => {
            let stride = session.screen_width as usize * 4;
            let source = extract_frame(
                &frame,
                stride,
                session.screen_width as usize,
                session.screen_height as usize,
            );
            if session.width == session.screen_width && session.height == session.screen_height {
                Some(source)
            } else {
                Some(scale_bgra(
                    &source,
                    session.screen_width as usize,
                    session.screen_height as usize,
                    session.width as usize,
                    session.height as usize,
                ))
            }
        }
        Err(error) if error.kind() == ErrorKind::WouldBlock => None,
        Err(_) => None,
    }
}

fn extract_frame(frame: &[u8], stride: usize, width: usize, height: usize) -> Vec<u8> {
    let mut data = vec![0u8; width * height * 4];
    for y in 0..height {
        let src_start = y * stride;
        let dst_start = y * width * 4;
        let src_end = src_start + width * 4;
        data[dst_start..dst_start + width * 4]
            .copy_from_slice(&frame[src_start..src_end]);
    }
    data
}

fn scale_bgra(
    source: &[u8],
    src_width: usize,
    src_height: usize,
    dst_width: usize,
    dst_height: usize,
) -> Vec<u8> {
    let mut output = vec![0u8; dst_width * dst_height * 4];
    for y in 0..dst_height {
        let src_y = y * src_height / dst_height;
        for x in 0..dst_width {
            let src_x = x * src_width / dst_width;
            let src_index = (src_y * src_width + src_x) * 4;
            let dst_index = (y * dst_width + x) * 4;
            output[dst_index..dst_index + 4]
                .copy_from_slice(&source[src_index..src_index + 4]);
        }
    }
    output
}

fn build_full_update(frame: &[u8], width: usize, height: usize) -> FrameUpdate {
    vec![RectUpdate::Pixels {
        rect: Rect {
            x: 0,
            y: 0,
            width: width as u16,
            height: height as u16,
        },
        data: frame.to_vec(),
    }]
}

fn build_diff_update(
    current: &[u8],
    previous: &[u8],
    width: usize,
    height: usize,
    allow_copyrect: bool,
) -> Option<FrameUpdate> {
    let rect = diff_rect(current, previous, width, height)?;
    let full_area = width * height;
    let rect_area = rect.width as usize * rect.height as usize;
    if full_area == 0 {
        return None;
    }
    if allow_copyrect && rect_area > 0 && (rect_area as f32) / (full_area as f32) >= 0.5 {
        if let Some(dy) = detect_vertical_scroll(current, previous, width, height) {
            let abs_dy = dy.abs() as usize;
            if abs_dy > 0 && abs_dy < height {
                let overlap_height = height - abs_dy;
                let overlap_rect = Rect {
                    x: 0,
                    y: if dy > 0 { abs_dy as u16 } else { 0 },
                    width: width as u16,
                    height: overlap_height as u16,
                };
                let src_y = if dy > 0 { 0 } else { abs_dy as u16 };
                let mut updates = Vec::with_capacity(2);
                updates.push(RectUpdate::CopyRect {
                    rect: overlap_rect,
                    src_x: 0,
                    src_y,
                });
                let exposed_rect = Rect {
                    x: 0,
                    y: if dy > 0 { 0 } else { overlap_height as u16 },
                    width: width as u16,
                    height: abs_dy as u16,
                };
                let data = extract_rect(current, width, exposed_rect);
                updates.push(RectUpdate::Pixels {
                    rect: exposed_rect,
                    data,
                });
                return Some(updates);
            }
        }
    }
    if full_area > 0 && (rect_area as f32) / (full_area as f32) >= DIFF_FULL_THRESHOLD {
        return Some(build_full_update(current, width, height));
    }
    let data = extract_rect(current, width, rect);
    Some(vec![RectUpdate::Pixels { rect, data }])
}

fn diff_rect(current: &[u8], previous: &[u8], width: usize, height: usize) -> Option<Rect> {
    if width == 0 || height == 0 {
        return None;
    }
    let mut min_x = width;
    let mut min_y = height;
    let mut max_x = 0usize;
    let mut max_y = 0usize;
    let mut changed = false;
    for y in 0..height {
        for x in 0..width {
            let idx = (y * width + x) * 4;
            if current[idx..idx + 4] != previous[idx..idx + 4] {
                changed = true;
                min_x = min_x.min(x);
                min_y = min_y.min(y);
                max_x = max_x.max(x);
                max_y = max_y.max(y);
            }
        }
    }
    if !changed {
        return None;
    }
    Some(Rect {
        x: min_x as u16,
        y: min_y as u16,
        width: (max_x - min_x + 1) as u16,
        height: (max_y - min_y + 1) as u16,
    })
}

fn extract_rect(data: &[u8], full_width: usize, rect: Rect) -> Vec<u8> {
    let rect_width = rect.width as usize;
    let rect_height = rect.height as usize;
    let bytes_per_pixel = 4;
    let mut output = vec![0u8; rect_width * rect_height * bytes_per_pixel];
    let src_stride = full_width * bytes_per_pixel;
    let dst_stride = rect_width * bytes_per_pixel;
    for row in 0..rect_height {
        let src_start =
            (rect.y as usize + row) * src_stride + rect.x as usize * bytes_per_pixel;
        let dst_start = row * dst_stride;
        output[dst_start..dst_start + dst_stride]
            .copy_from_slice(&data[src_start..src_start + dst_stride]);
    }
    output
}

fn encode_tight_rect(
    data: &[u8],
    width: u16,
    height: u16,
    compression: u8,
    quality: Option<u8>,
    allow_jpeg: bool,
) -> Result<Vec<u8>, String> {
    let pixel_count = width as usize * height as usize;
    let rgb = bgra_to_rgb(data);
    let reset_mask = 0x01;
    if allow_jpeg && quality.is_some() && pixel_count >= TIGHT_JPEG_MIN_AREA {
        if let Ok(jpeg_data) = encode_jpeg_rgb(&rgb, width, height, quality.unwrap()) {
            let mut buf = Vec::with_capacity(4 + jpeg_data.len());
            buf.push(0x90 | reset_mask);
            write_compact_length(&mut buf, jpeg_data.len());
            buf.extend_from_slice(&jpeg_data);
            return Ok(buf);
        }
    }

    let mut buf = Vec::new();
    if rgb.len() < 12 {
        buf.push(0x00 | reset_mask);
        buf.extend_from_slice(&rgb);
        return Ok(buf);
    }

    let payload = compress_zlib_level(&rgb, compression).unwrap_or(rgb);
    buf.push(0x00 | reset_mask);
    write_compact_length(&mut buf, payload.len());
    buf.extend_from_slice(&payload);
    Ok(buf)
}

fn bgra_to_rgb(data: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(data.len() / 4 * 3);
    for chunk in data.chunks_exact(4) {
        rgb.push(chunk[0]);
        rgb.push(chunk[1]);
        rgb.push(chunk[2]);
    }
    rgb
}

fn encode_jpeg_rgb(
    rgb: &[u8],
    width: u16,
    height: u16,
    quality: u8,
) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    let mapped_quality = (10 + (quality.min(9) as u16) * 9).min(100) as u8;
    let mut encoder = jpeg_encoder::Encoder::new(&mut output, mapped_quality);
    encoder
        .encode(rgb, width, height, jpeg_encoder::ColorType::Rgb)
        .map_err(|error| format!("Failed to encode JPEG: {error}"))?;
    Ok(output)
}

fn write_compact_length(buf: &mut Vec<u8>, mut length: usize) {
    loop {
        let mut byte = (length & 0x7f) as u8;
        length >>= 7;
        if length > 0 {
            byte |= 0x80;
        }
        buf.push(byte);
        if length == 0 {
            break;
        }
    }
}

fn detect_vertical_scroll(
    current: &[u8],
    previous: &[u8],
    width: usize,
    height: usize,
) -> Option<i32> {
    if width == 0 || height < 32 {
        return None;
    }
    let max_shift = height.min(160) as i32;
    if max_shift <= 1 {
        return None;
    }
    let mut prev_sig = Vec::with_capacity(height);
    let mut curr_sig = Vec::with_capacity(height);
    for y in 0..height {
        prev_sig.push(row_signature(previous, width, y));
        curr_sig.push(row_signature(current, width, y));
    }
    let mut best_ratio = 0.0;
    let mut best_dy = 0;
    for dy in -max_shift..=max_shift {
        if dy == 0 {
            continue;
        }
        let overlap = height.saturating_sub(dy.abs() as usize);
        if overlap < height / 2 {
            continue;
        }
        let mut matches = 0usize;
        for y in 0..height {
            let prev_y = y as i32 - dy;
            if prev_y < 0 || prev_y >= height as i32 {
                continue;
            }
            if curr_sig[y] == prev_sig[prev_y as usize] {
                matches += 1;
            }
        }
        let ratio = matches as f32 / overlap as f32;
        if ratio > best_ratio {
            best_ratio = ratio;
            best_dy = dy;
        }
    }
    if best_ratio >= COPYRECT_MATCH_THRESHOLD {
        Some(best_dy)
    } else {
        None
    }
}

fn row_signature(data: &[u8], width: usize, y: usize) -> u64 {
    let stride = width * 4;
    let base = y * stride;
    let sample_count = 8.min(width).max(1);
    let mut hash: u64 = 1469598103934665603;
    for i in 0..sample_count {
        let x = if sample_count == 1 {
            0
        } else {
            i * (width - 1) / (sample_count - 1)
        };
        let idx = base + x * 4;
        let pixel = u32::from_le_bytes([
            data[idx],
            data[idx + 1],
            data[idx + 2],
            data[idx + 3],
        ]);
        hash ^= pixel as u64;
        hash = hash.wrapping_mul(1099511628211);
    }
    hash
}

fn compress_zlib(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
    encoder
        .write_all(data)
        .map_err(|error| format!("Failed to compress frame: {error}"))?;
    encoder
        .finish()
        .map_err(|error| format!("Failed to finish compression: {error}"))
}

fn compress_zlib_level(data: &[u8], level: u8) -> Result<Vec<u8>, String> {
    let compression = if level == 0 {
        Compression::none()
    } else {
        Compression::new(u32::from(level.min(9)))
    };
    let mut encoder = ZlibEncoder::new(Vec::new(), compression);
    encoder
        .write_all(data)
        .map_err(|error| format!("Failed to compress tight frame: {error}"))?;
    encoder
        .finish()
        .map_err(|error| format!("Failed to finish tight compression: {error}"))
}

fn zrle_pixel_format() -> PixelFormat {
    PixelFormat {
        bits_per_pixel: 32,
        depth: 24,
        big_endian_flag: 0,
        true_colour_flag: 1,
        red_max: 255,
        green_max: 255,
        blue_max: 255,
        red_shift: 16,
        green_shift: 8,
        blue_shift: 0,
    }
}

fn select_preferred_encoding(encodings: &[i32]) -> i32 {
    for encoding in encodings {
        match *encoding {
            ENCODING_ZRLE | ENCODING_TIGHT | ENCODING_ZLIB | ENCODING_RAW => {
                return *encoding;
            }
            _ => {}
        }
    }
    ENCODING_ZLIB
}

fn parse_encoding_preferences(encodings: &[i32]) -> EncodingPreferences {
    let mut tight_compression = 6u8;
    let mut tight_quality = None;
    let mut copyrect_supported = false;

    for encoding in encodings {
        if *encoding == ENCODING_COPYRECT {
            copyrect_supported = true;
            continue;
        }
        if *encoding >= ENCODING_COMPRESS_LEVEL_BASE
            && *encoding <= ENCODING_COMPRESS_LEVEL_BASE + 9
        {
            tight_compression = (*encoding - ENCODING_COMPRESS_LEVEL_BASE) as u8;
            continue;
        }
        if *encoding >= ENCODING_QUALITY_LEVEL_BASE
            && *encoding <= ENCODING_QUALITY_LEVEL_BASE + 9
        {
            tight_quality = Some((*encoding - ENCODING_QUALITY_LEVEL_BASE) as u8);
        }
    }

    let preferred = select_preferred_encoding(encodings);
    let allow_jpeg = tight_quality.is_some();

    EncodingPreferences {
        encoding: preferred,
        tight_compression,
        tight_quality,
        allow_jpeg,
        copyrect_supported,
    }
}

fn build_framebuffer_update(
    updates: FrameUpdate,
    prefs: &EncodingPreferences,
) -> Result<Vec<u8>, String> {
    let rect_count = updates.len().min(u16::MAX as usize) as u16;
    let mut buffer = Vec::new();
    buffer.push(0);
    buffer.push(0);
    buffer.extend_from_slice(&rect_count.to_be_bytes());
    for update in updates.into_iter().take(rect_count as usize) {
        match update {
            RectUpdate::CopyRect { rect, src_x, src_y } => {
                buffer.extend_from_slice(&rect.x.to_be_bytes());
                buffer.extend_from_slice(&rect.y.to_be_bytes());
                buffer.extend_from_slice(&rect.width.to_be_bytes());
                buffer.extend_from_slice(&rect.height.to_be_bytes());
                buffer.extend_from_slice(&(ENCODING_COPYRECT as i32).to_be_bytes());
                buffer.extend_from_slice(&src_x.to_be_bytes());
                buffer.extend_from_slice(&src_y.to_be_bytes());
            }
            RectUpdate::Pixels { rect, data } => {
                let encoding = prefs.encoding;
                buffer.extend_from_slice(&rect.x.to_be_bytes());
                buffer.extend_from_slice(&rect.y.to_be_bytes());
                buffer.extend_from_slice(&rect.width.to_be_bytes());
                buffer.extend_from_slice(&rect.height.to_be_bytes());
                buffer.extend_from_slice(&(encoding as i32).to_be_bytes());
                match encoding {
                    ENCODING_ZLIB => {
                        let compressed = compress_zlib(&data)?;
                        buffer.extend_from_slice(&(compressed.len() as u32).to_be_bytes());
                        buffer.extend_from_slice(&compressed);
                    }
                    ENCODING_ZRLE => {
                        let pf = zrle_pixel_format();
                        let encoded = encode_zrle(
                            &data,
                            rect.width,
                            rect.height,
                            &pf,
                            6,
                        )
                        .map_err(|error| format!("Failed to encode ZRLE: {error}"))?;
                        buffer.extend_from_slice(&encoded);
                    }
                    ENCODING_TIGHT => {
                        let encoded = encode_tight_rect(
                            &data,
                            rect.width,
                            rect.height,
                            prefs.tight_compression,
                            prefs.tight_quality,
                            prefs.allow_jpeg,
                        )?;
                        buffer.extend_from_slice(&encoded);
                    }
                    _ => {
                        buffer.extend_from_slice(&data);
                    }
                }
            }
        }
    }
    Ok(buffer)
}

fn resolve_input_dimensions(
    screen_width: u32,
    screen_height: u32,
    display_index: Option<usize>,
) -> (u32, u32, f64, f64) {
    let (offset_x, offset_y) = parse_input_offset_env().unwrap_or((0.0, 0.0));
    if let Some((scale_x, scale_y)) = parse_input_scale_env() {
        let width = ((screen_width as f64) / scale_x).round().max(1.0) as u32;
        let height = ((screen_height as f64) / scale_y).round().max(1.0) as u32;
        return (width, height, offset_x, offset_y);
    }
    #[cfg(target_os = "macos")]
    {
        use core_graphics::display::CGDisplay;
        let mut display = CGDisplay::main();
        if let Some(index) = display_index {
            if let Ok(displays) = CGDisplay::active_displays() {
                if index < displays.len() {
                    display = CGDisplay::new(displays[index]);
                }
            }
        }
        let bounds = display.bounds();
        let logical_width = bounds.size.width;
        let logical_height = bounds.size.height;
        if logical_width > 0.0 && logical_height > 0.0 {
            let width = logical_width.round().max(1.0) as u32;
            let height = logical_height.round().max(1.0) as u32;
            let origin_x = bounds.origin.x + offset_x;
            let origin_y = bounds.origin.y + offset_y;
            return (width, height, origin_x, origin_y);
        }
    }
    (screen_width, screen_height, offset_x, offset_y)
}

fn parse_input_scale_env() -> Option<(f64, f64)> {
    let scale_all = env::var("VNC_INPUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<f64>().ok());
    let scale_x = env::var("VNC_INPUT_SCALE_X")
        .ok()
        .and_then(|value| value.parse::<f64>().ok());
    let scale_y = env::var("VNC_INPUT_SCALE_Y")
        .ok()
        .and_then(|value| value.parse::<f64>().ok());
    let resolved_x = scale_x.or(scale_all);
    let resolved_y = scale_y.or(scale_all);
    match (resolved_x, resolved_y) {
        (Some(x), Some(y)) if x > 0.0 && y > 0.0 => Some((x, y)),
        _ => None,
    }
}

fn parse_input_offset_env() -> Option<(f64, f64)> {
    let offset_x = env::var("VNC_INPUT_OFFSET_X")
        .ok()
        .and_then(|value| value.parse::<f64>().ok());
    let offset_y = env::var("VNC_INPUT_OFFSET_Y")
        .ok()
        .and_then(|value| value.parse::<f64>().ok());
    match (offset_x, offset_y) {
        (Some(x), Some(y)) => Some((x, y)),
        _ => None,
    }
}

fn resolve_target_dimensions(
    screen_width: u32,
    screen_height: u32,
    requested_width: Option<u32>,
    requested_height: Option<u32>,
) -> (u32, u32) {
    let max_width = requested_width.unwrap_or(screen_width).min(screen_width);
    let max_height = requested_height.unwrap_or(screen_height).min(screen_height);
    if screen_width == 0 || screen_height == 0 || max_width == 0 || max_height == 0 {
        return (screen_width.max(1), screen_height.max(1));
    }
    let scale_w = max_width as f64 / screen_width as f64;
    let scale_h = max_height as f64 / screen_height as f64;
    let mut scale = scale_w.min(scale_h).min(1.0);
    if scale <= 0.0 {
        scale = 1.0;
    }
    let mut target_width = (screen_width as f64 * scale).round() as u32;
    let mut target_height = (screen_height as f64 * scale).round() as u32;
    let min_scale_w = 320.0 / screen_width as f64;
    let min_scale_h = 240.0 / screen_height as f64;
    let min_scale = min_scale_w.max(min_scale_h);
    if min_scale > scale {
        let adjusted = min_scale.min(1.0);
        target_width = (screen_width as f64 * adjusted).round().max(1.0) as u32;
        target_height = (screen_height as f64 * adjusted).round().max(1.0) as u32;
    }
    (
        target_width.min(screen_width).max(1),
        target_height.min(screen_height).max(1),
    )
}

async fn read_exact(
    receiver: &mut futures_util::stream::SplitStream<WebSocket>,
    buffer: &mut Vec<u8>,
    size: usize,
) -> Result<Vec<u8>, String> {
    while buffer.len() < size {
        match receiver.next().await {
            Some(Ok(Message::Binary(data))) => buffer.extend_from_slice(&data),
            Some(Ok(Message::Close(_))) => return Err("Client disconnected".to_string()),
            Some(Ok(_)) => {}
            Some(Err(error)) => return Err(format!("WebSocket error: {error}")),
            None => return Err("Client disconnected".to_string()),
        }
    }
    Ok(buffer.drain(0..size).collect())
}

#[derive(Debug)]
enum InputEvent {
    Pointer { mask: u8, x: u16, y: u16 },
    Key { down: bool, keysym: u32 },
}

fn spawn_capture_thread(
    session: VncSession,
    ready: Arc<AtomicBool>,
    force_full: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
    copyrect_supported: Arc<AtomicBool>,
    sender: tokio::sync::mpsc::Sender<FrameUpdate>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let display = match resolve_display(Some(session.display_index)) {
            Ok((display, _)) => display,
            Err(_) => return,
        };
        let mut capturer = match Capturer::new(display) {
            Ok(capturer) => capturer,
            Err(_) => return,
        };
        let mut last_frame: Option<Vec<u8>> = None;
        loop {
            if !running.load(Ordering::SeqCst) {
                break;
            }
            thread::sleep(Duration::from_millis(MAX_FRAME_RATE_MS));
            if !ready.load(Ordering::SeqCst) {
                continue;
            }
            if let Some(frame) = capture_frame(&mut capturer, &session) {
                let send_full = force_full.swap(false, Ordering::SeqCst) || last_frame.is_none();
                let update = if send_full {
                    Some(build_full_update(
                        &frame,
                        session.width as usize,
                        session.height as usize,
                    ))
                } else if let Some(previous) = last_frame.as_ref() {
                    build_diff_update(
                        &frame,
                        previous,
                        session.width as usize,
                        session.height as usize,
                        copyrect_supported.load(Ordering::Relaxed),
                    )
                } else {
                    None
                };
                last_frame = Some(frame);
                if let Some(update) = update {
                    let _ = sender.try_send(update);
                }
            }
        }
    })
}

fn spawn_input_thread(
    session: VncSession,
    running: Arc<AtomicBool>,
    receiver: std::sync::mpsc::Receiver<InputEvent>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut enigo = Enigo::new();
        let mut last_buttons = 0u8;
        while running.load(Ordering::SeqCst) {
            match receiver.recv_timeout(Duration::from_millis(120)) {
                Ok(InputEvent::Pointer { mask, x, y }) => {
                    handle_pointer_event(&mut enigo, &session, &mut last_buttons, mask, x, y);
                }
                Ok(InputEvent::Key { down, keysym }) => {
                    handle_key_event(&mut enigo, down, keysym);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    })
}

#[derive(Debug)]
enum ClientMessage {
    SetPixelFormat,
    SetEncodings { encodings: Vec<i32> },
    FramebufferUpdateRequest {
        incremental: bool,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    },
    KeyEvent { down: bool, keysym: u32 },
    PointerEvent { mask: u8, x: u16, y: u16 },
    ClientCutText,
}

fn parse_client_message(buffer: &mut Vec<u8>) -> Option<ClientMessage> {
    let message_type = *buffer.first()?;
    match message_type {
        0 => {
            if buffer.len() < 20 {
                return None;
            }
            buffer.drain(0..20);
            Some(ClientMessage::SetPixelFormat)
        }
        2 => {
            if buffer.len() < 4 {
                return None;
            }
            let count = u16::from_be_bytes([buffer[2], buffer[3]]) as usize;
            let total = 4 + count * 4;
            if buffer.len() < total {
                return None;
            }
            let mut encodings = Vec::with_capacity(count);
            for index in 0..count {
                let base = 4 + index * 4;
                let raw = i32::from_be_bytes([
                    buffer[base],
                    buffer[base + 1],
                    buffer[base + 2],
                    buffer[base + 3],
                ]);
                encodings.push(raw);
            }
            buffer.drain(0..total);
            Some(ClientMessage::SetEncodings { encodings })
        }
        3 => {
            if buffer.len() < 10 {
                return None;
            }
            let incremental = buffer[1] != 0;
            let x = u16::from_be_bytes([buffer[2], buffer[3]]);
            let y = u16::from_be_bytes([buffer[4], buffer[5]]);
            let width = u16::from_be_bytes([buffer[6], buffer[7]]);
            let height = u16::from_be_bytes([buffer[8], buffer[9]]);
            buffer.drain(0..10);
            Some(ClientMessage::FramebufferUpdateRequest {
                incremental,
                x,
                y,
                width,
                height,
            })
        }
        4 => {
            if buffer.len() < 8 {
                return None;
            }
            let down = buffer[1] != 0;
            let keysym = u32::from_be_bytes([buffer[4], buffer[5], buffer[6], buffer[7]]);
            buffer.drain(0..8);
            Some(ClientMessage::KeyEvent { down, keysym })
        }
        5 => {
            if buffer.len() < 6 {
                return None;
            }
            let mask = buffer[1];
            let x = u16::from_be_bytes([buffer[2], buffer[3]]);
            let y = u16::from_be_bytes([buffer[4], buffer[5]]);
            buffer.drain(0..6);
            Some(ClientMessage::PointerEvent { mask, x, y })
        }
        6 => {
            if buffer.len() < 8 {
                return None;
            }
            let length = u32::from_be_bytes([buffer[4], buffer[5], buffer[6], buffer[7]]) as usize;
            let total = 8 + length;
            if buffer.len() < total {
                return None;
            }
            buffer.drain(0..total);
            Some(ClientMessage::ClientCutText)
        }
        _ => None,
    }
}

fn handle_pointer_event(
    enigo: &mut Enigo,
    session: &VncSession,
    last_buttons: &mut u8,
    mask: u8,
    x: u16,
    y: u16,
) {
    let input_width = session.input_width.max(1) as f64;
    let input_height = session.input_height.max(1) as f64;
    let scaled_x = (x as f64 / session.width as f64) * input_width;
    let scaled_y = (y as f64 / session.height as f64) * input_height;
    let clamped_x = scaled_x.clamp(0.0, input_width - 1.0);
    let clamped_y = scaled_y.clamp(0.0, input_height - 1.0);
    let dest_x = clamped_x + session.input_origin_x;
    let dest_y = clamped_y + session.input_origin_y;
    enigo.mouse_move_to(dest_x.round() as i32, dest_y.round() as i32);

    handle_button(enigo, last_buttons, mask, 1, MouseButton::Left);
    handle_button(enigo, last_buttons, mask, 2, MouseButton::Right);
    handle_button(enigo, last_buttons, mask, 4, MouseButton::Middle);

    if mask & 0b0001_0000 != 0 {
        enigo.mouse_scroll_y(40);
    }
    if mask & 0b0010_0000 != 0 {
        enigo.mouse_scroll_y(-40);
    }

    *last_buttons = mask;
}

fn handle_button(
    enigo: &mut Enigo,
    last_buttons: &mut u8,
    mask: u8,
    flag: u8,
    button: MouseButton,
) {
    let was_down = *last_buttons & flag != 0;
    let is_down = mask & flag != 0;
    if is_down && !was_down {
        enigo.mouse_down(button);
    } else if !is_down && was_down {
        enigo.mouse_up(button);
    }
}

fn handle_key_event(enigo: &mut Enigo, down: bool, keysym: u32) {
    if let Some(key) = map_keysym(keysym) {
        if down {
            enigo.key_down(key);
        } else {
            enigo.key_up(key);
        }
        return;
    }
    if down {
        if let Some(ch) = keysym_to_char(keysym) {
            enigo.key_sequence(&ch.to_string());
        }
    }
}

fn map_keysym(keysym: u32) -> Option<Key> {
    match keysym {
        0xff1b => Some(Key::Escape),
        0xff09 => Some(Key::Tab),
        0xff0d => Some(Key::Return),
        0xff08 => Some(Key::Backspace),
        0xffe1 => Some(Key::Shift),
        0xffe2 => Some(Key::Shift),
        0xffe3 => Some(Key::Control),
        0xffe4 => Some(Key::Control),
        0xffe7 => Some(Key::Meta),
        0xffe8 => Some(Key::Meta),
        0xffe9 => Some(Key::Alt),
        0xffea => Some(Key::Alt),
        0xff51 => Some(Key::LeftArrow),
        0xff52 => Some(Key::UpArrow),
        0xff53 => Some(Key::RightArrow),
        0xff54 => Some(Key::DownArrow),
        _ => None,
    }
}

fn keysym_to_char(keysym: u32) -> Option<char> {
    if keysym <= 0x7f {
        std::char::from_u32(keysym)
    } else {
        None
    }
}
