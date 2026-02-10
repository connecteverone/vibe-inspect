use rand::{distributions::Alphanumeric, Rng};
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct RoiSessionRequest {
    pub session_id: String,
    pub vnc_session_id: String,
    pub client_id: Option<String>,
    pub client_name: Option<String>,
    pub display_index: Option<usize>,
    pub framebuffer_width: u32,
    pub framebuffer_height: u32,
    pub screen_width: u32,
    pub screen_height: u32,
}

#[derive(Clone, Debug)]
pub struct RoiSessionInfo {
    pub session_id: String,
    pub token: String,
    pub quic_port: u16,
    pub display_index: Option<usize>,
    pub framebuffer_width: u32,
    pub framebuffer_height: u32,
    pub screen_width: u32,
    pub screen_height: u32,
    pub issued_at: u64,
}

#[derive(Clone, Debug)]
struct RoiSession {
    info: RoiSessionInfo,
    vnc_session_id: String,
    client_id: Option<String>,
    client_name: Option<String>,
}

pub struct RoiManager {
    quic_port: u16,
    sessions: HashMap<String, RoiSession>,
}

impl RoiManager {
    pub fn new(quic_port: u16) -> Self {
        Self {
            quic_port,
            sessions: HashMap::new(),
        }
    }

    pub fn quic_port(&self) -> u16 {
        self.quic_port
    }

    pub fn set_quic_port(&mut self, port: u16) {
        self.quic_port = port;
    }

    pub fn start_session(&mut self, request: RoiSessionRequest) -> RoiSessionInfo {
        let token = generate_token(32);
        let issued_at = current_unix_seconds();
        let info = RoiSessionInfo {
            session_id: request.session_id.clone(),
            token,
            quic_port: self.quic_port,
            display_index: request.display_index,
            framebuffer_width: request.framebuffer_width,
            framebuffer_height: request.framebuffer_height,
            screen_width: request.screen_width,
            screen_height: request.screen_height,
            issued_at,
        };
        let session = RoiSession {
            info: info.clone(),
            vnc_session_id: request.vnc_session_id,
            client_id: request.client_id,
            client_name: request.client_name,
        };
        self.sessions.insert(info.session_id.clone(), session);
        info
    }

    pub fn stop_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    pub fn get_session(&self, session_id: &str, token: &str) -> Option<RoiSessionInfo> {
        let session = self.sessions.get(session_id)?;
        if session.info.token != token {
            return None;
        }
        Some(session.info.clone())
    }
}

fn current_unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn generate_token(length: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(length)
        .map(char::from)
        .collect()
}
