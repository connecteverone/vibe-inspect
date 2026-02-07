use super::{
    RemoteCapabilities, RemoteManager, RemoteSessionInfo, RemoteStartRequest, RemoteStatus,
};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const SESSION_TTL: Duration = Duration::from_secs(15 * 60);

#[derive(Default)]
struct RemoteSessionState {
    session_id: Option<String>,
    started_at: Option<Instant>,
}

#[derive(Clone)]
pub struct RemoteSessionService {
    manager: Arc<Mutex<RemoteManager>>,
    state: Arc<Mutex<RemoteSessionState>>,
}

impl RemoteSessionService {
    pub fn new(manager: Arc<Mutex<RemoteManager>>) -> Self {
        Self {
            manager,
            state: Arc::new(Mutex::new(RemoteSessionState::default())),
        }
    }

    pub fn capabilities(&self) -> Option<RemoteCapabilities> {
        self.manager
            .lock()
            .ok()
            .and_then(|manager| manager.capabilities())
    }

    pub fn start(&self, request: RemoteStartRequest) -> Result<RemoteSessionInfo, String> {
        self.stop_if_expired();
        let info = {
            let mut manager = self
                .manager
                .lock()
                .map_err(|_| "remote backend unavailable".to_string())?;
            manager.start(request)?
        };
        if let Ok(mut state) = self.state.lock() {
            state.session_id = Some(info.session_id.clone());
            state.started_at = Some(Instant::now());
        }
        Ok(info)
    }

    pub fn stop(&self, session_id: &str) -> Result<(), String> {
        {
            if let Ok(mut state) = self.state.lock() {
                if state.session_id.as_deref() == Some(session_id) {
                    state.session_id = None;
                    state.started_at = None;
                }
            }
        }
        let mut manager = self
            .manager
            .lock()
            .map_err(|_| "remote backend unavailable".to_string())?;
        manager.stop(session_id)
    }

    pub fn status(&self) -> Option<RemoteStatus> {
        self.stop_if_expired();
        self.manager
            .lock()
            .ok()
            .and_then(|manager| manager.status())
    }

    pub fn validate_session(&self, session_id: &str, token: &str) -> bool {
        if self.is_expired() {
            return false;
        }
        self.manager
            .lock()
            .map(|manager| manager.validate_session(session_id, token))
            .unwrap_or(false)
    }

    fn is_expired(&self) -> bool {
        let state = match self.state.lock() {
            Ok(state) => state,
            Err(poison) => poison.into_inner(),
        };
        let started_at = match state.started_at {
            Some(started_at) => started_at,
            None => return false,
        };
        Instant::now().duration_since(started_at) > SESSION_TTL
    }

    fn stop_if_expired(&self) {
        let expired_session_id = {
            let mut state = match self.state.lock() {
                Ok(state) => state,
                Err(poison) => poison.into_inner(),
            };
            if let Some(started_at) = state.started_at {
                if Instant::now().duration_since(started_at) > SESSION_TTL {
                    state.started_at = None;
                    state.session_id.take()
                } else {
                    None
                }
            } else {
                None
            }
        };
        if let Some(session_id) = expired_session_id {
            if let Ok(mut manager) = self.manager.lock() {
                let _ = manager.stop(&session_id);
            }
        }
    }
}
