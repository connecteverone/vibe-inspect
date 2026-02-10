use crate::terminald_launcher::{resolve_terminald_binary, start_terminald_with_fallback};
use axum::extract::ws::{Message, WebSocket};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use serde_json::{json, Map, Value};
use std::cmp::Ordering;
use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant, UNIX_EPOCH};
use tokio::runtime::Runtime;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

use desktop::terminal_core::{
    read_discovery_file, terminal_discovery_path, TerminalActionRequest, TerminalError,
    TerminalSessionSummary, DEFAULT_TERMINALD_WS_URL, TERMINALD_PROTOCOL_VERSION,
};

const ENV_TERMINALD_CONFIG: &str = "VIBE_CTL_CONFIG";
const ENV_TERMINALD_ENDPOINT: &str = "VIBE_CTL_ENDPOINT";
const ENV_TERMINALD_TOKEN: &str = "VIBE_CTL_TOKEN";
const ENV_TERMINALD_AUTOSTART: &str = "VIBE_TERMINALD_AUTOSTART";
const TERMINALD_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const TERMINALD_AUTOSTART_TIMEOUT: Duration = Duration::from_secs(3);
const TERMINALD_DISCOVERY_POLL: Duration = Duration::from_millis(150);
const TERMINALD_RESTART_VERIFY_TIMEOUT: Duration = Duration::from_secs(5);
const REQUIRED_TERMINALD_CAPABILITIES: &[&str] = &["input_b64"];

type TerminaldSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct ResolvedConfig {
    ws_url: String,
    token: Option<String>,
    config_override: bool,
    discovery_created_at: Option<u64>,
    discovery_protocol_version: Option<String>,
    discovery_daemon_version: Option<String>,
    discovery_pid: Option<u32>,
    discovery_daemon_binary_path: Option<String>,
}

pub fn handle_terminal_command(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    block_on_terminal_future(handle_terminal_command_async(request))
}

#[derive(Debug, Clone)]
pub struct TerminalSessionListSnapshot {
    pub sessions: Vec<TerminalSessionSummary>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub update_available: bool,
    pub update_message: Option<String>,
    pub running_version: Option<String>,
    pub bundled_version: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct TerminaldUpdateStatus {
    available: bool,
    message: Option<String>,
    running_version: Option<String>,
    bundled_version: Option<String>,
}

pub fn list_terminal_sessions_snapshot() -> TerminalSessionListSnapshot {
    let update_status = detect_terminald_update_status();
    match block_on_terminal_future(list_terminal_sessions_async()) {
        Ok(sessions) => TerminalSessionListSnapshot {
            sessions,
            error_code: None,
            error_message: None,
            update_available: update_status.available,
            update_message: update_status.message,
            running_version: update_status.running_version,
            bundled_version: update_status.bundled_version,
        },
        Err(error) => {
            eprintln!("terminald list failed: {} ({})", error.message, error.code);
            TerminalSessionListSnapshot {
                sessions: Vec::new(),
                error_code: Some(error.code.to_string()),
                error_message: Some(error.message),
                update_available: update_status.available,
                update_message: update_status.message,
                running_version: update_status.running_version,
                bundled_version: update_status.bundled_version,
            }
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
        .send(TungsteniteMessage::Text(attach_request.to_string().into()))
        .await
        .is_err()
    {
        let _ = client_sender.send(Message::Close(None)).await;
        return;
    }

    if let Err(error) = wait_for_attach(
        &mut terminald_receiver,
        &mut terminald_sender,
        &mut client_sender,
        &attach_id,
        &session_id,
    )
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
                            let _ = terminald_sender
                                .send(TungsteniteMessage::Text(request.to_string().into()))
                                .await;
                        }
                    }
                    Ok(Message::Binary(bytes)) => {
                        if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                            if let Some(request) = build_terminald_request_from_client(&text, &session_id) {
                                let _ = terminald_sender
                                    .send(TungsteniteMessage::Text(request.to_string().into()))
                                    .await;
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
                        if let Some(payload) = extract_terminal_client_message(&text, &session_id) {
                            let _ = client_sender.send(Message::Text(payload.to_string().into())).await;
                        }
                    }
                    Ok(TungsteniteMessage::Binary(bytes)) => {
                        if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                            if let Some(payload) = extract_terminal_client_message(&text, &session_id) {
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
                .or_else(|| {
                    start_payload
                        .get("session_id")
                        .and_then(|value| value.as_str())
                })
                .map(|value| value.to_string());
            if let Some(session_id) = resolved_session_id {
                if let Ok(Some(input_payload)) =
                    build_input_payload_from_parts(&input, &input_bytes)
                {
                    let _ = terminald_request("input", Some(session_id), Some(input_payload), true)
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
        "restart_daemon" | "restart_terminald" => {
            try_start_terminald().await?;
            verify_terminald_restart_applied().await?;
            Ok(json!({
                "type": "terminal",
                "action": "restart_daemon",
                "status": "restarted"
            }))
        }
        "stop" | "kill" | "keepalive" | "delete" => {
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
    let sessions = data
        .get("sessions")
        .cloned()
        .unwrap_or(Value::Array(Vec::new()));
    serde_json::from_value::<Vec<TerminalSessionSummary>>(sessions).map_err(|error| TerminalError {
        code: "connection_failed",
        message: format!("Failed to parse terminal sessions: {error}"),
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
        Ok(None)
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
        .send(TungsteniteMessage::Text(request.to_string().into()))
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
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
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
                    && should_attempt_autostart_after_error(&error)
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

async fn connect_and_auth(ws_url: &str, token: &str) -> Result<TerminaldSocket, TerminalError> {
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
        .send(TungsteniteMessage::Text(auth_request.to_string().into()))
        .await
        .map_err(|error| connection_failed(format!("Failed to send auth request: {error}")))?;

    while let Some(message) = socket.next().await {
        match message {
            Ok(TungsteniteMessage::Text(text)) => {
                if let Some(result) = parse_terminald_response(&text, &auth_id) {
                    return result.and_then(|data| {
                        ensure_terminald_compatibility(&data)?;
                        Ok(socket)
                    });
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    if let Some(result) = parse_terminald_response(&text, &auth_id) {
                        return result.and_then(|data| {
                            ensure_terminald_compatibility(&data)?;
                            Ok(socket)
                        });
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
                if let Some(payload) = extract_terminal_client_message(&text, session_id) {
                    let _ = client_sender
                        .send(Message::Text(payload.to_string().into()))
                        .await;
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    if let Some(result) = parse_terminald_response(&text, attach_id) {
                        return result.map(|_| ());
                    }
                    if let Some(payload) = extract_terminal_client_message(&text, session_id) {
                        let _ = client_sender
                            .send(Message::Text(payload.to_string().into()))
                            .await;
                    }
                }
            }
            Ok(TungsteniteMessage::Ping(payload)) => {
                let _ = terminald_sender
                    .send(TungsteniteMessage::Pong(payload))
                    .await;
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

fn extract_terminal_client_message(text: &str, session_id: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    let message_type = parsed
        .get("type")
        .and_then(|value| value.as_str())
        .unwrap_or("");

    match message_type {
        "event" => {
            let event = parsed
                .get("event")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            match event {
                "terminal_payload" => {
                    if !event_session_matches(&parsed, session_id) {
                        return None;
                    }
                    parsed.get("data").cloned()
                }
                "session_warning" => {
                    if !event_session_matches(&parsed, session_id) {
                        return None;
                    }
                    let data = parsed.get("data").cloned().unwrap_or(Value::Null);
                    let reason = data
                        .get("reason")
                        .and_then(|value| value.as_str())
                        .unwrap_or("warning");
                    let message = data
                        .get("message")
                        .and_then(|value| value.as_str())
                        .unwrap_or("Terminal warning.");
                    let ts = data.get("ts").and_then(|value| value.as_u64());
                    Some(json!({
                        "type": "terminal",
                        "action": "session_warning",
                        "session_id": session_id,
                        "reason": reason,
                        "message": message,
                        "ts": ts,
                    }))
                }
                "stream_paused" => {
                    let data = parsed.get("data").cloned().unwrap_or(Value::Null);
                    let reason = data
                        .get("reason")
                        .and_then(|value| value.as_str())
                        .unwrap_or("backpressure");
                    let retry_after_ms = data
                        .get("retry_after_ms")
                        .and_then(|value| value.as_u64())
                        .unwrap_or(1000);
                    Some(json!({
                        "type": "terminal",
                        "action": "stream_paused",
                        "session_id": session_id,
                        "reason": reason,
                        "retry_after_ms": retry_after_ms,
                    }))
                }
                "stream_resumed" => Some(json!({
                    "type": "terminal",
                    "action": "stream_resumed",
                    "session_id": session_id,
                })),
                _ => None,
            }
        }
        "res" => {
            let ok = parsed
                .get("ok")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);
            if ok {
                return None;
            }
            let error = parsed.get("error").cloned().unwrap_or(Value::Null);
            let code = error
                .get("code")
                .and_then(|value| value.as_str())
                .unwrap_or("terminal_error");
            let message = error
                .get("message")
                .and_then(|value| value.as_str())
                .unwrap_or("Terminal daemon error.");
            let request_id = parsed
                .get("id")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            Some(json!({
                "type": "terminal",
                "action": "request_error",
                "session_id": session_id,
                "request_id": request_id,
                "error": {
                    "code": code,
                    "message": message,
                }
            }))
        }
        _ => None,
    }
}

fn event_session_matches(parsed: &Value, session_id: &str) -> bool {
    match parsed.get("session_id").and_then(|value| value.as_str()) {
        Some(event_session) => event_session == session_id,
        None => true,
    }
}

fn parse_terminald_response(text: &str, request_id: &str) -> Option<Result<Value, TerminalError>> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    if parsed.get("type")?.as_str()? != "res" {
        return None;
    }
    if parsed.get("id")?.as_str()? != request_id {
        return None;
    }
    let ok = parsed
        .get("ok")
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
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

fn ensure_terminald_compatibility(auth_data: &Value) -> Result<(), TerminalError> {
    let capabilities = auth_data
        .get("server_info")
        .and_then(|value| value.get("capabilities"))
        .and_then(|value| value.as_array())
        .ok_or_else(|| TerminalError {
            code: "version_mismatch",
            message: "Terminal daemon compatibility metadata missing. Restart desktop agent to refresh terminal daemon."
                .to_string(),
        })?;

    for required in REQUIRED_TERMINALD_CAPABILITIES {
        let supported = capabilities
            .iter()
            .filter_map(Value::as_str)
            .any(|capability| capability == *required);
        if !supported {
            return Err(TerminalError {
                code: "version_mismatch",
                message: format!(
                    "Terminal daemon missing capability '{required}'. Restart desktop agent to reload the latest terminal daemon."
                ),
            });
        }
    }

    Ok(())
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
        discovery_created_at: discovery.as_ref().map(|file| file.created_at),
        discovery_protocol_version: discovery.as_ref().map(|file| file.version.clone()),
        discovery_daemon_version: discovery
            .as_ref()
            .and_then(|file| file.daemon_version.clone()),
        discovery_pid: discovery.as_ref().map(|file| file.pid),
        discovery_daemon_binary_path: discovery
            .as_ref()
            .and_then(|file| file.daemon_binary_path.clone()),
    })
}

fn detect_terminald_update_status() -> TerminaldUpdateStatus {
    let Ok(config) = resolve_terminald_config() else {
        return TerminaldUpdateStatus::default();
    };

    let bundled_version = bundled_terminald_version();
    let running_daemon_version = non_empty_trimmed(config.discovery_daemon_version.as_deref())
        .map(|value| value.to_string());
    let running_version = running_daemon_version.clone().or_else(|| {
        non_empty_trimmed(config.discovery_protocol_version.as_deref())
            .map(|value| value.to_string())
    });
    let bundled_modified_at = local_terminald_binary_modified_at_secs();
    let agent_modified_at = local_agent_binary_modified_at_secs();
    let bundled_binary_path = local_terminald_binary_path();
    let running_binary_path = resolved_running_terminald_binary_path(&config);
    let runtime_metadata_missing = terminald_runtime_metadata_missing(
        running_daemon_version.as_deref(),
        config.discovery_daemon_binary_path.as_deref(),
    );
    let binary_path_mismatch = is_terminald_binary_path_mismatch(
        bundled_binary_path.as_deref(),
        running_binary_path.as_deref(),
    );
    let agent_newer_than_discovery =
        is_binary_newer_than_discovery(agent_modified_at, config.discovery_created_at);

    let available = runtime_metadata_missing
        || binary_path_mismatch
        || agent_newer_than_discovery
        || should_prompt_terminald_upgrade(
            bundled_version.as_deref(),
            running_daemon_version.as_deref(),
            bundled_modified_at,
            config.discovery_created_at,
        );
    let message = if available {
        Some(build_terminald_update_message(
            bundled_version.as_deref(),
            running_version.as_deref(),
            bundled_modified_at,
            config.discovery_created_at,
            agent_newer_than_discovery,
            runtime_metadata_missing,
            binary_path_mismatch,
            bundled_binary_path.as_deref(),
            running_binary_path.as_deref(),
        ))
    } else {
        None
    };

    TerminaldUpdateStatus {
        available,
        message,
        running_version,
        bundled_version,
    }
}

fn non_empty_trimmed(value: Option<&str>) -> Option<&str> {
    let trimmed = value?.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed)
}

fn terminald_runtime_metadata_missing(
    daemon_version: Option<&str>,
    daemon_binary_path: Option<&str>,
) -> bool {
    non_empty_trimmed(daemon_version).is_none() || non_empty_trimmed(daemon_binary_path).is_none()
}

fn should_prompt_terminald_upgrade(
    bundled_version: Option<&str>,
    running_version: Option<&str>,
    bundled_modified_at: Option<u64>,
    discovery_created_at: Option<u64>,
) -> bool {
    matches!(
        compare_version_strings(bundled_version, running_version),
        Some(Ordering::Greater)
    ) || is_binary_newer_than_discovery(bundled_modified_at, discovery_created_at)
}

fn build_terminald_update_message(
    bundled_version: Option<&str>,
    running_version: Option<&str>,
    bundled_modified_at: Option<u64>,
    discovery_created_at: Option<u64>,
    agent_newer_than_discovery: bool,
    runtime_metadata_missing: bool,
    binary_path_mismatch: bool,
    bundled_binary_path: Option<&Path>,
    running_binary_path: Option<&Path>,
) -> String {
    if runtime_metadata_missing {
        if let Some(running) = non_empty_trimmed(running_version) {
            return format!(
                "Terminal service metadata is outdated ({running}). Restart terminal service to load the latest terminald binary."
            );
        }
        return "Terminal service metadata is outdated. Restart terminal service to load the latest terminald binary."
            .to_string();
    }

    if binary_path_mismatch {
        if let (Some(running), Some(bundled)) = (running_binary_path, bundled_binary_path) {
            return format!(
                "Terminal service is running from {}. Bundled terminald is {}. Restart terminal service to switch to the bundled binary.",
                running.display(),
                bundled.display()
            );
        }
        return "Terminal service is running from a different binary. Restart terminal service to switch to the bundled binary.".to_string();
    }

    if matches!(
        compare_version_strings(bundled_version, running_version),
        Some(Ordering::Greater)
    ) {
        if let (Some(bundled), Some(running)) = (bundled_version, running_version) {
            return format!(
                "A newer terminald is bundled with PC agent ({bundled} > {running}). Restart terminal service to upgrade."
            );
        }
        return "A newer terminald is bundled with PC agent. Restart terminal service to upgrade."
            .to_string();
    }

    if is_binary_newer_than_discovery(bundled_modified_at, discovery_created_at) {
        return "A newer terminald build is bundled with PC agent. Restart terminal service to upgrade."
            .to_string();
    }

    if agent_newer_than_discovery {
        return "PC agent was updated after terminal service started. Restart terminal service to apply the latest integration.".to_string();
    }

    "Terminal service update available. Restart terminal service to continue.".to_string()
}

fn bundled_terminald_version() -> Option<String> {
    static VERSION: OnceLock<Option<String>> = OnceLock::new();
    VERSION.get_or_init(read_bundled_terminald_version).clone()
}

fn read_bundled_terminald_version() -> Option<String> {
    let binary = resolve_terminald_binary()?;
    let output = Command::new(binary)
        .arg("--version")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout)
        .lines()
        .next()
        .unwrap_or("")
        .trim()
        .to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn compare_version_strings(left: Option<&str>, right: Option<&str>) -> Option<Ordering> {
    let left_parts = version_parts(left?);
    let right_parts = version_parts(right?);
    if left_parts.is_empty() || right_parts.is_empty() {
        return None;
    }

    let max_len = left_parts.len().max(right_parts.len());
    for index in 0..max_len {
        let left_value = left_parts.get(index).copied().unwrap_or(0);
        let right_value = right_parts.get(index).copied().unwrap_or(0);
        match left_value.cmp(&right_value) {
            Ordering::Equal => continue,
            ordering => return Some(ordering),
        }
    }

    Some(Ordering::Equal)
}

fn version_parts(value: &str) -> Vec<u64> {
    value
        .split(|ch: char| !ch.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse::<u64>().ok())
        .collect()
}

fn local_terminald_binary_modified_at_secs() -> Option<u64> {
    let binary = resolve_terminald_binary()?;
    let metadata = std::fs::metadata(binary).ok()?;
    let modified = metadata.modified().ok()?;
    modified
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}

fn local_agent_binary_modified_at_secs() -> Option<u64> {
    let binary = env::current_exe().ok()?;
    let metadata = std::fs::metadata(binary).ok()?;
    let modified = metadata.modified().ok()?;
    modified
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}

fn local_terminald_binary_path() -> Option<PathBuf> {
    resolve_terminald_binary().map(canonical_or_original_path)
}

fn resolved_running_terminald_binary_path(config: &ResolvedConfig) -> Option<PathBuf> {
    if let Some(path) = non_empty_trimmed(config.discovery_daemon_binary_path.as_deref()) {
        return Some(canonical_or_original_path(PathBuf::from(path)));
    }

    let pid = config.discovery_pid?;
    running_terminald_binary_path_from_pid(pid)
}

fn running_terminald_binary_path_from_pid(pid: u32) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
        return Some(canonical_or_original_path(path));
    }

    #[cfg(all(unix, not(target_os = "linux")))]
    {
        let pid_text = pid.to_string();
        let output = Command::new("ps")
            .args(["-p", pid_text.as_str(), "-o", "command="])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let command_line = String::from_utf8_lossy(&output.stdout);
        let executable = parse_command_executable(command_line.lines().next().unwrap_or(""))?;
        return Some(canonical_or_original_path(PathBuf::from(executable)));
    }

    #[cfg(windows)]
    {
        let script =
            format!("(Get-CimInstance Win32_Process -Filter \"ProcessId = {pid}\").ExecutablePath");
        let output = Command::new("powershell")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                script.as_str(),
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if path.is_empty() {
            return None;
        }
        return Some(canonical_or_original_path(PathBuf::from(path)));
    }

    #[allow(unreachable_code)]
    None
}

fn parse_command_executable(command_line: &str) -> Option<String> {
    let trimmed = command_line.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Some(value) = trimmed.strip_prefix('"') {
        let end = value.find('"')?;
        return Some(value[..end].to_string());
    }
    if let Some(value) = trimmed.strip_prefix('\'') {
        let end = value.find('\'')?;
        return Some(value[..end].to_string());
    }

    trimmed
        .split_whitespace()
        .next()
        .map(|value| value.to_string())
}

fn canonical_or_original_path(path: PathBuf) -> PathBuf {
    std::fs::canonicalize(&path).unwrap_or(path)
}

fn is_terminald_binary_path_mismatch(
    bundled_binary_path: Option<&Path>,
    running_binary_path: Option<&Path>,
) -> bool {
    let (Some(bundled), Some(running)) = (bundled_binary_path, running_binary_path) else {
        return false;
    };

    if cfg!(windows) {
        bundled.to_string_lossy().to_ascii_lowercase()
            != running.to_string_lossy().to_ascii_lowercase()
    } else {
        bundled != running
    }
}

fn is_binary_newer_than_discovery(
    binary_modified_at: Option<u64>,
    discovery_created_at: Option<u64>,
) -> bool {
    let Some(binary_modified_at) = binary_modified_at else {
        return false;
    };
    let Some(discovery_created_at) = discovery_created_at else {
        return false;
    };
    binary_modified_at > discovery_created_at
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

async fn verify_terminald_restart_applied() -> Result<(), TerminalError> {
    let verification = tokio::task::spawn_blocking(|| {
        let start = Instant::now();
        while start.elapsed() < TERMINALD_RESTART_VERIFY_TIMEOUT {
            let status = detect_terminald_update_status();
            if !status.available {
                return Ok(());
            }
            thread::sleep(TERMINALD_DISCOVERY_POLL);
        }

        Err("Terminal service restart was attempted, but update is still pending. Please retry and ensure old terminald process is fully stopped.".to_string())
    })
    .await
    .map_err(|error| connection_failed(format!(
        "Terminal daemon restart verification failed: {error}"
    )))?;

    verification.map_err(connection_failed)
}

async fn try_start_terminald() -> Result<(), TerminalError> {
    tokio::task::spawn_blocking(start_terminald_with_fallback)
        .await
        .map_err(|error| connection_failed(format!("Terminal daemon start failed: {error}")))?
        .map(|_| ())
        .map_err(connection_failed)
}

fn terminal_runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().expect("terminald runtime"))
}

fn block_on_terminal_future<F>(future: F) -> F::Output
where
    F: std::future::Future,
{
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => tokio::task::block_in_place(|| handle.block_on(future)),
        Err(_) => terminal_runtime().block_on(future),
    }
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

fn should_attempt_autostart_after_error(error: &TerminalError) -> bool {
    !matches!(error.code, "version_mismatch")
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
        "auth_required" => "auth_required",
        "version_mismatch" => "version_mismatch",
        "connection_failed" => "connection_failed",
        _ => "terminal_error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_terminal_payload_event() {
        let text = json!({
            "type": "event",
            "event": "terminal_payload",
            "session_id": "s1",
            "data": {
                "type": "terminal",
                "action": "stream",
                "status": "running",
                "next_seq": 2
            }
        })
        .to_string();

        let payload = extract_terminal_client_message(&text, "s1").expect("payload");
        assert_eq!(payload["action"], "stream");
        assert_eq!(payload["status"], "running");
    }

    #[test]
    fn filters_payload_for_other_session() {
        let text = json!({
            "type": "event",
            "event": "terminal_payload",
            "session_id": "s2",
            "data": {
                "type": "terminal",
                "action": "stream"
            }
        })
        .to_string();

        assert!(extract_terminal_client_message(&text, "s1").is_none());
    }

    #[test]
    fn forwards_session_warning_as_terminal_control() {
        let text = json!({
            "type": "event",
            "event": "session_warning",
            "session_id": "s1",
            "data": {
                "reason": "buffer_truncated",
                "message": "Output buffer truncated; screen snapshot sent.",
                "ts": 1700
            }
        })
        .to_string();

        let payload = extract_terminal_client_message(&text, "s1").expect("warning payload");
        assert_eq!(payload["type"], "terminal");
        assert_eq!(payload["action"], "session_warning");
        assert_eq!(payload["reason"], "buffer_truncated");
    }

    #[test]
    fn forwards_stream_pause_control_event() {
        let text = json!({
            "type": "event",
            "event": "stream_paused",
            "data": {
                "reason": "backpressure",
                "retry_after_ms": 1000
            }
        })
        .to_string();

        let payload = extract_terminal_client_message(&text, "s1").expect("stream paused");
        assert_eq!(payload["type"], "terminal");
        assert_eq!(payload["action"], "stream_paused");
        assert_eq!(payload["retry_after_ms"], 1000);
    }

    #[test]
    fn forwards_request_error_response() {
        let text = json!({
            "type": "res",
            "id": "req-1",
            "ok": false,
            "error": {
                "code": "invalid_request",
                "message": "Missing action."
            }
        })
        .to_string();

        let payload = extract_terminal_client_message(&text, "s1").expect("request error");
        assert_eq!(payload["type"], "terminal");
        assert_eq!(payload["action"], "request_error");
        assert_eq!(payload["request_id"], "req-1");
        assert_eq!(payload["error"]["code"], "invalid_request");
    }

    #[test]
    fn ensure_terminald_compatibility_accepts_required_capabilities() {
        let auth_data = json!({
            "server_info": {
                "capabilities": ["attach", "poll", "input_b64"]
            }
        });

        let result = ensure_terminald_compatibility(&auth_data);

        assert!(result.is_ok());
    }

    #[test]
    fn ensure_terminald_compatibility_rejects_missing_capabilities() {
        let auth_data = json!({
            "server_info": {
                "capabilities": ["attach", "poll"]
            }
        });

        let error = ensure_terminald_compatibility(&auth_data).expect_err("missing capability");

        assert_eq!(error.code, "version_mismatch");
        assert!(error.message.contains("input_b64"));
    }

    #[test]
    fn should_not_autostart_on_version_mismatch() {
        let error = TerminalError {
            code: "version_mismatch",
            message: "restart required".to_string(),
        };

        assert!(!should_attempt_autostart_after_error(&error));
    }

    #[test]
    fn should_autostart_on_connection_failure() {
        let error = TerminalError {
            code: "connection_failed",
            message: "failed".to_string(),
        };

        assert!(should_attempt_autostart_after_error(&error));
    }

    #[test]
    fn binary_newer_than_discovery_when_timestamp_increases() {
        assert!(is_binary_newer_than_discovery(Some(20), Some(10)));
    }

    #[test]
    fn binary_not_newer_than_discovery_when_timestamp_missing_or_older() {
        assert!(!is_binary_newer_than_discovery(None, Some(10)));
        assert!(!is_binary_newer_than_discovery(Some(10), None));
        assert!(!is_binary_newer_than_discovery(Some(10), Some(10)));
        assert!(!is_binary_newer_than_discovery(Some(9), Some(10)));
    }

    #[test]
    fn compare_version_strings_orders_semantic_values() {
        assert_eq!(
            compare_version_strings(Some("terminald 1.2.3"), Some("1.2.2")),
            Some(Ordering::Greater)
        );
        assert_eq!(
            compare_version_strings(Some("1.0.0"), Some("1.0")),
            Some(Ordering::Equal)
        );
        assert_eq!(
            compare_version_strings(Some("0.9.9"), Some("1.0.0")),
            Some(Ordering::Less)
        );
    }

    #[test]
    fn should_prompt_terminal_upgrade_when_bundled_version_is_newer() {
        assert!(should_prompt_terminald_upgrade(
            Some("terminald 1.3.0"),
            Some("1.2.9"),
            Some(10),
            Some(20)
        ));
    }

    #[test]
    fn should_prompt_terminal_upgrade_when_bundled_build_is_newer() {
        assert!(should_prompt_terminald_upgrade(
            Some("terminald 1.0.0"),
            Some("1.0.0"),
            Some(20),
            Some(10)
        ));
    }

    #[test]
    fn parse_command_executable_handles_common_command_lines() {
        assert_eq!(
            parse_command_executable(
                "\"/Applications/Vibe Inspect Agent.app/Contents/MacOS/terminald\" --serve"
            ),
            Some("/Applications/Vibe Inspect Agent.app/Contents/MacOS/terminald".to_string())
        );
        assert_eq!(
            parse_command_executable("/usr/local/bin/terminald --serve"),
            Some("/usr/local/bin/terminald".to_string())
        );
        assert_eq!(parse_command_executable("   "), None);
    }

    #[test]
    fn terminald_binary_path_mismatch_detector_behaves_as_expected() {
        assert!(is_terminald_binary_path_mismatch(
            Some(Path::new("/tmp/vibe/new/terminald")),
            Some(Path::new("/tmp/vibe/old/terminald")),
        ));
        assert!(!is_terminald_binary_path_mismatch(
            Some(Path::new("/tmp/vibe/new/terminald")),
            Some(Path::new("/tmp/vibe/new/terminald")),
        ));
    }

    #[test]
    fn runtime_metadata_missing_detector_behaves_as_expected() {
        assert!(terminald_runtime_metadata_missing(Some("0.1.0"), None));
        assert!(terminald_runtime_metadata_missing(
            None,
            Some("/tmp/terminald")
        ));
        assert!(terminald_runtime_metadata_missing(
            Some(""),
            Some("/tmp/terminald")
        ));
        assert!(!terminald_runtime_metadata_missing(
            Some("0.1.0"),
            Some("/tmp/terminald"),
        ));
    }

    #[test]
    fn path_mismatch_message_mentions_running_and_bundled_paths() {
        let message = build_terminald_update_message(
            Some("1.0.0"),
            Some("1.0.0"),
            Some(0),
            Some(0),
            false,
            false,
            true,
            Some(Path::new("/bundle/terminald")),
            Some(Path::new("/running/terminald")),
        );
        assert!(message.contains("/running/terminald"));
        assert!(message.contains("/bundle/terminald"));
    }

    #[test]
    fn runtime_metadata_missing_message_is_clear() {
        let message = build_terminald_update_message(
            Some("1.0.0"),
            Some("1.0.0"),
            Some(0),
            Some(0),
            false,
            true,
            false,
            None,
            None,
        );
        assert!(message.to_lowercase().contains("metadata"));
        assert!(message.to_lowercase().contains("restart"));
    }

    #[test]
    fn agent_newer_message_is_clear() {
        let message = build_terminald_update_message(
            Some("1.0.0"),
            Some("1.0.0"),
            Some(0),
            Some(0),
            true,
            false,
            false,
            None,
            None,
        );
        assert!(message.to_lowercase().contains("pc agent"));
        assert!(message.to_lowercase().contains("restart"));
    }

    #[test]
    fn block_on_terminal_future_inside_runtime_does_not_panic() {
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let value = block_on_terminal_future(async { 7usize });
            assert_eq!(value, 7);
        });
    }
}
