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

use crate::auth::{
    ensure_auth_not_blocked, ensure_client_allowed, record_auth_failure, record_auth_success,
    record_client_activity, track_client_connection, validate_auth_token, validate_ws_ticket,
    AuthError,
};
use crate::command::{AgentCommandRequest, AgentCommandResponse, AgentCommandStatus};
use crate::pairing::{
    build_transport_endpoints, confirm_pairing_with_state, current_local_ips, current_local_urls,
    current_wifi_ssid, PairingError, PairingState,
};
use crate::quic::{start_quic_server, QuicServerConfig, QuicServerHandle};
use crate::remote_engine::rustdesk::RustDeskBackend;
use crate::remote_engine::service::RemoteSessionService;
use crate::remote_engine::{RemoteManager, RemoteStartRequest};
use crate::roi::{RoiErrorCode, RoiManager, RoiSessionRequest};
use crate::terminal::serve_terminal_socket;
use crate::vnc::{serve_vnc_socket, VncManager};

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
    eprintln!("QUIC server listening on UDP {}", quic_handle.port);
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

            let listener =
                tokio::net::TcpListener::from_std(listener).expect("local server listener");
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
                let tunnel_url = pairing_guard.tunnel_url();
                let transports = build_transport_endpoints(
                    &local_urls,
                    frp_url.as_deref(),
                    tunnel_url.as_deref(),
                );
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
                    "transports": transports,
                    "tunnel_url": tunnel_url,
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
                "transports": [],
                "tunnel_url": null,
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

    if request.command == "ws_ticket" {
        let payload = request.payload.clone().unwrap_or_else(|| json!({}));
        let ticket_request = match serde_json::from_value::<WsTicketCommandPayload>(payload) {
            Ok(value) => value,
            Err(error) => {
                let response = AgentCommandResponse {
                    request_id: request.request_id.clone(),
                    status: AgentCommandStatus::Error,
                    payload: None,
                    error: Some(crate::command::AgentCommandError {
                        code: "invalid_payload".to_string(),
                        message: format!("Invalid payload for ws_ticket command: {error}"),
                        details: Some(json!({ "command": "ws_ticket" })),
                    }),
                };
                return (StatusCode::BAD_REQUEST, Json(json!(response)));
            }
        };
        let scope = ticket_request
            .scope
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("terminal_ws")
            .to_string();
        let requested_session = ticket_request
            .session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.to_string());

        if matches!(scope.as_str(), "terminal_ws" | "vnc_ws") && requested_session.is_none() {
            let response = AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: "invalid_payload".to_string(),
                    message: "session_id is required for session websocket scope.".to_string(),
                    details: Some(json!({ "command": "ws_ticket", "scope": scope })),
                }),
            };
            return (StatusCode::BAD_REQUEST, Json(json!(response)));
        }

        let issue_result = match state.pairing.lock() {
            Ok(mut pairing_guard) => pairing_guard.issue_ws_ticket(
                scope.as_str(),
                requested_session.as_deref(),
                client_id.as_deref(),
            ),
            Err(_) => Err(crate::pairing::PairingError::new(
                "state_locked",
                "Pairing state unavailable.",
            )),
        };

        let response = match issue_result {
            Ok((token, expires_at)) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Ok,
                payload: Some(json!({
                    "type": "ws_ticket",
                    "scope": scope,
                    "session_id": requested_session,
                    "token": token,
                    "expires_at": expires_at,
                })),
                error: None,
            },
            Err(error) => AgentCommandResponse {
                request_id: request.request_id.clone(),
                status: AgentCommandStatus::Error,
                payload: None,
                error: Some(crate::command::AgentCommandError {
                    code: error.code,
                    message: error.message,
                    details: Some(json!({ "command": "ws_ticket" })),
                }),
            },
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
struct WsTicketCommandPayload {
    scope: Option<String>,
    session_id: Option<String>,
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
                info.quic_port = if quic_port == 0 {
                    None
                } else {
                    Some(quic_port)
                };
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
            if port == 0 {
                fallback_quic
            } else {
                port
            }
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
            session_id, client_id, client_name
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
    use axum::body::to_bytes;
    use axum::http::HeaderValue;
    use serde_json::{json, Value};
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

    fn build_test_server_state() -> LocalServerState {
        let pairing = Arc::new(Mutex::new(PairingState::default()));
        let vnc = Arc::new(Mutex::new(VncManager::new()));
        let roi = Arc::new(Mutex::new(RoiManager::new(4242)));
        let remote_manager = Arc::new(Mutex::new(RemoteManager::new()));
        let remote = Arc::new(RemoteSessionService::new(remote_manager));
        LocalServerState {
            pairing,
            vnc,
            roi,
            remote,
        }
    }

    async fn response_json(response: axum::response::Response) -> Value {
        let bytes = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("response bytes");
        serde_json::from_slice::<Value>(&bytes).expect("response json")
    }

    #[test]
    fn pairing_confirm_protocol_1_1_requires_nonce() {
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let request = json!({
                "protocol_version": "1.1",
                "token": "ABC123",
                "secret": "SECRET77"
            });
            let response = handle_pairing_confirm(
                State(build_test_server_state()),
                axum::body::Bytes::from(request.to_string()),
            )
            .await
            .into_response();

            assert_eq!(response.status(), StatusCode::BAD_REQUEST);
            let payload = response_json(response).await;
            assert_eq!(payload["error"]["code"], "missing_nonce");
        });
    }

    #[test]
    fn pairing_confirm_without_protocol_does_not_require_nonce() {
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let request = json!({
                "token": "ABC123",
                "secret": "SECRET77"
            });
            let response = handle_pairing_confirm(
                State(build_test_server_state()),
                axum::body::Bytes::from(request.to_string()),
            )
            .await
            .into_response();

            assert_eq!(response.status(), StatusCode::BAD_REQUEST);
            let payload = response_json(response).await;
            assert_eq!(payload["error"]["code"], "missing_token");
        });
    }

    #[test]
    fn resolve_ws_auth_context_prefers_headers() {
        let mut headers = HeaderMap::new();
        headers.insert("x-agent-token", HeaderValue::from_static("header-token"));
        headers.insert("x-client-id", HeaderValue::from_static("header-client"));
        headers.insert("x-client-name", HeaderValue::from_static("Header Client"));

        let mut params = HashMap::new();
        params.insert("auth_token".to_string(), "query-token".to_string());
        params.insert("client_id".to_string(), "query-client".to_string());
        params.insert("client_name".to_string(), "Query Client".to_string());

        params.insert("ws_ticket".to_string(), "query-ticket".to_string());

        let context = resolve_ws_auth_context(&headers, &params);
        assert_eq!(context.auth_token, "header-token");
        assert_eq!(context.ws_ticket.as_deref(), Some("query-ticket"));
        assert_eq!(context.client_id.as_deref(), Some("query-client"));
        assert_eq!(context.client_name.as_deref(), Some("Query Client"));
    }

    #[test]
    fn resolve_ws_auth_context_falls_back_to_query() {
        let headers = HeaderMap::new();
        let mut params = HashMap::new();
        params.insert("auth_token".to_string(), "query-token".to_string());
        params.insert("client_id".to_string(), "query-client".to_string());
        params.insert("client_name".to_string(), "Query Client".to_string());

        params.insert("ws_ticket".to_string(), "query-ticket".to_string());

        let context = resolve_ws_auth_context(&headers, &params);
        assert_eq!(context.auth_token, "query-token");
        assert_eq!(context.ws_ticket.as_deref(), Some("query-ticket"));
        assert_eq!(context.client_id.as_deref(), Some("query-client"));
        assert_eq!(context.client_name.as_deref(), Some("Query Client"));
    }

    #[test]
    fn resolve_ws_auth_context_prefers_ws_ticket_header() {
        let mut headers = HeaderMap::new();
        headers.insert("x-ws-ticket", HeaderValue::from_static("header-ticket"));

        let mut params = HashMap::new();
        params.insert("ws_ticket".to_string(), "query-ticket".to_string());

        let context = resolve_ws_auth_context(&headers, &params);
        assert_eq!(context.ws_ticket.as_deref(), Some("header-ticket"));
    }

    #[test]
    fn validate_ws_credentials_accepts_valid_ticket_without_auth_token() {
        let state = Arc::new(Mutex::new(PairingState::default()));
        let ticket = {
            let mut guard = state.lock().expect("pairing state lock");
            let (token, _) = guard
                .issue_ws_ticket("terminal_ws", Some("session-1"), Some("client-1"))
                .expect("issue ticket");
            token
        };
        let auth = WsAuthContext {
            auth_token: String::new(),
            ws_ticket: Some(ticket),
            client_id: Some("client-1".to_string()),
            client_name: None,
        };

        let result = validate_ws_credentials(&state, &auth, "terminal_ws", Some("session-1"));
        assert!(result.is_ok());
    }

    #[test]
    fn validate_ws_credentials_rejects_replayed_ticket() {
        let state = Arc::new(Mutex::new(PairingState::default()));
        let ticket = {
            let mut guard = state.lock().expect("pairing state lock");
            let (token, _) = guard
                .issue_ws_ticket("terminal_ws", Some("session-2"), Some("client-2"))
                .expect("issue ticket");
            token
        };
        let auth = WsAuthContext {
            auth_token: String::new(),
            ws_ticket: Some(ticket.clone()),
            client_id: Some("client-2".to_string()),
            client_name: None,
        };

        let first = validate_ws_credentials(&state, &auth, "terminal_ws", Some("session-2"));
        assert!(first.is_ok());

        let replay = WsAuthContext {
            auth_token: String::new(),
            ws_ticket: Some(ticket),
            client_id: Some("client-2".to_string()),
            client_name: None,
        };
        let second = validate_ws_credentials(&state, &replay, "terminal_ws", Some("session-2"))
            .expect_err("replay should fail");
        assert_eq!(second.code, "unauthorized");
    }

    #[test]
    fn validate_ws_credentials_prefers_auth_token_over_ws_ticket() {
        let state = Arc::new(Mutex::new(PairingState::default()));
        let ticket = {
            let mut guard = state.lock().expect("pairing state lock");
            let (token, _) = guard
                .issue_ws_ticket("terminal_ws", Some("session-3"), Some("client-3"))
                .expect("issue ticket");
            token
        };
        let auth = WsAuthContext {
            auth_token: "invalid-static-token".to_string(),
            ws_ticket: Some(ticket),
            client_id: Some("client-3".to_string()),
            client_name: None,
        };

        let error = validate_ws_credentials(&state, &auth, "terminal_ws", Some("session-3"))
            .expect_err("invalid long token should fail");
        assert_eq!(error.code, "unauthorized");
    }

    #[test]
    fn ws_ticket_command_requires_session_for_terminal_scope() {
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let state = build_test_server_state();
            let token = {
                let guard = state.pairing.lock().expect("pairing state lock");
                guard.auth_token().to_string()
            };

            let mut headers = HeaderMap::new();
            headers.insert(
                "x-agent-token",
                HeaderValue::from_str(token.as_str()).expect("token header"),
            );

            let request = json!({
                "request_id": "ws-ticket-1",
                "command": "ws_ticket",
                "payload": {
                    "scope": "terminal_ws"
                }
            });

            let response = handle_command(
                State(state),
                headers,
                axum::body::Bytes::from(request.to_string()),
            )
            .await
            .into_response();

            assert_eq!(response.status(), StatusCode::BAD_REQUEST);
            let payload = response_json(response).await;
            assert_eq!(payload["status"], "error");
            assert_eq!(payload["error"]["code"], "invalid_payload");
        });
    }

    #[test]
    fn ws_ticket_command_returns_token_for_terminal_scope() {
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let state = build_test_server_state();
            let token = {
                let guard = state.pairing.lock().expect("pairing state lock");
                guard.auth_token().to_string()
            };

            let mut headers = HeaderMap::new();
            headers.insert(
                "x-agent-token",
                HeaderValue::from_str(token.as_str()).expect("token header"),
            );
            headers.insert("x-client-id", HeaderValue::from_static("client-ws-1"));

            let request = json!({
                "request_id": "ws-ticket-2",
                "command": "ws_ticket",
                "payload": {
                    "scope": "terminal_ws",
                    "session_id": "terminal-session-1"
                }
            });

            let response = handle_command(
                State(state),
                headers,
                axum::body::Bytes::from(request.to_string()),
            )
            .await
            .into_response();

            assert_eq!(response.status(), StatusCode::OK);
            let payload = response_json(response).await;
            assert_eq!(payload["status"], "ok");
            assert_eq!(payload["payload"]["type"], "ws_ticket");
            assert_eq!(payload["payload"]["scope"], "terminal_ws");
            assert_eq!(payload["payload"]["session_id"], "terminal-session-1");
            let token_value = payload["payload"]["token"].as_str().unwrap_or_default();
            assert!(!token_value.is_empty());
        });
    }
}

#[derive(Debug, Deserialize)]
struct PairingConfirmRequest {
    protocol_version: Option<String>,
    token: String,
    secret: String,
    nonce: Option<String>,
    client_id: Option<String>,
    client_name: Option<String>,
}

fn is_supported_pairing_protocol(version: &str) -> bool {
    matches!(version, "1.0" | "1.1")
}

fn protocol_requires_nonce(version: &str) -> bool {
    matches!(version, "1.1")
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

    let client_id_for_guard = confirm_request.client_id.clone();
    if let Err(error) = ensure_auth_not_blocked(&state.pairing, client_id_for_guard.as_deref()) {
        return auth_error_response(error);
    }

    let requested_protocol = confirm_request
        .protocol_version
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    if let Some(protocol_version) = requested_protocol {
        if !is_supported_pairing_protocol(protocol_version) {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": {
                        "code": "unsupported_protocol",
                        "message": "Pairing protocol version is not supported."
                    }
                })),
            );
        }
        if protocol_requires_nonce(protocol_version)
            && confirm_request
                .nonce
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .is_none()
        {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": {
                        "code": "missing_nonce",
                        "message": "Pairing nonce is required for this protocol version."
                    }
                })),
            );
        }
    }

    if let Err(error) = ensure_client_allowed(&state.pairing, &confirm_request.client_id) {
        return auth_error_response(error);
    }

    match confirm_pairing_with_state(
        &state.pairing,
        &confirm_request.token,
        &confirm_request.secret,
        confirm_request.nonce.as_deref(),
        None,
        confirm_request.client_id.clone(),
        confirm_request.client_name.clone(),
    ) {
        Ok(response) => {
            if let Some(id) = confirm_request.client_id.as_deref() {
                record_auth_success(&state.pairing, Some(id));
            } else {
                record_auth_success(&state.pairing, None);
            }
            (StatusCode::OK, Json(json!(response)))
        }
        Err(error) => {
            if matches!(
                error.code.as_str(),
                "token_mismatch" | "secret_mismatch" | "nonce_mismatch"
            ) {
                let retry_after =
                    record_auth_failure(&state.pairing, confirm_request.client_id.as_deref());
                if retry_after.is_some() {
                    return auth_error_response(AuthError::rate_limited(retry_after));
                }
            }
            (StatusCode::BAD_REQUEST, Json(build_pairing_error(error)))
        }
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
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let token = ws_query_value(&params, "token").unwrap_or_default();
    let auth_context = resolve_ws_auth_context(&headers, &params);
    if let Err(error) = ensure_auth_not_blocked(&state.pairing, auth_context.client_id.as_deref()) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = validate_ws_credentials(
        &state.pairing,
        &auth_context,
        "vnc_ws",
        Some(session_id.as_str()),
    ) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = ensure_client_allowed(&state.pairing, &auth_context.client_id) {
        return auth_error_response(error).into_response();
    }
    let guard_id = auth_context.client_id.clone();
    record_client_activity(
        &state.pairing,
        auth_context.client_id,
        auth_context.client_name,
        None,
    );
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
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let auth_context = resolve_ws_auth_context(&headers, &params);
    if let Err(error) = ensure_auth_not_blocked(&state.pairing, auth_context.client_id.as_deref()) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = validate_ws_credentials(
        &state.pairing,
        &auth_context,
        "terminal_ws",
        Some(session_id.as_str()),
    ) {
        return auth_error_response(error).into_response();
    }
    if let Err(error) = ensure_client_allowed(&state.pairing, &auth_context.client_id) {
        return auth_error_response(error).into_response();
    }
    let guard_id = auth_context.client_id.clone();
    record_client_activity(
        &state.pairing,
        auth_context.client_id,
        auth_context.client_name,
        None,
    );
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

fn ws_query_value(params: &HashMap<String, String>, key: &str) -> Option<String> {
    params
        .get(key)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[derive(Debug, Clone)]
struct WsAuthContext {
    auth_token: String,
    ws_ticket: Option<String>,
    client_id: Option<String>,
    client_name: Option<String>,
}

fn resolve_ws_auth_context(headers: &HeaderMap, params: &HashMap<String, String>) -> WsAuthContext {
    let (header_client_id, header_client_name, _) = extract_client_headers(headers);
    let query_token = ws_query_value(params, "auth_token").unwrap_or_default();
    let header_token = extract_auth_token(headers).unwrap_or_default();
    let auth_token = if !header_token.is_empty() {
        header_token
    } else {
        query_token
    };

    let header_ticket = headers
        .get("x-ws-ticket")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string());
    let ws_ticket = header_ticket.or_else(|| ws_query_value(params, "ws_ticket"));

    let client_id = ws_query_value(params, "client_id").or(header_client_id);
    let client_name = ws_query_value(params, "client_name").or(header_client_name);

    WsAuthContext {
        auth_token,
        ws_ticket,
        client_id,
        client_name,
    }
}

fn validate_ws_credentials(
    state: &Arc<Mutex<PairingState>>,
    auth: &WsAuthContext,
    scope: &str,
    session_id: Option<&str>,
) -> Result<(), AuthError> {
    if !auth.auth_token.trim().is_empty() {
        return validate_auth_token(state, &auth.auth_token, auth.client_id.as_deref());
    }
    if let Some(ticket) = auth.ws_ticket.as_deref() {
        return validate_ws_ticket(state, ticket, auth.client_id.as_deref(), scope, session_id);
    }
    Err(AuthError::new(
        "unauthorized",
        "Missing authentication credential.",
    ))
}
