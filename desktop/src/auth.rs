use crate::pairing::{record_client_seen, PairingState};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

#[derive(Clone, Debug)]
pub struct AuthError {
    pub code: &'static str,
    pub message: String,
    pub retry_after: Option<u64>,
}

impl AuthError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retry_after: None,
        }
    }

    pub fn rate_limited(retry_after: Option<u64>) -> Self {
        Self {
            code: "rate_limited",
            message: "Too many invalid tokens. Try again later.".to_string(),
            retry_after,
        }
    }
}

pub struct ClientConnectionGuard {
    state: Arc<Mutex<PairingState>>,
    client_id: Option<String>,
}

impl Drop for ClientConnectionGuard {
    fn drop(&mut self) {
        if let Some(id) = self.client_id.as_deref() {
            if let Ok(mut state) = self.state.lock() {
                state.disconnect_client(id);
            }
        }
    }
}

pub fn track_client_connection(
    state: &Arc<Mutex<PairingState>>,
    client_id: Option<String>,
) -> ClientConnectionGuard {
    if let Some(id) = client_id.as_deref() {
        if let Ok(mut state) = state.lock() {
            state.connect_client(id);
        }
    }
    ClientConnectionGuard {
        state: state.clone(),
        client_id,
    }
}

pub fn ensure_auth_not_blocked(
    state: &Arc<Mutex<PairingState>>,
    client_id: Option<&str>,
) -> Result<(), AuthError> {
    let now = unix_now();
    let mut guard = state
        .lock()
        .map_err(|_| AuthError::new("state_locked", "Pairing state unavailable."))?;
    if guard.is_auth_blocked(client_id, now) {
        return Err(AuthError::rate_limited(None));
    }
    Ok(())
}

pub fn validate_auth_token(
    state: &Arc<Mutex<PairingState>>,
    token: &str,
    client_id: Option<&str>,
) -> Result<(), AuthError> {
    if token.trim().is_empty() {
        return Err(AuthError::new(
            "unauthorized",
            "Missing or invalid agent token.",
        ));
    }
    if !is_auth_token_valid(state, token, client_id) {
        let retry_after = record_auth_failure(state, client_id);
        if retry_after.is_some() {
            return Err(AuthError::rate_limited(retry_after));
        }
        return Err(AuthError::new(
            "unauthorized",
            "Missing or invalid agent token.",
        ));
    }
    record_auth_success(state, client_id);
    Ok(())
}

pub fn ensure_client_allowed(
    state: &Arc<Mutex<PairingState>>,
    client_id: &Option<String>,
) -> Result<(), AuthError> {
    let client_id = match client_id {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(()),
    };
    let now = unix_now();
    let mut state = state
        .lock()
        .map_err(|_| AuthError::new("state_locked", "Pairing state unavailable."))?;
    if state.is_client_blocked(client_id, now) {
        return Err(AuthError::new("client_blocked", "Client has been disabled."));
    }
    Ok(())
}

pub fn record_client_activity(
    state: &Arc<Mutex<PairingState>>,
    client_id: Option<String>,
    client_name: Option<String>,
    source: Option<String>,
) {
    let now = unix_now();
    if let Ok(mut state) = state.lock() {
        record_client_seen(&mut state, client_id, client_name, source, now);
    }
}

pub fn record_auth_failure(
    state: &Arc<Mutex<PairingState>>,
    client_id: Option<&str>,
) -> Option<u64> {
    let now = unix_now();
    if let Ok(mut guard) = state.lock() {
        return guard.record_auth_failure(client_id, now);
    }
    None
}

pub fn record_auth_success(state: &Arc<Mutex<PairingState>>, client_id: Option<&str>) {
    if let Ok(mut guard) = state.lock() {
        guard.record_auth_success(client_id);
    }
}

pub fn is_auth_token_valid(
    state: &Arc<Mutex<PairingState>>,
    token: &str,
    client_id: Option<&str>,
) -> bool {
    let guard = state.lock();
    if let Ok(state) = guard {
        return state.is_auth_token_valid(token, client_id);
    }
    false
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default()
}
