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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::env;

#[cfg(target_os = "macos")]
use crate::cursor_macos::{capture_cursor, cursor_changed, SystemCursor};

const RFB_VERSION: &[u8] = b"RFB 003.008\n";
const VNC_NAME: &str = "Vibe Inspect Agent";
const MAX_FRAME_RATE_MS: u64 = 33;
const DEFAULT_IDLE_FRAME_RATE_MS: u64 = 120;
const DEFAULT_KEEPALIVE_MS: u64 = 250;
const DEFAULT_HIGH_PERF_FRAME_INTERVAL_MS: u64 = 100;
const HIGH_PERF_INTERVAL_MIN_MS: u64 = 10;
const HIGH_PERF_INTERVAL_MAX_MS: u64 = 100;
const ACTIVE_INPUT_WINDOW_MS: u64 = 250;
const VNC_IDLE_POLL_MS: u64 = 5;
const ENCODING_RAW: i32 = 0;
const ENCODING_COPYRECT: i32 = 1;
const ENCODING_ZLIB: i32 = 6;
const ENCODING_TIGHT: i32 = 7;
const ENCODING_ZRLE: i32 = 16;
const DIFF_FULL_THRESHOLD: f32 = 0.85;
const LARGE_UPDATE_THRESHOLD: f32 = 0.6;
const FAST_TIGHT_COMPRESSION: u8 = 2;
const FAST_ZRLE_COMPRESSION: u8 = 1;
const COPYRECT_MATCH_THRESHOLD: f32 = 0.92;
const ENCODING_COMPRESS_LEVEL_BASE: i32 = -256;
const ENCODING_QUALITY_LEVEL_BASE: i32 = -32;
const ENCODING_CURSOR: i32 = -239;
const ENCODING_DATA_SAVER: i32 = -312;
const ENCODING_HIGH_PERF: i32 = -313;
const TIGHT_JPEG_MIN_AREA: usize = 20000;

static CAPTURE_INIT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static LAST_CAPTURE_LOG: AtomicU64 = AtomicU64::new(0);

fn capture_debug_enabled() -> bool {
    matches!(
        env::var("VNC_CAPTURE_DEBUG")
            .ok()
            .as_deref(),
        Some("1") | Some("true") | Some("TRUE")
    )
}

fn vnc_debug_enabled() -> bool {
    if capture_debug_enabled() {
        return true;
    }
    matches!(
        env::var("VNC_DEBUG")
            .ok()
            .as_deref(),
        Some("1") | Some("true") | Some("TRUE")
    )
}

fn cursor_trace_enabled() -> bool {
    if vnc_debug_enabled() {
        return true;
    }
    matches!(
        env::var("VNC_CURSOR_TRACE")
            .ok()
            .as_deref(),
        Some("1") | Some("true") | Some("TRUE")
    )
}

fn cursor_trace_log(message: &str) {
    if cursor_trace_enabled() {
        eprintln!("{message}");
    }
}

fn vnc_log(message: &str) {
    if vnc_debug_enabled() {
        eprintln!("{message}");
    }
}

fn capture_log_throttled(message: &str) {
    if !capture_debug_enabled() {
        return;
    }
    let now = current_millis();
    let last = LAST_CAPTURE_LOG.load(Ordering::Relaxed);
    if now.saturating_sub(last) < 1000 {
        return;
    }
    LAST_CAPTURE_LOG.store(now, Ordering::Relaxed);
    eprintln!("{message}");
}

fn current_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_millis() as u64
}

#[derive(Clone)]
pub struct VncSessionInfo {
    pub session_id: String,
    pub token: String,
    pub ws_path: String,
    pub width: u32,
    pub height: u32,
    pub display_index: usize,
    pub input_width: u32,
    pub input_height: u32,
    pub input_origin_x: f64,
    pub input_origin_y: f64,
    pub input_scale_x: f64,
    pub input_scale_y: f64,
    pub screen_width: u32,
    pub screen_height: u32,
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
    input_scale_x: f64,
    input_scale_y: f64,
    display_index: usize,
    high_perf_interval_ms: u64,
    generation: u64,
    guard: Arc<AtomicU64>,
}

#[derive(Clone, Debug)]
struct CursorData {
    width: u16,
    height: u16,
    hotspot_x: u16,
    hotspot_y: u16,
    pixels: Vec<u8>,
    mask: Vec<u8>,
}

#[derive(Clone, Debug)]
enum RectUpdate {
    Pixels { rect: Rect, data: Vec<u8> },
    CopyRect { rect: Rect, src_x: u16, src_y: u16 },
    Cursor(CursorData),
}

type FrameUpdate = Vec<RectUpdate>;

enum DiffOutcome {
    None,
    Full,
    Rect(Rect),
}

#[derive(Clone, Copy, Debug)]
struct EncodingPreferences {
    encoding: i32,
    tight_compression: u8,
    tight_quality: Option<u8>,
    allow_jpeg: bool,
    copyrect_supported: bool,
    cursor_supported: bool,
}

#[derive(Clone, Copy, Debug)]
struct PixelFormatSpec {
    bits_per_pixel: u8,
    depth: u8,
    big_endian: bool,
    true_color: bool,
    red_max: u16,
    green_max: u16,
    blue_max: u16,
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,
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
    guards: HashMap<String, Arc<AtomicU64>>,
}

impl VncManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            guards: HashMap::new(),
        }
    }

    pub fn start_session(
        &mut self,
        session_id: String,
        width: Option<u32>,
        height: Option<u32>,
        display_index: Option<usize>,
        high_perf_interval_ms: Option<u64>,
    ) -> Result<VncSessionInfo, String> {
        let (display, display_index) = resolve_display(display_index)?;
        let screen_width = display.width() as u32;
        let screen_height = display.height() as u32;
        preflight_capture_access()?;
        let (
            input_width,
            input_height,
            input_origin_x,
            input_origin_y,
            input_scale_x,
            input_scale_y,
        ) = resolve_input_dimensions(screen_width, screen_height, Some(display_index));
        let (target_width, target_height) = resolve_target_dimensions(
            screen_width,
            screen_height,
            width,
            height,
        );
        let high_perf_interval_ms =
            resolve_high_perf_interval_ms(high_perf_interval_ms);
        let token = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(24)
            .map(char::from)
            .collect::<String>();
        let guard = self
            .guards
            .entry(session_id.clone())
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        let generation = guard.fetch_add(1, Ordering::SeqCst) + 1;
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
            input_scale_x,
            input_scale_y,
            display_index,
            high_perf_interval_ms,
            generation,
            guard: guard.clone(),
        };
        self.sessions.insert(session_id.clone(), session);
        Ok(VncSessionInfo {
            session_id: session_id.clone(),
            token,
            ws_path: format!("/vnc/{session_id}"),
            width: target_width,
            height: target_height,
            display_index,
            input_width,
            input_height,
            input_origin_x,
            input_origin_y,
            input_scale_x,
            input_scale_y,
            screen_width,
            screen_height,
        })
    }

    pub fn stop_session(&mut self, session_id: &str) {
        if let Some(guard) = self.guards.get(session_id) {
            guard.fetch_add(1, Ordering::SeqCst);
        }
        self.sessions.remove(session_id);
    }

    fn get_session(&self, session_id: &str, token: &str) -> Option<VncSession> {
        self.sessions
            .get(session_id)
            .and_then(|session| if session.token == token { Some(session.clone()) } else { None })
    }
}

fn preflight_capture_access() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use core_graphics::access::ScreenCaptureAccess;
        if !ScreenCaptureAccess::default().preflight() {
            return Err(
                "Screen recording permission is required to stream the desktop. Enable it in System Settings > Privacy & Security > Screen Recording, then restart the desktop agent."
                    .to_string(),
            );
        }
    }
    Ok(())
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

#[cfg(target_os = "macos")]
fn resolve_capture_dimensions(
    display_index: usize,
    fallback_width: u32,
    fallback_height: u32,
) -> (u32, u32) {
    use core_graphics::display::CGDisplay;
    let mut display = CGDisplay::main();
    if let Ok(displays) = CGDisplay::active_displays() {
        if display_index < displays.len() {
            display = CGDisplay::new(displays[display_index]);
        }
    }
    let width = display.pixels_wide() as u32;
    let height = display.pixels_high() as u32;
    if width > 0 && height > 0 {
        return (width, height);
    }
    (fallback_width, fallback_height)
}

#[cfg(not(target_os = "macos"))]
fn resolve_capture_dimensions(
    _display_index: usize,
    fallback_width: u32,
    fallback_height: u32,
) -> (u32, u32) {
    (fallback_width, fallback_height)
}

pub async fn serve_vnc_socket(
    socket: WebSocket,
    manager: Arc<Mutex<VncManager>>,
    session_id: String,
    token: String,
) {
    vnc_log(&format!("vnc ws connect: session={session_id}"));
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
    vnc_log(&format!(
        "vnc session init: display={} size={}x{}",
        session.display_index, session.width, session.height
    ));
    vnc_log(&format!(
        "vnc input map: input={}x{} scale=({:.3},{:.3}) origin=({:.1},{:.1})",
        session.input_width,
        session.input_height,
        session.input_scale_x,
        session.input_scale_y,
        session.input_origin_x,
        session.input_origin_y
    ));

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
    let cursor_supported = Arc::new(AtomicBool::new(false));
    let (frame_tx, mut frame_rx) = tokio::sync::mpsc::channel::<FrameUpdate>(2);
    let (input_tx, input_rx) = std::sync::mpsc::channel::<InputEvent>();
    let last_input_at = Arc::new(AtomicU64::new(current_millis()));
    let data_saver_enabled = Arc::new(AtomicBool::new(false));
    let high_perf_enabled = Arc::new(AtomicBool::new(false));
    let _capture_handle = spawn_capture_thread(
        session.clone(),
        ready_for_updates.clone(),
        force_full.clone(),
        running.clone(),
        session.guard.clone(),
        session.generation,
        copyrect_supported.clone(),
        cursor_supported.clone(),
        last_input_at.clone(),
        data_saver_enabled.clone(),
        high_perf_enabled.clone(),
        frame_tx,
    );
    let _input_handle =
        spawn_input_thread(session.clone(), running.clone(), session.guard.clone(), input_rx);
    let mut encoding_prefs = EncodingPreferences {
        encoding: ENCODING_ZLIB,
        tight_compression: 6,
        tight_quality: None,
        allow_jpeg: false,
        copyrect_supported: false,
        cursor_supported: false,
    };
    let mut pixel_format = default_pixel_format_spec();
    let mut update_request_seen = false;

    loop {
        tokio::select! {
            Some(update) = frame_rx.recv() => {
                let message = build_framebuffer_update(
                    update,
                    &encoding_prefs,
                    &pixel_format,
                    session.width,
                    session.height,
                )?;
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
                                    if !update_request_seen {
                                        update_request_seen = true;
                                        vnc_log(&format!(
                                            "vnc update request: incremental={}",
                                            incremental
                                        ));
                                    }
                                    ready_for_updates.store(true, Ordering::SeqCst);
                                    if !incremental {
                                        force_full.store(true, Ordering::SeqCst);
                                    }
                                }
                                ClientMessage::PointerEvent { mask, x, y } => {
                                    last_input_at.store(current_millis(), Ordering::Relaxed);
                                    let _ = input_tx.send(InputEvent::Pointer { mask, x, y });
                                }
                                ClientMessage::KeyEvent { down, keysym } => {
                                    last_input_at.store(current_millis(), Ordering::Relaxed);
                                    let _ = input_tx.send(InputEvent::Key { down, keysym });
                                }
                                ClientMessage::SetEncodings { encodings } => {
                                    encoding_prefs = apply_pixel_format_constraints(
                                        parse_encoding_preferences(&encodings),
                                        &pixel_format,
                                    );
                                    data_saver_enabled.store(
                                        parse_data_saver(&encodings),
                                        Ordering::Relaxed,
                                    );
                                    high_perf_enabled.store(
                                        parse_high_perf(&encodings),
                                        Ordering::Relaxed,
                                    );
                                    copyrect_supported.store(
                                        encoding_prefs.copyrect_supported,
                                        Ordering::Relaxed,
                                    );
                                    cursor_supported.store(
                                        encoding_prefs.cursor_supported,
                                        Ordering::Relaxed,
                                    );
                                }
                                ClientMessage::SetPixelFormat { format } => {
                                    pixel_format = sanitize_pixel_format(format);
                                    encoding_prefs =
                                        apply_pixel_format_constraints(encoding_prefs, &pixel_format);
                                }
                                ClientMessage::ClientCutText => {}
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
    pixel_format_to_bytes(&default_pixel_format_spec())
}

fn default_pixel_format_spec() -> PixelFormatSpec {
    PixelFormatSpec {
        bits_per_pixel: 32,
        depth: 24,
        big_endian: false,
        true_color: true,
        red_max: 255,
        green_max: 255,
        blue_max: 255,
        red_shift: 16,
        green_shift: 8,
        blue_shift: 0,
    }
}

fn pixel_format_to_bytes(format: &PixelFormatSpec) -> [u8; 16] {
    let mut bytes = [0u8; 16];
    bytes[0] = format.bits_per_pixel;
    bytes[1] = format.depth;
    bytes[2] = if format.big_endian { 1 } else { 0 };
    bytes[3] = if format.true_color { 1 } else { 0 };
    bytes[4..6].copy_from_slice(&format.red_max.to_be_bytes());
    bytes[6..8].copy_from_slice(&format.green_max.to_be_bytes());
    bytes[8..10].copy_from_slice(&format.blue_max.to_be_bytes());
    bytes[10] = format.red_shift;
    bytes[11] = format.green_shift;
    bytes[12] = format.blue_shift;
    bytes
}

fn sanitize_pixel_format(format: PixelFormatSpec) -> PixelFormatSpec {
    if is_rgb565(&format) || is_bgra8888(&format) {
        format
    } else {
        default_pixel_format_spec()
    }
}

fn is_bgra8888(format: &PixelFormatSpec) -> bool {
    format.bits_per_pixel == 32
        && format.depth <= 24
        && format.true_color
        && !format.big_endian
        && format.red_max == 255
        && format.green_max == 255
        && format.blue_max == 255
        && format.red_shift == 16
        && format.green_shift == 8
        && format.blue_shift == 0
}

fn is_rgb565(format: &PixelFormatSpec) -> bool {
    format.bits_per_pixel == 16
        && format.depth == 16
        && format.true_color
        && format.red_max == 31
        && format.green_max == 63
        && format.blue_max == 31
        && format.red_shift == 11
        && format.green_shift == 5
        && format.blue_shift == 0
}

fn apply_pixel_format_constraints(
    mut prefs: EncodingPreferences,
    format: &PixelFormatSpec,
) -> EncodingPreferences {
    if format.bits_per_pixel == 16 {
        if matches!(prefs.encoding, ENCODING_ZRLE | ENCODING_TIGHT) {
            prefs.encoding = ENCODING_ZLIB;
        }
    }
    prefs
}

fn bgra_to_rgb565(data: &[u8], big_endian: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() / 4 * 2);
    for chunk in data.chunks_exact(4) {
        let b = chunk[0] as u16;
        let g = chunk[1] as u16;
        let r = chunk[2] as u16;
        let r5 = (r >> 3) & 0x1f;
        let g6 = (g >> 2) & 0x3f;
        let b5 = (b >> 3) & 0x1f;
        let value = (r5 << 11) | (g6 << 5) | b5;
        if big_endian {
            out.push((value >> 8) as u8);
            out.push((value & 0xff) as u8);
        } else {
            out.push((value & 0xff) as u8);
            out.push((value >> 8) as u8);
        }
    }
    out
}

fn capture_frame(
    capturer: &mut Capturer,
    session: &VncSession,
    capture_width: usize,
    capture_height: usize,
) -> Option<Vec<u8>> {
    match capturer.frame() {
        Ok(frame) => {
            if capture_width == 0 || capture_height == 0 {
                return None;
            }
            let mut width = capture_width;
            let mut height = capture_height;
            let mut stride = if frame.len() % height == 0 {
                frame.len() / height
            } else {
                0
            };
            let expected_min = width.saturating_mul(height).saturating_mul(4);
            if frame.len() >= expected_min && stride == 0 {
                // macOS IOSurface alloc size can be page-rounded; allow trailing padding.
                let extra = frame.len().saturating_sub(expected_min);
                if extra % height != 0 {
                    stride = width.saturating_mul(4);
                }
            }
            if frame.len() < expected_min || stride == 0 || stride < width * 4 {
                if let Some((guess_w, guess_h, guess_stride)) = guess_capture_dimensions(
                    frame.len(),
                    session.screen_width as usize,
                    session.screen_height as usize,
                ) {
                    width = guess_w;
                    height = guess_h;
                    stride = guess_stride;
                    if width != capture_width || height != capture_height {
                        capture_log_throttled(&format!(
                            "vnc capture adjusted: frame_len={} capture={}x{} guess={}x{} stride={}",
                            frame.len(),
                            capture_width,
                            capture_height,
                            width,
                            height,
                            stride
                        ));
                    }
                } else {
                    capture_log_throttled(&format!(
                        "vnc capture drop: frame_len={} capture={}x{} stride={}",
                        frame.len(),
                        capture_width,
                        capture_height,
                        stride
                    ));
                    return None;
                }
            }
            let expected_min = width.saturating_mul(height).saturating_mul(4);
            if frame.len() < expected_min || stride < width * 4 {
                capture_log_throttled(&format!(
                    "vnc capture mismatch: frame_len={} expected>={} width={} height={} stride={}",
                    frame.len(),
                    expected_min,
                    width,
                    height,
                    stride
                ));
                return None;
            }
            let source = extract_frame(
                &frame,
                stride,
                width,
                height,
            )?;
            if session.width as usize == width
                && session.height as usize == height
            {
                Some(source)
            } else {
                scale_bgra(
                    &source,
                    width,
                    height,
                    session.width as usize,
                    session.height as usize,
                )
            }
        }
        Err(error) if error.kind() == ErrorKind::WouldBlock => None,
        Err(_) => None,
    }
}

fn resolve_frame_intervals() -> (Duration, Duration) {
    let active_env = env::var("VNC_ACTIVE_FRAME_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok());
    let legacy_env = env::var("VNC_FRAME_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok());
    let active_ms = active_env
        .or(legacy_env)
        .filter(|value| *value > 0)
        .unwrap_or(MAX_FRAME_RATE_MS);
    let idle_env = env::var("VNC_IDLE_FRAME_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok());
    let idle_ms = idle_env
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_IDLE_FRAME_RATE_MS);
    (Duration::from_millis(active_ms), Duration::from_millis(idle_ms))
}

fn resolve_keepalive_interval() -> Duration {
    let env_value = env::var("VNC_KEEPALIVE_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok());
    let millis = env_value
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_KEEPALIVE_MS);
    Duration::from_millis(millis)
}

fn resolve_high_perf_interval_ms(override_ms: Option<u64>) -> u64 {
    let env_value = env::var("VNC_HIGH_PERF_FRAME_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok());
    let millis = override_ms
        .or(env_value)
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_HIGH_PERF_FRAME_INTERVAL_MS);
    millis.clamp(HIGH_PERF_INTERVAL_MIN_MS, HIGH_PERF_INTERVAL_MAX_MS)
}

fn guess_capture_dimensions(
    frame_len: usize,
    logical_width: usize,
    logical_height: usize,
) -> Option<(usize, usize, usize)> {
    if logical_width == 0 || logical_height == 0 || frame_len == 0 {
        return None;
    }
    let mut best: Option<(usize, usize, usize, usize)> = None;
    for scale in 1..=4 {
        let height = logical_height.saturating_mul(scale);
        if height == 0 || frame_len % height != 0 {
            continue;
        }
        let stride = frame_len / height;
        if stride < 4 {
            continue;
        }
        let width = logical_width.saturating_mul(scale);
        if width == 0 || stride < width * 4 {
            continue;
        }
        let padding = stride - width * 4;
        match best {
            Some((_, _, _, best_padding)) if padding >= best_padding => {}
            _ => best = Some((width, height, stride, padding)),
        }
    }
    best.map(|(width, height, stride, _)| (width, height, stride))
}

fn extract_frame(frame: &[u8], stride: usize, width: usize, height: usize) -> Option<Vec<u8>> {
    let expected = width.saturating_mul(height).saturating_mul(4);
    if expected == 0 || frame.len() < stride.saturating_mul(height) {
        return None;
    }
    let mut data = vec![0u8; expected];
    for y in 0..height {
        let src_start = y * stride;
        let src_end = src_start + width * 4;
        if src_end > frame.len() {
            return None;
        }
        let dst_start = y * width * 4;
        data[dst_start..dst_start + width * 4]
            .copy_from_slice(&frame[src_start..src_end]);
    }
    Some(data)
}

fn scale_bgra(
    source: &[u8],
    src_width: usize,
    src_height: usize,
    dst_width: usize,
    dst_height: usize,
) -> Option<Vec<u8>> {
    let expected = src_width.saturating_mul(src_height).saturating_mul(4);
    if expected == 0 || source.len() < expected || dst_width == 0 || dst_height == 0 {
        return None;
    }
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
    Some(output)
}

fn build_full_update(frame: &[u8], width: usize, height: usize) -> FrameUpdate {
    let expected = width.saturating_mul(height).saturating_mul(4);
    if expected == 0 || frame.len() < expected {
        return Vec::new();
    }
    vec![RectUpdate::Pixels {
        rect: Rect {
            x: 0,
            y: 0,
            width: width as u16,
            height: height as u16,
        },
        data: frame[..expected].to_vec(),
    }]
}

fn build_diff_update(
    current: &[u8],
    previous: &[u8],
    width: usize,
    height: usize,
    allow_copyrect: bool,
) -> Option<FrameUpdate> {
    let expected = width.saturating_mul(height).saturating_mul(4);
    if expected == 0 || current.len() < expected || previous.len() < expected {
        return None;
    }
    let diff = diff_rect_with_threshold(current, previous, width, height, DIFF_FULL_THRESHOLD);
    let full_area = width * height;
    if full_area == 0 {
        return None;
    }
    match diff {
        DiffOutcome::None => None,
        DiffOutcome::Full => {
            if allow_copyrect {
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
            Some(build_full_update(current, width, height))
        }
        DiffOutcome::Rect(rect) => {
            let rect_area = rect.width as usize * rect.height as usize;
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
            if (rect_area as f32) / (full_area as f32) >= DIFF_FULL_THRESHOLD {
                return Some(build_full_update(current, width, height));
            }
            let data = extract_rect(current, width, rect);
            Some(vec![RectUpdate::Pixels { rect, data }])
        }
    }
}

fn diff_rect_with_threshold(
    current: &[u8],
    previous: &[u8],
    width: usize,
    height: usize,
    threshold: f32,
) -> DiffOutcome {
    if width == 0 || height == 0 {
        return DiffOutcome::None;
    }
    let full_area = width.saturating_mul(height);
    if full_area == 0 {
        return DiffOutcome::None;
    }
    let threshold_area = ((full_area as f32) * threshold).ceil() as usize;
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
                let rect_area = (max_x - min_x + 1) * (max_y - min_y + 1);
                if rect_area >= threshold_area {
                    return DiffOutcome::Full;
                }
            }
        }
    }
    if !changed {
        return DiffOutcome::None;
    }
    DiffOutcome::Rect(Rect {
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
    let mut cursor_supported = false;

    for encoding in encodings {
        if *encoding == ENCODING_COPYRECT {
            copyrect_supported = true;
            continue;
        }
        if *encoding == ENCODING_CURSOR {
            cursor_supported = true;
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
        cursor_supported,
    }
}

fn parse_data_saver(encodings: &[i32]) -> bool {
    encodings.iter().any(|encoding| *encoding == ENCODING_DATA_SAVER)
}

fn parse_high_perf(encodings: &[i32]) -> bool {
    encodings
        .iter()
        .any(|encoding| *encoding == ENCODING_HIGH_PERF)
}

fn build_framebuffer_update(
    updates: FrameUpdate,
    prefs: &EncodingPreferences,
    pixel_format: &PixelFormatSpec,
    frame_width: u32,
    frame_height: u32,
) -> Result<Vec<u8>, String> {
    let rect_count = updates.len().min(u16::MAX as usize) as u16;
    let mut buffer = Vec::new();
    buffer.push(0);
    buffer.push(0);
    buffer.extend_from_slice(&rect_count.to_be_bytes());
    let frame_area = frame_width.saturating_mul(frame_height) as usize;
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
                let expected_len = rect.width as usize * rect.height as usize * 4;
                if expected_len == 0 || data.len() < expected_len {
                    continue;
                }
                let data = &data[..expected_len];
                let mut encoding = prefs.encoding;
                let is_large = frame_area > 0
                    && (rect.width as usize * rect.height as usize) as f32
                        >= (frame_area as f32) * LARGE_UPDATE_THRESHOLD;
                if pixel_format.bits_per_pixel == 16
                    && matches!(encoding, ENCODING_TIGHT | ENCODING_ZRLE)
                {
                    encoding = ENCODING_ZLIB;
                }
                buffer.extend_from_slice(&rect.x.to_be_bytes());
                buffer.extend_from_slice(&rect.y.to_be_bytes());
                buffer.extend_from_slice(&rect.width.to_be_bytes());
                buffer.extend_from_slice(&rect.height.to_be_bytes());
                buffer.extend_from_slice(&(encoding as i32).to_be_bytes());
                match encoding {
                    ENCODING_ZLIB => {
                        let converted;
                        let payload = if pixel_format.bits_per_pixel == 16 {
                            converted = bgra_to_rgb565(data, pixel_format.big_endian);
                            converted.as_slice()
                        } else {
                            data
                        };
                        let compressed = compress_zlib(payload)?;
                        buffer.extend_from_slice(&(compressed.len() as u32).to_be_bytes());
                        buffer.extend_from_slice(&compressed);
                    }
                    ENCODING_ZRLE => {
                        let compression = if is_large { FAST_ZRLE_COMPRESSION } else { 6 };
                        let pf = zrle_pixel_format();
                        let encoded = encode_zrle(
                            data,
                            rect.width,
                            rect.height,
                            &pf,
                            compression,
                        )
                        .map_err(|error| format!("Failed to encode ZRLE: {error}"))?;
                        buffer.extend_from_slice(&encoded);
                    }
                    ENCODING_TIGHT => {
                        let compression = if is_large {
                            prefs.tight_compression.min(FAST_TIGHT_COMPRESSION)
                        } else {
                            prefs.tight_compression
                        };
                        let encoded = encode_tight_rect(
                            data,
                            rect.width,
                            rect.height,
                            compression,
                            prefs.tight_quality,
                            prefs.allow_jpeg,
                        )?;
                        buffer.extend_from_slice(&encoded);
                    }
                    _ => {
                        if pixel_format.bits_per_pixel == 16 {
                            let converted = bgra_to_rgb565(data, pixel_format.big_endian);
                            buffer.extend_from_slice(&converted);
                        } else {
                            buffer.extend_from_slice(data);
                        }
                    }
                }
            }
            RectUpdate::Cursor(cursor) => {
                buffer.extend_from_slice(&cursor.hotspot_x.to_be_bytes());
                buffer.extend_from_slice(&cursor.hotspot_y.to_be_bytes());
                buffer.extend_from_slice(&cursor.width.to_be_bytes());
                buffer.extend_from_slice(&cursor.height.to_be_bytes());
                buffer.extend_from_slice(&ENCODING_CURSOR.to_be_bytes());
                if pixel_format.bits_per_pixel == 16 {
                    let converted = bgra_to_rgb565(&cursor.pixels, pixel_format.big_endian);
                    buffer.extend_from_slice(&converted);
                } else {
                    buffer.extend_from_slice(&cursor.pixels);
                }
                buffer.extend_from_slice(&cursor.mask);
            }
        }
    }
    Ok(buffer)
}

fn resolve_input_dimensions(
    screen_width: u32,
    screen_height: u32,
    display_index: Option<usize>,
) -> (u32, u32, f64, f64, f64, f64) {
    let (env_offset_x, env_offset_y) = parse_input_offset_env().unwrap_or((0.0, 0.0));
    let mut origin_x = env_offset_x;
    let mut origin_y = env_offset_y;

    #[cfg(target_os = "macos")]
    let _ = (screen_width, screen_height);

    #[cfg(not(target_os = "macos"))]
    let (mut input_width, mut input_height, mut scale_x, mut scale_y) =
        (screen_width, screen_height, 1.0, 1.0);

    #[cfg(target_os = "macos")]
    let (input_width, input_height, scale_x, scale_y) = {
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
        let pixel_width = display.pixels_wide().max(1) as u32;
        let pixel_height = display.pixels_high().max(1) as u32;
        let logical_width = bounds.size.width.max(1.0);
        let logical_height = bounds.size.height.max(1.0);
        origin_x += bounds.origin.x;
        origin_y += bounds.origin.y;
        (
            pixel_width,
            pixel_height,
            pixel_width as f64 / logical_width,
            pixel_height as f64 / logical_height,
        )
    };
    #[cfg(target_os = "windows")]
    {
        if let Some((left, top, width, height)) = resolve_windows_monitor(display_index) {
            input_width = width;
            input_height = height;
            origin_x += left;
            origin_y += top;
        }
    }

    #[cfg(all(target_os = "linux", x11))]
    {
        if let Some((left, top, width, height)) = resolve_x11_monitor(display_index) {
            input_width = width;
            input_height = height;
            origin_x += left;
            origin_y += top;
        }
    }

    if let Some((scale_env_x, scale_env_y)) = parse_input_scale_env() {
        let width = ((input_width as f64) / scale_env_x).round().max(1.0) as u32;
        let height = ((input_height as f64) / scale_env_y).round().max(1.0) as u32;
        return (width, height, origin_x, origin_y, scale_x, scale_y);
    }
    (input_width, input_height, origin_x, origin_y, scale_x, scale_y)
}

#[cfg(target_os = "windows")]
fn resolve_windows_monitor(display_index: Option<usize>) -> Option<(f64, f64, u32, u32)> {
    use std::mem::{size_of, MaybeUninit};
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{BOOL, LPARAM, RECT, TRUE};
    use windows_sys::Win32::Graphics::Gdi::{
        EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFOEXW, MONITORINFOF_PRIMARY,
    };

    #[derive(Clone, Copy)]
    struct MonitorRect {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
        primary: bool,
    }

    unsafe extern "system" fn enum_proc(
        monitor: HMONITOR,
        _hdc: HDC,
        _rect: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        let monitors = &mut *(data as *mut Vec<MonitorRect>);
        let mut info: MONITORINFOEXW = unsafe { MaybeUninit::zeroed().assume_init() };
        info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
        let ok = unsafe { GetMonitorInfoW(monitor, &mut info.monitorInfo) };
        if ok != 0 {
            let rect = info.monitorInfo.rcMonitor;
            monitors.push(MonitorRect {
                left: rect.left,
                top: rect.top,
                right: rect.right,
                bottom: rect.bottom,
                primary: (info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY) != 0,
            });
        }
        TRUE
    }

    let index = display_index?;
    let mut monitors: Vec<MonitorRect> = Vec::new();
    unsafe {
        let data = &mut monitors as *mut _ as LPARAM;
        EnumDisplayMonitors(0, null_mut(), Some(enum_proc), data);
    }
    if monitors.is_empty() {
        return None;
    }
    if index >= monitors.len() {
        return None;
    }
    let chosen = monitors[index];
    let width = (chosen.right - chosen.left).max(1) as u32;
    let height = (chosen.bottom - chosen.top).max(1) as u32;
    Some((chosen.left as f64, chosen.top as f64, width, height))
}

#[cfg(all(target_os = "linux", x11))]
fn resolve_x11_monitor(display_index: Option<usize>) -> Option<(f64, f64, u32, u32)> {
    use std::rc::Rc;
    let index = display_index?;
    let server = Rc::new(scrap::x11::Server::default().ok()?);
    let mut displays = scrap::x11::Server::displays(server);
    let display = displays.nth(index)?;
    let rect = display.rect();
    let width = rect.w.max(1) as u32;
    let height = rect.h.max(1) as u32;
    Some((rect.x as f64, rect.y as f64, width, height))
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
    guard: Arc<AtomicU64>,
    generation: u64,
    copyrect_supported: Arc<AtomicBool>,
    cursor_supported: Arc<AtomicBool>,
    last_input_at: Arc<AtomicU64>,
    data_saver_enabled: Arc<AtomicBool>,
    high_perf_enabled: Arc<AtomicBool>,
    sender: tokio::sync::mpsc::Sender<FrameUpdate>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        if guard.load(Ordering::SeqCst) != generation {
            return;
        }
        vnc_log(&format!(
            "vnc capture start: display={} size={}x{}",
            session.display_index, session.width, session.height
        ));
        if cursor_trace_enabled() {
            cursor_trace_log(&format!(
                "cursor_trace session display={} frame={}x{} input={}x{} origin=({:.2},{:.2}) scale=({:.3},{:.3}) screen={}x{}",
                session.display_index,
                session.width,
                session.height,
                session.input_width,
                session.input_height,
                session.input_origin_x,
                session.input_origin_y,
                session.input_scale_x,
                session.input_scale_y,
                session.screen_width,
                session.screen_height
            ));
        }
        let display = match resolve_display(Some(session.display_index)) {
            Ok((display, _)) => display,
            Err(_) => return,
        };
        let mut capturer = {
            let init_lock = CAPTURE_INIT_LOCK.get_or_init(|| Mutex::new(()));
            let _init_guard = match init_lock.lock() {
                Ok(lock) => lock,
                Err(poisoned) => poisoned.into_inner(),
            };
            match Capturer::new(display) {
                Ok(capturer) => capturer,
                Err(_) => return,
            }
        };
        let (capture_width, capture_height) = resolve_capture_dimensions(
            session.display_index,
            session.screen_width,
            session.screen_height,
        );
        let mut last_frame: Option<Vec<u8>> = None;
        #[cfg(target_os = "macos")]
        let mut last_cursor: Option<SystemCursor> = None;
        let mut logged_first_frame = false;
        let (active_interval, idle_interval) = resolve_frame_intervals();
        let keepalive_interval = resolve_keepalive_interval();
        let high_perf_interval = Duration::from_millis(session.high_perf_interval_ms);
        let idle_poll = Duration::from_millis(VNC_IDLE_POLL_MS);
        let mut last_success = Instant::now();
        let mut last_capture = Instant::now()
            .checked_sub(active_interval)
            .unwrap_or_else(Instant::now);
        let mut last_sent = Instant::now();
        loop {
            if !running.load(Ordering::SeqCst)
                || guard.load(Ordering::SeqCst) != generation
            {
                break;
            }
            if !ready.load(Ordering::SeqCst) {
                thread::sleep(idle_poll);
                continue;
            }
            let input_age = current_millis()
                .saturating_sub(last_input_at.load(Ordering::Relaxed));
            let high_perf = high_perf_enabled.load(Ordering::Relaxed);
            let frame_interval = if high_perf {
                high_perf_interval
            } else if input_age <= ACTIVE_INPUT_WINDOW_MS {
                active_interval
            } else if data_saver_enabled.load(Ordering::Relaxed) {
                idle_interval
            } else {
                active_interval
            };
            let elapsed = last_capture.elapsed();
            if elapsed < frame_interval {
                thread::sleep(frame_interval - elapsed);
                continue;
            }
            last_capture = Instant::now();
            let mut sent_update = false;

            #[cfg(target_os = "macos")]
            if cursor_supported.load(Ordering::Relaxed) {
                if let Some(cursor) = capture_cursor() {
                    if cursor_changed(&last_cursor, &cursor) {
                        let cursor_data = CursorData {
                            width: cursor.width,
                            height: cursor.height,
                            hotspot_x: cursor.hotspot_x,
                            hotspot_y: cursor.hotspot_y,
                            pixels: cursor.pixels.clone(),
                            mask: cursor.mask.clone(),
                        };
                        if cursor_trace_enabled() {
                            cursor_trace_log(&format!(
                                "cursor_trace update w={} h={} hot=({},{}) pixels={} mask={}",
                                cursor_data.width,
                                cursor_data.height,
                                cursor_data.hotspot_x,
                                cursor_data.hotspot_y,
                                cursor_data.pixels.len(),
                                cursor_data.mask.len()
                            ));
                        }
                        let _ = sender.try_send(vec![RectUpdate::Cursor(cursor_data)]);
                        last_cursor = Some(cursor);
                    }
                }
            }

            if let Some(frame) = capture_frame(
                &mut capturer,
                &session,
                capture_width as usize,
                capture_height as usize,
            ) {
                if !logged_first_frame {
                    logged_first_frame = true;
                    vnc_log(&format!(
                        "vnc capture first frame: {}x{}",
                        session.width, session.height
                    ));
                }
                last_success = Instant::now();
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
                    if sender.try_send(update).is_ok() {
                        last_sent = Instant::now();
                        sent_update = true;
                    }
                } else if !high_perf && last_sent.elapsed() >= keepalive_interval {
                    if sender.try_send(Vec::new()).is_ok() {
                        last_sent = Instant::now();
                        sent_update = true;
                    }
                }
            } else if vnc_debug_enabled() && last_success.elapsed() > Duration::from_secs(5) {
                last_success = Instant::now();
                vnc_log("vnc capture stalled: no frames ready");
            }

            if !sent_update
                && high_perf_enabled.load(Ordering::Relaxed)
                && last_sent.elapsed() >= high_perf_interval
            {
                if let Some(frame) = last_frame.as_ref() {
                    let update = build_full_update(
                        frame,
                        session.width as usize,
                        session.height as usize,
                    );
                    if sender.try_send(update).is_ok() {
                        last_sent = Instant::now();
                    }
                }
            }
        }
    })
}

fn spawn_input_thread(
    session: VncSession,
    running: Arc<AtomicBool>,
    guard: Arc<AtomicU64>,
    receiver: std::sync::mpsc::Receiver<InputEvent>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut enigo = Enigo::new();
        let mut last_buttons = 0u8;
        while running.load(Ordering::SeqCst)
            && guard.load(Ordering::SeqCst) == session.generation
        {
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
    SetPixelFormat { format: PixelFormatSpec },
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
            let format = PixelFormatSpec {
                bits_per_pixel: buffer[4],
                depth: buffer[5],
                big_endian: buffer[6] != 0,
                true_color: buffer[7] != 0,
                red_max: u16::from_be_bytes([buffer[8], buffer[9]]),
                green_max: u16::from_be_bytes([buffer[10], buffer[11]]),
                blue_max: u16::from_be_bytes([buffer[12], buffer[13]]),
                red_shift: buffer[14],
                green_shift: buffer[15],
                blue_shift: buffer[16],
            };
            buffer.drain(0..20);
            Some(ClientMessage::SetPixelFormat { format })
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
    let scaled_x = (x as f64 / session.width.max(1) as f64) * input_width;
    let scaled_y = (y as f64 / session.height.max(1) as f64) * input_height;
    let clamped_x = scaled_x.clamp(0.0, input_width - 1.0);
    let clamped_y = scaled_y.clamp(0.0, input_height - 1.0);
    let point_x = clamped_x / session.input_scale_x + session.input_origin_x;
    let point_y = clamped_y / session.input_scale_y + session.input_origin_y;
    if cursor_trace_enabled() {
        cursor_trace_log(&format!(
            "cursor_trace pointer raw=({},{}) scaled=({:.2},{:.2}) clamped=({:.2},{:.2}) point=({:.2},{:.2}) input={}x{} scale=({:.3},{:.3}) origin=({:.2},{:.2}) frame={}x{}",
            x,
            y,
            scaled_x,
            scaled_y,
            clamped_x,
            clamped_y,
            point_x,
            point_y,
            session.input_width,
            session.input_height,
            session.input_scale_x,
            session.input_scale_y,
            session.input_origin_x,
            session.input_origin_y,
            session.width,
            session.height
        ));
    }
    enigo.mouse_move_to(point_x.round() as i32, point_y.round() as i32);

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
