use base64::Engine;
use clap::{Args, Parser, Subcommand};
use desktop::terminal_core::{
    read_discovery_file, terminal_discovery_path, TerminalSessionSummary,
    DEFAULT_TERMINALD_WS_URL, TERMINALD_PROTOCOL_VERSION,
};
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

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
    /// Send input to a session.
    Send(SendArgs),
    /// Resize a session.
    Resize(ResizeArgs),
    /// Rename a session.
    Rename(RenameArgs),
    /// Stop a session.
    #[command(alias = "kill")]
    Stop(StopArgs),
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
                    CliError::new("connection_failed", format!("Failed to format JSON: {error}"))
                })?;
                println!("{payload}");
            } else {
                let sessions_value = data
                    .get("sessions")
                    .cloned()
                    .unwrap_or(Value::Array(Vec::new()));
                let sessions: Vec<TerminalSessionSummary> =
                    serde_json::from_value(sessions_value).map_err(|error| {
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
        Command::Send(args) => {
            let payload = build_input_payload(&args)?;
            terminald_request(
                &overrides,
                "input",
                Some(args.target),
                Some(payload),
            )
            .await?;
        }
        Command::Resize(args) => {
            let payload = json!({ "cols": args.cols, "rows": args.rows });
            terminald_request(
                &overrides,
                "resize",
                Some(args.target),
                Some(payload),
            )
            .await?;
        }
        Command::Rename(args) => {
            let payload = json!({ "label": args.label });
            terminald_request(
                &overrides,
                "rename",
                Some(args.target),
                Some(payload),
            )
            .await?;
        }
        Command::Stop(args) => {
            let action = if args.force { "kill" } else { "stop" };
            terminald_request(&overrides, action, Some(args.target), None).await?;
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
        .send(TungsteniteMessage::Text(request.to_string()))
        .await
        .map_err(|error| CliError::new("connection_failed", format!("Failed to send request: {error}")))?;

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
                if should_autostart(&resolved, attempted_start) {
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
        .send(TungsteniteMessage::Text(auth_request.to_string()))
        .await
        .map_err(|error| {
            CliError::new("connection_failed", format!("Failed to send auth request: {error}"))
        })?;

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
    tokio::task::spawn_blocking(|| start_terminald_process())
        .await
        .unwrap_or_else(|error| {
            Err(CliError::new(
                "connection_failed",
                format!("Terminal daemon start failed: {error}"),
            ))
        })
}

fn start_terminald_process() -> Result<(), CliError> {
    let binary = resolve_terminald_binary();
    let mut command = match binary {
        Some(path) => Command::new(path),
        None => Command::new("terminald"),
    };
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = command.spawn().map_err(|error| {
        CliError::new(
            "connection_failed",
            format!("Failed to start terminal daemon: {error}"),
        )
    })?;
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

fn parse_terminald_response(
    text: &str,
    request_id: &str,
) -> Option<Result<Value, CliError>> {
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
        "version_mismatch" => "version_mismatch",
        "connection_failed" => "connection_failed",
        _ => "terminal_error",
    }
}
