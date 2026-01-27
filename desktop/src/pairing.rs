use crate::command::{handle_agent_command, AgentCommandRequest};
use qrcode::render::svg;
use qrcode::QrCode;
use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::State;

const PAIRING_TTL_SECS: u64 = 180;
const TUNNEL_READY_TIMEOUT: Duration = Duration::from_secs(12);
const CLOUDFLARED_INSTALL_URL: &str =
    "https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/";

#[derive(Debug, Serialize, Deserialize)]
struct PairingPayload {
    token: String,
    secret: String,
    expires_at: u64,
    tunnel_url: Option<String>,
    tunnel_error: Option<String>,
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
}

#[derive(Debug, Serialize)]
pub struct PairingConfirmResponse {
    pub status: String,
    pub connected_at: u64,
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

pub struct PairingState {
    session: Option<PairingSession>,
    connected_at: Option<u64>,
    tunnel: Option<TunnelState>,
    tunnel_error: Option<String>,
    local_port: Option<u16>,
}

impl Default for PairingState {
    fn default() -> Self {
        Self {
            session: None,
            connected_at: None,
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
    state: State<Mutex<PairingState>>,
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

    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;

    let tunnel_details = ensure_tunnel(&mut pairing_state);

    let payload = PairingPayload {
        token: session.token.clone(),
        secret: session.secret.clone(),
        expires_at: session.expires_at,
        tunnel_url: tunnel_details.url.clone(),
        tunnel_error: tunnel_details.error.clone(),
    };

    let qr_payload = serde_json::to_string(&payload)
        .map_err(|_| PairingError::new("payload_error", "Failed to build QR payload."))?;
    let qr_svg = build_qr_svg(&qr_payload)?;

    pairing_state.session = Some(session.clone());
    pairing_state.connected_at = None;

    Ok(PairingSessionResponse {
        token: session.token,
        secret: session.secret,
        expires_at: session.expires_at,
        qr_payload,
        qr_svg,
        tunnel_url: tunnel_details.url,
        tunnel_error: tunnel_details.error,
    })
}

#[tauri::command]
pub fn confirm_pairing_session(
    state: State<Mutex<PairingState>>,
    token: String,
    secret: String,
) -> Result<PairingConfirmResponse, PairingError> {
    let now = current_timestamp()?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
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

    pairing_state.connected_at = Some(now);

    Ok(PairingConfirmResponse {
        status: "connected".to_string(),
        connected_at: now,
    })
}

fn ensure_tunnel(pairing_state: &mut PairingState) -> TunnelDetails {
    if let Some(tunnel) = pairing_state.tunnel.as_mut() {
        if tunnel_is_alive(tunnel) {
            return TunnelDetails {
                url: Some(tunnel.url.clone()),
                error: pairing_state.tunnel_error.clone(),
            };
        }
        pairing_state.tunnel = None;
    }

    let port = match pairing_state.local_port {
        Some(port) => port,
        None => match start_local_tunnel_server() {
            Ok(port) => {
                pairing_state.local_port = Some(port);
                port
            }
            Err(_) => {
                let message =
                    "Unable to start the local tunnel listener. Restart the desktop agent and retry pairing.";
                pairing_state.tunnel_error = Some(message.to_string());
                return TunnelDetails {
                    url: None,
                    error: Some(message.to_string()),
                };
            }
        },
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

fn start_local_tunnel_server() -> Result<u16, std::io::Error> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();

    thread::spawn(move || {
        for stream in listener.incoming() {
            if let Ok(stream) = stream {
                handle_tunnel_request(stream);
            }
        }
    });

    Ok(port)
}

fn handle_tunnel_request(mut stream: TcpStream) {
    let request = match read_tunnel_http_request(&mut stream) {
        Ok(request) => request,
        Err(_) => {
            let body = json!({
                "error": {
                    "code": "invalid_request",
                    "message": "Malformed HTTP request."
                }
            })
            .to_string();
            write_tunnel_response(&mut stream, 400, &body);
            return;
        }
    };

    if request.method.eq_ignore_ascii_case("OPTIONS") {
        write_tunnel_empty_response(&mut stream, 204);
        return;
    }

    if request.path.starts_with("/command") {
        if !request.method.eq_ignore_ascii_case("POST") {
            let body = json!({
                "error": {
                    "code": "method_not_allowed",
                    "message": "Use POST to send agent commands."
                }
            })
            .to_string();
            write_tunnel_response(&mut stream, 405, &body);
            return;
        }

        let command_request: AgentCommandRequest =
            match serde_json::from_slice(&request.body) {
                Ok(request) => request,
                Err(error) => {
                    let body = json!({
                        "error": {
                            "code": "invalid_payload",
                            "message": format!("Invalid JSON payload: {error}")
                        }
                    })
                    .to_string();
                    write_tunnel_response(&mut stream, 400, &body);
                    return;
                }
            };

        let response = handle_agent_command(command_request);
        let body = serde_json::to_string(&response).unwrap_or_else(|_| {
            json!({
                "error": {
                    "code": "serialize_failed",
                    "message": "Failed to serialize agent response."
                }
            })
            .to_string()
        });
        write_tunnel_response(&mut stream, 200, &body);
        return;
    }

    let body = json!({
        "status": "ok",
        "message": "Vibe Inspect tunnel active"
    })
    .to_string();
    write_tunnel_response(&mut stream, 200, &body);
}

struct TunnelHttpRequest {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

fn read_tunnel_http_request(
    stream: &mut TcpStream,
) -> Result<TunnelHttpRequest, std::io::Error> {
    let mut buffer = Vec::new();
    let mut temp = [0u8; 1024];
    let mut header_end = None;

    while header_end.is_none() {
        let bytes_read = stream.read(&mut temp)?;
        if bytes_read == 0 {
            break;
        }
        buffer.extend_from_slice(&temp[..bytes_read]);
        header_end = find_header_end(&buffer);
        if buffer.len() > 1024 * 1024 {
            break;
        }
    }

    let header_end = header_end.ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "Missing headers")
    })?;

    let header_text = String::from_utf8_lossy(&buffer[..header_end]);
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let path = parts.next().unwrap_or("/").to_string();
    let mut headers = HashMap::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((key, value)) = line.split_once(':') {
            headers.insert(key.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }

    let content_length = headers
        .get("content-length")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let mut body = buffer[header_end + 4..].to_vec();
    while body.len() < content_length {
        let bytes_read = stream.read(&mut temp)?;
        if bytes_read == 0 {
            break;
        }
        body.extend_from_slice(&temp[..bytes_read]);
        if body.len() > content_length {
            body.truncate(content_length);
            break;
        }
    }
    body.truncate(content_length);

    Ok(TunnelHttpRequest {
        method,
        path,
        headers,
        body,
    })
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
}

fn write_tunnel_response(stream: &mut TcpStream, status: u16, body: &str) {
    let status_text = status_text(status);
    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n{}",
        status,
        status_text,
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
}

fn write_tunnel_empty_response(stream: &mut TcpStream, status: u16) {
    let status_text = status_text(status);
    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: 0\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n",
        status,
        status_text
    );
    let _ = stream.write_all(response.as_bytes());
}

fn status_text(status: u16) -> &'static str {
    match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        _ => "OK",
    }
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
        .map(Duration::as_secs)
        .map_err(|_| PairingError::new("time_error", "Failed to read system time."))
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
