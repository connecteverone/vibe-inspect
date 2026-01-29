use axum::{
    extract::{ws::WebSocketUpgrade, Path, Query, State},
    http::StatusCode,
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
use crate::pairing::{confirm_pairing_with_state, PairingError, PairingState};
use crate::terminal::serve_terminal_socket;
use crate::vnc::{serve_vnc_socket, VncManager};

#[derive(Clone)]
struct LocalServerState {
    pairing: Arc<Mutex<PairingState>>,
    vnc: Arc<Mutex<VncManager>>,
}

pub fn start_local_server(state: Arc<Mutex<PairingState>>) -> Result<u16, std::io::Error> {
    let listener = TcpListener::bind("0.0.0.0:0")?;
    let port = listener.local_addr()?.port();
    listener.set_nonblocking(true)?;
    let vnc_manager = Arc::new(Mutex::new(VncManager::new()));
    let server_state = LocalServerState {
        pairing: state,
        vnc: vnc_manager,
    };

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
            if let Err(error) = axum::serve(listener, app).await {
                eprintln!("local server error: {error}");
            }
        });
    });

    Ok(port)
}

async fn handle_command(
    State(state): State<LocalServerState>,
    body: axum::body::Bytes,
) -> impl IntoResponse {
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
            return (StatusCode::BAD_REQUEST, Json(response));
        }
    };

    if request.command == "vnc" {
        let response = handle_vnc_command(&request, &state.vnc);
        return (StatusCode::OK, Json(response));
    }

    let response = crate::command::handle_agent_command(request);
    (StatusCode::OK, Json(response))
}

#[derive(Debug, Deserialize)]
struct VncCommandPayload {
    action: String,
    session_id: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    display_index: Option<usize>,
}

fn handle_vnc_command(
    request: &AgentCommandRequest,
    manager: &Arc<Mutex<VncManager>>,
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
        match manager.start_session(
            session_id.clone(),
            payload.width,
            payload.height,
            payload.display_index,
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
                    "width": info.width,
                    "height": info.height,
                    "display_index": info.display_index,
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

#[derive(Debug, Deserialize)]
struct PairingConfirmRequest {
    token: String,
    secret: String,
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

    match confirm_pairing_with_state(
        &state.pairing,
        &confirm_request.token,
        &confirm_request.secret,
        None,
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

async fn handle_vnc_ws(
    State(state): State<LocalServerState>,
    Path(session_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let token = params.get("token").cloned().unwrap_or_default();
    let manager = state.vnc.clone();
    ws.on_upgrade(move |socket| async move {
        serve_vnc_socket(socket, manager, session_id, token).await;
    })
}

async fn handle_terminal_ws(
    Path(session_id): Path<String>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| async move {
        serve_terminal_socket(socket, session_id).await;
    })
}
