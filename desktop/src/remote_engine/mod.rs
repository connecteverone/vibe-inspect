use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

use quinn::{Connection, RecvStream, SendStream};

pub mod rustdesk;
pub mod media;
pub mod service;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteBackendKind {
    Rustdesk,
    MediaV2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteCapabilities {
    pub h264: bool,
    pub h265: bool,
    pub av1: bool,
    pub zero_copy: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteStartRequest {
    pub display_index: Option<usize>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteSessionInfo {
    pub session_id: String,
    pub backend: RemoteBackendKind,
    pub connect_uri: Option<String>,
    pub token: Option<String>,
    pub display_index: Option<usize>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub quic_port: Option<u16>,
    pub codec_preference: Option<String>,
    pub hwcodec: Option<bool>,
    pub capabilities: Option<RemoteCapabilities>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteStatus {
    pub backend: RemoteBackendKind,
    pub running: bool,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RemoteQuicContext {
    pub session_id: String,
    pub client_id: Option<String>,
    pub client_name: Option<String>,
}

pub trait RemoteBackend: Send + Sync {
    fn kind(&self) -> RemoteBackendKind;
    fn capabilities(&self) -> RemoteCapabilities;
    fn start(&mut self, request: RemoteStartRequest) -> Result<RemoteSessionInfo, String>;
    fn stop(&mut self, session_id: &str) -> Result<(), String>;
    fn status(&self) -> RemoteStatus;
    fn validate_session(&self, session_id: &str, token: &str) -> bool;
    fn handle_quic_stream(
        &mut self,
        connection: Connection,
        send: SendStream,
        recv: RecvStream,
        context: RemoteQuicContext,
        token: String,
    ) -> Result<(), String>;
}

#[derive(Default)]
pub struct RemoteManager {
    backend: Option<Box<dyn RemoteBackend>>,
}

impl RemoteManager {
    pub fn new() -> Self {
        Self { backend: None }
    }

    pub fn set_backend(&mut self, backend: Box<dyn RemoteBackend>) {
        self.backend = Some(backend);
    }

    pub fn capabilities(&self) -> Option<RemoteCapabilities> {
        self.backend.as_ref().map(|backend| backend.capabilities())
    }

    pub fn start(&mut self, request: RemoteStartRequest) -> Result<RemoteSessionInfo, String> {
        let backend = self
            .backend
            .as_mut()
            .ok_or_else(|| "remote backend not configured".to_string())?;
        backend.start(request)
    }

    pub fn stop(&mut self, session_id: &str) -> Result<(), String> {
        let backend = self
            .backend
            .as_mut()
            .ok_or_else(|| "remote backend not configured".to_string())?;
        backend.stop(session_id)
    }

    pub fn status(&self) -> Option<RemoteStatus> {
        self.backend.as_ref().map(|backend| backend.status())
    }

    pub fn validate_session(&self, session_id: &str, token: &str) -> bool {
        self.backend
            .as_ref()
            .map(|backend| backend.validate_session(session_id, token))
            .unwrap_or(false)
    }

    pub fn handle_quic_stream(
        &mut self,
        connection: Connection,
        send: SendStream,
        recv: RecvStream,
        context: RemoteQuicContext,
        token: String,
    ) -> Result<(), String> {
        let backend = self
            .backend
            .as_mut()
            .ok_or_else(|| "remote backend not configured".to_string())?;
        backend.handle_quic_stream(connection, send, recv, context, token)
    }
}

pub type SharedRemoteManager = Arc<Mutex<RemoteManager>>;
