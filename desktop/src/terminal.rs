use axum::extract::ws::{Message, WebSocket};
use futures_util::{SinkExt, StreamExt};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use rand::{distributions::Alphanumeric, Rng};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::time::{interval, MissedTickBehavior};

const DEFAULT_COLS: u16 = 120;
const DEFAULT_ROWS: u16 = 32;
const MAX_BUFFER_BYTES: usize = 512 * 1024;
const CLEANUP_INTERVAL: Duration = Duration::from_secs(300);
const ENDED_SESSION_TTL: Duration = Duration::from_secs(60 * 60);
const OUTPUT_LIMIT_DEFAULT: usize = 200;

#[derive(Clone)]
struct TerminalOutputChunk {
    seq: u64,
    data: String,
    ts: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TerminalSessionStatus {
    Running,
    Exited,
    Killed,
    Error,
}

impl TerminalSessionStatus {
    fn as_str(self) -> &'static str {
        match self {
            TerminalSessionStatus::Running => "running",
            TerminalSessionStatus::Exited => "exited",
            TerminalSessionStatus::Killed => "killed",
            TerminalSessionStatus::Error => "error",
        }
    }

    fn is_ended(self) -> bool {
        !matches!(self, TerminalSessionStatus::Running)
    }
}

struct TerminalSession {
    id: String,
    created_at: u64,
    last_activity: u64,
    status: TerminalSessionStatus,
    exit_code: Option<i32>,
    buffer: VecDeque<TerminalOutputChunk>,
    buffer_bytes: usize,
    next_seq: u64,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn portable_pty::Child + Send>,
    writer: Box<dyn Write + Send>,
}

impl TerminalSession {
    fn push_output(&mut self, data: String) {
        if data.is_empty() {
            return;
        }
        self.next_seq = self.next_seq.saturating_add(1);
        let chunk = TerminalOutputChunk {
            seq: self.next_seq,
            data,
            ts: now_ts(),
        };
        self.buffer_bytes = self.buffer_bytes.saturating_add(chunk.data.len());
        self.buffer.push_back(chunk);
        while self.buffer_bytes > MAX_BUFFER_BYTES {
            if let Some(front) = self.buffer.pop_front() {
                self.buffer_bytes = self.buffer_bytes.saturating_sub(front.data.len());
            } else {
                break;
            }
        }
        self.last_activity = now_ts();
    }

    fn output_since(&self, since: u64, limit: usize) -> Vec<TerminalOutputChunk> {
        let mut output = self
            .buffer
            .iter()
            .filter(|chunk| chunk.seq > since)
            .cloned()
            .collect::<Vec<_>>();
        if output.len() > limit {
            output = output.split_off(output.len() - limit);
        }
        output
    }
}

pub struct TerminalManager {
    sessions: HashMap<String, Arc<Mutex<TerminalSession>>>,
}

impl TerminalManager {
    fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    fn session(&self, session_id: &str) -> Option<Arc<Mutex<TerminalSession>>> {
        self.sessions.get(session_id).cloned()
    }

    fn insert_session(&mut self, session: Arc<Mutex<TerminalSession>>) {
        let session_id = session.lock().ok().map(|s| s.id.clone());
        if let Some(session_id) = session_id {
            self.sessions.insert(session_id, session);
        }
    }

    fn remove_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }
}

pub struct TerminalActionRequest {
    pub action: String,
    pub session_id: Option<String>,
    pub input: Option<String>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
    pub since: Option<u64>,
    pub limit: Option<usize>,
    pub working_dir: Option<String>,
    pub env: Option<HashMap<String, String>>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TerminalSessionSummary {
    pub id: String,
    pub status: String,
    pub created_at: u64,
    pub last_activity: u64,
    pub exit_code: Option<i32>,
    pub last_output: String,
}

pub struct TerminalError {
    pub code: &'static str,
    pub message: String,
}

impl TerminalError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

static TERMINAL_MANAGER: OnceLock<Arc<Mutex<TerminalManager>>> = OnceLock::new();

pub fn terminal_manager() -> &'static Arc<Mutex<TerminalManager>> {
    TERMINAL_MANAGER.get_or_init(|| {
        let manager = Arc::new(Mutex::new(TerminalManager::new()));
        spawn_cleanup(manager.clone());
        manager
    })
}

pub fn list_terminal_sessions() -> Vec<TerminalSessionSummary> {
    let manager = terminal_manager();
    let manager = match manager.lock() {
        Ok(manager) => manager,
        Err(_) => return Vec::new(),
    };
    let mut sessions = Vec::new();
    for session in manager.sessions.values() {
        if let Ok(session) = session.lock() {
            let last_output = session
                .buffer
                .back()
                .map(|chunk| chunk.data.trim().to_string())
                .unwrap_or_default();
            let preview = if last_output.chars().count() > 160 {
                last_output
                    .chars()
                    .rev()
                    .take(160)
                    .collect::<Vec<char>>()
                    .into_iter()
                    .rev()
                    .collect()
            } else {
                last_output
            };
            sessions.push(TerminalSessionSummary {
                id: session.id.clone(),
                status: session.status.as_str().to_string(),
                created_at: session.created_at,
                last_activity: session.last_activity,
                exit_code: session.exit_code,
                last_output: preview,
            });
        }
    }
    sessions.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
    sessions
}

pub fn handle_terminal_command(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    match request.action.as_str() {
        "start" => start_session(request),
        "poll" => poll_session(request),
        "input" => input_session(request),
        "resize" => resize_session(request),
        "stop" | "kill" => stop_session(request),
        "keepalive" => keepalive_session(request),
        "status" => status_session(request),
        _ => Err(TerminalError::new(
            "unsupported_action",
            format!("Unsupported terminal action: {}", request.action),
        )),
    }
}

pub async fn serve_terminal_socket(socket: WebSocket, session_id: String) {
    let session = {
        let manager = terminal_manager();
        manager
            .lock()
            .ok()
            .and_then(|manager| manager.session(&session_id))
    };

    let Some(session) = session else {
        let mut socket = socket;
        let _ = socket
            .send(Message::Close(None))
            .await;
        return;
    };

    if let Err(error) = run_terminal_stream(socket, session, session_id).await {
        eprintln!("terminal stream error: {error}");
    }
}

async fn run_terminal_stream(
    socket: WebSocket,
    session: Arc<Mutex<TerminalSession>>,
    session_id: String,
) -> Result<(), String> {
    let (mut sender, mut receiver) = socket.split();
    let mut tick = interval(Duration::from_millis(80));
    tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

    let (initial_output, initial_status, initial_next_seq, initial_exit) = {
        let session = session
            .lock()
            .map_err(|_| "Terminal session unavailable.".to_string())?;
        (
            session.output_since(0, OUTPUT_LIMIT_DEFAULT),
            session.status,
            session.next_seq,
            session.exit_code,
        )
    };
    let initial_payload = build_session_payload(
        "stream",
        &session_id,
        initial_status,
        initial_next_seq,
        initial_output,
        initial_exit,
        now_ts(),
    );
    sender
        .send(Message::Text(initial_payload.to_string().into()))
        .await
        .map_err(|error| format!("Failed to send terminal snapshot: {error}"))?;

    let mut last_seq = initial_next_seq;
    let mut last_status = initial_status;
    let mut last_exit = initial_exit;
    let mut last_sent_at = Instant::now();

    loop {
        tokio::select! {
            _ = tick.tick() => {
                let (output, status, next_seq, exit_code) = {
                    let session = session
                        .lock()
                        .map_err(|_| "Terminal session unavailable.".to_string())?;
                    (
                        session.output_since(last_seq, OUTPUT_LIMIT_DEFAULT),
                        session.status,
                        session.next_seq,
                        session.exit_code,
                    )
                };

                if output.is_empty() && status == last_status && exit_code == last_exit {
                    if last_sent_at.elapsed() > Duration::from_secs(15) {
                        let _ = sender.send(Message::Ping(Vec::new().into())).await;
                        last_sent_at = Instant::now();
                    }
                    continue;
                }

                last_seq = next_seq;
                last_status = status;
                last_exit = exit_code;

                let payload = build_session_payload(
                    "stream",
                    &session_id,
                    status,
                    next_seq,
                    output,
                    exit_code,
                    now_ts(),
                );
                if sender.send(Message::Text(payload.to_string().into())).await.is_err() {
                    break;
                }
                last_sent_at = Instant::now();

                if status.is_ended() {
                    break;
                }
            }
            maybe_message = receiver.next() => {
                let Some(message) = maybe_message else {
                    break;
                };
                match message {
                    Ok(Message::Text(text)) => {
                        let parsed: Value = match serde_json::from_str(&text) {
                            Ok(value) => value,
                            Err(_) => continue,
                        };
                        let action = parsed.get("action").and_then(|value| value.as_str()).unwrap_or("");
                        match action {
                            "input" => {
                                if let Some(input) = parsed.get("data").and_then(|value| value.as_str()) {
                                    let request = TerminalActionRequest {
                                        action: "input".to_string(),
                                        session_id: Some(session_id.clone()),
                                        input: Some(input.to_string()),
                                        cols: None,
                                        rows: None,
                                        since: None,
                                        limit: None,
                                        working_dir: None,
                                        env: None,
                                    };
                                    let _ = handle_terminal_command(request);
                                }
                            }
                            "resize" => {
                                let cols = parsed.get("cols").and_then(|value| value.as_u64()).map(|value| value as u16);
                                let rows = parsed.get("rows").and_then(|value| value.as_u64()).map(|value| value as u16);
                                if cols.is_some() && rows.is_some() {
                                    let request = TerminalActionRequest {
                                        action: "resize".to_string(),
                                        session_id: Some(session_id.clone()),
                                        input: None,
                                        cols,
                                        rows,
                                        since: None,
                                        limit: None,
                                        working_dir: None,
                                        env: None,
                                    };
                                    let _ = handle_terminal_command(request);
                                }
                            }
                            "stop" => {
                                let request = TerminalActionRequest {
                                    action: "stop".to_string(),
                                    session_id: Some(session_id.clone()),
                                    input: None,
                                    cols: None,
                                    rows: None,
                                    since: None,
                                    limit: None,
                                    working_dir: None,
                                    env: None,
                                };
                                let _ = handle_terminal_command(request);
                            }
                            "keepalive" => {
                                let request = TerminalActionRequest {
                                    action: "keepalive".to_string(),
                                    session_id: Some(session_id.clone()),
                                    input: None,
                                    cols: None,
                                    rows: None,
                                    since: None,
                                    limit: None,
                                    working_dir: None,
                                    env: None,
                                };
                                let _ = handle_terminal_command(request);
                            }
                            _ => {}
                        }
                    }
                    Ok(Message::Close(_)) => break,
                    Ok(Message::Ping(payload)) => {
                        let _ = sender.send(Message::Pong(payload)).await;
                    }
                    _ => {}
                }
            }
        }
    }

    Ok(())
}

fn start_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = resolve_session_id(request.session_id)?;
    {
        let manager = terminal_manager();
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        if manager.sessions.contains_key(&session_id) {
            return Err(TerminalError::new(
                "session_exists",
                "Terminal session already exists.",
            ));
        }
    }
    let pty_system = native_pty_system();
    let cols = request.cols.unwrap_or(DEFAULT_COLS);
    let rows = request.rows.unwrap_or(DEFAULT_ROWS);
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| TerminalError::new("pty_error", error.to_string()))?;

    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let mut cmd = CommandBuilder::new(shell);
    if let Some(working_dir) = request.working_dir.clone() {
        if !working_dir.trim().is_empty() {
            cmd.cwd(working_dir);
        }
    } else if let Ok(home) = std::env::var("HOME") {
        cmd.cwd(home);
    }
    if let Some(env) = request.env.clone() {
        for (key, value) in env {
            cmd.env(key, value);
        }
    }
    if std::env::var("TERM").is_err() {
        cmd.env("TERM", "xterm-256color");
    }
    cmd.env("COLORTERM", "truecolor");

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|error| TerminalError::new("spawn_error", error.to_string()))?;

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| TerminalError::new("pty_error", error.to_string()))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|error| TerminalError::new("pty_error", error.to_string()))?;

    let now = now_ts();
    let session = Arc::new(Mutex::new(TerminalSession {
        id: session_id.clone(),
        created_at: now,
        last_activity: now,
        status: TerminalSessionStatus::Running,
        exit_code: None,
        buffer: VecDeque::new(),
        buffer_bytes: 0,
        next_seq: 0,
        master: pair.master,
        child,
        writer,
    }));

    {
        let manager = terminal_manager();
        let mut manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager.insert_session(session.clone());
    }

    spawn_reader(session, reader);

    if let Some(input) = request.input.as_ref() {
        if !input.is_empty() {
            let manager = terminal_manager();
            if let Ok(manager) = manager.lock() {
                if let Some(session) = manager.session(&session_id) {
                    if let Ok(mut session) = session.lock() {
                        let _ = session.writer.write_all(input.as_bytes());
                        let _ = session.writer.flush();
                    }
                }
            }
        }
    }

    Ok(build_session_payload(
        "start",
        &session_id,
        TerminalSessionStatus::Running,
        0,
        Vec::new(),
        None,
        now,
    ))
}

fn poll_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let mut session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    session.last_activity = now_ts();
    let since = request.since.unwrap_or(0);
    let limit = request.limit.unwrap_or(OUTPUT_LIMIT_DEFAULT);
    let output = session.output_since(since, limit);
    Ok(build_session_payload(
        "poll",
        &session.id,
        session.status,
        session.next_seq,
        output,
        session.exit_code,
        session.last_activity,
    ))
}

fn input_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let input = request
        .input
        .ok_or_else(|| TerminalError::new("missing_input", "Missing terminal input."))?;
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let mut session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    if session.status.is_ended() {
        return Err(TerminalError::new(
            "session_ended",
            "Terminal session has ended.",
        ));
    }
    session
        .writer
        .write_all(input.as_bytes())
        .map_err(|error| TerminalError::new("write_failed", error.to_string()))?;
    session
        .writer
        .flush()
        .map_err(|error| TerminalError::new("write_failed", error.to_string()))?;
    session.last_activity = now_ts();
    Ok(build_session_payload(
        "input",
        &session.id,
        session.status,
        session.next_seq,
        Vec::new(),
        session.exit_code,
        session.last_activity,
    ))
}

fn resize_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let cols = request
        .cols
        .ok_or_else(|| TerminalError::new("missing_size", "Missing terminal cols."))?;
    let rows = request
        .rows
        .ok_or_else(|| TerminalError::new("missing_size", "Missing terminal rows."))?;
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let mut session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    session
        .master
        .resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| TerminalError::new("resize_failed", error.to_string()))?;
    session.last_activity = now_ts();
    Ok(build_session_payload(
        "resize",
        &session.id,
        session.status,
        session.next_seq,
        Vec::new(),
        session.exit_code,
        session.last_activity,
    ))
}

fn stop_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let mut session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    let _ = session.child.kill();
    session.status = TerminalSessionStatus::Killed;
    session.exit_code = None;
    session.last_activity = now_ts();
    Ok(build_session_payload(
        "stop",
        &session.id,
        session.status,
        session.next_seq,
        Vec::new(),
        session.exit_code,
        session.last_activity,
    ))
}

fn keepalive_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let mut session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    session.last_activity = now_ts();
    Ok(build_session_payload(
        "keepalive",
        &session.id,
        session.status,
        session.next_seq,
        Vec::new(),
        session.exit_code,
        session.last_activity,
    ))
}

fn status_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    Ok(build_session_payload(
        "status",
        &session.id,
        session.status,
        session.next_seq,
        Vec::new(),
        session.exit_code,
        session.last_activity,
    ))
}

fn resolve_session_id(requested: Option<String>) -> Result<String, TerminalError> {
    if let Some(value) = requested {
        let trimmed = value.trim().to_string();
        if !trimmed.is_empty() {
            return Ok(trimmed);
        }
    }
    Ok(random_session_id())
}

fn required_session_id(session_id: Option<String>) -> Result<String, TerminalError> {
    let session_id = session_id
        .ok_or_else(|| TerminalError::new("missing_session", "Missing session id."))?;
    let trimmed = session_id.trim().to_string();
    if trimmed.is_empty() {
        return Err(TerminalError::new("missing_session", "Missing session id."));
    }
    Ok(trimmed)
}

fn random_session_id() -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(16)
        .map(char::from)
        .collect()
}

fn spawn_reader(session: Arc<Mutex<TerminalSession>>, mut reader: Box<dyn Read + Send>) {
    thread::spawn(move || {
        let mut buffer = [0u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    let mut session = match session.lock() {
                        Ok(guard) => guard,
                        Err(_) => return,
                    };
                    let exit_code = session
                        .child
                        .wait()
                        .ok()
                        .map(|status| status.exit_code() as i32);
                    if session.status != TerminalSessionStatus::Killed {
                        session.status = TerminalSessionStatus::Exited;
                    }
                    session.exit_code = exit_code;
                    session.last_activity = now_ts();
                    return;
                }
                Ok(count) => {
                    let data = String::from_utf8_lossy(&buffer[..count]).to_string();
                    if let Ok(mut session) = session.lock() {
                        session.push_output(data);
                    }
                }
                Err(_) => {
                    if let Ok(mut session) = session.lock() {
                        session.status = TerminalSessionStatus::Error;
                        session.last_activity = now_ts();
                    }
                    return;
                }
            }
        }
    });
}

fn spawn_cleanup(manager: Arc<Mutex<TerminalManager>>) {
    thread::spawn(move || loop {
        thread::sleep(CLEANUP_INTERVAL);
        let now = now_ts();
        let mut manager = match manager.lock() {
            Ok(guard) => guard,
            Err(_) => continue,
        };
        let expired_ids = manager
            .sessions
            .iter()
            .filter_map(|(id, session)| {
                let session = session.lock().ok()?;
                if !session.status.is_ended() {
                    return None;
                }
                let idle = now.saturating_sub(session.last_activity);
                if idle > ENDED_SESSION_TTL.as_secs() {
                    Some(id.clone())
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        for id in expired_ids {
            manager.remove_session(&id);
        }
    });
}

fn build_session_payload(
    action: &str,
    session_id: &str,
    status: TerminalSessionStatus,
    next_seq: u64,
    output: Vec<TerminalOutputChunk>,
    exit_code: Option<i32>,
    last_activity: u64,
) -> Value {
    let output_json = output
        .into_iter()
        .map(|chunk| {
            json!({
                "seq": chunk.seq,
                "data": chunk.data,
                "ts": chunk.ts,
            })
        })
        .collect::<Vec<_>>();
    json!({
        "type": "terminal",
        "action": action,
        "status": status.as_str(),
        "session_id": session_id,
        "output": output_json,
        "next_seq": next_seq,
        "exit_code": exit_code,
        "last_activity": last_activity,
    })
}

fn now_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
