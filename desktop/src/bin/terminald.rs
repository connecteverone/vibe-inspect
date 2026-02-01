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
use base64::Engine;
use clap::Parser;
use futures_util::{stream::SplitSink, SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};

use desktop::terminal_core::{
    build_terminal_snapshot_payload, handle_terminal_command, idle_cleanup_config,
    list_terminal_sessions, write_discovery_file, IdleCleanupConfig, TerminalActionRequest,
    TerminalDiscoveryFile, TerminalError, DEFAULT_TERMINALD_BIND, DEFAULT_TERMINALD_WS_PATH,
    TERMINALD_PROTOCOL_VERSION,
};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::SocketAddr;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::time::{interval, timeout, MissedTickBehavior};

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

type WsSender = SplitSink<WebSocket, Message>;

const MAX_TERMINAL_PAYLOAD_BYTES: usize = 900 * 1024;
const MAX_SUBSCRIPTIONS_PER_SOCKET: usize = 4;
const MAX_SEND_QUEUE_BYTES: usize = 2 * 1024 * 1024;
const LOW_WATER_MARK_BYTES: usize = 1024 * 1024;
const STREAM_PAUSED_REASON: &str = "backpressure";
const STREAM_PAUSED_RETRY_MS: u64 = 1000;
const BUFFER_TRUNCATED_MESSAGE: &str = "Output buffer truncated; screen snapshot sent.";
const PAYLOAD_TOO_LARGE_MESSAGE: &str =
    "Terminal snapshot too large to send; reduce output volume and retry.";
const IDLE_WARNING_REASON: &str = "idle_expiring";
const IDLE_WARNING_RATE_SECS: u64 = 30;

#[derive(Debug, Clone)]
struct AttachmentState {
    last_seq: u64,
    last_notification_seq: u64,
    last_status: String,
    last_exit_code: Option<i64>,
    last_label: String,
    last_truncated: bool,
    last_idle_warning_ts: u64,
}

#[derive(Debug, Clone)]
struct PayloadSummary {
    next_seq: u64,
    notification_next_seq: u64,
    status: String,
    exit_code: Option<i64>,
    label: String,
    output_len: usize,
    notifications_len: usize,
    truncated: bool,
}

struct StreamEventBatch {
    events: Vec<Value>,
    detached: Vec<String>,
    close: bool,
}

#[derive(Debug)]
struct QueuedMessage {
    text: String,
    bytes: usize,
    is_terminal_payload: bool,
    session_id: Option<String>,
}

#[derive(Debug, Default)]
struct OutboundQueue {
    items: VecDeque<QueuedMessage>,
    bytes: usize,
}

impl OutboundQueue {
    fn push(&mut self, message: QueuedMessage) {
        self.bytes = self.bytes.saturating_add(message.bytes);
        self.items.push_back(message);
    }

    fn pop(&mut self) -> Option<QueuedMessage> {
        let message = self.items.pop_front()?;
        self.bytes = self.bytes.saturating_sub(message.bytes);
        Some(message)
    }

    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    fn remove_terminal_payloads(&mut self, session_id: Option<&str>) -> usize {
        if self.items.is_empty() {
            return 0;
        }
        let mut removed_bytes = 0;
        let mut retained = VecDeque::with_capacity(self.items.len());
        while let Some(message) = self.items.pop_front() {
            let matches_session = session_id
                .map(|id| message.session_id.as_deref() == Some(id))
                .unwrap_or(true);
            if message.is_terminal_payload && matches_session {
                removed_bytes = removed_bytes.saturating_add(message.bytes);
                continue;
            }
            retained.push_back(message);
        }
        self.items = retained;
        self.bytes = self.bytes.saturating_sub(removed_bytes);
        removed_bytes
    }
}

#[derive(Debug, Default)]
struct BackpressureState {
    paused: bool,
    pending_snapshots: HashSet<String>,
}

#[derive(Debug)]
enum EnqueueResult {
    Enqueued,
    Dropped,
    Close,
}

#[tokio::main]
async fn main() {
    let args = TerminaldArgs::parse();
    let ws_path = normalize_ws_path(&args.ws_path);
    let bind = args.bind.trim().to_string();
    let ws_url = format!("ws://{bind}{ws_path}");
    let token = random_token(32);
    let capabilities: Vec<String> = vec![
        "attach".to_string(),
        "poll".to_string(),
        "notifications".to_string(),
    ];
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

    run_authenticated_socket(socket).await;
}

async fn run_authenticated_socket(socket: WebSocket) {
    let (mut sender, mut receiver) = socket.split();
    let mut subscriptions: HashMap<String, AttachmentState> = HashMap::new();
    let mut outbound = OutboundQueue::default();
    let mut backpressure = BackpressureState::default();
    let mut tick = interval(Duration::from_millis(80));
    tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut last_sent_at = Instant::now();
    let mut closing = false;
    let idle_config = idle_cleanup_config();

    loop {
        tokio::select! {
            _ = tick.tick() => {
                if flush_outbound_queue(&mut sender, &mut outbound, &mut last_sent_at)
                    .await
                    .is_err()
                {
                    return;
                }

                if closing {
                    if outbound.is_empty() {
                        let _ = sender.send(Message::Close(None)).await;
                        return;
                    }
                    continue;
                }

                if backpressure.paused && outbound.bytes <= LOW_WATER_MARK_BYTES {
                    if resume_streaming(&mut outbound, &mut backpressure, &mut subscriptions) {
                        closing = true;
                    }
                }

                if !subscriptions.is_empty() {
                    let batch = collect_stream_events(&mut subscriptions, idle_config);
                    for event in batch.events {
                        match enqueue_event(&mut outbound, &mut backpressure, event) {
                            EnqueueResult::Enqueued | EnqueueResult::Dropped => {}
                            EnqueueResult::Close => {
                                closing = true;
                                break;
                            }
                        }
                    }
                    for session_id in batch.detached {
                        subscriptions.remove(&session_id);
                        backpressure.pending_snapshots.remove(&session_id);
                    }
                    if batch.close {
                        closing = true;
                    }
                }

                if outbound.is_empty() && last_sent_at.elapsed() > Duration::from_secs(15) {
                    if sender.send(Message::Ping(Vec::new().into())).await.is_err() {
                        return;
                    }
                    last_sent_at = Instant::now();
                }
            }
            maybe_message = receiver.next() => {
                let Some(message) = maybe_message else {
                    break;
                };
                match message {
                    Ok(Message::Ping(payload)) => {
                        let _ = sender.send(Message::Pong(payload)).await;
                        last_sent_at = Instant::now();
                    }
                    Ok(Message::Text(text)) => {
                        if handle_request(
                            &mut sender,
                            &mut subscriptions,
                            &mut outbound,
                            &mut backpressure,
                            &text,
                            &mut last_sent_at,
                        )
                        .await
                        {
                            continue;
                        }
                        break;
                    }
                    Ok(Message::Close(_)) | Err(_) => break,
                    _ => {}
                }
            }
        }
    }
}

async fn handle_request(
    sender: &mut WsSender,
    subscriptions: &mut HashMap<String, AttachmentState>,
    outbound: &mut OutboundQueue,
    backpressure: &mut BackpressureState,
    text: &str,
    last_sent_at: &mut Instant,
) -> bool {
    let parsed: Value = match serde_json::from_str(text) {
        Ok(value) => value,
        Err(_) => {
            send_error_response(sender, "", "invalid_request", "Invalid JSON payload.").await;
            *last_sent_at = Instant::now();
            return true;
        }
    };

    let request_id = parsed.get("id").and_then(|value| value.as_str()).unwrap_or("");
    if request_id.trim().is_empty() {
        send_error_response(sender, "", "invalid_request", "Missing request id.").await;
        *last_sent_at = Instant::now();
        return true;
    }

    let message_type = parsed
        .get("type")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    if message_type != "req" {
        send_error_response(
            sender,
            request_id,
            "invalid_request",
            "Unsupported message type.",
        )
        .await;
        *last_sent_at = Instant::now();
        return true;
    }

    let action = parsed
        .get("action")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_lowercase();
    if action.is_empty() {
        send_error_response(sender, request_id, "invalid_request", "Missing action.").await;
        *last_sent_at = Instant::now();
        return true;
    }

    let payload = match parsed.get("payload") {
        Some(value) => {
            if let Some(map) = value.as_object() {
                Some(map)
            } else {
                send_error_response(
                    sender,
                    request_id,
                    "invalid_request",
                    "Payload must be an object.",
                )
                .await;
                *last_sent_at = Instant::now();
                return true;
            }
        }
        None => None,
    };

    let session_id = parsed
        .get("session_id")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string());

    match action.as_str() {
        "list" => {
            let sessions = list_terminal_sessions();
            let data = json!({ "sessions": sessions });
            send_ok_response(sender, request_id, data).await;
            *last_sent_at = Instant::now();
        }
        "start" => {
            let request = TerminalActionRequest {
                action: action.clone(),
                session_id,
                label: payload
                    .and_then(|payload| payload.get("label"))
                    .and_then(|value| value.as_str())
                    .map(|value| value.to_string()),
                input: None,
                input_bytes: None,
                cols: payload
                    .and_then(|payload| payload.get("cols"))
                    .and_then(|value| value.as_u64())
                    .and_then(|value| u16::try_from(value).ok()),
                rows: payload
                    .and_then(|payload| payload.get("rows"))
                    .and_then(|value| value.as_u64())
                    .and_then(|value| u16::try_from(value).ok()),
                since: None,
                limit: None,
                notify_since: None,
                working_dir: payload
                    .and_then(|payload| payload.get("working_dir"))
                    .and_then(|value| value.as_str())
                    .map(|value| value.to_string()),
                env: parse_env(payload),
            };
            match handle_terminal_command(request) {
                Ok(payload) => {
                    let session_id = payload
                        .get("session_id")
                        .and_then(|value| value.as_str())
                        .unwrap_or("")
                        .to_string();
                    let data = json!({
                        "session_id": session_id,
                        "payload": payload,
                    });
                    send_ok_response(sender, request_id, data).await;
                }
                Err(error) => send_terminal_error(sender, request_id, error).await,
            }
            *last_sent_at = Instant::now();
        }
        "attach" => {
            let session_id = match ensure_session_id(session_id) {
                Ok(session_id) => session_id,
                Err(error) => {
                    send_terminal_error(sender, request_id, error).await;
                    *last_sent_at = Instant::now();
                    return true;
                }
            };
            if !subscriptions.contains_key(&session_id)
                && subscriptions.len() >= MAX_SUBSCRIPTIONS_PER_SOCKET
            {
                send_error_response(
                    sender,
                    request_id,
                    "state_locked",
                    "Too many active subscriptions.",
                )
                .await;
                *last_sent_at = Instant::now();
                return true;
            }
            let since = payload
                .and_then(|payload| payload.get("since"))
                .and_then(|value| value.as_u64())
                .unwrap_or(0);
            let notify_since = payload
                .and_then(|payload| payload.get("notify_since"))
                .and_then(|value| value.as_u64())
                .unwrap_or(0);
            let request = TerminalActionRequest {
                action: "poll".to_string(),
                session_id: Some(session_id.clone()),
                label: None,
                input: None,
                input_bytes: None,
                cols: None,
                rows: None,
                since: Some(since),
                limit: None,
                notify_since: Some(notify_since),
                working_dir: None,
                env: None,
            };
            match handle_terminal_command(request) {
                Ok(payload) => {
                    if snapshot_too_large(&payload) {
                        let _ = send_session_warning(
                            sender,
                            &session_id,
                            "payload_too_large",
                            PAYLOAD_TOO_LARGE_MESSAGE,
                        )
                        .await;
                        send_error_response(
                            sender,
                            request_id,
                            "payload_too_large",
                            "Snapshot exceeds payload limits.",
                        )
                        .await;
                        let _ = sender.send(Message::Close(None)).await;
                        return false;
                    }
                    let summary = summarize_payload(&payload);
                    let attachment = AttachmentState {
                        last_seq: summary.next_seq.saturating_sub(1),
                        last_notification_seq: summary.notification_next_seq,
                        last_status: summary.status.clone(),
                        last_exit_code: summary.exit_code,
                        last_label: summary.label.clone(),
                        last_truncated: summary.truncated,
                        last_idle_warning_ts: 0,
                    };
                    subscriptions.insert(session_id.clone(), attachment);
                    send_ok_response(sender, request_id, json!({ "attached": true })).await;
                    if summary.truncated {
                        let warning =
                            build_session_warning(&session_id, "buffer_truncated", BUFFER_TRUNCATED_MESSAGE);
                        if enqueue_event(outbound, backpressure, warning) == EnqueueResult::Close {
                            return false;
                        }
                    }
                    let stream_payload = as_stream_payload(payload);
                    let event = build_terminal_payload_event(&session_id, stream_payload);
                    if enqueue_event(outbound, backpressure, event) == EnqueueResult::Close {
                        return false;
                    }
                }
                Err(error) => send_terminal_error(sender, request_id, error).await,
            }
            *last_sent_at = Instant::now();
        }
        "detach" => {
            let session_id = match ensure_session_id(session_id) {
                Ok(session_id) => session_id,
                Err(error) => {
                    send_terminal_error(sender, request_id, error).await;
                    *last_sent_at = Instant::now();
                    return true;
                }
            };
            subscriptions.remove(&session_id);
            backpressure.pending_snapshots.remove(&session_id);
            send_ok_response(sender, request_id, json!({ "detached": true })).await;
            *last_sent_at = Instant::now();
        }
        "poll" => {
            let session_id = match ensure_session_id(session_id) {
                Ok(session_id) => session_id,
                Err(error) => {
                    send_terminal_error(sender, request_id, error).await;
                    *last_sent_at = Instant::now();
                    return true;
                }
            };
            let request = TerminalActionRequest {
                action: "poll".to_string(),
                session_id: Some(session_id),
                label: None,
                input: None,
                input_bytes: None,
                cols: None,
                rows: None,
                since: payload
                    .and_then(|payload| payload.get("since"))
                    .and_then(|value| value.as_u64()),
                limit: payload
                    .and_then(|payload| payload.get("limit"))
                    .and_then(|value| value.as_u64())
                    .and_then(|value| usize::try_from(value).ok()),
                notify_since: payload
                    .and_then(|payload| payload.get("notify_since"))
                    .and_then(|value| value.as_u64()),
                working_dir: None,
                env: None,
            };
            match handle_terminal_command(request) {
                Ok(payload) => {
                    if snapshot_too_large(&payload) {
                        let _ = send_session_warning(
                            sender,
                            &session_id,
                            "payload_too_large",
                            PAYLOAD_TOO_LARGE_MESSAGE,
                        )
                        .await;
                        send_error_response(
                            sender,
                            request_id,
                            "payload_too_large",
                            "Snapshot exceeds payload limits.",
                        )
                        .await;
                        let _ = sender.send(Message::Close(None)).await;
                        return false;
                    }
                    let truncated = payload_truncated(&payload);
                    send_ok_response(sender, request_id, payload).await;
                    if truncated {
                        let warning =
                            build_session_warning(&session_id, "buffer_truncated", BUFFER_TRUNCATED_MESSAGE);
                        if enqueue_event(outbound, backpressure, warning) == EnqueueResult::Close {
                            return false;
                        }
                    }
                }
                Err(error) => send_terminal_error(sender, request_id, error).await,
            }
            *last_sent_at = Instant::now();
        }
        "status" => {
            let session_id = match ensure_session_id(session_id) {
                Ok(session_id) => session_id,
                Err(error) => {
                    send_terminal_error(sender, request_id, error).await;
                    *last_sent_at = Instant::now();
                    return true;
                }
            };
            let request = TerminalActionRequest {
                action: "status".to_string(),
                session_id: Some(session_id),
                label: None,
                input: None,
                input_bytes: None,
                cols: None,
                rows: None,
                since: None,
                limit: None,
                notify_since: payload
                    .and_then(|payload| payload.get("notify_since"))
                    .and_then(|value| value.as_u64()),
                working_dir: None,
                env: None,
            };
            match handle_terminal_command(request) {
                Ok(payload) => {
                    if snapshot_too_large(&payload) {
                        let _ = send_session_warning(
                            sender,
                            &session_id,
                            "payload_too_large",
                            PAYLOAD_TOO_LARGE_MESSAGE,
                        )
                        .await;
                        send_error_response(
                            sender,
                            request_id,
                            "payload_too_large",
                            "Snapshot exceeds payload limits.",
                        )
                        .await;
                        let _ = sender.send(Message::Close(None)).await;
                        return false;
                    }
                    send_ok_response(sender, request_id, payload).await;
                }
                Err(error) => send_terminal_error(sender, request_id, error).await,
            }
            *last_sent_at = Instant::now();
        }
        "input" => {
            let session_id = match ensure_session_id(session_id) {
                Ok(session_id) => session_id,
                Err(error) => {
                    send_terminal_error(sender, request_id, error).await;
                    *last_sent_at = Instant::now();
                    return true;
                }
            };
            let data = payload
                .and_then(|payload| payload.get("data"))
                .and_then(|value| value.as_str())
                .map(|value| value.to_string());
            let data_b64 = payload
                .and_then(|payload| payload.get("data_b64"))
                .and_then(|value| value.as_str())
                .map(|value| value.to_string());
            if data.is_some() && data_b64.is_some() {
                send_error_response(
                    sender,
                    request_id,
                    "invalid_request",
                    "Provide either data or data_b64, not both.",
                )
                .await;
                *last_sent_at = Instant::now();
                return true;
            }
            let input_bytes = match (data, data_b64) {
                (Some(data), None) => Some(data.into_bytes()),
                (None, Some(encoded)) => match decode_base64(&encoded) {
                    Ok(bytes) => Some(bytes),
                    Err(message) => {
                        send_error_response(sender, request_id, "invalid_request", &message).await;
                        *last_sent_at = Instant::now();
                        return true;
                    }
                },
                (None, None) => None,
                _ => None,
            };
            let request = TerminalActionRequest {
                action: "input".to_string(),
                session_id: Some(session_id),
                label: None,
                input: None,
                input_bytes,
                cols: None,
                rows: None,
                since: None,
                limit: None,
                notify_since: None,
                working_dir: None,
                env: None,
            };
            match handle_terminal_command(request) {
                Ok(payload) => send_ok_response(sender, request_id, payload).await,
                Err(error) => send_terminal_error(sender, request_id, error).await,
            }
            *last_sent_at = Instant::now();
        }
        "stop" | "kill" | "rename" | "resize" | "keepalive" => {
            let request = TerminalActionRequest {
                action: action.clone(),
                session_id,
                label: payload
                    .and_then(|payload| payload.get("label"))
                    .and_then(|value| value.as_str())
                    .map(|value| value.to_string()),
                input: None,
                input_bytes: None,
                cols: payload
                    .and_then(|payload| payload.get("cols"))
                    .and_then(|value| value.as_u64())
                    .and_then(|value| u16::try_from(value).ok()),
                rows: payload
                    .and_then(|payload| payload.get("rows"))
                    .and_then(|value| value.as_u64())
                    .and_then(|value| u16::try_from(value).ok()),
                since: None,
                limit: None,
                notify_since: None,
                working_dir: None,
                env: None,
            };
            match handle_terminal_command(request) {
                Ok(payload) => send_ok_response(sender, request_id, payload).await,
                Err(error) => send_terminal_error(sender, request_id, error).await,
            }
            *last_sent_at = Instant::now();
        }
        _ => {
            send_error_response(
                sender,
                request_id,
                "unsupported_action",
                "Unsupported action.",
            )
            .await;
            *last_sent_at = Instant::now();
        }
    }

    true
}

async fn send_json_sender(sender: &mut WsSender, value: Value) -> Result<(), axum::Error> {
    sender.send(Message::Text(value.to_string().into())).await
}

async fn send_json(socket: &mut WebSocket, value: Value) -> Result<(), axum::Error> {
    socket.send(Message::Text(value.to_string().into())).await
}

async fn send_ok_response(sender: &mut WsSender, request_id: &str, data: Value) {
    let payload = json!({
        "type": "res",
        "id": request_id,
        "ok": true,
        "data": data,
    });
    let _ = send_json_sender(sender, payload).await;
}

async fn send_error_response(
    sender: &mut WsSender,
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
    let _ = send_json_sender(sender, payload).await;
}

async fn send_terminal_error(sender: &mut WsSender, request_id: &str, error: TerminalError) {
    send_error_response(sender, request_id, error.code, &error.message).await;
}

fn build_terminal_payload_event(session_id: &str, data: Value) -> Value {
    json!({
        "type": "event",
        "event": "terminal_payload",
        "session_id": session_id,
        "data": data,
    })
}

fn build_stream_event(event: &str, data: Value) -> Value {
    json!({
        "type": "event",
        "event": event,
        "data": data,
    })
}

fn build_session_warning(session_id: &str, reason: &str, message: &str) -> Value {
    json!({
        "type": "event",
        "event": "session_warning",
        "session_id": session_id,
        "data": {
            "reason": reason,
            "message": message,
            "session_id": session_id,
            "ts": now_ts(),
        }
    })
}

fn format_idle_warning_message(remaining_secs: u64) -> String {
    let remaining = format_remaining_duration(remaining_secs);
    format!(
        "Session idle; will close in {remaining}. Send keepalive to continue."
    )
}

fn format_remaining_duration(remaining_secs: u64) -> String {
    if remaining_secs >= 3600 {
        let hours = remaining_secs / 3600;
        let minutes = (remaining_secs % 3600) / 60;
        if minutes > 0 {
            format!("{hours}h {minutes}m")
        } else {
            format!("{hours}h")
        }
    } else if remaining_secs >= 60 {
        let minutes = remaining_secs / 60;
        format!("{minutes}m")
    } else {
        format!("{remaining_secs}s")
    }
}

async fn send_session_warning(
    sender: &mut WsSender,
    session_id: &str,
    reason: &str,
    message: &str,
) -> Result<(), axum::Error> {
    send_json_sender(sender, build_session_warning(session_id, reason, message)).await
}

fn event_meta(value: &Value) -> (bool, Option<String>) {
    let event = value.get("event").and_then(|value| value.as_str()).unwrap_or("");
    let is_terminal_payload = event == "terminal_payload";
    let session_id = value
        .get("session_id")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string());
    (is_terminal_payload, session_id)
}

fn enqueue_control_event(queue: &mut OutboundQueue, value: Value) -> EnqueueResult {
    let text = value.to_string();
    let bytes = text.as_bytes().len();
    if queue.bytes.saturating_add(bytes) > MAX_SEND_QUEUE_BYTES {
        queue.remove_terminal_payloads(None);
    }
    if queue.bytes.saturating_add(bytes) > MAX_SEND_QUEUE_BYTES {
        return EnqueueResult::Close;
    }
    queue.push(QueuedMessage {
        text,
        bytes,
        is_terminal_payload: false,
        session_id: None,
    });
    EnqueueResult::Enqueued
}

fn trigger_backpressure(
    queue: &mut OutboundQueue,
    backpressure: &mut BackpressureState,
    session_id: Option<&str>,
) -> EnqueueResult {
    if let Some(session_id) = session_id {
        backpressure.pending_snapshots.insert(session_id.to_string());
        queue.remove_terminal_payloads(Some(session_id));
    }
    if backpressure.paused {
        return EnqueueResult::Dropped;
    }
    backpressure.paused = true;
    let paused_event = build_stream_event(
        "stream_paused",
        json!({
            "reason": STREAM_PAUSED_REASON,
            "retry_after_ms": STREAM_PAUSED_RETRY_MS,
        }),
    );
    enqueue_control_event(queue, paused_event)
}

fn enqueue_event(
    queue: &mut OutboundQueue,
    backpressure: &mut BackpressureState,
    value: Value,
) -> EnqueueResult {
    let (is_terminal_payload, session_id) = event_meta(&value);
    let text = value.to_string();
    let bytes = text.as_bytes().len();
    if is_terminal_payload {
        if backpressure.paused {
            if let Some(session_id) = session_id {
                backpressure.pending_snapshots.insert(session_id);
            }
            return EnqueueResult::Dropped;
        }
        if queue.bytes.saturating_add(bytes) > MAX_SEND_QUEUE_BYTES {
            let result = trigger_backpressure(queue, backpressure, session_id.as_deref());
            if matches!(result, EnqueueResult::Close) {
                return result;
            }
            return EnqueueResult::Dropped;
        }
    } else if queue.bytes.saturating_add(bytes) > MAX_SEND_QUEUE_BYTES {
        queue.remove_terminal_payloads(None);
        if queue.bytes.saturating_add(bytes) > MAX_SEND_QUEUE_BYTES {
            return EnqueueResult::Close;
        }
    }
    queue.push(QueuedMessage {
        text,
        bytes,
        is_terminal_payload,
        session_id,
    });
    EnqueueResult::Enqueued
}

fn enqueue_snapshot_event(queue: &mut OutboundQueue, value: Value) -> EnqueueResult {
    let (is_terminal_payload, session_id) = event_meta(&value);
    let text = value.to_string();
    let bytes = text.as_bytes().len();
    if queue.bytes.saturating_add(bytes) > MAX_SEND_QUEUE_BYTES {
        return EnqueueResult::Dropped;
    }
    queue.push(QueuedMessage {
        text,
        bytes,
        is_terminal_payload,
        session_id,
    });
    EnqueueResult::Enqueued
}

async fn flush_outbound_queue(
    sender: &mut WsSender,
    queue: &mut OutboundQueue,
    last_sent_at: &mut Instant,
) -> Result<(), axum::Error> {
    while let Some(message) = queue.pop() {
        sender.send(Message::Text(message.text.into())).await?;
        *last_sent_at = Instant::now();
    }
    Ok(())
}

fn apply_payload_summary(state: &mut AttachmentState, summary: &PayloadSummary) {
    state.last_seq = summary.next_seq.saturating_sub(1);
    state.last_notification_seq = summary.notification_next_seq;
    state.last_status = summary.status.clone();
    state.last_exit_code = summary.exit_code;
    state.last_label = summary.label.clone();
    state.last_truncated = summary.truncated;
}

fn resume_streaming(
    outbound: &mut OutboundQueue,
    backpressure: &mut BackpressureState,
    subscriptions: &mut HashMap<String, AttachmentState>,
) -> bool {
    if !backpressure.paused {
        return false;
    }
    let session_ids = backpressure
        .pending_snapshots
        .drain()
        .collect::<Vec<_>>();
    let mut still_pending = Vec::new();
    for session_id in session_ids {
        let notify_since = subscriptions
            .get(&session_id)
            .map(|state| state.last_notification_seq)
            .unwrap_or(0);
        let payload = match build_terminal_snapshot_payload(&session_id, notify_since) {
            Ok(payload) => payload,
            Err(_) => {
                subscriptions.remove(&session_id);
                continue;
            }
        };
        if snapshot_too_large(&payload) {
            let warning =
                build_session_warning(&session_id, "payload_too_large", PAYLOAD_TOO_LARGE_MESSAGE);
            let _ = enqueue_control_event(outbound, warning);
            return true;
        }
        let summary = summarize_payload(&payload);
        if let Some(state) = subscriptions.get_mut(&session_id) {
            apply_payload_summary(state, &summary);
        }
        let stream_payload = as_stream_payload(payload);
        let event = build_terminal_payload_event(&session_id, stream_payload);
        match enqueue_snapshot_event(outbound, event) {
            EnqueueResult::Enqueued => {}
            EnqueueResult::Dropped => still_pending.push(session_id),
            EnqueueResult::Close => return true,
        }
    }
    if !still_pending.is_empty() {
        for session_id in still_pending {
            backpressure.pending_snapshots.insert(session_id);
        }
        return false;
    }
    backpressure.paused = false;
    let resumed_event = build_stream_event("stream_resumed", json!({}));
    matches!(
        enqueue_control_event(outbound, resumed_event),
        EnqueueResult::Close
    )
}

fn ensure_session_id(session_id: Option<String>) -> Result<String, TerminalError> {
    let session_id = session_id
        .ok_or_else(|| TerminalError {
            code: "missing_session",
            message: "Missing session id.".to_string(),
        })?;
    let trimmed = session_id.trim();
    if trimmed.is_empty() {
        return Err(TerminalError {
            code: "missing_session",
            message: "Missing session id.".to_string(),
        });
    }
    Ok(trimmed.to_string())
}

fn summarize_payload(payload: &Value) -> PayloadSummary {
    PayloadSummary {
        next_seq: payload
            .get("next_seq")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        notification_next_seq: payload
            .get("notification_next_seq")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        status: payload
            .get("status")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string(),
        exit_code: payload.get("exit_code").and_then(|value| value.as_i64()),
        label: payload
            .get("label")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string(),
        output_len: payload
            .get("output")
            .and_then(|value| value.as_array())
            .map(|value| value.len())
            .unwrap_or(0),
        notifications_len: payload
            .get("notifications")
            .and_then(|value| value.as_array())
            .map(|value| value.len())
            .unwrap_or(0),
        truncated: payload
            .get("truncated")
            .and_then(|value| value.as_bool())
            .unwrap_or(false),
    }
}

fn payload_truncated(payload: &Value) -> bool {
    payload
        .get("truncated")
        .and_then(|value| value.as_bool())
        .unwrap_or(false)
}

fn snapshot_too_large(payload: &Value) -> bool {
    payload
        .get("snapshot")
        .and_then(|value| value.as_str())
        .map(|snapshot| snapshot.as_bytes().len() > MAX_TERMINAL_PAYLOAD_BYTES)
        .unwrap_or(false)
}

fn as_stream_payload(mut payload: Value) -> Value {
    if let Some(map) = payload.as_object_mut() {
        map.insert("action".to_string(), json!("stream"));
    }
    payload
}

fn collect_stream_events(
    subscriptions: &mut HashMap<String, AttachmentState>,
    idle_config: IdleCleanupConfig,
) -> StreamEventBatch {
    let mut events = Vec::new();
    let mut detached = Vec::new();
    let mut close = false;
    let now = now_ts();

    for (session_id, state) in subscriptions.iter_mut() {
        let request = TerminalActionRequest {
            action: "poll".to_string(),
            session_id: Some(session_id.clone()),
            label: None,
            input: None,
            input_bytes: None,
            cols: None,
            rows: None,
            since: Some(state.last_seq),
            limit: None,
            notify_since: Some(state.last_notification_seq),
            working_dir: None,
            env: None,
        };
        match handle_terminal_command(request) {
            Ok(payload) => {
                if snapshot_too_large(&payload) {
                    events.push(build_session_warning(
                        session_id,
                        "payload_too_large",
                        PAYLOAD_TOO_LARGE_MESSAGE,
                    ));
                    close = true;
                    continue;
                }
                let status = payload
                    .get("status")
                    .and_then(|value| value.as_str())
                    .unwrap_or("");
                let last_activity = payload
                    .get("last_activity")
                    .and_then(|value| value.as_u64())
                    .unwrap_or(now);
                if idle_config.ttl_secs > 0
                    && idle_config.warning_lead_secs > 0
                    && status == "running"
                {
                    let idle = now.saturating_sub(last_activity);
                    let warn_at = idle_config
                        .ttl_secs
                        .saturating_sub(idle_config.warning_lead_secs);
                    if idle >= warn_at && idle < idle_config.ttl_secs {
                        if now.saturating_sub(state.last_idle_warning_ts) >= IDLE_WARNING_RATE_SECS
                        {
                            let remaining = idle_config.ttl_secs.saturating_sub(idle);
                            let message = format_idle_warning_message(remaining);
                            events.push(build_session_warning(
                                session_id,
                                IDLE_WARNING_REASON,
                                &message,
                            ));
                            state.last_idle_warning_ts = now;
                        }
                    }
                }
                let summary = summarize_payload(&payload);
                let summary_last_seq = summary.next_seq.saturating_sub(1);
                let seq_changed = summary_last_seq != state.last_seq
                    || summary.notification_next_seq != state.last_notification_seq;
                let was_truncated = state.last_truncated;
                let should_send = summary.output_len > 0
                    || summary.notifications_len > 0
                    || summary.truncated
                    || summary.status != state.last_status
                    || summary.exit_code != state.last_exit_code
                    || summary.label != state.last_label
                    || seq_changed;
                if should_send {
                    if summary.truncated && !was_truncated {
                        events.push(build_session_warning(
                            session_id,
                            "buffer_truncated",
                            BUFFER_TRUNCATED_MESSAGE,
                        ));
                    }
                    state.last_seq = summary_last_seq;
                    state.last_notification_seq = summary.notification_next_seq;
                    state.last_status = summary.status;
                    state.last_exit_code = summary.exit_code;
                    state.last_label = summary.label;
                    state.last_truncated = summary.truncated;
                    let stream_payload = as_stream_payload(payload);
                    events.push(build_terminal_payload_event(session_id, stream_payload));
                } else if state.last_truncated {
                    state.last_truncated = false;
                }
            }
            Err(_) => detached.push(session_id.clone()),
        }
    }

    StreamEventBatch {
        events,
        detached,
        close,
    }
}

fn decode_base64(value: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(value.as_bytes())
        .map_err(|_| "Invalid base64 input.".to_string())
}

fn parse_env(
    payload: Option<&serde_json::Map<String, Value>>,
) -> Option<HashMap<String, String>> {
    let env = payload?.get("env")?.as_object()?;
    let mut entries = HashMap::new();
    for (key, value) in env {
        if let Some(value) = value.as_str() {
            entries.insert(key.clone(), value.to_string());
        }
    }
    if entries.is_empty() {
        None
    } else {
        Some(entries)
    }
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
