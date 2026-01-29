use crate::server;
use get_if_addrs::get_if_addrs;
use qrcode::render::svg;
use qrcode::QrCode;
use rand::{distributions::Alphanumeric, Rng};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::State;

const PAIRING_TTL_SECS: u64 = 180;
const TUNNEL_READY_TIMEOUT: Duration = Duration::from_secs(12);
const LOCAL_SERVER_HEALTH_TIMEOUT: Duration = Duration::from_millis(500);
const LOCAL_SERVER_HEALTH_RETRIES: usize = 3;
const LOCAL_SERVER_HEALTH_RETRY_DELAY: Duration = Duration::from_millis(120);
const LOCAL_SERVER_ERROR_PREFIX: &str = "Local server unavailable.";
const LOCAL_SERVER_ERROR_MESSAGE: &str =
    "Local server unavailable. Restart the desktop agent and retry pairing.";
const CLOUDFLARED_INSTALL_URL: &str =
    "https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/";

#[derive(Debug, Serialize, Deserialize)]
struct PairingPayload {
    token: String,
    secret: String,
    expires_at: u64,
    tunnel_url: Option<String>,
    tunnel_error: Option<String>,
    local_urls: Vec<String>,
    requires_approval: bool,
}

#[derive(Debug, Serialize)]
pub struct PairingSessionResponse {
    pub token: String,
    pub secret: String,
    pub expires_at: u64,
    pub qr_payload: String,
    pub qr_svg: String,
    pub tunnel_url: Option<String>,
    pub tunnel_error: Option<String>,
    pub local_urls: Vec<String>,
    pub requires_approval: bool,
}

#[derive(Debug, Serialize)]
pub struct PairingConfirmResponse {
    pub status: String,
    pub connected_at: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct PairingError {
    pub code: String,
    pub message: String,
}

impl PairingError {
    fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.to_string(),
            message: message.to_string(),
        }
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct PairingSessionInfo {
    pub token: String,
    pub secret: String,
    pub expires_at: u64,
}

#[derive(Debug, Serialize, Clone)]
pub struct PendingConfirmationInfo {
    pub token: String,
    pub requested_at: u64,
    pub source: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PairingStatusResponse {
    pub session: Option<PairingSessionInfo>,
    pub connected_at: Option<u64>,
    pub pending: Option<PendingConfirmationInfo>,
    pub requires_approval: bool,
    pub local_urls: Vec<String>,
    pub tunnel_url: Option<String>,
    pub tunnel_error: Option<String>,
}

pub struct PairingState {
    session: Option<PairingSession>,
    connected_at: Option<u64>,
    pending_confirmation: Option<PendingConfirmation>,
    requires_approval: bool,
    tunnel: Option<TunnelState>,
    tunnel_error: Option<String>,
    local_port: Option<u16>,
}

impl Default for PairingState {
    fn default() -> Self {
        Self {
            session: None,
            connected_at: None,
            pending_confirmation: None,
            requires_approval: false,
            tunnel: None,
            tunnel_error: None,
            local_port: None,
        }
    }
}

#[derive(Debug, Clone)]
struct PairingSession {
    token: String,
    secret: String,
    expires_at: u64,
}

#[derive(Debug, Clone)]
struct PendingConfirmation {
    token: String,
    requested_at: u64,
    source: Option<String>,
}

struct TunnelState {
    url: String,
    process: Child,
}

struct TunnelDetails {
    url: Option<String>,
    error: Option<String>,
}

struct TunnelHandle {
    url: String,
    process: Child,
}

struct TunnelStartError {
    message: String,
}

impl TunnelStartError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

#[tauri::command]
pub fn create_pairing_session(
    state: State<Arc<Mutex<PairingState>>>,
) -> Result<PairingSessionResponse, PairingError> {
    let token = generate_code(6);
    let secret = generate_code(8);
    let now = current_timestamp()?;
    let expires_at = now + PAIRING_TTL_SECS;

    let session = PairingSession {
        token,
        secret,
        expires_at,
    };

    let state = state.inner().clone();
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;

    let tunnel_details = ensure_tunnel(&state, &mut pairing_state);
    let local_urls = current_local_urls(&pairing_state);

    let payload = PairingPayload {
        token: session.token.clone(),
        secret: session.secret.clone(),
        expires_at: session.expires_at,
        tunnel_url: tunnel_details.url.clone(),
        tunnel_error: tunnel_details.error.clone(),
        local_urls: local_urls.clone(),
        requires_approval: pairing_state.requires_approval,
    };

    let qr_payload = serde_json::to_string(&payload)
        .map_err(|_| PairingError::new("payload_error", "Failed to build QR payload."))?;
    let qr_svg = build_qr_svg(&qr_payload)?;

    pairing_state.session = Some(session.clone());
    pairing_state.connected_at = None;
    pairing_state.pending_confirmation = None;

    Ok(PairingSessionResponse {
        token: session.token,
        secret: session.secret,
        expires_at: session.expires_at,
        qr_payload,
        qr_svg,
        tunnel_url: tunnel_details.url,
        tunnel_error: tunnel_details.error,
        local_urls,
        requires_approval: pairing_state.requires_approval,
    })
}

#[tauri::command]
pub fn confirm_pairing_session(
    state: State<Arc<Mutex<PairingState>>>,
    token: String,
    secret: String,
) -> Result<PairingConfirmResponse, PairingError> {
    confirm_pairing_with_state(state.inner(), &token, &secret, Some("tauri".to_string()))
}

#[tauri::command]
pub fn get_pairing_status(
    state: State<Arc<Mutex<PairingState>>>,
) -> Result<PairingStatusResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    refresh_local_server(state.inner(), &mut pairing_state);
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn set_pairing_requires_approval(
    state: State<Arc<Mutex<PairingState>>>,
    requires_approval: bool,
) -> Result<PairingStatusResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state.requires_approval = requires_approval;
    if !requires_approval && pairing_state.pending_confirmation.is_some() {
        let now = current_timestamp()?;
        pairing_state.connected_at = Some(now);
        pairing_state.pending_confirmation = None;
    }
    refresh_local_server(state.inner(), &mut pairing_state);
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn approve_pairing_request(
    state: State<Arc<Mutex<PairingState>>>,
) -> Result<PairingConfirmResponse, PairingError> {
    let now = current_timestamp()?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let session = pairing_state
        .session
        .as_ref()
        .ok_or_else(|| PairingError::new("missing_token", "No active pairing token."))?;
    if pairing_state.pending_confirmation.is_none() {
        return Err(PairingError::new(
            "no_pending",
            "No pending pairing requests.",
        ));
    }
    if now > session.expires_at {
        return Err(PairingError::new(
            "token_expired",
            "Pairing token expired. Generate a new token.",
        ));
    }
    pairing_state.connected_at = Some(now);
    pairing_state.pending_confirmation = None;
    Ok(PairingConfirmResponse {
        status: "connected".to_string(),
        connected_at: Some(now),
    })
}

#[tauri::command]
pub fn deny_pairing_request(
    state: State<Arc<Mutex<PairingState>>>,
) -> Result<PairingStatusResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state.pending_confirmation = None;
    refresh_local_server(state.inner(), &mut pairing_state);
    Ok(build_pairing_status(&pairing_state))
}

pub(crate) fn confirm_pairing_with_state(
    state: &Arc<Mutex<PairingState>>,
    token: &str,
    secret: &str,
    source: Option<String>,
) -> Result<PairingConfirmResponse, PairingError> {
    let now = current_timestamp()?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    confirm_pairing_locked(&mut pairing_state, token, secret, source, now)
}

fn confirm_pairing_locked(
    pairing_state: &mut PairingState,
    token: &str,
    secret: &str,
    source: Option<String>,
    now: u64,
) -> Result<PairingConfirmResponse, PairingError> {
    let session = pairing_state
        .session
        .as_ref()
        .ok_or_else(|| PairingError::new("missing_token", "No active pairing token."))?;

    if now > session.expires_at {
        return Err(PairingError::new(
            "token_expired",
            "Pairing token expired. Generate a new token.",
        ));
    }

    if session.token != token.trim() {
        return Err(PairingError::new(
            "token_mismatch",
            "Pairing token does not match.",
        ));
    }

    if session.secret != secret.trim() {
        return Err(PairingError::new(
            "secret_mismatch",
            "Shared secret does not match.",
        ));
    }

    if pairing_state.requires_approval {
        if let Some(connected_at) = pairing_state.connected_at {
            return Ok(PairingConfirmResponse {
                status: "connected".to_string(),
                connected_at: Some(connected_at),
            });
        }
        pairing_state.pending_confirmation = Some(PendingConfirmation {
            token: session.token.clone(),
            requested_at: now,
            source,
        });
        return Ok(PairingConfirmResponse {
            status: "pending".to_string(),
            connected_at: None,
        });
    }

    pairing_state.connected_at = Some(now);
    pairing_state.pending_confirmation = None;

    Ok(PairingConfirmResponse {
        status: "connected".to_string(),
        connected_at: Some(now),
    })
}

fn build_pairing_status(pairing_state: &PairingState) -> PairingStatusResponse {
    let session = pairing_state.session.as_ref().map(|session| PairingSessionInfo {
        token: session.token.clone(),
        secret: session.secret.clone(),
        expires_at: session.expires_at,
    });
    let pending = pairing_state.pending_confirmation.as_ref().map(|pending| {
        PendingConfirmationInfo {
            token: pending.token.clone(),
            requested_at: pending.requested_at,
            source: pending.source.clone(),
        }
    });
    let local_urls = current_local_urls(pairing_state);
    PairingStatusResponse {
        session,
        connected_at: pairing_state.connected_at,
        pending,
        requires_approval: pairing_state.requires_approval,
        local_urls,
        tunnel_url: pairing_state.tunnel.as_ref().map(|tunnel| tunnel.url.clone()),
        tunnel_error: pairing_state.tunnel_error.clone(),
    }
}

fn ensure_tunnel(state: &Arc<Mutex<PairingState>>, pairing_state: &mut PairingState) -> TunnelDetails {
    if let Some(tunnel) = pairing_state.tunnel.as_mut() {
        if tunnel_is_alive(tunnel) {
            return TunnelDetails {
                url: Some(tunnel.url.clone()),
                error: pairing_state.tunnel_error.clone(),
            };
        }
        pairing_state.tunnel = None;
    }

    let port = match ensure_local_server(state, pairing_state) {
        Ok(port) => {
            clear_local_server_error(pairing_state);
            port
        }
        Err(error) => {
            pairing_state.tunnel_error = Some(error.message);
            return TunnelDetails {
                url: None,
                error: pairing_state.tunnel_error.clone(),
            };
        }
    };

    match start_cloudflared_tunnel(port) {
        Ok(handle) => {
            pairing_state.tunnel = Some(TunnelState {
                url: handle.url.clone(),
                process: handle.process,
            });
            pairing_state.tunnel_error = None;
            TunnelDetails {
                url: Some(handle.url),
                error: None,
            }
        }
        Err(error) => {
            pairing_state.tunnel_error = Some(error.message.clone());
            TunnelDetails {
                url: None,
                error: Some(error.message),
            }
        }
    }
}

fn tunnel_is_alive(tunnel: &mut TunnelState) -> bool {
    match tunnel.process.try_wait() {
        Ok(None) => true,
        _ => false,
    }
}

fn ensure_local_server(
    state: &Arc<Mutex<PairingState>>,
    pairing_state: &mut PairingState,
) -> Result<u16, PairingError> {
    if let Some(port) = pairing_state.local_port {
        if is_local_server_healthy(port) {
            return Ok(port);
        }
        pairing_state.local_port = None;
    }

    match start_local_tunnel_server(state.clone()) {
        Ok(port) => {
            if is_local_server_healthy(port) {
                pairing_state.local_port = Some(port);
                Ok(port)
            } else {
                pairing_state.local_port = None;
                Err(PairingError::new(
                    "local_server_unavailable",
                    LOCAL_SERVER_ERROR_MESSAGE,
                ))
            }
        }
        Err(_) => {
            pairing_state.local_port = None;
            Err(PairingError::new(
                "local_server_unavailable",
                LOCAL_SERVER_ERROR_MESSAGE,
            ))
        }
    }
}

fn refresh_local_server(state: &Arc<Mutex<PairingState>>, pairing_state: &mut PairingState) {
    if ensure_local_server(state, pairing_state).is_ok() {
        clear_local_server_error(pairing_state);
    } else {
        pairing_state.tunnel_error = Some(LOCAL_SERVER_ERROR_MESSAGE.to_string());
    }
}

fn clear_local_server_error(pairing_state: &mut PairingState) {
    if let Some(error) = pairing_state.tunnel_error.as_deref() {
        if error.starts_with(LOCAL_SERVER_ERROR_PREFIX) {
            pairing_state.tunnel_error = None;
        }
    }
}

fn is_local_server_healthy(port: u16) -> bool {
    let url = format!("http://127.0.0.1:{port}/health");
    let client = match Client::builder()
        .timeout(LOCAL_SERVER_HEALTH_TIMEOUT)
        .no_proxy()
        .build()
    {
        Ok(client) => client,
        Err(_) => return false,
    };
    for attempt in 0..LOCAL_SERVER_HEALTH_RETRIES {
        if attempt > 0 {
            thread::sleep(LOCAL_SERVER_HEALTH_RETRY_DELAY);
        }
        match client.get(&url).send() {
            Ok(response) => {
                if response.status().is_success() {
                    return true;
                }
            }
            Err(_) => {}
        }
    }
    false
}

fn start_local_tunnel_server(state: Arc<Mutex<PairingState>>) -> Result<u16, std::io::Error> {
    server::start_local_server(state)
}

fn start_cloudflared_tunnel(port: u16) -> Result<TunnelHandle, TunnelStartError> {
    let url = format!("http://127.0.0.1:{port}");
    let mut child = Command::new("cloudflared")
        .args(["tunnel", "--url", &url, "--no-autoupdate"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            TunnelStartError::new(format!(
                "Cloudflared could not be started ({error}). Install it from {CLOUDFLARED_INSTALL_URL} and retry pairing."
            ))
        })?;

    let (sender, receiver) = mpsc::channel();

    if let Some(stdout) = child.stdout.take() {
        spawn_output_reader(stdout, sender.clone());
    }
    if let Some(stderr) = child.stderr.take() {
        spawn_output_reader(stderr, sender.clone());
    }

    let deadline = Instant::now() + TUNNEL_READY_TIMEOUT;
    while Instant::now() < deadline {
        if let Ok(line) = receiver.recv_timeout(Duration::from_millis(250)) {
            if let Some(url) = extract_tunnel_url(&line) {
                return Ok(TunnelHandle { url, process: child });
            }
        }

        if let Ok(Some(status)) = child.try_wait() {
            return Err(TunnelStartError::new(format!(
                "Cloudflared exited before reporting a tunnel URL (status: {status}). Install it from {CLOUDFLARED_INSTALL_URL} and retry pairing."
            )));
        }
    }

    Err(TunnelStartError::new(
        "Cloudflared started but the tunnel URL was not detected. Check your internet connection and retry pairing.",
    ))
}

fn spawn_output_reader<R: Read + Send + 'static>(reader: R, sender: mpsc::Sender<String>) {
    thread::spawn(move || {
        let buffered = BufReader::new(reader);
        for line in buffered.lines().flatten() {
            let _ = sender.send(line);
        }
    });
}

fn extract_tunnel_url(line: &str) -> Option<String> {
    let start = line.find("https://")?;
    let candidate = &line[start..];
    let end = candidate
        .find(|c: char| c.is_whitespace())
        .unwrap_or(candidate.len());
    let trimmed = candidate[..end].trim_end_matches(|c: char| {
        !c.is_ascii_alphanumeric() && c != '.' && c != ':' && c != '/' && c != '-'
    });

    if trimmed.starts_with("https://") {
        Some(trimmed.to_string())
    } else {
        None
    }
}

fn generate_code(length: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(length)
        .map(char::from)
        .collect::<String>()
        .to_uppercase()
}

fn current_timestamp() -> Result<u64, PairingError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| PairingError::new("time_error", "Failed to read system time."))
}

fn current_local_urls(pairing_state: &PairingState) -> Vec<String> {
    let port = match pairing_state.local_port {
        Some(port) => port,
        None => return Vec::new(),
    };
    let mut urls = Vec::new();
    if let Ok(interfaces) = get_if_addrs() {
        for iface in interfaces {
            if iface.is_loopback() {
                continue;
            }
            if let std::net::IpAddr::V4(addr) = iface.ip() {
                let octets = addr.octets();
                if octets[0] == 169 && octets[1] == 254 {
                    // Skip link-local IPv4 (APIPA) addresses.
                    continue;
                }
                urls.push(format!("http://{}:{}", addr, port));
            }
        }
    }
    urls.sort();
    urls.dedup();
    urls
}

fn build_qr_svg(payload: &str) -> Result<String, PairingError> {
    let code =
        QrCode::new(payload.as_bytes()).map_err(|_| PairingError::new("qr_error", "Invalid QR data."))?;
    Ok(code
        .render::<svg::Color>()
        .min_dimensions(220, 220)
        .dark_color(svg::Color("#1e293b"))
        .light_color(svg::Color("#f8fafc"))
        .build())
}
