use axum::extract::ws::{Message, WebSocket};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use serde_json::{json, Map, Value};
use std::env;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

use crate::terminal_core::{
    read_discovery_file, terminal_discovery_path, TerminalActionRequest, TerminalError,
    TerminalSessionSummary, DEFAULT_TERMINALD_WS_URL, TERMINALD_PROTOCOL_VERSION,
};

const ENV_TERMINALD_CONFIG: &str = "VIBE_CTL_CONFIG";
const ENV_TERMINALD_ENDPOINT: &str = "VIBE_CTL_ENDPOINT";
const ENV_TERMINALD_TOKEN: &str = "VIBE_CTL_TOKEN";
const ENV_TERMINALD_AUTOSTART: &str = "VIBE_TERMINALD_AUTOSTART";
const ENV_TERMINALD_BIN: &str = "VIBE_TERMINALD_BIN";
const TERMINALD_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const TERMINALD_AUTOSTART_TIMEOUT: Duration = Duration::from_secs(3);
const TERMINALD_DISCOVERY_POLL: Duration = Duration::from_millis(150);

type TerminaldSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct ResolvedConfig {
    ws_url: String,
    token: Option<String>,
    config_override: bool,
}

pub fn handle_terminal_command(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    terminal_runtime().block_on(handle_terminal_command_async(request))
}

pub fn list_terminal_sessions() -> Vec<TerminalSessionSummary> {
    match terminal_runtime().block_on(list_terminal_sessions_async()) {
        Ok(sessions) => sessions,
        Err(error) => {
            eprintln!("terminald list failed: {} ({})", error.message, error.code);
            Vec::new()
        }
    }
}

pub async fn serve_terminal_socket(socket: WebSocket, session_id: String) {
    let (mut client_sender, mut client_receiver) = socket.split();
    let terminald = match connect_terminald(true).await {
        Ok(terminald) => terminald,
        Err(error) => {
            eprintln!("terminald connection failed: {}", error.message);
            let _ = client_sender.send(Message::Close(None)).await;
            return;
        }
    };

    let (mut terminald_sender, mut terminald_receiver) = terminald.split();
    let attach_id = random_request_id();
    let attach_request = json!({
        "type": "req",
        "id": attach_id,
        "action": "attach",
        "session_id": session_id,
        "payload": {
            "since": 0,
            "notify_since": 0
        }
    });
    if terminald_sender
        .send(TungsteniteMessage::Text(attach_request.to_string()))
        .await
        .is_err()
    {
        let _ = client_sender.send(Message::Close(None)).await;
        return;
    }

    if let Err(error) =
        wait_for_attach(&mut terminald_receiver, &mut terminald_sender, &mut client_sender, &attach_id, &session_id)
            .await
    {
        eprintln!("terminald attach failed: {}", error.message);
        let _ = client_sender.send(Message::Close(None)).await;
        return;
    }

    loop {
        tokio::select! {
            maybe_client = client_receiver.next() => {
                let Some(message) = maybe_client else { break; };
                match message {
                    Ok(Message::Text(text)) => {
                        if let Some(request) = build_terminald_request_from_client(&text, &session_id) {
                            let _ = terminald_sender.send(TungsteniteMessage::Text(request.to_string())).await;
                        }
                    }
                    Ok(Message::Binary(bytes)) => {
                        if let Ok(text) = String::from_utf8(bytes) {
                            if let Some(request) = build_terminald_request_from_client(&text, &session_id) {
                                let _ = terminald_sender.send(TungsteniteMessage::Text(request.to_string())).await;
                            }
                        }
                    }
                    Ok(Message::Ping(payload)) => {
                        let _ = client_sender.send(Message::Pong(payload)).await;
                    }
                    Ok(Message::Close(_)) => {
                        let _ = terminald_sender.send(TungsteniteMessage::Close(None)).await;
                        break;
                    }
                    _ => {}
                }
            }
            maybe_terminald = terminald_receiver.next() => {
                let Some(message) = maybe_terminald else { break; };
                match message {
                    Ok(TungsteniteMessage::Text(text)) => {
                        if let Some(payload) = extract_terminal_payload(&text, &session_id) {
                            let _ = client_sender.send(Message::Text(payload.to_string().into())).await;
                        }
                    }
                    Ok(TungsteniteMessage::Binary(bytes)) => {
                        if let Ok(text) = String::from_utf8(bytes) {
                            if let Some(payload) = extract_terminal_payload(&text, &session_id) {
                                let _ = client_sender.send(Message::Text(payload.to_string().into())).await;
                            }
                        }
                    }
                    Ok(TungsteniteMessage::Ping(payload)) => {
                        let _ = terminald_sender.send(TungsteniteMessage::Pong(payload)).await;
                    }
                    Ok(TungsteniteMessage::Close(_)) => {
                        let _ = client_sender.send(Message::Close(None)).await;
                        break;
                    }
                    _ => {}
                }
            }
        }
    }
}

async fn handle_terminal_command_async(
    request: TerminalActionRequest,
) -> Result<Value, TerminalError> {
    let action = request.action.to_lowercase();
    match action.as_str() {
        "list" => {
            let data = terminald_request("list", None, None, true).await?;
            let sessions = data
                .get("sessions")
                .cloned()
                .unwrap_or_else(|| Value::Array(Vec::new()));
            Ok(json!({
                "type": "terminal",
                "action": "list",
                "sessions": sessions,
            }))
        }
        "start" => {
            let start_session_id = request.session_id.clone();
            let input = request.input.clone();
            let input_bytes = request.input_bytes.clone();
            let payload = build_start_payload(&request);
            let data = terminald_request("start", start_session_id, payload, true).await?;
            let start_payload = data
                .get("payload")
                .cloned()
                .ok_or_else(|| connection_failed("Missing terminal payload."))?;
            let resolved_session_id = data
                .get("session_id")
                .and_then(|value| value.as_str())
                .or_else(|| start_payload.get("session_id").and_then(|value| value.as_str()))
                .map(|value| value.to_string());
            if let Some(session_id) = resolved_session_id {
                if let Ok(Some(input_payload)) =
                    build_input_payload_from_parts(&input, &input_bytes)
                {
                    let _ = terminald_request(
                        "input",
                        Some(session_id),
                        Some(input_payload),
                        true,
                    )
                    .await;
                }
            }
            Ok(start_payload)
        }
        "poll" => {
            let payload = build_poll_payload(&request);
            terminald_request("poll", request.session_id, payload, true).await
        }
        "status" => {
            let payload = build_status_payload(&request);
            terminald_request("status", request.session_id, payload, true).await
        }
        "input" => {
            let payload = build_input_payload(&request)?;
            terminald_request("input", request.session_id, payload, true).await
        }
        "resize" => {
            let payload = build_resize_payload(&request);
            terminald_request("resize", request.session_id, payload, true).await
        }
        "rename" => {
            let payload = build_rename_payload(&request);
            terminald_request("rename", request.session_id, payload, true).await
        }
        "stop" | "kill" | "keepalive" => {
            terminald_request(action.as_str(), request.session_id, None, true).await
        }
        _ => Err(TerminalError {
            code: "unsupported_action",
            message: format!("Unsupported terminal action: {}", request.action),
        }),
    }
}

async fn list_terminal_sessions_async() -> Result<Vec<TerminalSessionSummary>, TerminalError> {
    let data = terminald_request("list", None, None, false).await?;
    let sessions = data.get("sessions").cloned().unwrap_or(Value::Array(Vec::new()));
    serde_json::from_value::<Vec<TerminalSessionSummary>>(sessions).map_err(|error| {
        TerminalError {
            code: "connection_failed",
            message: format!("Failed to parse terminal sessions: {error}"),
        }
    })
}

fn build_start_payload(request: &TerminalActionRequest) -> Option<Value> {
    let mut payload = Map::new();
    if let Some(label) = request.label.as_ref() {
        payload.insert("label".to_string(), json!(label));
    }
    if let Some(cols) = request.cols {
        payload.insert("cols".to_string(), json!(cols));
    }
    if let Some(rows) = request.rows {
        payload.insert("rows".to_string(), json!(rows));
    }
    if let Some(working_dir) = request.working_dir.as_ref() {
        payload.insert("working_dir".to_string(), json!(working_dir));
    }
    if let Some(env) = request.env.as_ref() {
        payload.insert("env".to_string(), json!(env));
    }
    if payload.is_empty() {
        None
    } else {
        Some(Value::Object(payload))
    }
}

fn build_poll_payload(request: &TerminalActionRequest) -> Option<Value> {
    let mut payload = Map::new();
    if let Some(since) = request.since {
        payload.insert("since".to_string(), json!(since));
    }
    if let Some(limit) = request.limit {
        payload.insert("limit".to_string(), json!(limit));
    }
    if let Some(notify_since) = request.notify_since {
        payload.insert("notify_since".to_string(), json!(notify_since));
    }
    if payload.is_empty() {
        None
    } else {
        Some(Value::Object(payload))
    }
}

fn build_status_payload(request: &TerminalActionRequest) -> Option<Value> {
    let mut payload = Map::new();
    if let Some(notify_since) = request.notify_since {
        payload.insert("notify_since".to_string(), json!(notify_since));
    }
    if payload.is_empty() {
        None
    } else {
        Some(Value::Object(payload))
    }
}

fn build_input_payload(request: &TerminalActionRequest) -> Result<Option<Value>, TerminalError> {
    build_input_payload_from_parts(&request.input, &request.input_bytes)
}

fn build_input_payload_from_parts(
    input: &Option<String>,
    input_bytes: &Option<Vec<u8>>,
) -> Result<Option<Value>, TerminalError> {
    let mut payload = Map::new();
    match (input, input_bytes) {
        (Some(input), None) => {
            payload.insert("data".to_string(), json!(input));
        }
        (None, Some(bytes)) => {
            let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
            payload.insert("data_b64".to_string(), json!(encoded));
        }
        (Some(_), Some(_)) => {
            return Err(TerminalError {
                code: "invalid_request",
                message: "Provide either data or data_b64, not both.".to_string(),
            })
        }
        (None, None) => {}
    }
    if payload.is_empty() {
        None
    } else {
        Ok(Some(Value::Object(payload)))
    }
}

fn build_resize_payload(request: &TerminalActionRequest) -> Option<Value> {
    let mut payload = Map::new();
    if let Some(cols) = request.cols {
        payload.insert("cols".to_string(), json!(cols));
    }
    if let Some(rows) = request.rows {
        payload.insert("rows".to_string(), json!(rows));
    }
    if payload.is_empty() {
        None
    } else {
        Some(Value::Object(payload))
    }
}

fn build_rename_payload(request: &TerminalActionRequest) -> Option<Value> {
    let mut payload = Map::new();
    if let Some(label) = request.label.as_ref() {
        payload.insert("label".to_string(), json!(label));
    }
    if payload.is_empty() {
        None
    } else {
        Some(Value::Object(payload))
    }
}

async fn terminald_request(
    action: &str,
    session_id: Option<String>,
    payload: Option<Value>,
    allow_autostart: bool,
) -> Result<Value, TerminalError> {
    let mut socket = connect_terminald(allow_autostart).await?;
    let request_id = random_request_id();
    let request = build_terminald_request(&request_id, action, session_id, payload);
    socket
        .send(TungsteniteMessage::Text(request.to_string()))
        .await
        .map_err(|error| connection_failed(format!("Failed to send request: {error}")))?;

    while let Some(message) = socket.next().await {
        match message {
            Ok(TungsteniteMessage::Text(text)) => {
                if let Some(result) = parse_terminald_response(&text, &request_id) {
                    return result;
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes) {
                    if let Some(result) = parse_terminald_response(&text, &request_id) {
                        return result;
                    }
                }
            }
            Ok(TungsteniteMessage::Close(_)) => {
                return Err(connection_failed("Terminal daemon closed connection."));
            }
            _ => {}
        }
    }

    Err(connection_failed("Terminal daemon closed connection."))
}

async fn connect_terminald(allow_autostart: bool) -> Result<TerminaldSocket, TerminalError> {
    let mut resolved = resolve_terminald_config()?;
    let mut attempted_start = false;

    loop {
        if resolved.token.is_none() {
            if allow_autostart && !resolved.config_override && autostart_enabled() && !attempted_start
            {
                attempted_start = true;
                try_start_terminald().await?;
                if let Some(updated) = wait_for_terminald_config() {
                    resolved = updated;
                    continue;
                }
            }
            return Err(connection_failed("Terminal daemon token unavailable."));
        }

        let token = resolved.token.clone().unwrap_or_default();
        match connect_and_auth(&resolved.ws_url, &token).await {
            Ok(socket) => return Ok(socket),
            Err(error) => {
                if allow_autostart
                    && !resolved.config_override
                    && autostart_enabled()
                    && !attempted_start
                {
                    attempted_start = true;
                    try_start_terminald().await?;
                    if let Some(updated) = wait_for_terminald_config() {
                        resolved = updated;
                        continue;
                    }
                }
                return Err(error);
            }
        }
    }
}

async fn connect_and_auth(
    ws_url: &str,
    token: &str,
) -> Result<TerminaldSocket, TerminalError> {
    let connect_result =
        tokio::time::timeout(TERMINALD_CONNECT_TIMEOUT, connect_async(ws_url)).await;
    let (mut socket, _) = match connect_result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            return Err(connection_failed(format!(
                "Failed to connect to terminal daemon: {error}"
            )))
        }
        Err(_) => {
            return Err(connection_failed(
                "Timed out connecting to terminal daemon.",
            ))
        }
    };

    let auth_id = random_request_id();
    let auth_request = json!({
        "type": "req",
        "id": auth_id,
        "action": "auth",
        "payload": {
            "token": token,
            "version": TERMINALD_PROTOCOL_VERSION,
        }
    });
    socket
        .send(TungsteniteMessage::Text(auth_request.to_string()))
        .await
        .map_err(|error| connection_failed(format!("Failed to send auth request: {error}")))?;

    while let Some(message) = socket.next().await {
        match message {
            Ok(TungsteniteMessage::Text(text)) => {
                if let Some(result) = parse_terminald_response(&text, &auth_id) {
                    return result.map(|_| socket);
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes) {
                    if let Some(result) = parse_terminald_response(&text, &auth_id) {
                        return result.map(|_| socket);
                    }
                }
            }
            Ok(TungsteniteMessage::Close(_)) => {
                return Err(connection_failed("Terminal daemon closed connection."));
            }
            _ => {}
        }
    }

    Err(connection_failed("Terminal daemon closed connection."))
}

async fn wait_for_attach(
    terminald_receiver: &mut futures_util::stream::SplitStream<TerminaldSocket>,
    terminald_sender: &mut futures_util::stream::SplitSink<TerminaldSocket, TungsteniteMessage>,
    client_sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
    attach_id: &str,
    session_id: &str,
) -> Result<(), TerminalError> {
    while let Some(message) = terminald_receiver.next().await {
        match message {
            Ok(TungsteniteMessage::Text(text)) => {
                if let Some(result) = parse_terminald_response(&text, attach_id) {
                    return result.map(|_| ());
                }
                if let Some(payload) = extract_terminal_payload(&text, session_id) {
                    let _ = client_sender
                        .send(Message::Text(payload.to_string().into()))
                        .await;
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes) {
                    if let Some(result) = parse_terminald_response(&text, attach_id) {
                        return result.map(|_| ());
                    }
                    if let Some(payload) = extract_terminal_payload(&text, session_id) {
                        let _ = client_sender
                            .send(Message::Text(payload.to_string().into()))
                            .await;
                    }
                }
            }
            Ok(TungsteniteMessage::Ping(payload)) => {
                let _ = terminald_sender.send(TungsteniteMessage::Pong(payload)).await;
            }
            Ok(TungsteniteMessage::Close(_)) => {
                return Err(connection_failed("Terminal daemon closed connection."));
            }
            _ => {}
        }
    }
    Err(connection_failed("Terminal daemon closed connection."))
}

fn build_terminald_request(
    request_id: &str,
    action: &str,
    session_id: Option<String>,
    payload: Option<Value>,
) -> Value {
    let mut request = json!({
        "type": "req",
        "id": request_id,
        "action": action,
    });
    if let Some(map) = request.as_object_mut() {
        if let Some(session_id) = session_id {
            map.insert("session_id".to_string(), json!(session_id));
        }
        if let Some(payload) = payload {
            map.insert("payload".to_string(), payload);
        }
    }
    request
}

fn build_terminald_request_from_client(text: &str, session_id: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    let action = parsed.get("action")?.as_str()?.trim().to_lowercase();
    let mut payload = Map::new();

    match action.as_str() {
        "input" => {
            let data = parsed.get("data").and_then(|value| value.as_str());
            let data_b64 = parsed.get("data_b64").and_then(|value| value.as_str());
            if data.is_some() && data_b64.is_some() {
                return None;
            }
            if let Some(data) = data {
                payload.insert("data".to_string(), json!(data));
            }
            if let Some(data_b64) = data_b64 {
                payload.insert("data_b64".to_string(), json!(data_b64));
            }
            if payload.is_empty() {
                return None;
            }
        }
        "resize" => {
            let cols = parsed.get("cols").and_then(|value| value.as_u64());
            let rows = parsed.get("rows").and_then(|value| value.as_u64());
            if let (Some(cols), Some(rows)) = (cols, rows) {
                payload.insert("cols".to_string(), json!(cols));
                payload.insert("rows".to_string(), json!(rows));
            } else {
                return None;
            }
        }
        "stop" | "keepalive" => {}
        "status" => {
            return None;
        }
        _ => return None,
    }

    Some(build_terminald_request(
        &random_request_id(),
        action.as_str(),
        Some(session_id.to_string()),
        if payload.is_empty() {
            None
        } else {
            Some(Value::Object(payload))
        },
    ))
}

fn extract_terminal_payload(text: &str, session_id: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    if parsed.get("type")?.as_str()? != "event" {
        return None;
    }
    if parsed.get("event")?.as_str()? != "terminal_payload" {
        return None;
    }
    if let Some(event_session) = parsed.get("session_id").and_then(|value| value.as_str()) {
        if event_session != session_id {
            return None;
        }
    }
    parsed.get("data").cloned()
}

fn parse_terminald_response(
    text: &str,
    request_id: &str,
) -> Option<Result<Value, TerminalError>> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    if parsed.get("type")?.as_str()? != "res" {
        return None;
    }
    if parsed.get("id")?.as_str()? != request_id {
        return None;
    }
    let ok = parsed.get("ok").and_then(|value| value.as_bool()).unwrap_or(false);
    if ok {
        return Some(Ok(parsed.get("data").cloned().unwrap_or(Value::Null)));
    }
    let error = parsed.get("error");
    let code = error
        .and_then(|value| value.get("code"))
        .and_then(|value| value.as_str())
        .unwrap_or("connection_failed");
    let message = error
        .and_then(|value| value.get("message"))
        .and_then(|value| value.as_str())
        .unwrap_or("Terminal daemon error.")
        .to_string();
    Some(Err(TerminalError {
        code: map_error_code(code),
        message,
    }))
}

fn resolve_terminald_config() -> Result<ResolvedConfig, TerminalError> {
    let config_override = read_env_value(ENV_TERMINALD_CONFIG).map(PathBuf::from);
    let config_path = config_override.clone().or_else(terminal_discovery_path);
    let discovery = match config_path {
        Some(path) => match read_discovery_file(&path) {
            Ok(file) => Some(file),
            Err(error) => {
                if config_override.is_some() {
                    return Err(connection_failed(format!(
                        "Failed to read terminal config {}: {error}",
                        path.display()
                    )));
                }
                None
            }
        },
        None => None,
    };

    let ws_url = read_env_value(ENV_TERMINALD_ENDPOINT)
        .or_else(|| discovery.as_ref().map(|file| file.ws_url.clone()))
        .unwrap_or_else(|| DEFAULT_TERMINALD_WS_URL.to_string());
    let token = read_env_value(ENV_TERMINALD_TOKEN)
        .or_else(|| discovery.as_ref().map(|file| file.token.clone()));
    Ok(ResolvedConfig {
        ws_url,
        token,
        config_override: config_override.is_some(),
    })
}

fn wait_for_terminald_config() -> Option<ResolvedConfig> {
    let start = Instant::now();
    while start.elapsed() < TERMINALD_AUTOSTART_TIMEOUT {
        if let Ok(config) = resolve_terminald_config() {
            if config.token.is_some() {
                return Some(config);
            }
        }
        thread::sleep(TERMINALD_DISCOVERY_POLL);
    }
    None
}

async fn try_start_terminald() -> Result<(), TerminalError> {
    tokio::task::spawn_blocking(|| start_terminald_process())
        .await
        .unwrap_or_else(|error| Err(connection_failed(format!("Terminal daemon start failed: {error}"))))
}

fn start_terminald_process() -> Result<(), TerminalError> {
    let binary = resolve_terminald_binary();
    let mut command = match binary {
        Some(path) => Command::new(path),
        None => Command::new("terminald"),
    };
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|error| connection_failed(format!("Failed to start terminal daemon: {error}")))?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

fn resolve_terminald_binary() -> Option<PathBuf> {
    if let Some(path) = read_env_value(ENV_TERMINALD_BIN) {
        return Some(PathBuf::from(path));
    }
    if let Ok(mut exe) = env::current_exe() {
        exe.set_file_name(terminald_executable_name());
        if exe.exists() {
            return Some(exe);
        }
    }
    None
}

fn terminald_executable_name() -> &'static str {
    if cfg!(windows) {
        "terminald.exe"
    } else {
        "terminald"
    }
}

fn terminal_runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().expect("terminald runtime"))
}

fn random_request_id() -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(12)
        .map(char::from)
        .collect()
}

fn read_env_value(key: &str) -> Option<String> {
    match env::var(key) {
        Ok(value) => {
            let trimmed = value.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        }
        Err(_) => None,
    }
}

fn autostart_enabled() -> bool {
    let value = read_env_value(ENV_TERMINALD_AUTOSTART);
    match value.as_deref() {
        None => true,
        Some("0") | Some("false") | Some("no") | Some("off") => false,
        _ => true,
    }
}

fn connection_failed(message: impl Into<String>) -> TerminalError {
    TerminalError {
        code: "connection_failed",
        message: message.into(),
    }
}

fn map_error_code(code: &str) -> &'static str {
    match code {
        "missing_session" => "missing_session",
        "missing_input" => "missing_input",
        "missing_size" => "missing_size",
        "invalid_request" => "invalid_request",
        "invalid_label" => "invalid_label",
        "invalid_size" => "invalid_size",
        "session_not_found" => "session_not_found",
        "session_exists" => "session_exists",
        "session_ended" => "session_ended",
        "write_failed" => "write_failed",
        "resize_failed" => "resize_failed",
        "state_locked" => "state_locked",
        "unsupported_action" => "unsupported_action",
        "pty_error" => "pty_error",
        "spawn_error" => "spawn_error",
        "payload_too_large" => "payload_too_large",
        "invalid_auth" => "invalid_auth",
        "version_mismatch" => "version_mismatch",
        "connection_failed" => "connection_failed",
        _ => "terminal_error",
    }
}
