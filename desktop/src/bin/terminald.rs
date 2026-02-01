use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        ConnectInfo, State,
    },
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Router,
};
use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};

use desktop::terminal_core::{
    write_discovery_file, TerminalDiscoveryFile, DEFAULT_TERMINALD_BIND,
    DEFAULT_TERMINALD_WS_PATH, TERMINALD_PROTOCOL_VERSION,
};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::timeout;

#[derive(Debug, Parser)]
#[command(name = "terminald", about = "Terminal daemon for Vibe", version)]
struct TerminaldArgs {
    /// Address to bind the WebSocket server.
    #[arg(long, default_value = DEFAULT_TERMINALD_BIND)]
    bind: String,
    /// WebSocket path for the daemon.
    #[arg(long, default_value = DEFAULT_TERMINALD_WS_PATH)]
    ws_path: String,
}

#[derive(Clone)]
struct TerminaldState {
    token: String,
    version: String,
    capabilities: Vec<String>,
}

#[tokio::main]
async fn main() {
    let args = TerminaldArgs::parse();
    let ws_path = normalize_ws_path(&args.ws_path);
    let bind = args.bind.trim().to_string();
    let ws_url = format!("ws://{bind}{ws_path}");
    let token = random_token(32);
    let capabilities: Vec<String> = Vec::new();
    let discovery = TerminalDiscoveryFile {
        ws_url,
        token: token.clone(),
        version: TERMINALD_PROTOCOL_VERSION.to_string(),
        pid: std::process::id(),
        created_at: now_ts(),
        capabilities: capabilities.clone(),
    };
    if let Err(error) = write_discovery_file(&discovery) {
        eprintln!("Failed to write discovery file: {error}");
        std::process::exit(1);
    }

    let listener = match tokio::net::TcpListener::bind(&bind).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("Failed to bind terminald on {bind}: {error}");
            std::process::exit(1);
        }
    };

    let state = TerminaldState {
        token,
        version: TERMINALD_PROTOCOL_VERSION.to_string(),
        capabilities,
    };

    let app = Router::new()
        .route(ws_path.as_str(), get(handle_ws))
        .with_state(state);

    let server = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>());
    if let Err(error) = server.await {
        eprintln!("terminald server error: {error}");
        std::process::exit(1);
    }
}

fn normalize_ws_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return DEFAULT_TERMINALD_WS_PATH.to_string();
    }
    if trimmed.starts_with('/') {
        trimmed.to_string()
    } else {
        format!("/{trimmed}")
    }
}

fn random_token(len: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(len)
        .map(char::from)
        .collect()
}

fn now_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

async fn handle_ws(
    ws: WebSocketUpgrade,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<TerminaldState>,
) -> impl IntoResponse {
    if !addr.ip().is_loopback() {
        return StatusCode::FORBIDDEN.into_response();
    }
    ws.on_upgrade(move |socket| async move {
        handle_socket(socket, state).await;
    })
}

async fn handle_socket(mut socket: WebSocket, state: TerminaldState) {
    let auth_message = match timeout(Duration::from_secs(3), socket.recv()).await {
        Ok(Some(Ok(message))) => message,
        Ok(Some(Err(_))) | Ok(None) | Err(_) => {
            send_error_and_close(
                &mut socket,
                "",
                "invalid_auth",
                "Auth required within 3 seconds.",
            )
            .await;
            return;
        }
    };

    let text = match auth_message {
        Message::Text(text) => text,
        Message::Close(_) => return,
        Message::Ping(payload) => {
            let _ = socket.send(Message::Pong(payload)).await;
            send_error_and_close(
                &mut socket,
                "",
                "invalid_auth",
                "Auth required within 3 seconds.",
            )
            .await;
            return;
        }
        _ => {
            send_error_and_close(
                &mut socket,
                "",
                "invalid_auth",
                "Auth required within 3 seconds.",
            )
            .await;
            return;
        }
    };

    let parsed: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(_) => {
            send_error_and_close(&mut socket, "", "invalid_auth", "Invalid auth payload.").await;
            return;
        }
    };

    let request_id = parsed.get("id").and_then(|value| value.as_str()).unwrap_or("");
    let message_type = parsed
        .get("type")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let action = parsed
        .get("action")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    if message_type != "req" || action != "auth" {
        send_error_and_close(
            &mut socket,
            request_id,
            "invalid_auth",
            "Auth required.",
        )
        .await;
        return;
    }

    let payload = parsed.get("payload");
    let token = payload
        .and_then(|value| value.get("token"))
        .and_then(|value| value.as_str())
        .unwrap_or("");
    if token.is_empty() || token != state.token {
        send_error_and_close(
            &mut socket,
            request_id,
            "invalid_auth",
            "Invalid auth token.",
        )
        .await;
        return;
    }

    if let Some(client_version) = payload
        .and_then(|value| value.get("version"))
        .and_then(|value| value.as_str())
    {
        let server_major = parse_major_version(&state.version);
        let client_major = parse_major_version(client_version);
        if server_major.is_none()
            || client_major.is_none()
            || server_major != client_major
        {
            let message = format!(
                "Protocol version mismatch. Server {}, client {}.",
                state.version, client_version
            );
            send_error_and_close(
                &mut socket,
                request_id,
                "version_mismatch",
                &message,
            )
            .await;
            return;
        }
    }

    let response = json!({
        "type": "res",
        "id": request_id,
        "ok": true,
        "data": {
            "server_info": {
                "version": state.version,
                "server_time": now_ts(),
                "capabilities": state.capabilities,
            }
        }
    });
    if send_json(&mut socket, response).await.is_err() {
        return;
    }

    run_authenticated_socket(&mut socket).await;
}

async fn run_authenticated_socket(socket: &mut WebSocket) {
    while let Some(message) = socket.recv().await {
        match message {
            Ok(Message::Ping(payload)) => {
                let _ = socket.send(Message::Pong(payload)).await;
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {}
        }
    }
}

async fn send_json(socket: &mut WebSocket, value: Value) -> Result<(), axum::Error> {
    socket.send(Message::Text(value.to_string().into())).await
}

async fn send_error_and_close(
    socket: &mut WebSocket,
    request_id: &str,
    code: &str,
    message: &str,
) {
    let payload = json!({
        "type": "res",
        "id": request_id,
        "ok": false,
        "data": null,
        "error": {
            "code": code,
            "message": message,
        }
    });
    let _ = send_json(socket, payload).await;
    let _ = socket.send(Message::Close(None)).await;
}

fn parse_major_version(version: &str) -> Option<u64> {
    version.split('.').next()?.parse().ok()
}
