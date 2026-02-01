//! Shared terminal daemon core types and defaults.

use axum::extract::ws::{Message, WebSocket};
use directories::ProjectDirs;
use futures_util::{SinkExt, StreamExt};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::time::{interval, MissedTickBehavior};
use vt100;

/// Default WebSocket URL for terminald.
pub const DEFAULT_TERMINALD_WS_URL: &str = "ws://127.0.0.1:7078/ws";

/// Default bind address for terminald.
pub const DEFAULT_TERMINALD_BIND: &str = "127.0.0.1:7078";

/// Default WebSocket path for terminald.
pub const DEFAULT_TERMINALD_WS_PATH: &str = "/ws";

/// Protocol version for terminald clients.
pub const TERMINALD_PROTOCOL_VERSION: &str = "1.0";

/// Discovery file name for terminald.
pub const TERMINALD_DISCOVERY_FILE: &str = "terminald.json";

const DEFAULT_COLS: u16 = 120;
const DEFAULT_ROWS: u16 = 32;
const MIN_COLS: u16 = 10;
const MAX_COLS: u16 = 400;
const MIN_ROWS: u16 = 4;
const MAX_ROWS: u16 = 200;
const MAX_BUFFER_BYTES: usize = 512 * 1024;
const CLEANUP_INTERVAL: Duration = Duration::from_secs(300);
const DEFAULT_IDLE_TTL_SECS: u64 = 60 * 60 * 24;
const DEFAULT_IDLE_WARNING_SECS: u64 = 60 * 10;
const ENV_IDLE_TTL_SECS: &str = "TERMINALD_IDLE_TTL_SECS";
const ENV_IDLE_WARNING_SECS: &str = "TERMINALD_IDLE_WARNING_SECS";
const OUTPUT_LIMIT_DEFAULT: usize = 800;
const SNAPSHOT_SCROLLBACK: usize = 0;
const MAX_LABEL_LEN: usize = 80;
const TERMINAL_SESSIONS_FILE: &str = "terminal_sessions.json";
const TERMINAL_RESTART_REASON: &str = "Session closed because terminald restarted.";
const IDLE_TIMEOUT_REASON: &str = "Session closed after idle timeout.";
const NOTIFICATION_RATE_LIMIT_SECS: u64 = 10;
const NOTIFICATION_QUEUE_LIMIT: usize = 200;
const NOTIFICATION_MESSAGE_LIMIT: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalDiscoveryFile {
    pub ws_url: String,
    pub token: String,
    pub version: String,
    pub pid: u32,
    pub created_at: u64,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Copy, Debug)]
pub struct IdleCleanupConfig {
    pub ttl_secs: u64,
    pub warning_lead_secs: u64,
}

fn parse_env_seconds(key: &str) -> Option<u64> {
    let value = std::env::var(key).ok()?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    trimmed.parse::<u64>().ok()
}

pub fn idle_cleanup_config() -> IdleCleanupConfig {
    let ttl = parse_env_seconds(ENV_IDLE_TTL_SECS).unwrap_or(DEFAULT_IDLE_TTL_SECS);
    if ttl == 0 {
        return IdleCleanupConfig {
            ttl_secs: 0,
            warning_lead_secs: 0,
        };
    }
    let mut warning = parse_env_seconds(ENV_IDLE_WARNING_SECS).unwrap_or(DEFAULT_IDLE_WARNING_SECS);
    if warning >= ttl {
        warning = ttl.saturating_div(2);
    }
    IdleCleanupConfig {
        ttl_secs: ttl,
        warning_lead_secs: warning,
    }
}

fn resolve_shell() -> String {
    if let Ok(shell) = std::env::var("SHELL") {
        let trimmed = shell.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    if cfg!(target_os = "windows") {
        if let Ok(comspec) = std::env::var("COMSPEC") {
            let trimmed = comspec.trim();
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
        return "powershell.exe".to_string();
    }
    if cfg!(target_os = "macos") {
        if Path::new("/bin/zsh").exists() {
            return "/bin/zsh".to_string();
        }
        if Path::new("/bin/bash").exists() {
            return "/bin/bash".to_string();
        }
        return "/bin/sh".to_string();
    }
    if cfg!(target_os = "linux") {
        if Path::new("/bin/bash").exists() {
            return "/bin/bash".to_string();
        }
        if Path::new("/bin/sh").exists() {
            return "/bin/sh".to_string();
        }
        return "sh".to_string();
    }
    if Path::new("/bin/sh").exists() {
        return "/bin/sh".to_string();
    }
    "sh".to_string()
}

pub fn terminal_discovery_path() -> Option<PathBuf> {
    let dirs = ProjectDirs::from("com", "vibe", "vibe-inspect")?;
    Some(dirs.config_dir().join(TERMINALD_DISCOVERY_FILE))
}

pub fn read_discovery_file(path: &Path) -> Result<TerminalDiscoveryFile, std::io::Error> {
    let contents = fs::read_to_string(path)?;
    serde_json::from_str(&contents)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

pub fn write_discovery_file(
    discovery: &TerminalDiscoveryFile,
) -> Result<PathBuf, std::io::Error> {
    let path = terminal_discovery_path()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "Config dir missing"))?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let payload = serde_json::to_vec_pretty(discovery)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::Other, error))?;
    write_atomic_file(&path, &payload)?;
    Ok(path)
}

fn discovery_tmp_path(path: &Path) -> PathBuf {
    let suffix: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(12)
        .map(char::from)
        .collect();
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("terminald.json");
    let tmp_name = format!(".{file_name}.tmp-{suffix}");
    match path.parent() {
        Some(parent) => parent.join(tmp_name),
        None => PathBuf::from(tmp_name),
    }
}

fn sync_parent_dir(path: &Path) {
    if let Some(parent) = path.parent() {
        let _ = fs::File::open(parent).and_then(|dir| dir.sync_all());
    }
}

fn write_atomic_file(path: &Path, payload: &[u8]) -> Result<(), std::io::Error> {
    let tmp_path = discovery_tmp_path(path);
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        options.mode(0o600);
    }
    let mut file = options.open(&tmp_path)?;
    file.write_all(payload)?;
    file.sync_all()?;
    #[cfg(unix)]
    {
        let permissions = fs::Permissions::from_mode(0o600);
        fs::set_permissions(&tmp_path, permissions)?;
    }
    if let Err(error) = fs::rename(&tmp_path, path) {
        #[cfg(windows)]
        {
            if path.exists() {
                let _ = fs::remove_file(path);
                fs::rename(&tmp_path, path)?;
                sync_parent_dir(path);
                return Ok(());
            }
        }
        let _ = fs::remove_file(&tmp_path);
        return Err(error);
    }
    sync_parent_dir(path);
    Ok(())
}

#[derive(Clone)]
struct TerminalOutputChunk {
    seq: u64,
    data: String,
    ts: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
struct TerminalNotification {
    id: String,
    session_id: String,
    message: String,
    level: String,
    created_at: u64,
    source: String,
    seq: u64,
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
    label: String,
    cols: u16,
    rows: u16,
    created_at: u64,
    last_activity: u64,
    status: TerminalSessionStatus,
    exit_code: Option<i32>,
    closed_reason: Option<String>,
    buffer: VecDeque<TerminalOutputChunk>,
    buffer_bytes: usize,
    next_seq: u64,
    notification_seq: u64,
    notifications: VecDeque<TerminalNotification>,
    notification_cache: HashMap<String, u64>,
    parser: vt100::Parser,
    utf8_carry: Vec<u8>,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn portable_pty::Child + Send>,
    writer: Box<dyn Write + Send>,
}

fn next_expected_seq(current: u64) -> u64 {
    current.saturating_add(1)
}

fn last_delivered_seq(next_seq: u64) -> u64 {
    next_seq.saturating_sub(1)
}

impl TerminalSession {
    fn push_output(&mut self, data: String) {
        if data.is_empty() {
            return;
        }
        self.capture_notifications(&data);
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

    fn push_output_bytes(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.parser.process(bytes);
        let text = decode_utf8_stream(&mut self.utf8_carry, bytes);
        if !text.is_empty() {
            self.push_output(text);
        }
    }

    fn flush_utf8_carry(&mut self) {
        if self.utf8_carry.is_empty() {
            return;
        }
        let text = String::from_utf8_lossy(&self.utf8_carry).to_string();
        self.utf8_carry.clear();
        if !text.is_empty() {
            self.push_output(text);
        }
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

    fn notifications_since(
        &self,
        since: u64,
        limit: usize,
    ) -> Vec<TerminalNotification> {
        let mut notifications = self
            .notifications
            .iter()
            .filter(|notification| notification.seq > since)
            .cloned()
            .collect::<Vec<_>>();
        if notifications.len() > limit {
            notifications = notifications.split_off(notifications.len() - limit);
        }
        notifications
    }

    fn capture_notifications(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        let now = now_ts();
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let lowered = trimmed.to_lowercase();
            let (level, matched) = if lowered.contains("warning") || lowered.contains("warn") {
                ("warning", true)
            } else if lowered.contains("error")
                || lowered.contains("failed")
                || lowered.contains("fatal")
            {
                ("error", true)
            } else {
                ("info", false)
            };
            if !matched {
                continue;
            }
            let message = truncate_message(trimmed, NOTIFICATION_MESSAGE_LIMIT);
            let fingerprint = format!("{}:{}", level, message);
            if let Some(last_seen) = self.notification_cache.get(&fingerprint) {
                if now.saturating_sub(*last_seen) < NOTIFICATION_RATE_LIMIT_SECS {
                    continue;
                }
            }
            self.notification_cache.insert(fingerprint, now);
            if self.notification_cache.len() > NOTIFICATION_QUEUE_LIMIT {
                self.notification_cache
                    .retain(|_, ts| now.saturating_sub(*ts) < 300);
            }
            self.notification_seq = self.notification_seq.saturating_add(1);
            let notification = TerminalNotification {
                id: format!("{}:{}", self.id, self.notification_seq),
                session_id: self.id.clone(),
                message: message.to_string(),
                level: level.to_string(),
                created_at: now,
                source: "terminal_output".to_string(),
                seq: self.notification_seq,
            };
            if self.notifications.len() >= NOTIFICATION_QUEUE_LIMIT {
                self.notifications.pop_front();
            }
            self.notifications.push_back(notification);
        }
    }

    fn first_seq(&self) -> Option<u64> {
        self.buffer.front().map(|chunk| chunk.seq)
    }

    fn snapshot_formatted(&self) -> Option<String> {
        let screen = self.parser.screen();
        let mut bytes = screen.state_formatted();
        bytes.extend(screen.cursor_state_formatted());
        if bytes.is_empty() {
            return None;
        }
        Some(String::from_utf8_lossy(&bytes).to_string())
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
    pub label: Option<String>,
    pub input: Option<String>,
    pub input_bytes: Option<Vec<u8>>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
    pub since: Option<u64>,
    pub limit: Option<usize>,
    pub notify_since: Option<u64>,
    pub working_dir: Option<String>,
    pub env: Option<HashMap<String, String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalSessionSummary {
    pub id: String,
    pub label: String,
    pub status: String,
    pub created_at: u64,
    pub last_activity: u64,
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub last_output: String,
    #[serde(default)]
    pub closed_reason: Option<String>,
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
static TERMINAL_HISTORY: OnceLock<Arc<Mutex<TerminalSessionHistory>>> = OnceLock::new();

struct TerminalSessionHistory {
    sessions: HashMap<String, TerminalSessionSummary>,
}

impl TerminalSessionHistory {
    fn load() -> Self {
        let (mut sessions, parsed_ok) = load_terminal_session_history();
        let changed = normalize_history_entries(&mut sessions);
        let history = Self { sessions };
        if parsed_ok && changed {
            history.persist();
        }
        history
    }

    fn persist(&self) {
        let _ = save_terminal_session_history(&self.sessions);
    }
}

fn terminal_history() -> &'static Arc<Mutex<TerminalSessionHistory>> {
    TERMINAL_HISTORY.get_or_init(|| Arc::new(Mutex::new(TerminalSessionHistory::load())))
}

fn terminal_sessions_path() -> Option<PathBuf> {
    let dirs = ProjectDirs::from("com", "vibe", "vibe-inspect")?;
    Some(dirs.config_dir().join(TERMINAL_SESSIONS_FILE))
}

fn normalize_history_entries(
    sessions: &mut HashMap<String, TerminalSessionSummary>,
) -> bool {
    let now = now_ts();
    let mut changed = false;
    for session in sessions.values_mut() {
        let status = session.status.trim();
        if status.is_empty() {
            session.status = "exited".to_string();
            changed = true;
            continue;
        }
        if status == "closed" || status == "running" {
            session.status = "exited".to_string();
            if session.closed_reason.is_none() {
                session.closed_reason = Some(TERMINAL_RESTART_REASON.to_string());
            }
            session.last_activity = now;
            changed = true;
        }
    }
    changed
}

fn load_terminal_session_history() -> (HashMap<String, TerminalSessionSummary>, bool) {
    let mut sessions = HashMap::new();
    let Some(path) = terminal_sessions_path() else {
        return (sessions, false);
    };
    let contents = match fs::read_to_string(&path) {
        Ok(contents) => contents,
        Err(error) => {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!(
                    "Warning: failed to read terminal session summaries at {}: {error}",
                    path.display()
                );
            }
            return (sessions, false);
        }
    };
    let parsed = match serde_json::from_str::<Vec<TerminalSessionSummary>>(&contents) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!(
                "Warning: failed to parse terminal session summaries at {}: {error}",
                path.display()
            );
            return (sessions, false);
        }
    };
    for session in parsed {
        if !session.id.trim().is_empty() {
            sessions.insert(session.id.clone(), session);
        }
    }
    (sessions, true)
}

fn save_terminal_session_history(
    sessions: &HashMap<String, TerminalSessionSummary>,
) -> Result<(), std::io::Error> {
    let Some(path) = terminal_sessions_path() else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut entries = sessions.values().cloned().collect::<Vec<_>>();
    entries.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
    let payload = serde_json::to_vec_pretty(&entries)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::Other, error))?;
    write_atomic_file(&path, &payload)?;
    Ok(())
}

pub fn terminal_manager() -> &'static Arc<Mutex<TerminalManager>> {
    TERMINAL_MANAGER.get_or_init(|| {
        let manager = Arc::new(Mutex::new(TerminalManager::new()));
        spawn_cleanup(manager.clone());
        manager
    })
}

fn build_session_summary(session: &TerminalSession) -> TerminalSessionSummary {
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
    TerminalSessionSummary {
        id: session.id.clone(),
        label: session.label.clone(),
        status: session.status.as_str().to_string(),
        created_at: session.created_at,
        last_activity: session.last_activity,
        exit_code: session.exit_code,
        last_output: preview,
        closed_reason: session.closed_reason.clone(),
    }
}

fn persist_session_summary(session: &TerminalSession) {
    let summary = build_session_summary(session);
    let history = terminal_history();
    let mut history = match history.lock() {
        Ok(history) => history,
        Err(_) => return,
    };
    history.sessions.insert(summary.id.clone(), summary);
    history.persist();
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
            sessions.push(build_session_summary(&session));
        }
    }
    let active_ids = sessions
        .iter()
        .map(|session| session.id.clone())
        .collect::<HashSet<_>>();
    if let Ok(mut history) = terminal_history().lock() {
        for session in &sessions {
            history.sessions.insert(session.id.clone(), session.clone());
        }
        let now = now_ts();
        for session in history.sessions.values_mut() {
            if active_ids.contains(&session.id) {
                continue;
            }
            if session.status == "running" || session.status == "closed" {
                session.status = "exited".to_string();
                if session.closed_reason.is_none() {
                    session.closed_reason = Some(TERMINAL_RESTART_REASON.to_string());
                }
                session.last_activity = now;
            }
        }
        history.persist();
        for session in history.sessions.values() {
            if !active_ids.contains(&session.id) {
                sessions.push(session.clone());
            }
        }
    }
    sessions.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
    sessions
}

pub fn handle_terminal_command(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    match request.action.as_str() {
        "start" => start_session(request),
        "poll" => poll_session(request),
        "list" => list_sessions(request),
        "input" => input_session(request),
        "resize" => resize_session(request),
        "stop" | "kill" => stop_session(request),
        "keepalive" => keepalive_session(request),
        "status" => status_session(request),
        "rename" => rename_session(request),
        _ => Err(TerminalError::new(
            "unsupported_action",
            format!("Unsupported terminal action: {}", request.action),
        )),
    }
}

pub fn build_terminal_snapshot_payload(
    session_id: &str,
    notify_since: u64,
) -> Result<Value, TerminalError> {
    let trimmed = session_id.trim();
    if trimmed.is_empty() {
        return Err(TerminalError::new("missing_session", "Missing session id."));
    }
    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager
            .session(trimmed)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?
    };
    let session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    let notifications = session.notifications_since(notify_since, NOTIFICATION_QUEUE_LIMIT);
    let snapshot = session.snapshot_formatted().unwrap_or_default();
    Ok(build_session_payload(
        "poll",
        &session.id,
        session.status,
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        true,
        Some(snapshot),
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        notifications,
    ))
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
        let _ = socket.send(Message::Close(None)).await;
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

    let (
        initial_output,
        initial_status,
        initial_next_seq,
        initial_exit,
        initial_first_seq,
        initial_snapshot,
        initial_label,
        initial_notifications,
        initial_notification_seq,
    ) = {
        let session = session
            .lock()
            .map_err(|_| "Terminal session unavailable.".to_string())?;
        (
            session.output_since(0, OUTPUT_LIMIT_DEFAULT),
            session.status,
            next_expected_seq(session.next_seq),
            session.exit_code,
            session.first_seq(),
            session.snapshot_formatted(),
            session.label.clone(),
            session.notifications_since(0, NOTIFICATION_QUEUE_LIMIT),
            session.notification_seq,
        )
    };
    let initial_last_seq = last_delivered_seq(initial_next_seq);
    let initial_truncated = initial_first_seq
        .map(|first| initial_last_seq.saturating_add(1) < first)
        .unwrap_or(false);
    let initial_payload = build_session_payload(
        "stream",
        &session_id,
        initial_status,
        initial_next_seq,
        initial_output,
        initial_first_seq,
        initial_truncated,
        if initial_truncated { initial_snapshot } else { None },
        initial_exit,
        now_ts(),
        Some(initial_label.as_str()),
        initial_notification_seq,
        initial_notifications,
    );
    sender
        .send(Message::Text(initial_payload.to_string().into()))
        .await
        .map_err(|error| format!("Failed to send terminal snapshot: {error}"))?;

    let mut last_seq = initial_last_seq;
    let mut last_status = initial_status;
    let mut last_exit = initial_exit;
    let mut last_label = initial_label;
    let mut last_notification_seq = initial_notification_seq;
    let mut last_sent_at = Instant::now();

    loop {
        tokio::select! {
            _ = tick.tick() => {
                let (output, status, next_seq, exit_code, first_seq, snapshot, label, notifications, notification_seq) = {
                    let session = session
                        .lock()
                        .map_err(|_| "Terminal session unavailable.".to_string())?;
                    (
                        session.output_since(last_seq, OUTPUT_LIMIT_DEFAULT),
                        session.status,
                        next_expected_seq(session.next_seq),
                        session.exit_code,
                        session.first_seq(),
                        session.snapshot_formatted(),
                        session.label.clone(),
                        session.notifications_since(last_notification_seq, NOTIFICATION_QUEUE_LIMIT),
                        session.notification_seq,
                    )
                };

                if output.is_empty()
                    && status == last_status
                    && exit_code == last_exit
                    && label == last_label
                    && notifications.is_empty()
                {
                    if last_sent_at.elapsed() > Duration::from_secs(15) {
                        let _ = sender.send(Message::Ping(Vec::new().into())).await;
                        last_sent_at = Instant::now();
                    }
                    continue;
                }

                last_status = status;
                last_exit = exit_code;
                last_label = label.clone();
                last_notification_seq = notification_seq;

                let truncated = first_seq
                    .map(|first| last_seq.saturating_add(1) < first)
                    .unwrap_or(false);
                let payload = build_session_payload(
                    "stream",
                    &session_id,
                    status,
                    next_seq,
                    output,
                    first_seq,
                    truncated,
                    if truncated { snapshot } else { None },
                    exit_code,
                    now_ts(),
                    Some(label.as_str()),
                    notification_seq,
                    notifications,
                );
                if sender.send(Message::Text(payload.to_string().into())).await.is_err() {
                    break;
                }
                last_seq = last_delivered_seq(next_seq);
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
                                        label: None,
                                        input: Some(input.to_string()),
                                        input_bytes: None,
                                        cols: None,
                                        rows: None,
                                        since: None,
                                        limit: None,
                                        notify_since: None,
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
                                        label: None,
                                        input: None,
                                        input_bytes: None,
                                        cols,
                                        rows,
                                        since: None,
                                        limit: None,
                                        notify_since: None,
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
                                    label: None,
                                    input: None,
                                    input_bytes: None,
                                    cols: None,
                                    rows: None,
                                    since: None,
                                    limit: None,
                                    notify_since: None,
                                    working_dir: None,
                                    env: None,
                                };
                                let _ = handle_terminal_command(request);
                            }
                            "keepalive" => {
                                let request = TerminalActionRequest {
                                    action: "keepalive".to_string(),
                                    session_id: Some(session_id.clone()),
                                    label: None,
                                    input: None,
                                    input_bytes: None,
                                    cols: None,
                                    rows: None,
                                    since: None,
                                    limit: None,
                                    notify_since: None,
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
    let label = resolve_start_label(request.label.clone(), &session_id)?;
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
    validate_size(cols, rows)?;
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| TerminalError::new("pty_error", error.to_string()))?;

    let shell = resolve_shell();
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
        label: label.clone(),
        cols,
        rows,
        created_at: now,
        last_activity: now,
        status: TerminalSessionStatus::Running,
        exit_code: None,
        closed_reason: None,
        buffer: VecDeque::new(),
        buffer_bytes: 0,
        next_seq: 0,
        notification_seq: 0,
        notifications: VecDeque::new(),
        notification_cache: HashMap::new(),
        parser: vt100::Parser::new(rows, cols, SNAPSHOT_SCROLLBACK),
        utf8_carry: Vec::new(),
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

    spawn_reader(session.clone(), reader);

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
    if let Ok(session) = session.lock() {
        persist_session_summary(&session);
    }

    Ok(build_session_payload(
        "start",
        &session_id,
        TerminalSessionStatus::Running,
        next_expected_seq(0),
        Vec::new(),
        None,
        false,
        None,
        None,
        now,
        Some(label.as_str()),
        0,
        Vec::new(),
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
    let session = session
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
    let since = request.since.unwrap_or(0);
    let notify_since = request.notify_since.unwrap_or(0);
    let limit = request.limit.unwrap_or(OUTPUT_LIMIT_DEFAULT);
    let output = session.output_since(since, limit);
    let notifications = session.notifications_since(notify_since, NOTIFICATION_QUEUE_LIMIT);
    let first_seq = session.first_seq();
    let truncated = first_seq
        .map(|first| since.saturating_add(1) < first)
        .unwrap_or(false);
    let snapshot = if truncated {
        session.snapshot_formatted()
    } else {
        None
    };
    Ok(build_session_payload(
        "poll",
        &session.id,
        session.status,
        next_expected_seq(session.next_seq),
        output,
        first_seq,
        truncated,
        snapshot,
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        notifications,
    ))
}

fn input_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let input_bytes = match (request.input, request.input_bytes) {
        (Some(input), None) => input.into_bytes(),
        (None, Some(bytes)) => bytes,
        (Some(_), Some(_)) => {
            return Err(TerminalError::new(
                "invalid_request",
                "Provide either data or data_b64, not both.",
            ))
        }
        (None, None) => {
            return Err(TerminalError::new(
                "missing_input",
                "Missing terminal input.",
            ))
        }
    };
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
        .write_all(&input_bytes)
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
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        false,
        None,
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        Vec::new(),
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
    validate_size(cols, rows)?;
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
    if session.cols != cols || session.rows != rows {
        session
            .master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|error| TerminalError::new("resize_failed", error.to_string()))?;
        session.parser.screen_mut().set_size(rows, cols);
        session.cols = cols;
        session.rows = rows;
        session.last_activity = now_ts();
    }
    Ok(build_session_payload(
        "resize",
        &session.id,
        session.status,
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        false,
        None,
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        Vec::new(),
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
    persist_session_summary(&session);
    Ok(build_session_payload(
        "stop",
        &session.id,
        session.status,
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        false,
        None,
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        Vec::new(),
    ))
}

fn list_sessions(_request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let sessions = list_terminal_sessions();
    Ok(json!({
        "type": "terminal",
        "action": "list",
        "sessions": sessions,
    }))
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
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        false,
        None,
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        Vec::new(),
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
    let snapshot = session.snapshot_formatted();
    let notify_since = request.notify_since.unwrap_or(0);
    let notifications = session.notifications_since(notify_since, NOTIFICATION_QUEUE_LIMIT);
    Ok(build_session_payload(
        "status",
        &session.id,
        session.status,
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        false,
        snapshot,
        session.exit_code,
        session.last_activity,
        Some(session.label.as_str()),
        session.notification_seq,
        notifications,
    ))
}

fn rename_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let label = resolve_rename_label(request.label)?;
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
    if session.label != label {
        session.label = label.clone();
        session.last_activity = now_ts();
        persist_session_summary(&session);
    }
    Ok(build_session_payload(
        "rename",
        &session.id,
        session.status,
        next_expected_seq(session.next_seq),
        Vec::new(),
        session.first_seq(),
        false,
        None,
        session.exit_code,
        session.last_activity,
        Some(label.as_str()),
        session.notification_seq,
        Vec::new(),
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

fn resolve_start_label(label: Option<String>, session_id: &str) -> Result<String, TerminalError> {
    if let Some(raw) = label {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            ensure_label_length(trimmed)?;
            return Ok(trimmed.to_string());
        }
    }
    Ok(default_label(session_id))
}

fn resolve_rename_label(label: Option<String>) -> Result<String, TerminalError> {
    let raw = label.unwrap_or_default();
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(TerminalError::new(
            "invalid_label",
            "Session name cannot be empty.",
        ));
    }
    ensure_label_length(trimmed)?;
    Ok(trimmed.to_string())
}

fn ensure_label_length(label: &str) -> Result<(), TerminalError> {
    if label.chars().count() > MAX_LABEL_LEN {
        return Err(TerminalError::new(
            "invalid_label",
            format!("Session name must be {MAX_LABEL_LEN} characters or fewer."),
        ));
    }
    Ok(())
}

fn validate_size(cols: u16, rows: u16) -> Result<(), TerminalError> {
    if cols < MIN_COLS || cols > MAX_COLS || rows < MIN_ROWS || rows > MAX_ROWS {
        return Err(TerminalError::new(
            "invalid_size",
            format!(
                "Terminal size must be cols {MIN_COLS}-{MAX_COLS} and rows {MIN_ROWS}-{MAX_ROWS}."
            ),
        ));
    }
    Ok(())
}

fn default_label(session_id: &str) -> String {
    let short = session_id.chars().take(6).collect::<String>();
    format!("Terminal {}", short)
}

fn truncate_message(message: &str, max_len: usize) -> String {
    if message.chars().count() <= max_len {
        return message.to_string();
    }
    if max_len <= 3 {
        return message.chars().take(max_len).collect();
    }
    let mut truncated = message.chars().take(max_len - 3).collect::<String>();
    truncated.push_str("...");
    truncated
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
                    session.flush_utf8_carry();
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
                    persist_session_summary(&session);
                    return;
                }
                Ok(count) => {
                    if let Ok(mut session) = session.lock() {
                        session.push_output_bytes(&buffer[..count]);
                    }
                }
                Err(_) => {
                    if let Ok(mut session) = session.lock() {
                        session.flush_utf8_carry();
                        session.status = TerminalSessionStatus::Error;
                        session.last_activity = now_ts();
                        persist_session_summary(&session);
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
        let idle_config = idle_cleanup_config();
        if idle_config.ttl_secs == 0 {
            continue;
        }
        let now = now_ts();
        let mut manager = match manager.lock() {
            Ok(guard) => guard,
            Err(_) => continue,
        };
        let mut expired_ids = Vec::new();
        for (id, session) in manager.sessions.iter() {
            let mut session = match session.lock() {
                Ok(session) => session,
                Err(_) => continue,
            };
            let idle = now.saturating_sub(session.last_activity);
            if idle < idle_config.ttl_secs {
                continue;
            }
            if !session.status.is_ended() {
                let _ = session.child.kill();
                session.status = TerminalSessionStatus::Killed;
                session.exit_code = None;
                session.closed_reason = Some(IDLE_TIMEOUT_REASON.to_string());
            } else if session.closed_reason.is_none() {
                session.closed_reason = Some(IDLE_TIMEOUT_REASON.to_string());
            }
            session.last_activity = now;
            persist_session_summary(&session);
            expired_ids.push(id.clone());
        }
        for id in &expired_ids {
            manager.remove_session(id);
        }
        let active_ids = manager
            .sessions
            .keys()
            .cloned()
            .collect::<HashSet<_>>();
        drop(manager);
        if let Ok(mut history) = terminal_history().lock() {
            let mut changed = false;
            history.sessions.retain(|session_id, summary| {
                if active_ids.contains(session_id) {
                    return true;
                }
                let idle = now.saturating_sub(summary.last_activity);
                if idle >= idle_config.ttl_secs {
                    changed = true;
                    return false;
                }
                true
            });
            if changed {
                history.persist();
            }
        }
    });
}

fn build_session_payload(
    action: &str,
    session_id: &str,
    status: TerminalSessionStatus,
    next_seq: u64,
    output: Vec<TerminalOutputChunk>,
    first_seq: Option<u64>,
    truncated: bool,
    snapshot: Option<String>,
    exit_code: Option<i32>,
    last_activity: u64,
    label: Option<&str>,
    notification_next_seq: u64,
    notifications: Vec<TerminalNotification>,
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
    let mut payload = json!({
        "type": "terminal",
        "action": action,
        "status": status.as_str(),
        "session_id": session_id,
        "output": output_json,
        "next_seq": next_seq,
        "first_seq": first_seq,
        "truncated": truncated,
        "exit_code": exit_code,
        "last_activity": last_activity,
    });
    if let Some(map) = payload.as_object_mut() {
        map.insert("label".to_string(), json!(label.unwrap_or("")));
        map.insert(
            "notification_next_seq".to_string(),
            json!(notification_next_seq),
        );
    }
    if !notifications.is_empty() {
        let notifications_json = notifications
            .into_iter()
            .map(|notification| json!(notification))
            .collect::<Vec<_>>();
        if let Some(map) = payload.as_object_mut() {
            map.insert("notifications".to_string(), json!(notifications_json));
        }
    }
    if let Some(snapshot) = snapshot {
        if let Some(map) = payload.as_object_mut() {
            map.insert("snapshot".to_string(), json!(snapshot));
        }
    }
    payload
}

fn now_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn decode_utf8_stream(carry: &mut Vec<u8>, bytes: &[u8]) -> String {
    if bytes.is_empty() && carry.is_empty() {
        return String::new();
    }
    if carry.is_empty() {
        if let Ok(text) = std::str::from_utf8(bytes) {
            return text.to_string();
        }
    }
    carry.extend_from_slice(bytes);
    let mut output = String::new();
    loop {
        match std::str::from_utf8(carry) {
            Ok(valid) => {
                output.push_str(valid);
                carry.clear();
                break;
            }
            Err(error) => {
                let valid_up_to = error.valid_up_to();
                if valid_up_to > 0 {
                    let valid = &carry[..valid_up_to];
                    output.push_str(unsafe { std::str::from_utf8_unchecked(valid) });
                    carry.drain(..valid_up_to);
                }
                match error.error_len() {
                    Some(len) => {
                        output.push('\u{FFFD}');
                        carry.drain(..len);
                    }
                    None => break,
                }
            }
        }
    }
    output
}
