use axum::{
    extract::{ws::WebSocketUpgrade, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use tower_http::cors::{Any, CorsLayer};

use crate::command::{AgentCommandRequest, AgentCommandResponse, AgentCommandStatus};
use crate::pairing::{
    confirm_pairing_with_state, current_local_ips, current_local_urls, current_wifi_ssid,
    PairingError, PairingState,
};
use crate::terminal::serve_terminal_socket;
use crate::vnc::{serve_vnc_socket, VncManager};
use crate::auth::{
    ensure_auth_not_blocked, ensure_client_allowed, record_client_activity,
    track_client_connection, validate_auth_token, AuthError,
};
use crate::roi::{RoiErrorCode, RoiManager, RoiSessionRequest};
use crate::remote_engine::{RemoteManager, RemoteStartRequest};
use crate::remote_engine::service::RemoteSessionService;
use crate::remote_engine::rustdesk::RustDeskBackend;
use crate::quic::{start_quic_server, QuicServerConfig, QuicServerHandle};

pub struct LocalServerHandle {
    pub port: u16,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    quic: Option<QuicServerHandle>,
}

impl LocalServerHandle {
    pub fn stop(&mut self) {
        if let Some(sender) = self.shutdown.take() {
            let _ = sender.send(());
        }
        if let Some(handle) = self.quic.take() {
            handle.stop();
        }
    }

    pub fn quic_port(&self) -> Option<u16> {
        self.quic.as_ref().map(|handle| handle.port)
    }
}

#[derive(Clone)]
struct LocalServerState {
    pairing: Arc<Mutex<PairingState>>,
    vnc: Arc<Mutex<VncManager>>,
    roi: Arc<Mutex<RoiManager>>,
    remote: Arc<RemoteSessionService>,
}

pub fn start_local_server(
    state: Arc<Mutex<PairingState>>,
    port: u16,
    roi_port_override: Option<u16>,
) -> Result<LocalServerHandle, std::io::Error> {
    if port == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Listen port must be between 1 and 65535.",
        ));
    }
    let listener = TcpListener::bind(format!("0.0.0.0:{port}"))?;
    let actual_port = listener.local_addr()?.port();
    if actual_port != port {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AddrInUse,
            format!("Listen port {port} unavailable."),
        ));
    }
    listener.set_nonblocking(true)?;
    let vnc_manager = Arc::new(Mutex::new(VncManager::new()));
    let remote_manager = Arc::new(Mutex::new(RemoteManager::new()));
    if let Ok(mut guard) = remote_manager.lock() {
        guard.set_backend(Box::new(RustDeskBackend::new()));
    }
    let remote_service = Arc::new(RemoteSessionService::new(remote_manager.clone()));
    let roi_port = roi_port_override.unwrap_or_else(|| {
        state
            .lock()
            .ok()
            .map(|guard| guard.roi_quic_port())
            .unwrap_or(0)
    });
    if roi_port == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "ROI QUIC port must be between 1 and 65535.",
        ));
    }
    let roi_manager = Arc::new(Mutex::new(RoiManager::new(roi_port)));
    let quic_handle = match start_quic_server(QuicServerConfig {
        port: roi_port,
        roi: Some(roi_manager.clone()),
        vnc: Some(vnc_manager.clone()),
        pairing: Some(state.clone()),
        remote: Some(remote_manager.clone()),
    }) {
        Ok(handle) => handle,
        Err(error) => {
            return Err(std::io::Error::new(
                error.kind(),
                format!("ROI QUIC port {roi_port} unavailable: {error}"),
            ));
        }
    };
    if let Ok(mut guard) = roi_manager.lock() {
        guard.set_quic_port(quic_handle.port);
    }
    let server_state = LocalServerState {
        pairing: state,
        vnc: vnc_manager,
        roi: roi_manager,
        remote: remote_service,
    };
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async move {
            let app = Router::new()
                .route("/command", post(handle_command))
                .route("/pairing/confirm", post(handle_pairing_confirm))
                .route("/vnc/{session_id}", get(handle_vnc_ws))
                .route("/terminal/{session_id}", get(handle_terminal_ws))
                .route("/health", get(|| async { "ok" }))
                .layer(
                    CorsLayer::new()
                        .allow_origin(Any)
                        .allow_methods(Any)
                        .allow_headers(Any),
                )
                .with_state(server_state);

            let listener = tokio::net::TcpListener::from_std(listener)
                .expect("local server listener");
            let server = axum::serve(listener, app).with_graceful_shutdown(async {
                let _ = shutdown_rx.await;
            });
            if let Err(error) = server.await {
                eprintln!("local server error: {error}");
            }
        });
    });

    Ok(LocalServerHandle {
        port,
        shutdown: Some(shutdown_tx),
        quic: Some(quic_handle),
    })
}

async fn handle_command(
    State(state): State<LocalServerState>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    if let Err(response) = ensure_authorized(&state.pairing, &headers) {
        return response;
    }

    let (client_id, client_name, source) = extract_client_headers(&headers);
    if let Err(error) = ensure_client_allowed(&state.pairing, &client_id) {
        return auth_error_response(error);
    }
    record_client_activity(
        &state.pairing,
        client_id.clone(),
        client_name.clone(),
        source,
    );

    let request: AgentCommandRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => {
            let response = AgentCommandResponse {
                request_id: String::new(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "invalid_payload".to_string(),
                    message: format!("Invalid JSON payload: {error}"),
                    details: None,
                }),
            };
            return (StatusCode::BAD_REQUEST, Json(json!(response)));
        }
    };

    if request.command == "identity" {
                let identity = match state.pairing.lock() {
                    Ok(pairing_guard) => {
                        let local_urls = current_local_urls(&pairing_guard);
                        let local_ips = current_local_ips();
                        let wifi_ssid = current_wifi_ssid();
                        let frp_url = pairing_guard.frp_url();
                        let roi_quic_port = state
                            .roi
                            .lock()
                            .map(|guard| guard.quic_port())
                            .unwrap_or_else(|poison| poison.into_inner().quic_port());
                        let remote_caps = state.remote.capabilities();
                        json!({
                            "type": "identity",
                            "device_id": pairing_guard.device_id(),
                            "host_name": pairing_guard.host_name(),
                            "auth_token": pairing_guard.auth_token(),
                            "wifi_ssid": wifi_ssid,
                            "local_ips": local_ips,
                            "local_urls": local_urls,
                            "frp_url": frp_url,
                            "roi_quic_port": roi_quic_port,
                            "listen_port": pairing_guard.listen_port(),
                            "remote_capabilities": remote_caps,
                        })
                    }
            Err(_) => json!({
                "type": "identity",
                "device_id": "",
                "host_name": null,
                "auth_token": "",
                "wifi_ssid": null,
                "local_ips": [],
                "local_urls": [],
                "frp_url": null,
            }),
        };
        let response = AgentCommandResponse {
            request_id: request.request_id.clone(),
            status: AgentCommandStatus::Ok,
            payload: Some(identity),
            error: None,
        };
        return (StatusCode::OK, Json(json!(response)));
    }

    if request.command == "vnc" {
        let response = handle_vnc_command(&request, &state.vnc, &state.pairing, &state.roi);
        return (StatusCode::OK, Json(json!(response)));
    }

    if request.command == "roi" {
        let response = handle_roi_command(&request, &state.roi, client_id, client_name);
        return (StatusCode::OK, Json(json!(response)));
    }

    if request.command == "remote" {
        let response = handle_remote_command(&request, &state.remote, &state.roi);
        return (StatusCode::OK, Json(json!(response)));
    }

    let response = crate::command::handle_agent_command(request);
    (StatusCode::OK, Json(json!(response)))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
struct RemoteCommandPayload {
    action: String,
    session_id: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    display_index: Option<usize>,
}

fn handle_remote_command(
    request: &AgentCommandRequest,
    manager: &Arc<RemoteSessionService>,
    roi: &Arc<Mutex<RoiManager>>,
) -> AgentCommandResponse {
    let payload: RemoteCommandPayload = match request.payload.clone() {
        Some(payload) => match serde_json::from_value(payload) {
            Ok(payload) => payload,
            Err(error) => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: "invalid_payload".to_string(),
                        message: format!("Invalid payload for remote command: {error}"),
                        details: Some(json!({ "command": "remote" })),
                    }),
                };
            }
        },
        None => {
            return AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "missing_payload".to_string(),
                    message: "Missing payload for remote command.".to_string(),
                    details: Some(json!({ "command": "remote" })),
                }),
            };
        }
    };

    match payload.action.as_str() {
        "start" => match manager.start(RemoteStartRequest {
            display_index: payload.display_index,
            width: payload.width,
            height: payload.height,
        }) {
            Ok(mut info) => {
                let quic_port = roi
                    .lock()
                    .map(|guard| guard.quic_port())
                    .unwrap_or_else(|poison| poison.into_inner().quic_port());
                info.quic_port = if quic_port == 0 { None } else { Some(quic_port) };
                AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Ok,
                payload: Some(json!({
                    "type": "remote",
                    "status": "started",
                    "session": info,
                })),
                error: None,
            }
            }
            Err(error) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "remote_start_failed".to_string(),
                    message: error,
                    details: Some(json!({ "command": "remote" })),
                }),
            },
        },
        "stop" => {
            let session_id = payload.session_id.unwrap_or_default();
            match manager.stop(&session_id) {
                Ok(()) => AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Ok,
                    payload: Some(json!({
                        "type": "remote",
                        "status": "stopped",
                        "session_id": session_id,
                    })),
                    error: None,
                },
                Err(error) => AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: "remote_stop_failed".to_string(),
                        message: error,
                        details: Some(json!({ "command": "remote" })),
                    }),
                },
            }
        }
        "status" => match manager.status() {
            Some(status) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Ok,
                payload: Some(json!({
                    "type": "remote",
                    "status": "ok",
                    "state": status,
                })),
                error: None,
            },
            None => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "remote_not_configured".to_string(),
                    message: "Remote backend not configured.".to_string(),
                    details: Some(json!({ "command": "remote" })),
                }),
            },
        },
        _ => AgentCommandResponse {
            request_id: request.request_id.clone(),
            status: AgentCommandStatus::Error,
            payload: None,
            error: Some(crate::command::AgentCommandError {
                code: "unsupported_action".to_string(),
                message: format!("Unsupported remote action: {}", payload.action),
                details: Some(json!({ "command": "remote" })),
            }),
        },
    }
}

#[derive(Debug, Deserialize)]
struct VncCommandPayload {
    action: String,
    session_id: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    display_index: Option<usize>,
    high_perf_interval_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct RoiCommandPayload {
    action: String,
    session_id: Option<String>,
    vnc_session_id: Option<String>,
    display_index: Option<usize>,
    framebuffer_width: Option<u32>,
    framebuffer_height: Option<u32>,
    screen_width: Option<u32>,
    screen_height: Option<u32>,
}

fn handle_vnc_command(
    request: &AgentCommandRequest,
    manager: &Arc<Mutex<VncManager>>,
    pairing: &Arc<Mutex<PairingState>>,
    roi: &Arc<Mutex<RoiManager>>,
) -> AgentCommandResponse {
    let payload: VncCommandPayload = match request.payload.clone() {
        Some(payload) => match serde_json::from_value(payload) {
            Ok(payload) => payload,
            Err(error) => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: "invalid_payload".to_string(),
                        message: format!("Invalid payload for vnc command: {error}"),
                        details: None,
                    }),
                };
            }
        },
        None => {
            return AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "missing_payload".to_string(),
                    message: "Missing payload for vnc command.".to_string(),
                    details: Some(json!({ "command": "vnc" })),
                }),
            };
        }
    };

    let action = payload.action.to_lowercase();
    if action == "displays" {
        match crate::vnc::list_displays() {
            Ok(displays) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Ok,
                payload: Some(json!({
                    "type": "vnc",
                    "status": "displays",
                    "displays": displays
                        .iter()
                        .map(|display| json!({
                            "index": display.index,
                            "width": display.width,
                            "height": display.height,
                            "is_primary": display.is_primary,
                        }))
                        .collect::<Vec<_>>(),
                })),
                error: None,
            },
            Err(message) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "vnc_displays_failed".to_string(),
                    message,
                    details: Some(json!({ "command": "vnc" })),
                }),
            },
        }
    } else if action == "start" {
        let session_id = payload
            .session_id
            .clone()
            .unwrap_or_else(|| request.request_id.clone());
        let mut manager = manager.lock().unwrap();
        let fallback_quic = pairing
            .lock()
            .map(|guard| guard.roi_quic_port())
            .unwrap_or_else(|poison| poison.into_inner().roi_quic_port());
        let quic_port = {
            let port = roi
                .lock()
                .map(|guard| guard.quic_port())
                .unwrap_or_else(|poison| poison.into_inner().quic_port());
            if port == 0 { fallback_quic } else { port }
        };
        match manager.start_session(
            session_id.clone(),
            payload.width,
            payload.height,
            payload.display_index,
            payload.high_perf_interval_ms,
        ) {
            Ok(info) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Ok,
                payload: Some(json!({
                    "type": "vnc",
                    "status": "ready",
                    "session_id": info.session_id,
                    "token": info.token,
                    "ws_path": info.ws_path,
                    "quic_port": quic_port,
                    "width": info.width,
                    "height": info.height,
                    "display_index": info.display_index,
                    "input_width": info.input_width,
                    "input_height": info.input_height,
                    "input_origin_x": info.input_origin_x,
                    "input_origin_y": info.input_origin_y,
                    "input_scale_x": info.input_scale_x,
                    "input_scale_y": info.input_scale_y,
                    "screen_width": info.screen_width,
                    "screen_height": info.screen_height,
                })),
                error: None,
            },
            Err(message) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "vnc_start_failed".to_string(),
                    message,
                    details: Some(json!({ "command": "vnc" })),
                }),
            },
        }
    } else if action == "stop" {
        let session_id = payload.session_id.unwrap_or_default();
        let mut manager = manager.lock().unwrap();
        manager.stop_session(&session_id);
        AgentCommandResponse {
            request_id: request.request_id.clone(),
            status: AgentCommandStatus::Ok,
            payload: Some(json!({
                "type": "vnc",
                "status": "stopped",
                "session_id": session_id,
            })),
            error: None,
        }
    } else {
        AgentCommandResponse {
            request_id: request.request_id.clone(),
            status: AgentCommandStatus::Error,
            payload: None,
            error: Some(crate::command::AgentCommandError {
                code: "unsupported_action".to_string(),
                message: format!("Unsupported VNC action: {}", payload.action),
                details: Some(json!({ "command": "vnc" })),
            }),
        }
    }
}

fn handle_roi_command(
    request: &AgentCommandRequest,
    manager: &Arc<Mutex<RoiManager>>,
    client_id: Option<String>,
    client_name: Option<String>,
) -> AgentCommandResponse {
    let payload: RoiCommandPayload = match request.payload.clone() {
        Some(payload) => match serde_json::from_value(payload) {
            Ok(payload) => payload,
            Err(error) => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: RoiErrorCode::InvalidPayload.as_str().to_string(),
                        message: format!("Invalid payload for roi command: {error}"),
                        details: None,
                    }),
                };
            }
        },
        None => {
            return AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: RoiErrorCode::MissingPayload.as_str().to_string(),
                        message: "Missing payload for roi command.".to_string(),
                        details: Some(json!({ "command": "roi" })),
                    }),
            };
        }
    };

    let action = payload.action.to_lowercase();
    if action == "start" {
        let session_id = payload
            .session_id
            .clone()
            .unwrap_or_else(|| request.request_id.clone());
        let vnc_session_id = payload
            .vnc_session_id
            .clone()
            .unwrap_or_else(|| session_id.clone());
        let framebuffer_width = match payload.framebuffer_width {
            Some(value) => value,
            None => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: RoiErrorCode::MissingPayload.as_str().to_string(),
                        message: "Missing framebuffer_width for roi command.".to_string(),
                        details: Some(json!({ "command": "roi" })),
                    }),
                };
            }
        };
        let framebuffer_height = match payload.framebuffer_height {
            Some(value) => value,
            None => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: RoiErrorCode::MissingPayload.as_str().to_string(),
                        message: "Missing framebuffer_height for roi command.".to_string(),
                        details: Some(json!({ "command": "roi" })),
                    }),
                };
            }
        };
        let screen_width = match payload.screen_width {
            Some(value) => value,
            None => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: RoiErrorCode::MissingPayload.as_str().to_string(),
                        message: "Missing screen_width for roi command.".to_string(),
                        details: Some(json!({ "command": "roi" })),
                    }),
                };
            }
        };
        let screen_height = match payload.screen_height {
            Some(value) => value,
            None => {
                return AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: RoiErrorCode::MissingPayload.as_str().to_string(),
                        message: "Missing screen_height for roi command.".to_string(),
                        details: Some(json!({ "command": "roi" })),
                    }),
                };
            }
        };

        let request_payload = RoiSessionRequest {
            session_id: session_id.clone(),
            vnc_session_id: vnc_session_id.clone(),
            client_id: client_id.clone(),
            client_name: client_name.clone(),
            display_index: payload.display_index,
            framebuffer_width,
            framebuffer_height,
            screen_width,
            screen_height,
        };
        let mut manager = manager.lock().unwrap();
        let info = manager.start_session(request_payload);
        eprintln!(
            "ROI start: session_id={} vnc_session_id={} client_id={:?} client_name={:?} quic_port={} display_index={:?} framebuffer={}x{} screen={}x{}",
            info.session_id,
            vnc_session_id,
            client_id,
            client_name,
            info.quic_port,
            info.display_index,
            info.framebuffer_width,
            info.framebuffer_height,
            info.screen_width,
            info.screen_height,
        );
        return AgentCommandResponse {
            request_id: request.request_id.clone(),
            status: AgentCommandStatus::Ok,
            payload: Some(json!({
                "type": "roi",
                "status": "ready",
                "session_id": info.session_id,
                "token": info.token,
                "quic_port": info.quic_port,
                "display_index": info.display_index,
                "framebuffer_width": info.framebuffer_width,
                "framebuffer_height": info.framebuffer_height,
                "screen_width": info.screen_width,
                "screen_height": info.screen_height,
                "issued_at": info.issued_at,
            })),
            error: None,
        };
    }

    if action == "stop" {
        let session_id = payload.session_id.unwrap_or_default();
        let mut manager = manager.lock().unwrap();
        manager.stop_session(&session_id);
        eprintln!(
            "ROI stop: session_id={} client_id={:?} client_name={:?}",
            session_id,
            client_id,
            client_name
        );
        return AgentCommandResponse {
            request_id: request.request_id.clone(),
            status: AgentCommandStatus::Ok,
            payload: Some(json!({
                "type": "roi",
                "status": "stopped",
                "session_id": session_id,
            })),
            error: None,
        };
    }

    AgentCommandResponse {
        request_id: request.request_id.clone(),
        status: AgentCommandStatus::Error,
        payload: None,
        error: Some(crate::command::AgentCommandError {
            code: RoiErrorCode::UnsupportedAction.as_str().to_string(),
            message: format!("Unsupported ROI action: {}", payload.action),
            details: Some(json!({ "command": "roi" })),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    #[test]
    fn roi_start_returns_session_metadata() {
        let manager = Arc::new(Mutex::new(RoiManager::new(4242)));
        let request = AgentCommandRequest {
            request_id: "req-1".to_string(),
            command: "roi".to_string(),
            payload: Some(json!({
                "action": "start",
                "session_id": "roi-1",
                "vnc_session_id": "vnc-1",
                "framebuffer_width": 1920,
                "framebuffer_height": 1080,
                "screen_width": 1920,
                "screen_height": 1080
            })),
        };

        let response = handle_roi_command(
            &request,
            &manager,
            Some("client-1".to_string()),
            Some("Test Client".to_string()),
        );
        assert!(matches!(response.status, AgentCommandStatus::Ok));
        let payload = response.payload.expect("missing payload");
        assert_eq!(payload["type"], "roi");
        assert_eq!(payload["status"], "ready");
        assert_eq!(payload["session_id"], "roi-1");
        assert_eq!(payload["quic_port"], 4242);
        assert_eq!(payload["framebuffer_width"], 1920);
        assert_eq!(payload["framebuffer_height"], 1080);
    }

    #[test]
    fn roi_command_http_roundtrip() {
        let state = Arc::new(Mutex::new(PairingState::default()));
        let token = {
            let guard = state.lock().expect("pairing state lock");
            guard.auth_token().to_string()
        };
        let mut server = start_local_server(state, 0, None).expect("start local server");
        let port = server.port;
        let health_url = format!("http://127.0.0.1:{port}/health");
        let command_url = format!("http://127.0.0.1:{port}/command");
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_proxy()
            .build()
            .expect("http client");

        let mut healthy = false;
        for _ in 0..10 {
            if let Ok(response) = client.get(&health_url).send() {
                if response.status().is_success() {
                    healthy = true;
                    break;
                }
            }
            thread::sleep(Duration::from_millis(120));
        }
        assert!(healthy, "local server did not become healthy");

        let request = json!({
            "request_id": "roi-http-1",
            "command": "roi",
            "payload": {
                "action": "start",
                "session_id": "roi-http-1",
                "vnc_session_id": "vnc-http-1",
                "framebuffer_width": 1920,
                "framebuffer_height": 1080,
                "screen_width": 1920,
                "screen_height": 1080
            }
        });
        let response = client
            .post(&command_url)
            .header("x-agent-token", token)
            .json(&request)
            .send()
            .expect("roi command response");
        assert!(response.status().is_success());
        let body: serde_json::Value = response.json().expect("response json");
        assert_eq!(body["status"], "ok");
        assert_eq!(body["payload"]["type"], "roi");
        assert_eq!(body["payload"]["status"], "ready");
        assert_eq!(body["payload"]["session_id"], "roi-http-1");

        server.stop();
    }
}

#[derive(Debug, Deserialize)]
struct PairingConfirmRequest {
    token: String,
    secret: String,
    client_id: Option<String>,
    client_name: Option<String>,
}

async fn handle_pairing_confirm(
    State(state): State<LocalServerState>,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    let confirm_request: PairingConfirmRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": {
                        "code": "invalid_payload",
                        "message": format!("Invalid JSON payload: {error}")
                    }
                })),
            )
        }
    };

    if let Err(error) = ensure_client_allowed(&state.pairing, &confirm_request.client_id) {
        return auth_error_response(error);
    }

    match confirm_pairing_with_state(
        &state.pairing,
        &confirm_request.token,
        &confirm_request.secret,
        None,
        confirm_request.client_id.clone(),
        confirm_request.client_name.clone(),
    ) {
        Ok(response) => (StatusCode::OK, Json(json!(response))),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(build_pairing_error(error)),
        ),
    }
}

fn build_pairing_error(error: PairingError) -> serde_json::Value {
    json!({
        "error": {
            "code": error.code,
            "message": error.message,
        }
    })
}

fn auth_error_response(error: AuthError) -> (StatusCode, Json<serde_json::Value>) {
    let status = match error.code {
        "rate_limited" => StatusCode::TOO_MANY_REQUESTS,
        "client_blocked" => StatusCode::FORBIDDEN,
        "unauthorized" => StatusCode::UNAUTHORIZED,
        "state_locked" => StatusCode::INTERNAL_SERVER_ERROR,
        _ => StatusCode::BAD_REQUEST,
    };
    let mut payload = json!({
        "error": {
            "code": error.code,
            "message": error.message,
        }
    });
    if let Some(retry_after) = error.retry_after {
        if let Some(error_obj) = payload.get_mut("error") {
            error_obj["retry_after"] = json!(retry_after);
        }
    }
    (status, Json(payload))
}

async fn handle_vnc_ws(
    State(state): State<LocalServerState>,
    Path(session_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let token = params.get("token").cloned().unwrap_or_default();
    let auth_token = params.get("auth_token").cloned().unwrap_or_default();
    let client_id = params.get("client_id").cloned();
    let client_name = params.get("client_name").cloned();
    if let Err(error) = ensure_auth_not_blocked(&state.pairing, client_id.as_deref()) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = validate_auth_token(&state.pairing, &auth_token, client_id.as_deref()) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = ensure_client_allowed(&state.pairing, &client_id) {
        return auth_error_response(error).into_response();
    }
    let guard_id = client_id.clone();
    record_client_activity(&state.pairing, client_id, client_name, None);
    let guard = track_client_connection(&state.pairing, guard_id);
    let manager = state.vnc.clone();
    ws.on_upgrade(move |socket| async move {
        let _guard = guard;
        serve_vnc_socket(socket, manager, session_id, token).await;
    })
}

async fn handle_terminal_ws(
    State(state): State<LocalServerState>,
    Path(session_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let auth_token = params.get("auth_token").cloned().unwrap_or_default();
    let client_id = params.get("client_id").cloned();
    let client_name = params.get("client_name").cloned();
    if let Err(error) = ensure_auth_not_blocked(&state.pairing, client_id.as_deref()) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = validate_auth_token(&state.pairing, &auth_token, client_id.as_deref()) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = ensure_client_allowed(&state.pairing, &client_id) {
        return auth_error_response(error).into_response();
    }
    let guard_id = client_id.clone();
    record_client_activity(&state.pairing, client_id, client_name, None);
    let guard = track_client_connection(&state.pairing, guard_id);
    ws.on_upgrade(move |socket| async move {
        let _guard = guard;
        serve_terminal_socket(socket, session_id).await;
    })
}

fn ensure_authorized(
    state: &Arc<Mutex<PairingState>>,
    headers: &HeaderMap,
) -> Result<(), (StatusCode, Json<serde_json::Value>)> {
    let (client_id, _, _) = extract_client_headers(headers);
    if let Err(error) = ensure_auth_not_blocked(state, client_id.as_deref()) {
        return Err(auth_error_response(error));
    }
    let token = extract_auth_token(headers).unwrap_or_default();
    if let Err(error) = validate_auth_token(state, &token, client_id.as_deref()) {
        return Err(auth_error_response(error));
    }
    Ok(())
}

fn extract_auth_token(headers: &HeaderMap) -> Option<String> {
    if let Some(value) = headers.get("x-agent-token") {
        if let Ok(token) = value.to_str() {
            let trimmed = token.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    if let Some(value) = headers.get(axum::http::header::AUTHORIZATION) {
        if let Ok(value) = value.to_str() {
            let trimmed = value.trim();
            if let Some(rest) = trimmed.strip_prefix("Bearer ") {
                let token = rest.trim();
                if !token.is_empty() {
                    return Some(token.to_string());
                }
            }
        }
    }
    None
}

fn extract_client_headers(headers: &HeaderMap) -> (Option<String>, Option<String>, Option<String>) {
    let client_id = headers
        .get("x-client-id")
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let client_name = headers
        .get("x-client-name")
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let source = headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    (client_id, client_name, source)
}
