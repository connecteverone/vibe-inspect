use qrcode::render::svg;
use qrcode::QrCode;
use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::State;

const PAIRING_TTL_SECS: u64 = 180;

#[derive(Debug, Serialize, Deserialize)]
struct PairingPayload {
    token: String,
    secret: String,
    expires_at: u64,
}

#[derive(Debug, Serialize)]
pub struct PairingSessionResponse {
    pub token: String,
    pub secret: String,
    pub expires_at: u64,
    pub qr_payload: String,
    pub qr_svg: String,
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

#[derive(Default)]
pub struct PairingState {
    session: Option<PairingSession>,
    connected_at: Option<u64>,
}

#[derive(Debug, Clone)]
struct PairingSession {
    token: String,
    secret: String,
    expires_at: u64,
}

#[tauri::command]
pub fn create_pairing_session(
    state: State<Mutex<PairingState>>,
) -> Result<PairingSessionResponse, PairingError> {
    let token = generate_code(6);
    let secret = generate_code(8);
    let now = current_timestamp()?;
    let expires_at = now + PAIRING_TTL_SECS;
    let payload = PairingPayload {
        token: token.clone(),
        secret: secret.clone(),
        expires_at,
    };
    let qr_payload = serde_json::to_string(&payload)
        .map_err(|_| PairingError::new("payload_error", "Failed to build QR payload."))?;
    let qr_svg = build_qr_svg(&qr_payload)?;

    let session = PairingSession {
        token,
        secret,
        expires_at,
    };

    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state.session = Some(session.clone());
    pairing_state.connected_at = None;

    Ok(PairingSessionResponse {
        token: session.token,
        secret: session.secret,
        expires_at: session.expires_at,
        qr_payload,
        qr_svg,
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
