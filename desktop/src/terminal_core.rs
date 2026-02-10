//! Shared terminal daemon core types and defaults.

use axum::extract::ws::{Message, WebSocket};
use base64::Engine;
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
use std::sync::atomic::{AtomicU64, Ordering};
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
const MAX_HISTORY_SNAPSHOT_CHARS: usize = 200_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalDiscoveryFile {
    pub ws_url: String,
    pub token: String,
    pub version: String,
    #[serde(default)]
    pub daemon_version: Option<String>,
    #[serde(default)]
    pub daemon_binary_path: Option<String>,
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

fn shell_login_args(shell: &str) -> &'static [&'static str] {
    if cfg!(target_os = "windows") {
        return &[];
    }

    let shell_name = Path::new(shell)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(shell);

    match shell_name {
        "zsh" | "bash" | "fish" => &["-il"],
        _ => &[],
    }
}

const LOCALE_ENV_KEYS: &[&str] = &["LC_ALL", "LC_CTYPE", "LANG"];

fn request_env_has_non_empty_value(env: Option<&HashMap<String, String>>, key: &str) -> bool {
    env.and_then(|values| values.get(key))
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
}

fn request_env_contains_any_locale(env: Option<&HashMap<String, String>>) -> bool {
    LOCALE_ENV_KEYS
        .iter()
        .copied()
        .any(|key| request_env_has_non_empty_value(env, key))
}

fn is_utf8_locale(value: &str) -> bool {
    let lowered = value.trim().to_ascii_lowercase();
    lowered.contains("utf-8") || lowered.contains("utf8")
}

fn process_env_effective_locale_is_utf8() -> bool {
    for key in LOCALE_ENV_KEYS.iter().copied() {
        let Ok(value) = std::env::var(key) else {
            continue;
        };
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        return is_utf8_locale(trimmed);
    }
    false
}

fn default_utf8_locale() -> Option<&'static str> {
    if cfg!(target_os = "macos") {
        return Some("en_US.UTF-8");
    }
    if cfg!(target_os = "linux") {
        return Some("C.UTF-8");
    }
    None
}

fn apply_default_utf8_locale_env(
    cmd: &mut CommandBuilder,
    request_env: Option<&HashMap<String, String>>,
) {
    if request_env_contains_any_locale(request_env) || process_env_effective_locale_is_utf8() {
        return;
    }
    if let Some(locale) = default_utf8_locale() {
        cmd.env("LANG", locale);
        cmd.env("LC_CTYPE", locale);
        cmd.env("LC_ALL", locale);
    }
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

pub fn write_discovery_file(discovery: &TerminalDiscoveryFile) -> Result<PathBuf, std::io::Error> {
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

    fn from_summary_status(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "running" => TerminalSessionStatus::Running,
            "killed" => TerminalSessionStatus::Killed,
            "error" => TerminalSessionStatus::Error,
            _ => TerminalSessionStatus::Exited,
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
        let mut dropped_chunks = 0;
        while self.buffer_bytes > MAX_BUFFER_BYTES {
            if let Some(front) = self.buffer.pop_front() {
                self.buffer_bytes = self.buffer_bytes.saturating_sub(front.data.len());
                dropped_chunks += 1;
            } else {
                break;
            }
        }
        if dropped_chunks > 0 {
            record_dropped_chunks(dropped_chunks);
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

    fn notifications_since(&self, since: u64, limit: usize) -> Vec<TerminalNotification> {
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<String>,
    #[serde(default)]
    pub snapshot_truncated: bool,
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

#[derive(Debug, Clone, Copy, Serialize)]
pub struct TerminalMetricsSnapshot {
    pub active_sessions: u64,
    pub dropped_chunks_total: u64,
}

#[derive(Debug, Default)]
struct TerminalMetrics {
    dropped_chunks_total: AtomicU64,
}

impl TerminalMetrics {
    fn record_dropped_chunks(&self, count: u64) {
        if count == 0 {
            return;
        }
        self.dropped_chunks_total
            .fetch_add(count, Ordering::Relaxed);
    }

    fn dropped_chunks_total(&self) -> u64 {
        self.dropped_chunks_total.load(Ordering::Relaxed)
    }
}

static TERMINAL_MANAGER: OnceLock<Arc<Mutex<TerminalManager>>> = OnceLock::new();
static TERMINAL_HISTORY: OnceLock<Arc<Mutex<TerminalSessionHistory>>> = OnceLock::new();
static TERMINAL_METRICS: OnceLock<Arc<TerminalMetrics>> = OnceLock::new();

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

fn normalize_history_entries(sessions: &mut HashMap<String, TerminalSessionSummary>) -> bool {
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

fn terminal_metrics() -> &'static Arc<TerminalMetrics> {
    TERMINAL_METRICS.get_or_init(|| Arc::new(TerminalMetrics::default()))
}

fn active_session_count() -> u64 {
    let manager = terminal_manager();
    let manager = match manager.lock() {
        Ok(manager) => manager,
        Err(_) => return 0,
    };
    let mut count = 0;
    for session in manager.sessions.values() {
        if let Ok(session) = session.lock() {
            if !session.status.is_ended() {
                count += 1;
            }
        }
    }
    count
}

pub fn terminal_metrics_snapshot() -> TerminalMetricsSnapshot {
    let metrics = terminal_metrics();
    TerminalMetricsSnapshot {
        active_sessions: active_session_count(),
        dropped_chunks_total: metrics.dropped_chunks_total(),
    }
}

fn trim_history_snapshot_tail(text: String) -> (String, bool) {
    let char_count = text.chars().count();
    if char_count <= MAX_HISTORY_SNAPSHOT_CHARS {
        return (text, false);
    }
    let truncated = text
        .chars()
        .rev()
        .take(MAX_HISTORY_SNAPSHOT_CHARS)
        .collect::<Vec<char>>()
        .into_iter()
        .rev()
        .collect::<String>();
    (truncated, true)
}

fn session_stream_snapshot(session: &TerminalSession) -> Option<(String, bool)> {
    let mut text = String::new();
    for chunk in session.buffer.iter() {
        text.push_str(&chunk.data);
    }
    if text.trim().is_empty() {
        text = session.snapshot_formatted().unwrap_or_default();
    }
    if text.trim().is_empty() {
        return None;
    }
    let (snapshot, truncated) = trim_history_snapshot_tail(text);
    Some((snapshot, truncated))
}

fn build_session_summary(
    session: &TerminalSession,
    include_snapshot: bool,
) -> TerminalSessionSummary {
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
    let (snapshot, snapshot_truncated) = if include_snapshot {
        match session_stream_snapshot(session) {
            Some((snapshot, truncated)) => (Some(snapshot), truncated),
            None => (None, false),
        }
    } else {
        (None, false)
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
        snapshot,
        snapshot_truncated,
    }
}

fn history_session_summary(session_id: &str) -> Option<TerminalSessionSummary> {
    let history = terminal_history();
    let history = history.lock().ok()?;
    history.sessions.get(session_id).cloned()
}

fn merge_active_summary_into_history(
    history: &mut TerminalSessionHistory,
    summary: &TerminalSessionSummary,
) -> bool {
    match history.sessions.get(&summary.id) {
        Some(existing) => {
            let mut merged = summary.clone();
            merged.snapshot = existing.snapshot.clone();
            merged.snapshot_truncated = existing.snapshot_truncated;
            if *existing == merged {
                return false;
            }
            history.sessions.insert(summary.id.clone(), merged);
            true
        }
        None => {
            history.sessions.insert(summary.id.clone(), summary.clone());
            true
        }
    }
}

fn build_history_session_payload(
    action: &str,
    summary: &TerminalSessionSummary,
    include_snapshot: bool,
) -> Value {
    build_session_payload(
        action,
        summary.id.as_str(),
        TerminalSessionStatus::from_summary_status(summary.status.as_str()),
        0,
        Vec::new(),
        None,
        include_snapshot && summary.snapshot_truncated,
        if include_snapshot {
            summary.snapshot.clone()
        } else {
            None
        },
        summary.exit_code,
        summary.last_activity,
        Some(summary.label.as_str()),
        0,
        Vec::new(),
    )
}

fn persist_session_summary(session: &TerminalSession) {
    let summary = build_session_summary(session, true);
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
            sessions.push(build_session_summary(&session, false));
        }
    }
    let active_ids = sessions
        .iter()
        .map(|session| session.id.clone())
        .collect::<HashSet<_>>();
    if let Ok(mut history) = terminal_history().lock() {
        let mut changed = false;
        for session in &sessions {
            changed = merge_active_summary_into_history(&mut history, session) || changed;
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
                changed = true;
            }
        }
        if changed {
            history.persist();
        }
        for session in history.sessions.values() {
            if !active_ids.contains(&session.id) {
                let mut view = session.clone();
                view.snapshot = None;
                view.snapshot_truncated = false;
                sessions.push(view);
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
        "delete" => delete_session(request),
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
        if initial_truncated {
            initial_snapshot
        } else {
            None
        },
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
                                let data = parsed.get("data").and_then(|value| value.as_str());
                                let data_b64 =
                                    parsed.get("data_b64").and_then(|value| value.as_str());
                                if data.is_some() && data_b64.is_some() {
                                    continue;
                                }
                                let (input, input_bytes) = if let Some(input) = data {
                                    (Some(input.to_string()), None)
                                } else if let Some(encoded) = data_b64 {
                                    let decoded = match base64::engine::general_purpose::STANDARD
                                        .decode(encoded.as_bytes())
                                    {
                                        Ok(bytes) => bytes,
                                        Err(_) => continue,
                                    };
                                    (None, Some(decoded))
                                } else {
                                    continue;
                                };
                                let request = TerminalActionRequest {
                                    action: "input".to_string(),
                                    session_id: Some(session_id.clone()),
                                    label: None,
                                    input,
                                    input_bytes,
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
    let mut cmd = CommandBuilder::new(shell.clone());
    for arg in shell_login_args(&shell) {
        cmd.arg(*arg);
    }
    if let Some(working_dir) = request.working_dir.clone() {
        if !working_dir.trim().is_empty() {
            cmd.cwd(working_dir);
        }
    } else if let Ok(home) = std::env::var("HOME") {
        cmd.cwd(home);
    }
    let request_env = request.env.clone();
    if let Some(env) = request_env.as_ref() {
        for (key, value) in env {
            cmd.env(key, value);
        }
    }
    apply_default_utf8_locale_env(&mut cmd, request_env.as_ref());
    if std::env::var("TERM").is_err()
        && !request_env_has_non_empty_value(request_env.as_ref(), "TERM")
    {
        cmd.env("TERM", "xterm-256color");
    }
    if !request_env_has_non_empty_value(request_env.as_ref(), "COLORTERM") {
        cmd.env("COLORTERM", "truecolor");
    }

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

    log_session_event(
        "session_start",
        "info",
        json!({
            "session_id": session_id.as_str(),
            "label": label.as_str(),
            "cols": cols,
            "rows": rows,
            "created_at": now,
        }),
    );

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
    let since = request.since.unwrap_or(0);
    let notify_since = request.notify_since.unwrap_or(0);
    let limit = request.limit.unwrap_or(OUTPUT_LIMIT_DEFAULT);

    let manager = terminal_manager();
    let session = {
        let manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        manager.session(&session_id)
    };

    if let Some(session) = session {
        let session = session
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
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
        return Ok(build_session_payload(
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
        ));
    }

    if let Some(summary) = history_session_summary(&session_id) {
        let include_snapshot = since == 0;
        return Ok(build_history_session_payload(
            "poll",
            &summary,
            include_snapshot,
        ));
    }

    Err(TerminalError::new(
        "session_not_found",
        "Session not found.",
    ))
}

fn input_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let input_bytes = match (request.input, request.input_bytes) {
        (Some(input), None) => terminal_input_string_to_bytes(input),
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
    let input_bytes = normalize_terminal_input_bytes(input_bytes);
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

fn terminal_input_string_to_bytes(input: String) -> Vec<u8> {
    if input.is_empty() {
        return Vec::new();
    }
    if input.is_ascii() {
        return input.into_bytes();
    }

    let all_latin1 = input.chars().all(|ch| (ch as u32) <= 0x00FF);
    if all_latin1 {
        let has_c1_or_control = input.chars().any(|ch| {
            let code = ch as u32;
            matches!(code, 0x00..=0x1F | 0x7F..=0x9F)
        });
        if has_c1_or_control {
            return input.chars().map(|ch| ch as u8).collect();
        }
    }

    input.into_bytes()
}

fn normalize_terminal_input_bytes(input: Vec<u8>) -> Vec<u8> {
    if !looks_like_utf16le_input(&input) {
        return input;
    }
    let Some(decoded) = decode_utf16le_input(&input) else {
        return input;
    };
    if !looks_like_readable_terminal_text(&decoded) {
        return input;
    }
    decoded.into_bytes()
}

fn looks_like_utf16le_input(bytes: &[u8]) -> bool {
    if bytes.len() < 2 || bytes.len() % 2 != 0 {
        return false;
    }
    if has_utf16le_null_pattern(bytes) {
        return true;
    }
    bytes.iter().any(|byte| *byte >= 0x80) && !is_valid_utf8(bytes)
}

fn has_utf16le_null_pattern(bytes: &[u8]) -> bool {
    if bytes.len() < 4 || bytes.len() % 2 != 0 {
        return false;
    }
    let pair_count = bytes.len() / 2;
    let null_high_bytes = bytes
        .iter()
        .skip(1)
        .step_by(2)
        .filter(|value| **value == 0)
        .count();
    null_high_bytes * 10 >= pair_count * 6
}

fn is_valid_utf8(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).is_ok()
}

fn decode_utf16le_input(bytes: &[u8]) -> Option<String> {
    if bytes.len() < 2 || bytes.len() % 2 != 0 {
        return None;
    }
    let mut code_units = Vec::with_capacity(bytes.len() / 2);
    for chunk in bytes.chunks_exact(2) {
        code_units.push(u16::from_le_bytes([chunk[0], chunk[1]]));
    }
    String::from_utf16(&code_units).ok()
}

fn looks_like_readable_terminal_text(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    let mut printable = 0usize;
    for ch in text.chars() {
        if !is_readable_terminal_char(ch) {
            return false;
        }
        if !ch.is_whitespace() {
            printable += 1;
        }
    }
    printable > 0
}

fn is_readable_terminal_char(ch: char) -> bool {
    matches!(ch, '\t' | '\n' | '\r') || !ch.is_control()
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
        manager.session(&session_id)
    };

    if let Some(session) = session {
        let mut session = session
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
        let _ = session.child.kill();
        session.status = TerminalSessionStatus::Killed;
        session.exit_code = None;
        session.last_activity = now_ts();
        persist_session_summary(&session);
        let reason = if request.action == "kill" {
            "kill"
        } else {
            "stop"
        };
        log_session_event(
            "session_stop",
            "info",
            json!({
                "session_id": session.id.as_str(),
                "label": session.label.as_str(),
                "reason": reason,
                "status": session.status.as_str(),
            }),
        );
        return Ok(build_session_payload(
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
        ));
    }

    if let Some(summary) = history_session_summary(&session_id) {
        return Ok(build_history_session_payload("stop", &summary, true));
    }

    Err(TerminalError::new(
        "session_not_found",
        "Session not found.",
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
        manager.session(&session_id)
    };

    if let Some(session) = session {
        let session = session
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
        let snapshot = session.snapshot_formatted();
        let notify_since = request.notify_since.unwrap_or(0);
        let notifications = session.notifications_since(notify_since, NOTIFICATION_QUEUE_LIMIT);
        return Ok(build_session_payload(
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
        ));
    }

    if let Some(summary) = history_session_summary(&session_id) {
        return Ok(build_history_session_payload("status", &summary, true));
    }

    Err(TerminalError::new(
        "session_not_found",
        "Session not found.",
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
        manager.session(&session_id)
    };

    if let Some(session) = session {
        let mut session = session
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Session unavailable."))?;
        if session.label != label {
            session.label = label.clone();
            session.last_activity = now_ts();
            persist_session_summary(&session);
        }
        return Ok(build_session_payload(
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
        ));
    }

    let history = terminal_history();
    let mut history = history
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Terminal history unavailable."))?;
    let mut changed = false;
    let payload_summary = {
        let summary = history
            .sessions
            .get_mut(&session_id)
            .ok_or_else(|| TerminalError::new("session_not_found", "Session not found."))?;
        if summary.label != label {
            summary.label = label.clone();
            summary.last_activity = now_ts();
            changed = true;
        }
        summary.clone()
    };
    if changed {
        history.persist();
    }
    Ok(build_history_session_payload(
        "rename",
        &payload_summary,
        false,
    ))
}

fn delete_session(request: TerminalActionRequest) -> Result<Value, TerminalError> {
    let session_id = required_session_id(request.session_id)?;
    let mut removed_active = false;
    let manager = terminal_manager();
    {
        let mut manager = manager
            .lock()
            .map_err(|_| TerminalError::new("state_locked", "Terminal state unavailable."))?;
        if let Some(session) = manager.session(&session_id) {
            if let Ok(mut session) = session.lock() {
                if !session.status.is_ended() {
                    let _ = session.child.kill();
                    session.status = TerminalSessionStatus::Killed;
                    session.exit_code = None;
                    session.closed_reason = Some("Deleted by user.".to_string());
                    session.last_activity = now_ts();
                }
            }
            manager.remove_session(&session_id);
            removed_active = true;
        }
    }

    let history = terminal_history();
    let mut history = history
        .lock()
        .map_err(|_| TerminalError::new("state_locked", "Terminal history unavailable."))?;
    let removed_history = history.sessions.remove(&session_id).is_some();
    if removed_history {
        history.persist();
    }

    if !removed_active && !removed_history {
        return Err(TerminalError::new(
            "session_not_found",
            "Session not found.",
        ));
    }

    Ok(json!({
        "type": "terminal",
        "action": "delete",
        "session_id": session_id,
        "status": "deleted",
        "removed_active": removed_active,
        "removed_history": removed_history,
        "last_activity": now_ts(),
    }))
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
    let session_id =
        session_id.ok_or_else(|| TerminalError::new("missing_session", "Missing session id."))?;
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

fn record_dropped_chunks(count: u64) {
    let metrics = terminal_metrics();
    metrics.record_dropped_chunks(count);
}

fn log_session_event(event: &str, level: &str, data: Value) {
    let payload = json!({
        "ts": now_ts(),
        "component": "terminald",
        "event": event,
        "level": level,
        "data": data,
    });
    println!("{}", payload);
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
                    if session.status == TerminalSessionStatus::Exited {
                        log_session_event(
                            "session_exit",
                            "info",
                            json!({
                                "session_id": session.id.as_str(),
                                "label": session.label.as_str(),
                                "exit_code": session.exit_code,
                            }),
                        );
                    }
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
                        log_session_event(
                            "session_error",
                            "error",
                            json!({
                                "session_id": session.id.as_str(),
                                "label": session.label.as_str(),
                                "reason": "reader_error",
                            }),
                        );
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
                log_session_event(
                    "session_stop",
                    "info",
                    json!({
                        "session_id": session.id.as_str(),
                        "label": session.label.as_str(),
                        "reason": "idle_timeout",
                        "status": session.status.as_str(),
                    }),
                );
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
        drop(manager);
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
                    let valid_text =
                        std::str::from_utf8(valid).expect("valid UTF-8 slice from parser boundary");
                    output.push_str(valid_text);
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

#[cfg(test)]
mod tests {
    use super::*;
    use portable_pty::CommandBuilder;

    struct ManagedSession {
        session_id: String,
        session: Arc<Mutex<TerminalSession>>,
    }

    impl ManagedSession {
        fn new(session_id: &str, rows: u16, cols: u16) -> Self {
            let session = Arc::new(Mutex::new(build_session(session_id, rows, cols)));
            let manager = terminal_manager();
            let mut manager = manager.lock().expect("manager lock");
            manager.insert_session(session.clone());
            Self {
                session_id: session_id.to_string(),
                session,
            }
        }
    }

    impl Drop for ManagedSession {
        fn drop(&mut self) {
            if let Ok(mut session) = self.session.lock() {
                let _ = session.child.kill();
            }
            if let Ok(mut manager) = terminal_manager().lock() {
                manager.remove_session(&self.session_id);
            }
        }
    }

    fn build_session(session_id: &str, rows: u16, cols: u16) -> TerminalSession {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("open pty");
        let child = pair
            .slave
            .spawn_command(test_command())
            .expect("spawn pty child");
        let writer = pair.master.take_writer().expect("pty writer");
        let now = now_ts();
        TerminalSession {
            id: session_id.to_string(),
            label: format!("Test {session_id}"),
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
        }
    }

    fn test_command() -> CommandBuilder {
        if cfg!(windows) {
            let mut cmd = CommandBuilder::new("cmd.exe");
            cmd.arg("/C");
            cmd.arg("ping");
            cmd.arg("127.0.0.1");
            cmd.arg("-n");
            cmd.arg("5");
            cmd
        } else {
            let mut cmd = CommandBuilder::new("sh");
            cmd.arg("-c");
            cmd.arg("sleep 5");
            cmd
        }
    }

    #[test]
    fn seq_ordering_increments() {
        let mut session = build_session("seq-order", 10, 20);
        session.push_output_bytes(b"first");
        session.push_output_bytes(b"second");
        session.push_output_bytes(b"third");

        let seqs = session
            .buffer
            .iter()
            .map(|chunk| chunk.seq)
            .collect::<Vec<_>>();
        assert_eq!(seqs, vec![1, 2, 3]);

        let output = session.output_since(0, 10);
        let output_seqs = output.iter().map(|chunk| chunk.seq).collect::<Vec<_>>();
        assert_eq!(output_seqs, vec![1, 2, 3]);
        assert_eq!(next_expected_seq(session.next_seq), 4);
        let _ = session.child.kill();
    }

    #[test]
    fn utf8_chunks_reassemble() {
        let mut session = build_session("utf8-reassemble", 10, 20);
        let bytes = "\u{2603}".as_bytes();
        session.push_output_bytes(&bytes[..2]);
        assert!(session.buffer.is_empty());
        session.push_output_bytes(&bytes[2..]);
        let chunk = session.buffer.back().expect("chunk");
        assert_eq!(chunk.data, "\u{2603}");
        let _ = session.child.kill();
    }

    #[test]
    fn malformed_utf8_replaced() {
        let mut session = build_session("utf8-invalid", 10, 20);
        session.push_output_bytes(&[0xF0]);
        session.push_output_bytes(&[0x28, 0x8C, 0x28]);
        let chunk = session.buffer.back().expect("chunk");
        assert!(chunk.data.contains('\u{FFFD}'));
        let _ = session.child.kill();
    }

    #[test]
    fn login_args_match_platform_shell_expectations() {
        #[cfg(windows)]
        {
            assert!(shell_login_args("powershell.exe").is_empty());
            assert!(shell_login_args("cmd.exe").is_empty());
        }

        #[cfg(not(windows))]
        {
            assert_eq!(shell_login_args("/bin/zsh"), &["-il"]);
            assert_eq!(shell_login_args("/bin/bash"), &["-il"]);
            assert_eq!(shell_login_args("/opt/homebrew/bin/fish"), &["-il"]);
        }
    }

    #[test]
    fn login_args_disabled_for_non_login_shells() {
        assert!(shell_login_args("/bin/sh").is_empty());
    }

    #[test]
    fn request_env_contains_any_locale_detects_lang_and_ctype() {
        let mut env = HashMap::new();
        env.insert("LANG".to_string(), "zh_CN.UTF-8".to_string());
        assert!(request_env_contains_any_locale(Some(&env)));

        env.remove("LANG");
        env.insert("LC_CTYPE".to_string(), "en_US.UTF-8".to_string());
        assert!(request_env_contains_any_locale(Some(&env)));
    }

    #[test]
    fn request_env_contains_any_locale_ignores_empty_values() {
        let mut env = HashMap::new();
        env.insert("LANG".to_string(), "   ".to_string());
        assert!(!request_env_contains_any_locale(Some(&env)));
    }

    #[test]
    fn default_utf8_locale_matches_platform() {
        #[cfg(target_os = "macos")]
        assert_eq!(default_utf8_locale(), Some("en_US.UTF-8"));

        #[cfg(target_os = "linux")]
        assert_eq!(default_utf8_locale(), Some("C.UTF-8"));

        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        assert_eq!(default_utf8_locale(), None);
    }

    #[test]
    fn utf8_locale_detector_matches_common_values() {
        assert!(is_utf8_locale("en_US.UTF-8"));
        assert!(is_utf8_locale("C.UTF8"));
        assert!(!is_utf8_locale("C"));
    }

    #[test]
    fn normalize_terminal_input_bytes_decodes_utf16le_multibyte_text() {
        let mut utf16_bytes = Vec::new();
        for unit in "中文输入✓🚀".encode_utf16() {
            utf16_bytes.extend_from_slice(&unit.to_le_bytes());
        }

        let normalized = normalize_terminal_input_bytes(utf16_bytes);

        assert_eq!(String::from_utf8(normalized).expect("utf8"), "中文输入✓🚀");
    }

    #[test]
    fn normalize_terminal_input_bytes_decodes_utf16le_ascii_text() {
        let utf16_bytes = vec![
            b'e', 0, b'c', 0, b'h', 0, b'o', 0, b' ', 0, b'h', 0, b'i', 0, b'\n', 0,
        ];

        let normalized = normalize_terminal_input_bytes(utf16_bytes);

        assert_eq!(normalized, b"echo hi\n");
    }

    #[test]
    fn terminal_input_string_to_bytes_preserves_byte_stream_codepoints() {
        let input: String = [0x0093u16, 0x0088u16]
            .into_iter()
            .map(|unit| char::from_u32(unit as u32).expect("char"))
            .collect();

        let bytes = terminal_input_string_to_bytes(input);

        assert_eq!(bytes, vec![0x93, 0x88]);
    }

    #[test]
    fn terminal_input_string_to_bytes_keeps_utf8_for_latin1_printable_text() {
        let bytes = terminal_input_string_to_bytes("café".to_string());

        assert_eq!(bytes, "café".as_bytes());
    }

    #[test]
    fn terminal_input_string_to_bytes_keeps_utf8_for_unicode_text() {
        let bytes = terminal_input_string_to_bytes("中文输入".to_string());

        assert_eq!(bytes, "中文输入".as_bytes());
    }

    #[test]
    fn normalize_terminal_input_bytes_preserves_escape_sequences() {
        let bytes = vec![27, 91, 65];
        assert_eq!(normalize_terminal_input_bytes(bytes.clone()), bytes);
    }

    #[test]
    fn buffer_truncation_triggers_snapshot() {
        let managed = ManagedSession::new("truncate-buffer", 10, 20);
        let chunk = vec![b'x'; 4096];
        {
            let mut session = managed.session.lock().expect("session lock");
            let mut total = 0usize;
            while total <= MAX_BUFFER_BYTES + chunk.len() {
                session.push_output_bytes(&chunk);
                total += chunk.len();
            }
            assert!(session.buffer_bytes <= MAX_BUFFER_BYTES);
            let first_seq = session.first_seq().expect("first seq");
            assert!(first_seq > 1);
        }
        let payload = match poll_session(TerminalActionRequest {
            action: "poll".to_string(),
            session_id: Some(managed.session_id.clone()),
            label: None,
            input: None,
            input_bytes: None,
            cols: None,
            rows: None,
            since: Some(0),
            limit: None,
            notify_since: Some(0),
            working_dir: None,
            env: None,
        }) {
            Ok(payload) => payload,
            Err(error) => panic!("poll payload failed: {}", error.code),
        };
        assert_eq!(
            payload.get("truncated").and_then(Value::as_bool),
            Some(true)
        );
        assert!(payload.get("snapshot").and_then(Value::as_str).is_some());
    }

    #[test]
    fn resize_updates_session_size() {
        let managed = ManagedSession::new("resize-session", 12, 24);
        let payload = match resize_session(TerminalActionRequest {
            action: "resize".to_string(),
            session_id: Some(managed.session_id.clone()),
            label: None,
            input: None,
            input_bytes: None,
            cols: Some(80),
            rows: Some(40),
            since: None,
            limit: None,
            notify_since: None,
            working_dir: None,
            env: None,
        }) {
            Ok(payload) => payload,
            Err(error) => panic!("resize payload failed: {}", error.code),
        };
        assert_eq!(
            payload.get("action").and_then(Value::as_str),
            Some("resize")
        );
        let session = managed.session.lock().expect("session lock");
        assert_eq!(session.cols, 80);
        assert_eq!(session.rows, 40);
        assert_eq!(session.parser.screen().size(), (40, 80));
    }

    #[test]
    fn resize_rejects_invalid_size() {
        let managed = ManagedSession::new("resize-invalid", 12, 24);
        let error = match resize_session(TerminalActionRequest {
            action: "resize".to_string(),
            session_id: Some(managed.session_id.clone()),
            label: None,
            input: None,
            input_bytes: None,
            cols: Some(5),
            rows: Some(2),
            since: None,
            limit: None,
            notify_since: None,
            working_dir: None,
            env: None,
        }) {
            Ok(_) => panic!("expected invalid size error"),
            Err(error) => error,
        };
        assert_eq!(error.code, "invalid_size");
    }

    fn remove_history_entry(session_id: &str) {
        if let Ok(mut history) = terminal_history().lock() {
            if history.sessions.remove(session_id).is_some() {
                history.persist();
            }
        }
    }

    #[test]
    fn status_session_uses_history_when_session_not_active() {
        let session_id = "history-status-session";
        remove_history_entry(session_id);
        let now = now_ts();
        {
            let mut history = terminal_history().lock().expect("history lock");
            history.sessions.insert(
                session_id.to_string(),
                TerminalSessionSummary {
                    id: session_id.to_string(),
                    label: "History Session".to_string(),
                    status: "exited".to_string(),
                    created_at: now.saturating_sub(10),
                    last_activity: now,
                    exit_code: Some(0),
                    last_output: "echo hi".to_string(),
                    closed_reason: Some("Ended".to_string()),
                    snapshot: Some("$ echo hi\nhi\n".to_string()),
                    snapshot_truncated: false,
                },
            );
            history.persist();
        }

        let payload = match status_session(TerminalActionRequest {
            action: "status".to_string(),
            session_id: Some(session_id.to_string()),
            label: None,
            input: None,
            input_bytes: None,
            cols: None,
            rows: None,
            since: None,
            limit: None,
            notify_since: Some(0),
            working_dir: None,
            env: None,
        }) {
            Ok(payload) => payload,
            Err(error) => panic!("status payload failed: {}", error.code),
        };

        assert_eq!(
            payload.get("session_id").and_then(Value::as_str),
            Some(session_id)
        );
        assert_eq!(
            payload.get("status").and_then(Value::as_str),
            Some("exited")
        );
        assert_eq!(
            payload.get("snapshot").and_then(Value::as_str),
            Some("$ echo hi\nhi\n")
        );

        remove_history_entry(session_id);
    }

    #[test]
    fn stop_session_returns_history_payload_for_ended_session() {
        let session_id = "history-stop-session";
        remove_history_entry(session_id);
        let now = now_ts();
        {
            let mut history = terminal_history().lock().expect("history lock");
            history.sessions.insert(
                session_id.to_string(),
                TerminalSessionSummary {
                    id: session_id.to_string(),
                    label: "Ended Session".to_string(),
                    status: "killed".to_string(),
                    created_at: now.saturating_sub(20),
                    last_activity: now,
                    exit_code: None,
                    last_output: "last line".to_string(),
                    closed_reason: Some("Disconnected".to_string()),
                    snapshot: Some("$ ls\n".to_string()),
                    snapshot_truncated: false,
                },
            );
            history.persist();
        }

        let payload = match stop_session(TerminalActionRequest {
            action: "stop".to_string(),
            session_id: Some(session_id.to_string()),
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
        }) {
            Ok(payload) => payload,
            Err(error) => panic!("stop payload failed: {}", error.code),
        };

        assert_eq!(
            payload.get("session_id").and_then(Value::as_str),
            Some(session_id)
        );
        assert_eq!(
            payload.get("status").and_then(Value::as_str),
            Some("killed")
        );

        remove_history_entry(session_id);
    }

    #[test]
    fn delete_session_removes_history_entry() {
        let session_id = "history-delete-session";
        remove_history_entry(session_id);
        let now = now_ts();
        {
            let mut history = terminal_history().lock().expect("history lock");
            history.sessions.insert(
                session_id.to_string(),
                TerminalSessionSummary {
                    id: session_id.to_string(),
                    label: "Delete Session".to_string(),
                    status: "exited".to_string(),
                    created_at: now.saturating_sub(10),
                    last_activity: now,
                    exit_code: Some(0),
                    last_output: "done".to_string(),
                    closed_reason: None,
                    snapshot: Some("done\n".to_string()),
                    snapshot_truncated: false,
                },
            );
            history.persist();
        }

        let payload = match delete_session(TerminalActionRequest {
            action: "delete".to_string(),
            session_id: Some(session_id.to_string()),
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
        }) {
            Ok(payload) => payload,
            Err(error) => panic!("delete payload failed: {}", error.code),
        };

        assert_eq!(
            payload.get("status").and_then(Value::as_str),
            Some("deleted")
        );
        let history = terminal_history().lock().expect("history lock");
        assert!(!history.sessions.contains_key(session_id));
    }
}
