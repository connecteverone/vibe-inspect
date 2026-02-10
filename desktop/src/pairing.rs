use crate::identity::{load_or_create_identity, AgentIdentity};
use crate::roi::RoiErrorCode;
use crate::server;
use crate::terminal;
use get_if_addrs::get_if_addrs;
use qrcode::render::svg;
use qrcode::QrCode;
use rand::{distributions::Alphanumeric, Rng};
use reqwest::blocking::Client;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::State;

const PAIRING_TTL_SECS: u64 = 180;
const APPROVAL_TTL_SECS: u64 = 60;
const PAIRING_PROTOCOL_VERSION: &str = "1.1";
const TUNNEL_READY_TIMEOUT: Duration = Duration::from_secs(12);
const LOCAL_SERVER_HEALTH_TIMEOUT: Duration = Duration::from_millis(500);
const LOCAL_SERVER_HEALTH_RETRIES: usize = 3;
const LOCAL_SERVER_HEALTH_RETRY_DELAY: Duration = Duration::from_millis(120);
const LOCAL_SERVER_ERROR_PREFIX: &str = "Local server unavailable.";
const LOCAL_SERVER_ERROR_MESSAGE: &str =
    "Local server unavailable. Restart the desktop agent and retry pairing.";
const ACTIVE_CLIENT_WINDOW_SECS: u64 = 45;
const CLOUDFLARED_INSTALL_URL: &str =
    "https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/";
const LONG_TOKEN_LEN: usize = 64;
const AUTH_FAIL_WINDOW_SECS: u64 = 60;
const AUTH_FAIL_LIMIT: u32 = 6;
const AUTH_BLOCK_SECS: u64 = 120;
const WS_TICKET_TTL_SECS: u64 = 30;
const WS_TICKET_MAX_ACTIVE: usize = 1024;
const WS_TICKET_LEN: usize = 48;

fn listen_port_in_use_message(port: u16) -> String {
    format!(
        "{LOCAL_SERVER_ERROR_PREFIX} Listen port {port} is already in use. Stop the other app using port {port} or update the listen port in Settings, then restart the desktop agent."
    )
}

fn roi_quic_port_in_use_message(port: u16) -> String {
    format!(
        "{LOCAL_SERVER_ERROR_PREFIX} ROI QUIC port {port} is already in use. Stop the other app using port {port} or update the ROI QUIC port in Settings, then restart the desktop agent."
    )
}

#[derive(Debug, Serialize)]
pub struct PairingSessionResponse {
    pub protocol_version: String,
    pub token: String,
    pub secret: String,
    pub nonce: String,
    pub expires_at: u64,
    pub qr_payload: String,
    pub qr_svg: String,
    pub tunnel_url: Option<String>,
    pub tunnel_error: Option<String>,
    pub local_urls: Vec<String>,
    pub requires_approval: bool,
    pub device_id: String,
    pub host_name: Option<String>,
    pub auth_token: String,
    pub wifi_ssid: Option<String>,
    pub local_ips: Vec<String>,
    pub frp_url: Option<String>,
    pub transports: Vec<TransportEndpointSnapshot>,
    pub listen_port: u16,
    pub roi_quic_port: u16,
}

#[derive(Debug, Serialize)]
pub struct PairingConfirmResponse {
    pub status: String,
    pub connected_at: Option<u64>,
    pub device_id: Option<String>,
    pub auth_token: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PairingError {
    pub code: String,
    pub message: String,
}

impl PairingError {
    pub(crate) fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.to_string(),
            message: message.to_string(),
        }
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct PairingSessionInfo {
    pub protocol_version: String,
    pub token: String,
    pub secret: String,
    pub nonce: String,
    pub expires_at: u64,
}

#[derive(Debug, Serialize, Clone)]
pub struct PendingConfirmationInfo {
    pub token: String,
    pub requested_at: u64,
    pub expires_at: u64,
    pub source: Option<String>,
    pub client_id: Option<String>,
    pub client_name: Option<String>,
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
    pub device_id: String,
    pub host_name: Option<String>,
    pub auth_token: String,
    pub auth_tokens: Vec<AuthTokenSnapshot>,
    pub wifi_ssid: Option<String>,
    pub location_permission: Option<String>,
    pub bundle_id: Option<String>,
    pub bundle_path: Option<String>,
    pub location_usage_key: Option<bool>,
    pub local_ips: Vec<String>,
    pub frp_url: Option<String>,
    pub transports: Vec<TransportEndpointSnapshot>,
    pub listen_port: u16,
    pub roi_quic_port: u16,
    pub paired_devices: Vec<ClientSnapshot>,
    pub active_devices: Vec<ClientSnapshot>,
    pub connected_devices: Vec<ClientSnapshot>,
    pub terminal_sessions: Vec<desktop::terminal_core::TerminalSessionSummary>,
    pub terminal_error_code: Option<String>,
    pub terminal_error_message: Option<String>,
    pub terminal_update_available: bool,
    pub terminal_update_message: Option<String>,
    pub terminal_running_version: Option<String>,
    pub terminal_bundled_version: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct TransportEndpointSnapshot {
    pub r#type: String,
    pub url: String,
    pub priority: u32,
    pub probe_timeout_ms: u64,
    pub enabled: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct AuthTokenSnapshot {
    pub token: String,
    pub label: Option<String>,
    pub created_at: u64,
    pub revoked_at: Option<u64>,
    pub client_id: Option<String>,
    pub is_primary: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct ClientSnapshot {
    pub id: String,
    pub name: String,
    pub paired_at: Option<u64>,
    pub last_seen_at: Option<u64>,
    pub source: Option<String>,
    pub disabled: bool,
    pub blocked_until: Option<u64>,
}

pub struct PairingState {
    session: Option<PairingSession>,
    connected_at: Option<u64>,
    pending_confirmation: Option<PendingConfirmation>,
    requires_approval: bool,
    tunnel: Option<TunnelState>,
    tunnel_error: Option<String>,
    local_port: Option<u16>,
    local_server: Option<server::LocalServerHandle>,
    identity: AgentIdentity,
    clients: HashMap<String, ClientInfo>,
    blocked_clients: HashMap<String, Option<u64>>,
    connected_clients: HashMap<String, usize>,
    auth_failures: HashMap<String, AuthFailure>,
    ws_tickets: HashMap<String, WsTicket>,
}

impl Default for PairingState {
    fn default() -> Self {
        let identity = load_or_create_identity();
        Self {
            session: None,
            connected_at: None,
            pending_confirmation: None,
            requires_approval: true,
            tunnel: None,
            tunnel_error: None,
            local_port: None,
            local_server: None,
            identity,
            clients: HashMap::new(),
            blocked_clients: HashMap::new(),
            connected_clients: HashMap::new(),
            auth_failures: HashMap::new(),
            ws_tickets: HashMap::new(),
        }
    }
}

impl PairingState {
    pub fn auth_token(&self) -> &str {
        &self.identity.auth_token
    }

    pub fn device_id(&self) -> &str {
        &self.identity.device_id
    }

    pub fn host_name(&self) -> Option<String> {
        self.identity.host_name()
    }

    pub fn frp_url(&self) -> Option<String> {
        self.identity.frp_url.clone()
    }

    pub fn tunnel_url(&self) -> Option<String> {
        self.tunnel.as_ref().map(|tunnel| tunnel.url.clone())
    }

    pub fn listen_port(&self) -> u16 {
        self.identity.listen_port()
    }

    pub fn roi_quic_port(&self) -> u16 {
        self.identity.roi_quic_port()
    }

    pub fn is_auth_token_valid(&self, token: &str, client_id: Option<&str>) -> bool {
        self.identity.is_token_valid(token, client_id)
    }

    pub fn issue_ws_ticket(
        &mut self,
        scope: &str,
        session_id: Option<&str>,
        client_id: Option<&str>,
    ) -> Result<(String, u64), PairingError> {
        let now = current_timestamp().unwrap_or_default();
        self.prune_ws_tickets(now);
        let normalized_scope = scope.trim().to_lowercase();
        if normalized_scope.is_empty() {
            return Err(PairingError::new(
                "invalid_scope",
                "WebSocket ticket scope is required.",
            ));
        }
        let normalized_session = session_id
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(|value| value.to_string());
        let normalized_client = client_id
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(|value| value.to_string());

        let token = generate_code(WS_TICKET_LEN);
        let expires_at = now.saturating_add(WS_TICKET_TTL_SECS);
        self.ws_tickets.insert(
            token.clone(),
            WsTicket {
                scope: normalized_scope,
                session_id: normalized_session,
                client_id: normalized_client,
                issued_at: now,
                expires_at,
            },
        );
        self.trim_ws_tickets();
        Ok((token, expires_at))
    }

    pub fn consume_ws_ticket(
        &mut self,
        token: &str,
        scope: &str,
        session_id: Option<&str>,
        client_id: Option<&str>,
    ) -> bool {
        let now = current_timestamp().unwrap_or_default();
        self.prune_ws_tickets(now);

        let trimmed = token.trim();
        if trimmed.is_empty() {
            return false;
        }

        let Some(ticket) = self.ws_tickets.remove(trimmed) else {
            return false;
        };

        if ticket.expires_at > 0 && now > ticket.expires_at {
            return false;
        }

        let normalized_scope = scope.trim().to_lowercase();
        if normalized_scope.is_empty() || normalized_scope != ticket.scope {
            return false;
        }

        let requested_session = session_id
            .map(|value| value.trim())
            .filter(|value| !value.is_empty());
        if let Some(bound_session) = ticket.session_id.as_deref() {
            if Some(bound_session) != requested_session {
                return false;
            }
        }

        let requested_client = client_id
            .map(|value| value.trim())
            .filter(|value| !value.is_empty());
        if let Some(bound_client) = ticket.client_id.as_deref() {
            if Some(bound_client) != requested_client {
                return false;
            }
        }

        true
    }

    fn prune_ws_tickets(&mut self, now: u64) {
        self.ws_tickets
            .retain(|_, ticket| ticket.expires_at == 0 || now <= ticket.expires_at);
    }

    fn trim_ws_tickets(&mut self) {
        while self.ws_tickets.len() > WS_TICKET_MAX_ACTIVE {
            let oldest = self
                .ws_tickets
                .iter()
                .min_by_key(|(_, ticket)| ticket.issued_at)
                .map(|(token, _)| token.clone());
            let Some(oldest) = oldest else {
                break;
            };
            self.ws_tickets.remove(&oldest);
        }
    }

    pub fn connect_client(&mut self, client_id: &str) {
        let entry = self
            .connected_clients
            .entry(client_id.to_string())
            .or_insert(0);
        *entry = entry.saturating_add(1);
    }

    pub fn disconnect_client(&mut self, client_id: &str) {
        if let Some(count) = self.connected_clients.get_mut(client_id) {
            if *count <= 1 {
                self.connected_clients.remove(client_id);
            } else {
                *count -= 1;
            }
        }
    }

    pub fn is_client_blocked(&mut self, client_id: &str, now: u64) -> bool {
        is_client_blocked(self, client_id, now)
    }

    pub fn is_auth_blocked(&mut self, client_id: Option<&str>, now: u64) -> bool {
        let key = auth_failure_key(client_id);
        if let Some(entry) = self.auth_failures.get(&key) {
            if let Some(until) = entry.blocked_until {
                if until > now {
                    return true;
                }
            }
        }
        false
    }

    pub fn record_auth_success(&mut self, client_id: Option<&str>) {
        let key = auth_failure_key(client_id);
        self.auth_failures.remove(&key);
    }

    pub fn record_auth_failure(&mut self, client_id: Option<&str>, now: u64) -> Option<u64> {
        let key = auth_failure_key(client_id);
        let entry = self.auth_failures.entry(key).or_insert(AuthFailure {
            count: 0,
            first_seen: now,
            blocked_until: None,
        });
        if entry.first_seen.saturating_add(AUTH_FAIL_WINDOW_SECS) < now {
            entry.count = 0;
            entry.first_seen = now;
            entry.blocked_until = None;
        }
        entry.count = entry.count.saturating_add(1);
        if entry.count >= AUTH_FAIL_LIMIT {
            let until = now.saturating_add(AUTH_BLOCK_SECS);
            entry.blocked_until = Some(until);
            return Some(until);
        }
        None
    }
}

#[derive(Debug, Clone)]
struct PairingSession {
    protocol_version: String,
    token: String,
    secret: String,
    nonce: String,
    expires_at: u64,
}

#[derive(Debug, Clone)]
struct PendingConfirmation {
    token: String,
    requested_at: u64,
    expires_at: u64,
    source: Option<String>,
    client_id: Option<String>,
    client_name: Option<String>,
}

#[derive(Debug, Clone)]
struct WsTicket {
    scope: String,
    session_id: Option<String>,
    client_id: Option<String>,
    issued_at: u64,
    expires_at: u64,
}

#[derive(Debug, Clone)]
struct ClientInfo {
    id: String,
    name: String,
    paired_at: Option<u64>,
    last_seen_at: Option<u64>,
    source: Option<String>,
}

struct AuthFailure {
    count: u32,
    first_seen: u64,
    blocked_until: Option<u64>,
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
    let nonce = generate_code(12);
    let now = current_timestamp()?;
    let expires_at = compute_expires_at(now);

    let session = PairingSession {
        protocol_version: PAIRING_PROTOCOL_VERSION.to_string(),
        token,
        secret,
        nonce,
        expires_at,
    };

    let state = state.inner().clone();
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;

    let tunnel_details = ensure_tunnel(&state, &mut pairing_state);
    let local_urls = current_local_urls(&pairing_state);
    let local_ips = current_local_ips();
    let wifi_ssid = current_wifi_ssid();
    let frp_url = pairing_state.identity.frp_url.clone();
    let transports = build_transport_endpoints(
        &local_urls,
        frp_url.as_deref(),
        tunnel_details.url.as_deref(),
    );

    let payload = serde_json::json!({
        "protocol_version": session.protocol_version.clone(),
        "token": session.token.clone(),
        "secret": session.secret.clone(),
        "nonce": session.nonce.clone(),
        "pairing_token": session.token.clone(),
        "pairing_secret": session.secret.clone(),
        "expires_at": session.expires_at,
        "device_id": pairing_state.identity.device_id.clone(),
        "host_name": pairing_state.identity.host_name.clone(),
        "wifi_ssid": wifi_ssid.clone(),
        "local_ips": local_ips.clone(),
        "local_urls": local_urls.clone(),
        "frp_url": frp_url.clone(),
        "transports": transports.clone(),
        "tunnel_url": tunnel_details.url.clone(),
        "tunnel_error": tunnel_details.error.clone(),
        "requires_approval": pairing_state.requires_approval,
        "roi_quic_port": pairing_state.roi_quic_port(),
    });

    let qr_payload = serde_json::to_string(&payload)
        .map_err(|_| PairingError::new("payload_error", "Failed to build QR payload."))?;
    let qr_svg = build_qr_svg(&qr_payload)?;

    pairing_state.session = Some(session.clone());
    pairing_state.connected_at = None;
    pairing_state.pending_confirmation = None;

    Ok(PairingSessionResponse {
        protocol_version: session.protocol_version,
        token: session.token,
        secret: session.secret,
        nonce: session.nonce,
        expires_at: session.expires_at,
        qr_payload,
        qr_svg,
        tunnel_url: tunnel_details.url,
        tunnel_error: tunnel_details.error,
        local_urls,
        requires_approval: pairing_state.requires_approval,
        device_id: pairing_state.identity.device_id.clone(),
        host_name: pairing_state.identity.host_name.clone(),
        auth_token: pairing_state.identity.auth_token.clone(),
        wifi_ssid,
        local_ips,
        frp_url,
        transports,
        listen_port: pairing_state.listen_port(),
        roi_quic_port: pairing_state.roi_quic_port(),
    })
}

#[tauri::command]
pub fn confirm_pairing_session(
    state: State<Arc<Mutex<PairingState>>>,
    token: String,
    secret: String,
) -> Result<PairingConfirmResponse, PairingError> {
    confirm_pairing_with_state(
        state.inner(),
        &token,
        &secret,
        None,
        Some("tauri".to_string()),
        None,
        None,
    )
}

#[tauri::command]
pub fn get_pairing_status(
    state: State<Arc<Mutex<PairingState>>>,
) -> Result<PairingStatusResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let now = current_timestamp()?;
    if let Some(pending) = pairing_state.pending_confirmation.as_ref() {
        if is_pending_expired(pending, now) {
            pairing_state.pending_confirmation = None;
        }
    }
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
    refresh_local_server(state.inner(), &mut pairing_state);
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn set_frp_url(
    state: State<Arc<Mutex<PairingState>>>,
    url: String,
) -> Result<PairingStatusResponse, PairingError> {
    let trimmed = url.trim();
    let value = if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    };
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state
        .identity
        .set_frp_url(value)
        .map_err(|_| PairingError::new("identity_error", "Failed to update FRP URL."))?;
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn set_listen_port(
    state: State<Arc<Mutex<PairingState>>>,
    port: u16,
) -> Result<PairingStatusResponse, PairingError> {
    set_listen_port_inner(state.inner(), port)
}

fn validate_port_value(port: u16) -> Result<(), PairingError> {
    if port == 0 {
        return Err(PairingError::new(
            "invalid_port",
            "Port must be between 1 and 65535.",
        ));
    }
    Ok(())
}

fn set_listen_port_inner(
    state: &Arc<Mutex<PairingState>>,
    port: u16,
) -> Result<PairingStatusResponse, PairingError> {
    validate_port_value(port)?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let previous_port = pairing_state.listen_port();
    if port == previous_port {
        return Ok(build_pairing_status(&pairing_state));
    }
    pairing_state
        .identity
        .set_listen_port(port)
        .map_err(|_| PairingError::new("identity_error", "Failed to update listen port."))?;
    match ensure_local_server(state, &mut pairing_state) {
        Ok(_) => {
            if let Some(handle) = pairing_state.local_server.as_ref() {
                if handle.port != port {
                    if let Err(error) = pairing_state.identity.set_listen_port(previous_port) {
                        eprintln!("Failed to revert listen port {previous_port}: {error}");
                    }
                    return Err(PairingError::new(
                        "listen_port_busy",
                        "Listen port change deferred while active sessions are connected. Disconnect active sessions and retry.",
                    ));
                }
            }
            clear_local_server_error(&mut pairing_state);
            Ok(build_pairing_status(&pairing_state))
        }
        Err(error) => {
            if let Err(revert_error) = pairing_state.identity.set_listen_port(previous_port) {
                eprintln!("Failed to revert listen port {previous_port}: {revert_error}");
            }
            if ensure_local_server(state, &mut pairing_state).is_ok() {
                clear_local_server_error(&mut pairing_state);
            } else {
                pairing_state.tunnel_error = Some(error.message.clone());
            }
            Err(error)
        }
    }
}

#[tauri::command]
pub fn set_roi_quic_port(
    state: State<Arc<Mutex<PairingState>>>,
    port: u16,
) -> Result<PairingStatusResponse, PairingError> {
    set_roi_quic_port_inner(state.inner(), port)
}

fn set_roi_quic_port_inner(
    state: &Arc<Mutex<PairingState>>,
    port: u16,
) -> Result<PairingStatusResponse, PairingError> {
    validate_port_value(port)?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let previous_port = pairing_state.roi_quic_port();
    if port == previous_port {
        return Ok(build_pairing_status(&pairing_state));
    }
    pairing_state
        .identity
        .set_roi_quic_port(port)
        .map_err(|_| PairingError::new("identity_error", "Failed to update ROI QUIC port."))?;
    match ensure_local_server(state, &mut pairing_state) {
        Ok(_) => {
            if let Some(handle) = pairing_state.local_server.as_ref() {
                if handle.quic_port().unwrap_or(0) != port {
                    if let Err(error) = pairing_state.identity.set_roi_quic_port(previous_port) {
                        eprintln!("Failed to revert ROI QUIC port {previous_port}: {error}");
                    }
                    return Err(PairingError::new(
                        RoiErrorCode::RoiQuicPortBusy.as_str(),
                        "ROI QUIC port change deferred while active sessions are connected. Disconnect active sessions and retry.",
                    ));
                }
            }
            clear_local_server_error(&mut pairing_state);
            Ok(build_pairing_status(&pairing_state))
        }
        Err(error) => {
            if let Err(revert_error) = pairing_state.identity.set_roi_quic_port(previous_port) {
                eprintln!("Failed to revert ROI QUIC port {previous_port}: {revert_error}");
            }
            if ensure_local_server(state, &mut pairing_state).is_ok() {
                clear_local_server_error(&mut pairing_state);
            } else {
                pairing_state.tunnel_error = Some(error.message.clone());
            }
            Err(error)
        }
    }
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
    if let Some(pending) = pairing_state.pending_confirmation.as_ref() {
        if is_pending_expired(pending, now) {
            pairing_state.pending_confirmation = None;
            return Err(PairingError::new(
                "approval_timeout",
                "Approval window expired. Generate a new QR token and retry.",
            ));
        }
    }
    if is_session_expired(session, now) {
        return Err(PairingError::new(
            "token_expired",
            "Pairing token expired. Generate a new token.",
        ));
    }
    pairing_state.connected_at = Some(now);
    let mut bound_token = pairing_state.identity.auth_token.clone();
    if let Some(pending) = pairing_state.pending_confirmation.take() {
        let client_id = pending.client_id.clone();
        register_client_pairing(
            &mut pairing_state,
            pending.client_id,
            pending.client_name,
            pending.source,
            now,
        );
        bound_token = resolve_client_token(&mut pairing_state, client_id.as_deref());
    } else {
        pairing_state.pending_confirmation = None;
    }
    Ok(PairingConfirmResponse {
        status: "connected".to_string(),
        connected_at: Some(now),
        device_id: Some(pairing_state.identity.device_id.clone()),
        auth_token: Some(bound_token),
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

#[derive(Debug, Serialize)]
pub struct IdentityResponse {
    pub device_id: String,
    pub auth_token: String,
}

#[tauri::command]
pub fn reset_auth_token(
    state: State<Arc<Mutex<PairingState>>>,
) -> Result<IdentityResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state
        .identity
        .rotate_auth_token()
        .map_err(|_| PairingError::new("identity_error", "Failed to reset token."))?;
    for client in pairing_state.clients.values_mut() {
        client.last_seen_at = None;
    }
    Ok(IdentityResponse {
        device_id: pairing_state.identity.device_id.clone(),
        auth_token: pairing_state.identity.auth_token.clone(),
    })
}

#[tauri::command]
pub fn create_auth_token(
    state: State<Arc<Mutex<PairingState>>>,
    label: Option<String>,
) -> Result<AuthTokenSnapshot, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let record = pairing_state
        .identity
        .create_long_token(label, None)
        .map_err(|_| PairingError::new("identity_error", "Failed to create token."))?;
    Ok(snapshot_from_record(&pairing_state, record))
}

#[tauri::command]
pub fn add_auth_token(
    state: State<Arc<Mutex<PairingState>>>,
    token: String,
    label: Option<String>,
) -> Result<AuthTokenSnapshot, PairingError> {
    let trimmed = token.trim().to_string();
    validate_long_token(&trimmed)?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let record = pairing_state
        .identity
        .add_custom_token(trimmed, label, None)
        .map_err(|_| PairingError::new("identity_error", "Failed to add token."))?;
    Ok(snapshot_from_record(&pairing_state, record))
}

#[tauri::command]
pub fn set_primary_auth_token(
    state: State<Arc<Mutex<PairingState>>>,
    token: String,
    label: Option<String>,
) -> Result<IdentityResponse, PairingError> {
    let trimmed = token.trim().to_string();
    validate_long_token(&trimmed)?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state
        .identity
        .set_primary_token(trimmed, label)
        .map_err(|_| PairingError::new("identity_error", "Failed to update token."))?;
    Ok(IdentityResponse {
        device_id: pairing_state.identity.device_id.clone(),
        auth_token: pairing_state.identity.auth_token.clone(),
    })
}

#[tauri::command]
pub fn revoke_auth_token(
    state: State<Arc<Mutex<PairingState>>>,
    token: String,
) -> Result<PairingStatusResponse, PairingError> {
    let trimmed = token.trim().to_string();
    if trimmed.is_empty() {
        return Err(PairingError::new("invalid_token", "Token cannot be empty."));
    }
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state
        .identity
        .revoke_token(&trimmed)
        .map_err(|_| PairingError::new("identity_error", "Failed to revoke token."))?;
    Ok(build_pairing_status(&pairing_state))
}

fn validate_long_token(token: &str) -> Result<(), PairingError> {
    if token.len() != LONG_TOKEN_LEN {
        return Err(PairingError::new(
            "invalid_token_length",
            "Token must be 64 characters.",
        ));
    }
    if !token.chars().all(|ch| ch.is_ascii_alphanumeric()) {
        return Err(PairingError::new(
            "invalid_token_format",
            "Token must use only letters and numbers.",
        ));
    }
    Ok(())
}

fn snapshot_from_record(
    pairing_state: &PairingState,
    record: crate::identity::AuthTokenRecord,
) -> AuthTokenSnapshot {
    AuthTokenSnapshot {
        token: record.token.clone(),
        label: record.label,
        created_at: record.created_at,
        revoked_at: record.revoked_at,
        client_id: record.client_id,
        is_primary: record.token == pairing_state.identity.auth_token,
    }
}

#[tauri::command]
pub fn rename_client(
    state: State<Arc<Mutex<PairingState>>>,
    client_id: String,
    name: String,
) -> Result<PairingStatusResponse, PairingError> {
    let now = current_timestamp()?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(PairingError::new(
            "invalid_name",
            "Client name cannot be empty.",
        ));
    }
    let entry = pairing_state
        .clients
        .entry(client_id.clone())
        .or_insert(ClientInfo {
            id: client_id.clone(),
            name: trimmed.to_string(),
            paired_at: None,
            last_seen_at: None,
            source: None,
        });
    entry.name = trimmed.to_string();
    entry.last_seen_at = entry.last_seen_at.or(Some(now));
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn set_client_blocked(
    state: State<Arc<Mutex<PairingState>>>,
    client_id: String,
    blocked: bool,
) -> Result<PairingStatusResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    if blocked {
        pairing_state
            .blocked_clients
            .insert(client_id.clone(), None);
    } else {
        pairing_state.blocked_clients.remove(&client_id);
    }
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn kick_client(
    state: State<Arc<Mutex<PairingState>>>,
    client_id: String,
) -> Result<PairingStatusResponse, PairingError> {
    let now = current_timestamp()?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    let expires_at = now.saturating_add(60);
    pairing_state
        .blocked_clients
        .insert(client_id.clone(), Some(expires_at));
    if let Some(client) = pairing_state.clients.get_mut(&client_id) {
        client.last_seen_at = None;
    }
    Ok(build_pairing_status(&pairing_state))
}

#[tauri::command]
pub fn forget_client(
    state: State<Arc<Mutex<PairingState>>>,
    client_id: String,
) -> Result<PairingStatusResponse, PairingError> {
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    pairing_state.clients.remove(&client_id);
    pairing_state.blocked_clients.remove(&client_id);
    pairing_state.connected_clients.remove(&client_id);
    let clear_pending = pairing_state
        .pending_confirmation
        .as_ref()
        .map(|pending| pending.client_id.as_deref() == Some(client_id.as_str()))
        .unwrap_or(false);
    if clear_pending {
        pairing_state.pending_confirmation = None;
    }
    pairing_state
        .identity
        .revoke_tokens_for_client(&client_id)
        .map_err(|_| PairingError::new("identity_error", "Failed to revoke token."))?;
    Ok(build_pairing_status(&pairing_state))
}

pub(crate) fn confirm_pairing_with_state(
    state: &Arc<Mutex<PairingState>>,
    token: &str,
    secret: &str,
    nonce: Option<&str>,
    source: Option<String>,
    client_id: Option<String>,
    client_name: Option<String>,
) -> Result<PairingConfirmResponse, PairingError> {
    let now = current_timestamp()?;
    let mut pairing_state = state
        .lock()
        .map_err(|_| PairingError::new("state_locked", "Pairing state unavailable."))?;
    confirm_pairing_locked(
        &mut pairing_state,
        token,
        secret,
        nonce,
        source,
        client_id,
        client_name,
        now,
    )
}

fn confirm_pairing_locked(
    pairing_state: &mut PairingState,
    token: &str,
    secret: &str,
    nonce: Option<&str>,
    source: Option<String>,
    client_id: Option<String>,
    client_name: Option<String>,
    now: u64,
) -> Result<PairingConfirmResponse, PairingError> {
    let session = pairing_state
        .session
        .as_ref()
        .ok_or_else(|| PairingError::new("missing_token", "No active pairing token."))?;

    if is_session_expired(session, now) {
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

    if let Some(value) = nonce {
        if session.nonce != value.trim() {
            return Err(PairingError::new(
                "nonce_mismatch",
                "Pairing nonce does not match.",
            ));
        }
    }
    if let Some(id) = client_id.as_deref() {
        if let Some(record) = pairing_state.identity.find_token_for_client(id) {
            pairing_state.connected_at = Some(now);
            register_client_pairing(pairing_state, client_id, client_name, source, now);
            return Ok(PairingConfirmResponse {
                status: "connected".to_string(),
                connected_at: Some(now),
                device_id: Some(pairing_state.identity.device_id.clone()),
                auth_token: Some(record.token),
            });
        }
    }

    if !pairing_state.requires_approval {
        pairing_state.connected_at = Some(now);
        pairing_state.pending_confirmation = None;
        let bound_token = resolve_client_token(pairing_state, client_id.as_deref());
        register_client_pairing(pairing_state, client_id, client_name, source, now);
        return Ok(PairingConfirmResponse {
            status: "connected".to_string(),
            connected_at: Some(now),
            device_id: Some(pairing_state.identity.device_id.clone()),
            auth_token: Some(bound_token),
        });
    }

    if let Some(pending) = pairing_state.pending_confirmation.as_ref() {
        if is_pending_expired(pending, now) {
            pairing_state.pending_confirmation = None;
            return Err(PairingError::new(
                "approval_timeout",
                "Approval window expired. Generate a new QR token and retry.",
            ));
        }
        if pending.client_id.as_deref() == client_id.as_deref() {
            return Ok(PairingConfirmResponse {
                status: "pending".to_string(),
                connected_at: None,
                device_id: None,
                auth_token: None,
            });
        }
        return Err(PairingError::new(
            "approval_pending",
            "Another device is awaiting approval.",
        ));
    }

    pairing_state.pending_confirmation = Some(PendingConfirmation {
        token: session.token.clone(),
        requested_at: now,
        expires_at: compute_approval_expires_at(now),
        source,
        client_id: client_id.clone(),
        client_name: client_name.clone(),
    });
    Ok(PairingConfirmResponse {
        status: "pending".to_string(),
        connected_at: None,
        device_id: None,
        auth_token: None,
    })
}

fn build_pairing_status(pairing_state: &PairingState) -> PairingStatusResponse {
    let session = pairing_state
        .session
        .as_ref()
        .map(|session| PairingSessionInfo {
            protocol_version: session.protocol_version.clone(),
            token: session.token.clone(),
            secret: session.secret.clone(),
            nonce: session.nonce.clone(),
            expires_at: session.expires_at,
        });
    let pending =
        pairing_state
            .pending_confirmation
            .as_ref()
            .map(|pending| PendingConfirmationInfo {
                token: pending.token.clone(),
                requested_at: pending.requested_at,
                expires_at: pending.expires_at,
                source: pending.source.clone(),
                client_id: pending.client_id.clone(),
                client_name: pending.client_name.clone(),
            });
    let local_urls = current_local_urls(pairing_state);
    let local_ips = current_local_ips();
    let wifi_ssid = current_wifi_ssid();
    let location_permission = current_location_permission();
    let (bundle_id, bundle_path, location_usage_key) = current_bundle_diagnostics();
    let frp_url = pairing_state.identity.frp_url.clone();
    let tunnel_url = pairing_state
        .tunnel
        .as_ref()
        .map(|tunnel| tunnel.url.clone());
    let transports =
        build_transport_endpoints(&local_urls, frp_url.as_deref(), tunnel_url.as_deref());
    let paired_devices = client_snapshots(pairing_state, false);
    let active_devices = client_snapshots(pairing_state, true);
    let connected_devices = connected_snapshots(pairing_state);
    let terminal_snapshot = terminal::list_terminal_sessions_snapshot();
    PairingStatusResponse {
        session,
        connected_at: pairing_state.connected_at,
        pending,
        requires_approval: pairing_state.requires_approval,
        local_urls,
        tunnel_url,
        tunnel_error: pairing_state.tunnel_error.clone(),
        device_id: pairing_state.identity.device_id.clone(),
        host_name: pairing_state.identity.host_name.clone(),
        auth_token: pairing_state.identity.auth_token.clone(),
        auth_tokens: auth_token_snapshots(pairing_state),
        wifi_ssid,
        location_permission,
        bundle_id,
        bundle_path,
        location_usage_key,
        local_ips,
        frp_url,
        transports,
        listen_port: pairing_state.listen_port(),
        roi_quic_port: pairing_state.roi_quic_port(),
        paired_devices,
        active_devices,
        connected_devices,
        terminal_sessions: terminal_snapshot.sessions,
        terminal_error_code: terminal_snapshot.error_code,
        terminal_error_message: terminal_snapshot.error_message,
        terminal_update_available: terminal_snapshot.update_available,
        terminal_update_message: terminal_snapshot.update_message,
        terminal_running_version: terminal_snapshot.running_version,
        terminal_bundled_version: terminal_snapshot.bundled_version,
    }
}

pub(crate) fn build_transport_endpoints(
    local_urls: &[String],
    frp_url: Option<&str>,
    tunnel_url: Option<&str>,
) -> Vec<TransportEndpointSnapshot> {
    let mut transports = Vec::new();
    let mut seen = HashSet::new();
    for url in local_urls {
        let trimmed = url.trim();
        if trimmed.is_empty() {
            continue;
        }
        let key = format!("lan::{trimmed}");
        if seen.insert(key) {
            transports.push(TransportEndpointSnapshot {
                r#type: "lan".to_string(),
                url: trimmed.to_string(),
                priority: 100,
                probe_timeout_ms: 2000,
                enabled: true,
            });
        }
    }
    if let Some(url) = frp_url {
        let trimmed = url.trim();
        if !trimmed.is_empty() {
            let key = format!("frp::{trimmed}");
            if seen.insert(key) {
                transports.push(TransportEndpointSnapshot {
                    r#type: "frp".to_string(),
                    url: trimmed.to_string(),
                    priority: 60,
                    probe_timeout_ms: 3000,
                    enabled: true,
                });
            }
        }
    }
    if let Some(url) = tunnel_url {
        let trimmed = url.trim();
        if !trimmed.is_empty() {
            let key = format!("tun::{trimmed}");
            if seen.insert(key) {
                transports.push(TransportEndpointSnapshot {
                    r#type: "tun".to_string(),
                    url: trimmed.to_string(),
                    priority: 50,
                    probe_timeout_ms: 3000,
                    enabled: true,
                });
            }
        }
    }
    transports
}

fn auth_token_snapshots(pairing_state: &PairingState) -> Vec<AuthTokenSnapshot> {
    let primary = pairing_state.identity.auth_token.clone();
    let mut tokens = pairing_state
        .identity
        .list_tokens()
        .into_iter()
        .map(|record| AuthTokenSnapshot {
            token: record.token.clone(),
            label: record.label,
            created_at: record.created_at,
            revoked_at: record.revoked_at,
            client_id: record.client_id,
            is_primary: record.token == primary,
        })
        .collect::<Vec<_>>();
    tokens.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    tokens
}

fn resolve_client_token(pairing_state: &mut PairingState, client_id: Option<&str>) -> String {
    if let Some(id) = client_id {
        if let Ok(record) = pairing_state.identity.token_for_client(id) {
            return record.token;
        }
    }
    pairing_state.identity.auth_token.clone()
}

fn ensure_tunnel(
    state: &Arc<Mutex<PairingState>>,
    pairing_state: &mut PairingState,
) -> TunnelDetails {
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
    let desired_port = pairing_state.listen_port();
    let roi_port = pairing_state.roi_quic_port();
    let has_clients = !pairing_state.connected_clients.is_empty();
    if let Some(handle) = pairing_state.local_server.as_ref() {
        let active_quic_port = handle.quic_port().unwrap_or(0);
        let port_matches = handle.port == desired_port;
        let quic_matches = active_quic_port == roi_port;
        if port_matches && quic_matches {
            if has_clients || is_local_server_healthy(handle.port) {
                pairing_state.local_port = Some(handle.port);
                return Ok(handle.port);
            }
        } else if has_clients {
            eprintln!(
                "Local server restart deferred (active clients). listen_port={} quic_port={} active_quic_port={}",
                desired_port,
                roi_port,
                active_quic_port
            );
            pairing_state.local_port = Some(handle.port);
            return Ok(handle.port);
        }
    }

    if let Some(mut handle) = pairing_state.local_server.take() {
        handle.stop();
    }
    pairing_state.local_port = None;
    match start_local_tunnel_server(state.clone(), desired_port, roi_port) {
        Ok(handle) => {
            let port = handle.port;
            pairing_state.local_port = Some(port);
            pairing_state.local_server = Some(handle);
            if is_local_server_healthy(port) {
                Ok(port)
            } else {
                pairing_state.local_port = None;
                Err(PairingError::new(
                    "local_server_unavailable",
                    LOCAL_SERVER_ERROR_MESSAGE,
                ))
            }
        }
        Err(error) => {
            pairing_state.local_port = None;
            let message = error.to_string();
            if message.contains("ROI QUIC port") {
                let code = if error.kind() == std::io::ErrorKind::AddrInUse {
                    RoiErrorCode::RoiQuicPortBusy.as_str()
                } else {
                    RoiErrorCode::RoiQuicPortUnavailable.as_str()
                };
                let formatted = if error.kind() == std::io::ErrorKind::AddrInUse {
                    roi_quic_port_in_use_message(roi_port)
                } else if message.starts_with(LOCAL_SERVER_ERROR_PREFIX) {
                    message
                } else {
                    format!("{LOCAL_SERVER_ERROR_PREFIX} {message}")
                };
                eprintln!("{formatted}");
                return Err(PairingError {
                    code: code.to_string(),
                    message: formatted,
                });
            }
            if error.kind() == std::io::ErrorKind::AddrInUse {
                let formatted = listen_port_in_use_message(desired_port);
                eprintln!("{formatted}");
                return Err(PairingError {
                    code: "listen_port_busy".to_string(),
                    message: formatted,
                });
            }
            let formatted =
                format!("Local server unavailable. Failed to bind port {desired_port}: {message}");
            eprintln!("{formatted}");
            Err(PairingError {
                code: "local_server_unavailable".to_string(),
                message: formatted,
            })
        }
    }
}

fn refresh_local_server(state: &Arc<Mutex<PairingState>>, pairing_state: &mut PairingState) {
    let port = pairing_state.listen_port();
    if is_local_server_healthy(port) {
        pairing_state.local_port = Some(port);
        clear_local_server_error(pairing_state);
        return;
    }

    if !pairing_state.connected_clients.is_empty() {
        pairing_state.tunnel_error = Some(LOCAL_SERVER_ERROR_MESSAGE.to_string());
        return;
    }

    match ensure_local_server(state, pairing_state) {
        Ok(active_port) => {
            pairing_state.local_port = Some(active_port);
            clear_local_server_error(pairing_state);
        }
        Err(error) => {
            pairing_state.local_port = None;
            let detail = if error.message.starts_with(LOCAL_SERVER_ERROR_PREFIX) {
                error.message
            } else {
                format!("{LOCAL_SERVER_ERROR_PREFIX} {}", error.message)
            };
            pairing_state.tunnel_error = Some(detail);
        }
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

fn start_local_tunnel_server(
    state: Arc<Mutex<PairingState>>,
    port: u16,
    roi_port: u16,
) -> Result<server::LocalServerHandle, std::io::Error> {
    server::start_local_server(state, port, Some(roi_port))
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
                return Ok(TunnelHandle {
                    url,
                    process: child,
                });
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

fn compute_expires_at(now: u64) -> u64 {
    if PAIRING_TTL_SECS == 0 {
        0
    } else {
        now.saturating_add(PAIRING_TTL_SECS)
    }
}

fn compute_approval_expires_at(now: u64) -> u64 {
    if APPROVAL_TTL_SECS == 0 {
        0
    } else {
        now.saturating_add(APPROVAL_TTL_SECS)
    }
}

fn is_session_expired(session: &PairingSession, now: u64) -> bool {
    if session.expires_at == 0 {
        return false;
    }
    now > session.expires_at
}

fn is_pending_expired(pending: &PendingConfirmation, now: u64) -> bool {
    if pending.expires_at == 0 {
        return false;
    }
    now > pending.expires_at
}

fn auth_failure_key(client_id: Option<&str>) -> String {
    client_id.unwrap_or("unknown").to_string()
}

fn register_client_pairing(
    pairing_state: &mut PairingState,
    client_id: Option<String>,
    client_name: Option<String>,
    source: Option<String>,
    now: u64,
) {
    if let Some(id) = client_id.as_deref() {
        if is_client_blocked(pairing_state, id, now) {
            return;
        }
    }
    let id = client_id.unwrap_or_else(|| format!("unknown-{}", now));
    let name = client_name.unwrap_or_else(|| "Unknown".to_string());
    let entry = pairing_state
        .clients
        .entry(id.clone())
        .or_insert(ClientInfo {
            id,
            name: name.clone(),
            paired_at: None,
            last_seen_at: None,
            source: source.clone(),
        });
    entry.name = name;
    entry.paired_at = Some(now);
    entry.last_seen_at = Some(now);
    if source.is_some() {
        entry.source = source;
    }
}

pub(crate) fn record_client_seen(
    pairing_state: &mut PairingState,
    client_id: Option<String>,
    client_name: Option<String>,
    source: Option<String>,
    now: u64,
) {
    if let Some(id) = client_id.as_deref() {
        if is_client_blocked(pairing_state, id, now) {
            return;
        }
    }
    let id = client_id.unwrap_or_else(|| format!("unknown-{}", now));
    let name = client_name.unwrap_or_else(|| "Unknown".to_string());
    let entry = pairing_state
        .clients
        .entry(id.clone())
        .or_insert(ClientInfo {
            id,
            name: name.clone(),
            paired_at: None,
            last_seen_at: None,
            source: source.clone(),
        });
    entry.name = name;
    entry.last_seen_at = Some(now);
    if source.is_some() {
        entry.source = source;
    }
}

fn client_snapshots(pairing_state: &PairingState, active_only: bool) -> Vec<ClientSnapshot> {
    let now = current_timestamp().unwrap_or_default();
    let mut list = Vec::new();
    for client in pairing_state.clients.values() {
        if active_only {
            let is_active = client
                .last_seen_at
                .map(|last| now.saturating_sub(last) <= ACTIVE_CLIENT_WINDOW_SECS)
                .unwrap_or(false);
            if !is_active {
                continue;
            }
        } else if client.paired_at.is_none() {
            continue;
        }
        let (disabled, blocked_until) = blocked_info(pairing_state, &client.id, now);
        list.push(ClientSnapshot {
            id: client.id.clone(),
            name: client.name.clone(),
            paired_at: client.paired_at,
            last_seen_at: client.last_seen_at,
            source: client.source.clone(),
            disabled,
            blocked_until,
        });
    }
    list.sort_by(|a, b| b.last_seen_at.cmp(&a.last_seen_at));
    list
}

fn connected_snapshots(pairing_state: &PairingState) -> Vec<ClientSnapshot> {
    let now = current_timestamp().unwrap_or_default();
    let mut list = Vec::new();
    for (client_id, count) in pairing_state.connected_clients.iter() {
        if *count == 0 {
            continue;
        }
        let (disabled, blocked_until) = blocked_info(pairing_state, client_id, now);
        if let Some(client) = pairing_state.clients.get(client_id) {
            list.push(ClientSnapshot {
                id: client.id.clone(),
                name: client.name.clone(),
                paired_at: client.paired_at,
                last_seen_at: client.last_seen_at,
                source: client.source.clone(),
                disabled,
                blocked_until,
            });
        } else {
            list.push(ClientSnapshot {
                id: client_id.clone(),
                name: "Unknown".to_string(),
                paired_at: None,
                last_seen_at: None,
                source: None,
                disabled,
                blocked_until,
            });
        }
    }
    list.sort_by(|a, b| b.last_seen_at.cmp(&a.last_seen_at));
    list
}

fn blocked_info(pairing_state: &PairingState, client_id: &str, now: u64) -> (bool, Option<u64>) {
    if let Some(until) = pairing_state.blocked_clients.get(client_id) {
        match until {
            None => (true, None),
            Some(ts) => {
                if now > *ts {
                    (false, None)
                } else {
                    (false, Some(*ts))
                }
            }
        }
    } else {
        (false, None)
    }
}

fn is_client_blocked(pairing_state: &mut PairingState, client_id: &str, now: u64) -> bool {
    if let Some(until) = pairing_state.blocked_clients.get(client_id).cloned() {
        if let Some(expiry) = until {
            if now > expiry {
                pairing_state.blocked_clients.remove(client_id);
                return false;
            }
        }
        return true;
    }
    false
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

pub(crate) fn current_local_urls(pairing_state: &PairingState) -> Vec<String> {
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
                if !is_private_ipv4(addr) {
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

pub(crate) fn current_local_ips() -> Vec<String> {
    let mut ips = Vec::new();
    if let Ok(interfaces) = get_if_addrs() {
        for iface in interfaces {
            if iface.is_loopback() {
                continue;
            }
            if let std::net::IpAddr::V4(addr) = iface.ip() {
                let octets = addr.octets();
                if octets[0] == 169 && octets[1] == 254 {
                    continue;
                }
                if !is_private_ipv4(addr) {
                    continue;
                }
                ips.push(addr.to_string());
            }
        }
    }
    ips.sort();
    ips.dedup();
    ips
}

pub(crate) fn current_wifi_ssid() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        if let Some(ssid) = wifi_ssid_from_corewlan() {
            return Some(ssid);
        }
        if let Ok(output) = std::process::Command::new(
            "/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport",
        )
        .arg("-I")
        .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    let trimmed = line.trim();
                    if let Some(rest) = trimmed.strip_prefix("SSID:") {
                        let ssid = rest.trim();
                        if !ssid.is_empty() {
                            return Some(ssid.to_string());
                        }
                    }
                }
            }
        }
        if let Some(ssid) = wifi_ssid_from_networksetup() {
            return Some(ssid);
        }
        for device in ["en0", "en1", "en2"] {
            if let Some(ssid) = wifi_ssid_from_airportnetwork(device) {
                return Some(ssid);
            }
        }
    }
    #[cfg(target_os = "windows")]
    {
        let output = std::process::Command::new("netsh")
            .args(["wlan", "show", "interfaces"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("SSID") && !trimmed.starts_with("SSID BSSID") {
                if let Some(pos) = trimmed.find(':') {
                    let ssid = trimmed[pos + 1..].trim();
                    if !ssid.is_empty() {
                        return Some(ssid.to_string());
                    }
                }
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Ok(output) = std::process::Command::new("iwgetid").args(["-r"]).output() {
            if output.status.success() {
                let ssid = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !ssid.is_empty() {
                    return Some(ssid);
                }
            }
        }
        if let Ok(output) = std::process::Command::new("nmcli")
            .args(["-t", "-f", "active,ssid", "dev", "wifi"])
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    let trimmed = line.trim();
                    if let Some(rest) = trimmed.strip_prefix("yes:") {
                        let ssid = rest.trim();
                        if !ssid.is_empty() {
                            return Some(ssid.to_string());
                        }
                    }
                }
            }
        }
    }
    None
}

pub(crate) fn current_location_permission() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        return Some(location_permission_state());
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

pub(crate) fn current_bundle_diagnostics() -> (Option<String>, Option<String>, Option<bool>) {
    #[cfg(target_os = "macos")]
    {
        use objc2_foundation::{ns_string, NSBundle};
        let bundle = NSBundle::mainBundle();
        let bundle_id = bundle.bundleIdentifier().map(|value| value.to_string());
        let bundle_path = Some(bundle.bundlePath().to_string());
        let key = ns_string!("NSLocationWhenInUseUsageDescription");
        let has_usage_key = bundle.objectForInfoDictionaryKey(key).is_some();
        return (bundle_id, bundle_path, Some(has_usage_key));
    }
    #[cfg(not(target_os = "macos"))]
    {
        (None, None, None)
    }
}

#[tauri::command]
pub fn request_location_permission(app: tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let _ = app.run_on_main_thread(|| {
            request_location_authorization();
        });
    }
}

#[tauri::command]
pub fn open_location_settings() -> bool {
    #[cfg(target_os = "macos")]
    {
        let url =
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices";
        return std::process::Command::new("open")
            .arg(url)
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

#[cfg(target_os = "macos")]
fn wifi_ssid_from_corewlan() -> Option<String> {
    use objc2::rc::autoreleasepool;
    use objc2_core_wlan::CWWiFiClient;

    autoreleasepool(|_| {
        let client = unsafe { CWWiFiClient::sharedWiFiClient() };
        let interface = unsafe { client.interface()? };
        let ssid = unsafe { interface.ssid()? };
        let value = ssid.to_string();
        if value.trim().is_empty() {
            None
        } else {
            Some(value)
        }
    })
}

#[cfg(target_os = "macos")]
fn wifi_ssid_from_networksetup() -> Option<String> {
    let output = std::process::Command::new("/usr/sbin/networksetup")
        .arg("-listallhardwareports")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut is_wifi = false;
    for line in stdout.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("Hardware Port:") {
            let port = rest.trim();
            is_wifi = port.eq_ignore_ascii_case("Wi-Fi") || port.eq_ignore_ascii_case("AirPort");
            continue;
        }
        if is_wifi {
            if let Some(rest) = trimmed.strip_prefix("Device:") {
                let device = rest.trim();
                if device.is_empty() {
                    continue;
                }
                if let Some(ssid) = wifi_ssid_from_airportnetwork(device) {
                    return Some(ssid);
                }
                break;
            }
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn wifi_ssid_from_airportnetwork(device: &str) -> Option<String> {
    let output = std::process::Command::new("/usr/sbin/networksetup")
        .args(["-getairportnetwork", device])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    if let Some(pos) = stdout.find(':') {
        let ssid = stdout[pos + 1..].trim();
        if !ssid.is_empty() && !ssid.contains("not associated") && !ssid.contains("not connected") {
            return Some(ssid.to_string());
        }
    }
    None
}

fn is_private_ipv4(addr: std::net::Ipv4Addr) -> bool {
    let octets = addr.octets();
    match octets[0] {
        10 => true,
        172 => (16..=31).contains(&octets[1]),
        192 => octets[1] == 168,
        100 => (64..=127).contains(&octets[1]),
        _ => false,
    }
}

#[cfg(target_os = "macos")]
#[link(name = "CoreLocation", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
pub(crate) fn request_location_authorization() {
    use objc2::msg_send;
    use objc2::rc::autoreleasepool;
    use objc2::runtime::{AnyClass, AnyObject};
    use std::ffi::CStr;
    use std::sync::atomic::{AtomicPtr, Ordering};

    static MANAGER: AtomicPtr<AnyObject> = AtomicPtr::new(std::ptr::null_mut());

    autoreleasepool(|_| unsafe {
        let existing = MANAGER.load(Ordering::SeqCst);
        if !existing.is_null() {
            let _: () = msg_send![existing, requestWhenInUseAuthorization];
            return;
        }
        let class_name = CStr::from_bytes_with_nul(b"CLLocationManager\0").ok();
        let Some(class) = class_name.and_then(AnyClass::get) else {
            return;
        };
        let manager: *mut AnyObject = msg_send![class, alloc];
        let manager: *mut AnyObject = msg_send![manager, init];
        let _: () = msg_send![manager, requestWhenInUseAuthorization];
        MANAGER.store(manager, Ordering::SeqCst);
    });
}

#[cfg(target_os = "macos")]
fn location_permission_state() -> String {
    use objc2::msg_send;
    use objc2::runtime::AnyClass;
    use std::ffi::CStr;

    unsafe {
        let class_name = CStr::from_bytes_with_nul(b"CLLocationManager\0").ok();
        let Some(class) = class_name.and_then(AnyClass::get) else {
            return "unknown".to_string();
        };
        let enabled: bool = msg_send![class, locationServicesEnabled];
        if !enabled {
            return "disabled".to_string();
        }
        let status: i32 = msg_send![class, authorizationStatus];
        match status {
            0 => "not_determined",
            1 => "restricted",
            2 => "denied",
            3 | 4 => "authorized",
            _ => "unknown",
        }
        .to_string()
    }
}

fn build_qr_svg(payload: &str) -> Result<String, PairingError> {
    let code = QrCode::new(payload.as_bytes())
        .map_err(|_| PairingError::new("qr_error", "Invalid QR data."))?;
    Ok(code
        .render::<svg::Color>()
        .min_dimensions(320, 320)
        .dark_color(svg::Color("#1e293b"))
        .light_color(svg::Color("#f8fafc"))
        .build())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{TcpListener, UdpSocket};

    fn free_tcp_port() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind tcp");
        listener.local_addr().expect("tcp addr").port()
    }

    fn free_udp_port() -> u16 {
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind udp");
        socket.local_addr().expect("udp addr").port()
    }

    #[test]
    fn ensure_local_server_returns_listen_port_busy_when_tcp_port_is_taken() {
        let occupied_listener = TcpListener::bind("0.0.0.0:0").expect("occupied listener");
        let occupied_port = occupied_listener
            .local_addr()
            .expect("occupied listener addr")
            .port();
        let roi_port = free_udp_port();

        let state = Arc::new(Mutex::new(PairingState::default()));
        let mut pairing_state = state.lock().expect("pairing state lock");
        pairing_state.identity.listen_port = occupied_port;
        pairing_state.identity.roi_quic_port = roi_port;

        let error =
            ensure_local_server(&state, &mut pairing_state).expect_err("expected listen conflict");
        assert_eq!(error.code, "listen_port_busy");
        assert!(error.message.contains("already in use"));
    }

    #[test]
    fn ensure_local_server_returns_roi_quic_port_busy_when_udp_port_is_taken() {
        let occupied_socket = UdpSocket::bind("0.0.0.0:0").expect("occupied udp socket");
        let occupied_roi_port = occupied_socket
            .local_addr()
            .expect("occupied udp addr")
            .port();
        let listen_port = free_tcp_port();

        let state = Arc::new(Mutex::new(PairingState::default()));
        let mut pairing_state = state.lock().expect("pairing state lock");
        pairing_state.identity.listen_port = listen_port;
        pairing_state.identity.roi_quic_port = occupied_roi_port;

        let error = ensure_local_server(&state, &mut pairing_state)
            .expect_err("expected roi quic port conflict");
        assert_eq!(error.code, RoiErrorCode::RoiQuicPortBusy.as_str());
        assert!(error.message.contains("already in use"));
    }

    #[test]
    fn set_listen_port_zero_returns_invalid_port() {
        let state = Arc::new(Mutex::new(PairingState::default()));
        let error = set_listen_port_inner(&state, 0).expect_err("expected invalid port error");
        assert_eq!(error.code, "invalid_port");
        assert_eq!(error.message, "Port must be between 1 and 65535.");
    }

    #[test]
    fn set_roi_quic_port_zero_returns_invalid_port() {
        let state = Arc::new(Mutex::new(PairingState::default()));
        let error = set_roi_quic_port_inner(&state, 0).expect_err("expected invalid port error");
        assert_eq!(error.code, "invalid_port");
        assert_eq!(error.message, "Port must be between 1 and 65535.");
    }

    #[test]
    fn refresh_local_server_bootstraps_listener_without_new_handshake() {
        let listen_port = free_tcp_port();
        let roi_port = free_udp_port();
        let state = Arc::new(Mutex::new(PairingState::default()));

        {
            let mut pairing_state = state.lock().expect("pairing state lock");
            pairing_state.identity.listen_port = listen_port;
            pairing_state.identity.roi_quic_port = roi_port;
            pairing_state.local_server = None;
            pairing_state.local_port = None;

            refresh_local_server(&state, &mut pairing_state);
            assert!(
                pairing_state.local_server.is_some(),
                "local server should start during status refresh"
            );
            assert_eq!(pairing_state.local_port, Some(listen_port));
            assert!(is_local_server_healthy(listen_port));

            if let Some(mut handle) = pairing_state.local_server.take() {
                handle.stop();
            }
        }
    }
}
