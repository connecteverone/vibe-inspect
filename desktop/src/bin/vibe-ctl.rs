use base64::Engine;
use clap::{Args, Parser, Subcommand};
use crossterm::terminal;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use desktop::terminal_core::{
    read_discovery_file, terminal_discovery_path, TerminalSessionSummary, DEFAULT_TERMINALD_WS_URL,
    TERMINALD_PROTOCOL_VERSION,
};
use desktop::terminald_launcher::start_terminald_with_fallback;
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
#[cfg(unix)]
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::mpsc;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

const ENV_TERMINALD_CONFIG: &str = "VIBE_CTL_CONFIG";
const ENV_TERMINALD_ENDPOINT: &str = "VIBE_CTL_ENDPOINT";
const ENV_TERMINALD_TOKEN: &str = "VIBE_CTL_TOKEN";
const ENV_TERMINALD_AUTOSTART: &str = "VIBE_TERMINALD_AUTOSTART";
const TERMINALD_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const TERMINALD_AUTOSTART_TIMEOUT: Duration = Duration::from_secs(3);
const TERMINALD_DISCOVERY_POLL: Duration = Duration::from_millis(150);

type TerminaldSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
type TerminaldSink = futures_util::stream::SplitSink<TerminaldSocket, TungsteniteMessage>;
type TerminaldStream = futures_util::stream::SplitStream<TerminaldSocket>;

#[derive(Debug, Parser)]
#[command(
    name = "vibe-ctl",
    about = "CLI for managing terminald sessions",
    version,
    arg_required_else_help = true
)]
struct Cli {
    /// Override the discovery endpoint URL.
    #[arg(long, global = true, value_name = "WS_URL")]
    endpoint: Option<String>,
    /// Override the discovery auth token.
    #[arg(long, global = true, value_name = "TOKEN")]
    token: Option<String>,
    /// Override the discovery file path.
    #[arg(long, global = true, value_name = "PATH")]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// List terminal sessions.
    Ls(LsArgs),
    /// Create a new session.
    New(NewArgs),
    /// Attach to a session.
    #[command(alias = "a")]
    Attach(AttachArgs),
    /// Send input to a session.
    Send(SendArgs),
    /// Resize a session.
    Resize(ResizeArgs),
    /// Rename a session.
    Rename(RenameArgs),
    /// Stop a session.
    #[command(alias = "kill")]
    Stop(StopArgs),
    /// Show terminald server info and metrics.
    Debug,
    /// Print the resolved terminald endpoint.
    Defaults,
}

#[derive(Debug, Args)]
struct LsArgs {
    /// Output machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Args)]
struct NewArgs {
    /// Session label.
    #[arg(short = 's', long = "name", value_name = "LABEL")]
    name: Option<String>,
    /// Working directory.
    #[arg(long, value_name = "DIR")]
    cwd: Option<String>,
    /// Terminal columns.
    #[arg(long, value_name = "N")]
    cols: Option<u16>,
    /// Terminal rows.
    #[arg(long, value_name = "N")]
    rows: Option<u16>,
    /// Environment overrides (KEY=VALUE).
    #[arg(long = "env", value_name = "KEY=VALUE")]
    env: Vec<String>,
}

#[derive(Debug, Args)]
struct AttachArgs {
    /// Target session id.
    #[arg(short = 't', long = "target", value_name = "ID")]
    target: String,
    /// Disable input forwarding.
    #[arg(long)]
    read_only: bool,
    /// Detach key sequence (two keys, e.g. "Ctrl-b d").
    #[arg(long, value_name = "KEYS", default_value = "Ctrl-b d")]
    detach_key: String,
    /// Detach timeout in milliseconds.
    #[arg(long, value_name = "MS", default_value_t = 1000)]
    detach_timeout_ms: u64,
    /// Disable raw mode for debugging.
    #[arg(long)]
    no_raw: bool,
}

#[derive(Debug, Args)]
struct SendArgs {
    /// Target session id.
    #[arg(short = 't', long = "target", value_name = "ID")]
    target: String,
    /// Read input from a file.
    #[arg(long, value_name = "PATH")]
    file: Option<PathBuf>,
    /// Input string to send.
    #[arg(value_name = "DATA", required_unless_present = "file")]
    data: Option<String>,
}

#[derive(Debug, Args)]
struct ResizeArgs {
    /// Target session id.
    #[arg(short = 't', long = "target", value_name = "ID")]
    target: String,
    /// Terminal columns.
    #[arg(long, value_name = "N")]
    cols: u16,
    /// Terminal rows.
    #[arg(long, value_name = "N")]
    rows: u16,
}

#[derive(Debug, Args)]
struct RenameArgs {
    /// Target session id.
    #[arg(short = 't', long = "target", value_name = "ID")]
    target: String,
    /// New label.
    #[arg(value_name = "LABEL")]
    label: String,
}

#[derive(Debug, Args)]
struct StopArgs {
    /// Target session id.
    #[arg(short = 't', long = "target", value_name = "ID")]
    target: String,
    /// Force stop (kill).
    #[arg(long)]
    force: bool,
}

fn main() {
    let cli = Cli::parse();
    let runtime = Runtime::new().expect("failed to start runtime");
    if let Err(error) = runtime.block_on(run(cli)) {
        eprintln!("{}: {}", error.code, error.message);
        std::process::exit(1);
    }
}

async fn run(cli: Cli) -> Result<(), CliError> {
    let overrides = ConfigOverrides {
        endpoint: cli.endpoint.clone(),
        token: cli.token.clone(),
        config: cli.config.clone(),
    };

    match cli.command {
        Command::Defaults => {
            let config = resolve_config(&overrides)?;
            println!("{}", config.ws_url);
        }
        Command::Ls(args) => {
            let data = terminald_request(&overrides, "list", None, None).await?;
            if args.json {
                let payload = serde_json::to_string_pretty(&data).map_err(|error| {
                    CliError::new(
                        "connection_failed",
                        format!("Failed to format JSON: {error}"),
                    )
                })?;
                println!("{payload}");
            } else {
                let sessions_value = data
                    .get("sessions")
                    .cloned()
                    .unwrap_or(Value::Array(Vec::new()));
                let sessions: Vec<TerminalSessionSummary> = serde_json::from_value(sessions_value)
                    .map_err(|error| {
                        CliError::new(
                            "connection_failed",
                            format!("Failed to parse sessions: {error}"),
                        )
                    })?;
                print_sessions(&sessions);
            }
        }
        Command::New(args) => {
            let payload = build_start_payload(&args)?;
            let data = terminald_request(&overrides, "start", None, payload).await?;
            let session_id = extract_session_id(&data).ok_or_else(|| {
                CliError::new("connection_failed", "Missing session_id in response.")
            })?;
            println!("{session_id}");
        }
        Command::Attach(args) => {
            attach_session(&overrides, args).await?;
        }
        Command::Send(args) => {
            let payload = build_input_payload(&args)?;
            terminald_request(&overrides, "input", Some(args.target), Some(payload)).await?;
        }
        Command::Resize(args) => {
            let payload = json!({ "cols": args.cols, "rows": args.rows });
            terminald_request(&overrides, "resize", Some(args.target), Some(payload)).await?;
        }
        Command::Rename(args) => {
            let payload = json!({ "label": args.label });
            terminald_request(&overrides, "rename", Some(args.target), Some(payload)).await?;
        }
        Command::Stop(args) => {
            let action = if args.force { "kill" } else { "stop" };
            terminald_request(&overrides, action, Some(args.target), None).await?;
        }
        Command::Debug => {
            let data = terminald_request(&overrides, "debug", None, None).await?;
            print_debug_info(&data)?;
        }
    }
    Ok(())
}

fn print_sessions(sessions: &[TerminalSessionSummary]) {
    println!("id\tlabel\tstatus\tlast_activity");
    for session in sessions {
        println!(
            "{}\t{}\t{}\t{}",
            session.id, session.label, session.status, session.last_activity
        );
    }
}

fn print_debug_info(data: &Value) -> Result<(), CliError> {
    let server_info = data
        .get("server_info")
        .and_then(|value| value.as_object())
        .ok_or_else(|| CliError::new("connection_failed", "Missing server_info in response."))?;
    let metrics = data
        .get("metrics")
        .and_then(|value| value.as_object())
        .ok_or_else(|| CliError::new("connection_failed", "Missing metrics in response."))?;

    let version = server_info
        .get("version")
        .and_then(|value| value.as_str())
        .unwrap_or("unknown");
    let server_time = server_info
        .get("server_time")
        .and_then(|value| value.as_u64())
        .unwrap_or_default();
    let capabilities = server_info
        .get("capabilities")
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|value| value.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_else(|| "unknown".to_string());

    let active_sessions = read_metric(metrics, "active_sessions")?;
    let active_connections = read_metric(metrics, "active_connections")?;
    let dropped_chunks_total = read_metric(metrics, "dropped_chunks_total")?;
    let ws_backpressure_events_total = read_metric(metrics, "ws_backpressure_events_total")?;
    let ws_auth_attempts_total = read_metric_or_default(metrics, "ws_auth_attempts_total");
    let ws_auth_success_total = read_metric_or_default(metrics, "ws_auth_success_total");
    let reconnect_success_rate_percent =
        read_metric_or_default(metrics, "reconnect_success_rate_percent");
    let pause_duration_p50_ms = read_metric_or_default(metrics, "pause_duration_p50_ms");
    let pause_duration_p95_ms = read_metric_or_default(metrics, "pause_duration_p95_ms");
    let pause_duration_samples_total =
        read_metric_or_default(metrics, "pause_duration_samples_total");

    println!("server_version: {version}");
    println!("server_time: {server_time}");
    println!("capabilities: {capabilities}");
    println!("active_sessions: {active_sessions}");
    println!("active_connections: {active_connections}");
    println!("dropped_chunks_total: {dropped_chunks_total}");
    println!("ws_backpressure_events_total: {ws_backpressure_events_total}");
    println!("ws_auth_attempts_total: {ws_auth_attempts_total}");
    println!("ws_auth_success_total: {ws_auth_success_total}");
    println!("reconnect_success_rate_percent: {reconnect_success_rate_percent}");
    println!("pause_duration_p50_ms: {pause_duration_p50_ms}");
    println!("pause_duration_p95_ms: {pause_duration_p95_ms}");
    println!("pause_duration_samples_total: {pause_duration_samples_total}");
    Ok(())
}

fn read_metric(metrics: &serde_json::Map<String, Value>, key: &str) -> Result<u64, CliError> {
    metrics
        .get(key)
        .and_then(|value| value.as_u64())
        .ok_or_else(|| {
            CliError::new(
                "connection_failed",
                format!("Missing metric '{key}' in response."),
            )
        })
}

fn read_metric_or_default(metrics: &serde_json::Map<String, Value>, key: &str) -> u64 {
    metrics
        .get(key)
        .and_then(|value| value.as_u64())
        .unwrap_or(0)
}

fn build_start_payload(args: &NewArgs) -> Result<Option<Value>, CliError> {
    let mut payload = Map::new();
    if let Some(label) = args.name.as_ref() {
        payload.insert("label".to_string(), json!(label));
    }
    if let Some(cols) = args.cols {
        payload.insert("cols".to_string(), json!(cols));
    }
    if let Some(rows) = args.rows {
        payload.insert("rows".to_string(), json!(rows));
    }
    if let Some(working_dir) = args.cwd.as_ref() {
        payload.insert("working_dir".to_string(), json!(working_dir));
    }
    if let Some(env) = parse_env(&args.env)? {
        payload.insert("env".to_string(), json!(env));
    }
    if payload.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Value::Object(payload)))
    }
}

fn parse_env(values: &[String]) -> Result<Option<HashMap<String, String>>, CliError> {
    if values.is_empty() {
        return Ok(None);
    }
    let mut env = HashMap::new();
    for entry in values {
        let (key, value) = entry.split_once('=').ok_or_else(|| {
            CliError::new(
                "invalid_request",
                format!("Invalid env '{entry}', expected KEY=VALUE."),
            )
        })?;
        let trimmed_key = key.trim();
        if trimmed_key.is_empty() {
            return Err(CliError::new(
                "invalid_request",
                "Environment key cannot be empty.",
            ));
        }
        env.insert(trimmed_key.to_string(), value.to_string());
    }
    Ok(Some(env))
}

fn build_input_payload(args: &SendArgs) -> Result<Value, CliError> {
    if args.file.is_some() && args.data.is_some() {
        return Err(CliError::new(
            "invalid_request",
            "Provide either --file or input text, not both.",
        ));
    }
    let mut payload = Map::new();
    if let Some(path) = args.file.as_ref() {
        let bytes = fs::read(path).map_err(|error| {
            CliError::new(
                "invalid_request",
                format!("Failed to read file {}: {error}", path.display()),
            )
        })?;
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        payload.insert("data_b64".to_string(), json!(encoded));
    } else if let Some(data) = args.data.as_ref() {
        payload.insert("data".to_string(), json!(data));
    }
    if payload.is_empty() {
        return Err(CliError::new("missing_input", "Input is required."));
    }
    Ok(Value::Object(payload))
}

struct DetachSequence {
    prefix: u8,
    key: u8,
    timeout: Duration,
}

struct RawModeGuard {
    enabled: bool,
}

impl RawModeGuard {
    fn new(enable: bool) -> Result<Self, CliError> {
        if enable {
            enable_raw_mode().map_err(|error| {
                CliError::new(
                    "terminal_error",
                    format!("Failed to enable raw mode: {error}"),
                )
            })?;
        }
        Ok(Self { enabled: enable })
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if self.enabled {
            let _ = disable_raw_mode();
        }
    }
}

async fn attach_session(overrides: &ConfigOverrides, args: AttachArgs) -> Result<(), CliError> {
    let detach_sequence = parse_detach_sequence(&args.detach_key, args.detach_timeout_ms)?;
    let socket = connect_terminald(overrides).await?;
    let (mut sender, mut receiver) = socket.split();

    let attach_id = random_request_id();
    let attach_request = build_terminald_request(
        &attach_id,
        "attach",
        Some(args.target.clone()),
        Some(json!({
            "since": 0,
            "notify_since": 0,
        })),
    );
    sender
        .send(TungsteniteMessage::Text(attach_request.to_string().into()))
        .await
        .map_err(|error| {
            CliError::new(
                "connection_failed",
                format!("Failed to send attach request: {error}"),
            )
        })?;

    let mut stdout = std::io::stdout();
    wait_for_attach(
        &mut receiver,
        &mut sender,
        &attach_id,
        &args.target,
        &mut stdout,
    )
    .await?;

    let _raw_guard = RawModeGuard::new(!args.no_raw)?;

    if let Ok((cols, rows)) = terminal::size() {
        let _ = send_resize(&mut sender, &args.target, cols, rows).await;
    }

    let (input_tx, mut input_rx) = mpsc::channel::<Vec<u8>>(32);
    let _input_handle = spawn_stdin_reader(input_tx);

    let (resize_tx, mut resize_rx) = mpsc::channel::<(u16, u16)>(8);
    spawn_resize_listener(resize_tx);

    let mut prefix_deadline: Option<Instant> = None;

    loop {
        let sleep = if let Some(deadline) = prefix_deadline {
            tokio::time::sleep_until(tokio::time::Instant::from_std(deadline))
        } else {
            tokio::time::sleep(Duration::from_secs(3600))
        };
        tokio::pin!(sleep);

        tokio::select! {
            _ = &mut sleep, if prefix_deadline.is_some() => {
                if let Some(deadline) = prefix_deadline {
                    if Instant::now() >= deadline {
                        if !args.read_only {
                            let _ = send_input_bytes(&mut sender, &args.target, &[detach_sequence.prefix]).await;
                        }
                        prefix_deadline = None;
                    }
                }
            }
            maybe_input = input_rx.recv() => {
                let Some(bytes) = maybe_input else { break; };
                let detach = handle_input_bytes(
                    &mut sender,
                    &args.target,
                    &bytes,
                    args.read_only,
                    &detach_sequence,
                    &mut prefix_deadline,
                ).await?;
                if detach {
                    let _ = send_detach(&mut sender, &args.target).await;
                    break;
                }
            }
            maybe_resize = resize_rx.recv() => {
                if let Some((cols, rows)) = maybe_resize {
                    let _ = send_resize(&mut sender, &args.target, cols, rows).await;
                }
            }
            maybe_message = receiver.next() => {
                let Some(message) = maybe_message else { break; };
                if !handle_terminald_message(message, &args.target, &mut stdout, &mut sender).await? {
                    break;
                }
            }
        }
    }

    Ok(())
}

fn parse_detach_sequence(value: &str, timeout_ms: u64) -> Result<DetachSequence, CliError> {
    let tokens: Vec<&str> = value.split_whitespace().collect();
    if tokens.len() != 2 {
        return Err(CliError::new(
            "invalid_request",
            "Detach key must be two keys (e.g. \"Ctrl-b d\").",
        ));
    }
    let prefix = parse_key_token(tokens[0])?;
    let key = parse_key_token(tokens[1])?;
    let timeout = Duration::from_millis(timeout_ms.max(1));
    Ok(DetachSequence {
        prefix,
        key,
        timeout,
    })
}

fn parse_key_token(token: &str) -> Result<u8, CliError> {
    let normalized = token.trim();
    if normalized.is_empty() {
        return Err(CliError::new(
            "invalid_request",
            "Detach key token is empty.",
        ));
    }
    let lower = normalized.to_lowercase();
    if let Some(rest) = lower
        .strip_prefix("ctrl-")
        .or_else(|| lower.strip_prefix("c-"))
    {
        let mut chars = rest.chars();
        let Some(ch) = chars.next() else {
            return Err(CliError::new(
                "invalid_request",
                "Detach key missing character.",
            ));
        };
        if chars.next().is_some() {
            return Err(CliError::new(
                "invalid_request",
                "Detach key must be a single character.",
            ));
        }
        let byte = ch as u32;
        if byte > u8::MAX as u32 {
            return Err(CliError::new(
                "invalid_request",
                "Detach key must be ASCII.",
            ));
        }
        return Ok((byte as u8) & 0x1f);
    }
    let mut chars = normalized.chars();
    let Some(ch) = chars.next() else {
        return Err(CliError::new(
            "invalid_request",
            "Detach key missing character.",
        ));
    };
    if chars.next().is_some() {
        return Err(CliError::new(
            "invalid_request",
            "Detach key must be a single character.",
        ));
    }
    let byte = ch as u32;
    if byte > u8::MAX as u32 {
        return Err(CliError::new(
            "invalid_request",
            "Detach key must be ASCII.",
        ));
    }
    Ok(byte as u8)
}

fn spawn_stdin_reader(sender: mpsc::Sender<Vec<u8>>) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buffer = [0u8; 1024];
        loop {
            match stdin.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    if sender.blocking_send(buffer[..count].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    })
}

fn spawn_resize_listener(sender: mpsc::Sender<(u16, u16)>) {
    #[cfg(unix)]
    {
        tokio::spawn(async move {
            let mut signals = match signal(SignalKind::window_change()) {
                Ok(value) => value,
                Err(_) => return,
            };
            loop {
                if signals.recv().await.is_none() {
                    break;
                }
                if let Ok((cols, rows)) = terminal::size() {
                    if sender.send((cols, rows)).await.is_err() {
                        break;
                    }
                }
            }
        });
    }
    #[cfg(not(unix))]
    {
        let _ = sender;
    }
}

async fn wait_for_attach(
    receiver: &mut TerminaldStream,
    sender: &mut TerminaldSink,
    attach_id: &str,
    session_id: &str,
    stdout: &mut dyn Write,
) -> Result<(), CliError> {
    while let Some(message) = receiver.next().await {
        match message {
            Ok(TungsteniteMessage::Text(text)) => {
                if let Some(result) = parse_terminald_response(&text, attach_id) {
                    return result.map(|_| ());
                }
                if let Some(payload) = extract_terminal_payload_event(&text, session_id) {
                    write_terminal_payload(&payload, stdout)?;
                } else if let Some(warning) = extract_session_warning(&text, session_id) {
                    eprintln!("session warning: {warning}");
                } else if let Some(error) = parse_terminald_error(&text) {
                    eprintln!("{}: {}", error.code, error.message);
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    if let Some(result) = parse_terminald_response(&text, attach_id) {
                        return result.map(|_| ());
                    }
                    if let Some(payload) = extract_terminal_payload_event(&text, session_id) {
                        write_terminal_payload(&payload, stdout)?;
                    } else if let Some(warning) = extract_session_warning(&text, session_id) {
                        eprintln!("session warning: {warning}");
                    } else if let Some(error) = parse_terminald_error(&text) {
                        eprintln!("{}: {}", error.code, error.message);
                    }
                }
            }
            Ok(TungsteniteMessage::Ping(payload)) => {
                let _ = sender.send(TungsteniteMessage::Pong(payload)).await;
            }
            Ok(TungsteniteMessage::Close(_)) => {
                return Err(CliError::new(
                    "connection_failed",
                    "Terminal daemon closed connection.",
                ));
            }
            _ => {}
        }
    }

    Err(CliError::new(
        "connection_failed",
        "Terminal daemon closed connection.",
    ))
}

async fn handle_terminald_message(
    message: Result<TungsteniteMessage, tokio_tungstenite::tungstenite::Error>,
    session_id: &str,
    stdout: &mut dyn Write,
    sender: &mut TerminaldSink,
) -> Result<bool, CliError> {
    match message {
        Ok(TungsteniteMessage::Text(text)) => {
            if let Some(payload) = extract_terminal_payload_event(&text, session_id) {
                write_terminal_payload(&payload, stdout)?;
            } else if let Some(warning) = extract_session_warning(&text, session_id) {
                eprintln!("session warning: {warning}");
            } else if let Some(error) = parse_terminald_error(&text) {
                eprintln!("{}: {}", error.code, error.message);
            }
        }
        Ok(TungsteniteMessage::Binary(bytes)) => {
            if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                if let Some(payload) = extract_terminal_payload_event(&text, session_id) {
                    write_terminal_payload(&payload, stdout)?;
                } else if let Some(warning) = extract_session_warning(&text, session_id) {
                    eprintln!("session warning: {warning}");
                } else if let Some(error) = parse_terminald_error(&text) {
                    eprintln!("{}: {}", error.code, error.message);
                }
            }
        }
        Ok(TungsteniteMessage::Ping(payload)) => {
            let _ = sender.send(TungsteniteMessage::Pong(payload)).await;
        }
        Ok(TungsteniteMessage::Close(_)) => {
            return Ok(false);
        }
        Err(error) => {
            return Err(CliError::new(
                "connection_failed",
                format!("Terminal daemon error: {error}"),
            ));
        }
        _ => {}
    }
    Ok(true)
}

fn extract_terminal_payload_event(text: &str, session_id: &str) -> Option<Value> {
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

fn extract_session_warning(text: &str, session_id: &str) -> Option<String> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    if parsed.get("type")?.as_str()? != "event" {
        return None;
    }
    if parsed.get("event")?.as_str()? != "session_warning" {
        return None;
    }
    if let Some(event_session) = parsed.get("session_id").and_then(|value| value.as_str()) {
        if event_session != session_id {
            return None;
        }
    }
    parsed
        .get("data")
        .and_then(|value| value.get("message"))
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
}

fn parse_terminald_error(text: &str) -> Option<CliError> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    if parsed.get("type")?.as_str()? != "res" {
        return None;
    }
    let ok = parsed
        .get("ok")
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    if ok {
        return None;
    }
    let error = parsed.get("error")?;
    let code = error
        .get("code")
        .and_then(|value| value.as_str())
        .unwrap_or("terminal_error");
    let message = error
        .get("message")
        .and_then(|value| value.as_str())
        .unwrap_or("Terminal daemon error.");
    Some(CliError::new(map_error_code(code), message.to_string()))
}

fn write_terminal_payload(payload: &Value, stdout: &mut dyn Write) -> Result<(), CliError> {
    if let Some(snapshot) = payload.get("snapshot").and_then(|value| value.as_str()) {
        stdout.write_all(snapshot.as_bytes()).map_err(|error| {
            CliError::new("terminal_error", format!("stdout write failed: {error}"))
        })?;
    }
    if let Some(output) = payload.get("output").and_then(|value| value.as_array()) {
        for chunk in output {
            if let Some(data) = chunk.get("data").and_then(|value| value.as_str()) {
                stdout.write_all(data.as_bytes()).map_err(|error| {
                    CliError::new("terminal_error", format!("stdout write failed: {error}"))
                })?;
            }
        }
    }
    stdout.flush().map_err(|error| {
        CliError::new("terminal_error", format!("stdout flush failed: {error}"))
    })?;
    Ok(())
}

async fn handle_input_bytes(
    sender: &mut TerminaldSink,
    session_id: &str,
    bytes: &[u8],
    read_only: bool,
    detach_sequence: &DetachSequence,
    prefix_deadline: &mut Option<Instant>,
) -> Result<bool, CliError> {
    let mut buffer: Vec<u8> = Vec::new();
    for &byte in bytes {
        if let Some(deadline) = *prefix_deadline {
            if Instant::now() > deadline {
                if !read_only {
                    buffer.push(detach_sequence.prefix);
                }
                *prefix_deadline = None;
            }
        }
        if let Some(deadline) = *prefix_deadline {
            if Instant::now() <= deadline && byte == detach_sequence.key {
                *prefix_deadline = None;
                if !read_only && !buffer.is_empty() {
                    send_input_bytes(sender, session_id, &buffer).await?;
                }
                return Ok(true);
            }
            if !read_only {
                buffer.push(detach_sequence.prefix);
            }
            *prefix_deadline = None;
        }
        if byte == detach_sequence.prefix {
            *prefix_deadline = Some(Instant::now() + detach_sequence.timeout);
        } else if !read_only {
            buffer.push(byte);
        }
    }
    if !read_only && !buffer.is_empty() {
        send_input_bytes(sender, session_id, &buffer).await?;
    }
    Ok(false)
}

async fn send_input_bytes(
    sender: &mut TerminaldSink,
    session_id: &str,
    bytes: &[u8],
) -> Result<(), CliError> {
    if bytes.is_empty() {
        return Ok(());
    }
    let payload = match std::str::from_utf8(bytes) {
        Ok(text) => json!({ "data": text }),
        Err(_) => {
            let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
            json!({ "data_b64": encoded })
        }
    };
    send_terminald_action(sender, "input", session_id, Some(payload)).await
}

async fn send_resize(
    sender: &mut TerminaldSink,
    session_id: &str,
    cols: u16,
    rows: u16,
) -> Result<(), CliError> {
    let payload = json!({ "cols": cols, "rows": rows });
    send_terminald_action(sender, "resize", session_id, Some(payload)).await
}

async fn send_detach(sender: &mut TerminaldSink, session_id: &str) -> Result<(), CliError> {
    send_terminald_action(sender, "detach", session_id, None).await
}

async fn send_terminald_action(
    sender: &mut TerminaldSink,
    action: &str,
    session_id: &str,
    payload: Option<Value>,
) -> Result<(), CliError> {
    let request_id = random_request_id();
    let request =
        build_terminald_request(&request_id, action, Some(session_id.to_string()), payload);
    sender
        .send(TungsteniteMessage::Text(request.to_string().into()))
        .await
        .map_err(|error| {
            CliError::new(
                "connection_failed",
                format!("Failed to send {action}: {error}"),
            )
        })?;
    Ok(())
}

fn extract_session_id(data: &Value) -> Option<String> {
    data.get("session_id")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .or_else(|| {
            data.get("payload")
                .and_then(|payload| payload.get("session_id"))
                .and_then(|value| value.as_str())
                .map(|value| value.to_string())
        })
}

struct ConfigOverrides {
    endpoint: Option<String>,
    token: Option<String>,
    config: Option<PathBuf>,
}

struct ResolvedConfig {
    ws_url: String,
    token: Option<String>,
    config_override: bool,
}

struct CliError {
    code: &'static str,
    message: String,
}

impl CliError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

async fn terminald_request(
    overrides: &ConfigOverrides,
    action: &str,
    session_id: Option<String>,
    payload: Option<Value>,
) -> Result<Value, CliError> {
    let mut socket = connect_terminald(overrides).await?;
    let request_id = random_request_id();
    let request = build_terminald_request(&request_id, action, session_id, payload);
    socket
        .send(TungsteniteMessage::Text(request.to_string().into()))
        .await
        .map_err(|error| {
            CliError::new(
                "connection_failed",
                format!("Failed to send request: {error}"),
            )
        })?;

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
                return Err(CliError::new(
                    "connection_failed",
                    "Terminal daemon closed connection.",
                ));
            }
            _ => {}
        }
    }

    Err(CliError::new(
        "connection_failed",
        "Terminal daemon closed connection.",
    ))
}

async fn connect_terminald(overrides: &ConfigOverrides) -> Result<TerminaldSocket, CliError> {
    let mut resolved = resolve_config(overrides)?;
    let mut attempted_start = false;

    loop {
        if resolved.token.is_none() {
            if should_autostart(&resolved, attempted_start) {
                attempted_start = true;
                try_start_terminald().await?;
                if let Some(updated) = wait_for_terminald_config(overrides) {
                    resolved = updated;
                    continue;
                }
            }
            return Err(CliError::new(
                "connection_failed",
                "Terminal daemon token unavailable.",
            ));
        }

        let token = resolved.token.clone().unwrap_or_default();
        match connect_and_auth(&resolved.ws_url, &token).await {
            Ok(socket) => return Ok(socket),
            Err(error) => {
                if should_autostart(&resolved, attempted_start)
                    && should_autostart_after_error(&error)
                {
                    attempted_start = true;
                    try_start_terminald().await?;
                    if let Some(updated) = wait_for_terminald_config(overrides) {
                        resolved = updated;
                        continue;
                    }
                }
                return Err(error);
            }
        }
    }
}

fn should_autostart(config: &ResolvedConfig, attempted_start: bool) -> bool {
    !config.config_override && autostart_enabled() && !attempted_start
}

fn should_autostart_after_error(error: &CliError) -> bool {
    !matches!(error.code, "version_mismatch")
}

async fn connect_and_auth(ws_url: &str, token: &str) -> Result<TerminaldSocket, CliError> {
    let connect_result =
        tokio::time::timeout(TERMINALD_CONNECT_TIMEOUT, connect_async(ws_url)).await;
    let (mut socket, _) = match connect_result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            return Err(CliError::new(
                "connection_failed",
                format!("Failed to connect to terminal daemon: {error}"),
            ))
        }
        Err(_) => {
            return Err(CliError::new(
                "connection_failed",
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
        .map_err(|error| {
            CliError::new(
                "connection_failed",
                format!("Failed to send auth request: {error}"),
            )
        })?;

    while let Some(message) = socket.next().await {
        match message {
            Ok(TungsteniteMessage::Text(text)) => {
                if let Some(result) = parse_terminald_response(&text, &auth_id) {
                    return result.map(|_| socket);
                }
            }
            Ok(TungsteniteMessage::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    if let Some(result) = parse_terminald_response(&text, &auth_id) {
                        return result.map(|_| socket);
                    }
                }
            }
            Ok(TungsteniteMessage::Close(_)) => {
                return Err(CliError::new(
                    "connection_failed",
                    "Terminal daemon closed connection.",
                ));
            }
            _ => {}
        }
    }

    Err(CliError::new(
        "connection_failed",
        "Terminal daemon closed connection.",
    ))
}

fn resolve_config(overrides: &ConfigOverrides) -> Result<ResolvedConfig, CliError> {
    let env_config = read_env_value(ENV_TERMINALD_CONFIG).map(PathBuf::from);
    let env_endpoint = read_env_value(ENV_TERMINALD_ENDPOINT);
    let env_token = read_env_value(ENV_TERMINALD_TOKEN);

    let config_override = overrides.config.is_some()
        || overrides.endpoint.is_some()
        || overrides.token.is_some()
        || env_config.is_some()
        || env_endpoint.is_some()
        || env_token.is_some();

    let config_path = overrides
        .config
        .clone()
        .or(env_config.clone())
        .or_else(terminal_discovery_path);

    let discovery = match config_path {
        Some(path) => match read_discovery_file(&path) {
            Ok(file) => Some(file),
            Err(error) => {
                if overrides.config.is_some() || env_config.is_some() {
                    return Err(CliError::new(
                        "connection_failed",
                        format!("Failed to read config {}: {error}", path.display()),
                    ));
                }
                None
            }
        },
        None => None,
    };

    let ws_url = overrides
        .endpoint
        .clone()
        .or(env_endpoint)
        .or_else(|| discovery.as_ref().map(|file| file.ws_url.clone()))
        .unwrap_or_else(|| DEFAULT_TERMINALD_WS_URL.to_string());
    let token = overrides
        .token
        .clone()
        .or(env_token)
        .or_else(|| discovery.as_ref().map(|file| file.token.clone()));

    Ok(ResolvedConfig {
        ws_url,
        token,
        config_override,
    })
}

fn wait_for_terminald_config(overrides: &ConfigOverrides) -> Option<ResolvedConfig> {
    let start = Instant::now();
    while start.elapsed() < TERMINALD_AUTOSTART_TIMEOUT {
        if let Ok(config) = resolve_config(overrides) {
            if config.token.is_some() {
                return Some(config);
            }
        }
        thread::sleep(TERMINALD_DISCOVERY_POLL);
    }
    None
}

async fn try_start_terminald() -> Result<(), CliError> {
    tokio::task::spawn_blocking(start_terminald_with_fallback)
        .await
        .map_err(|error| {
            CliError::new(
                "connection_failed",
                format!("Terminal daemon start failed: {error}"),
            )
        })?
        .map(|_| ())
        .map_err(|error| CliError::new("connection_failed", error))
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

fn parse_terminald_response(text: &str, request_id: &str) -> Option<Result<Value, CliError>> {
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
    Some(Err(CliError::new(map_error_code(code), message)))
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
