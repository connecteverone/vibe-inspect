use clap::Parser;
use rand::{distributions::Alphanumeric, Rng};

use desktop::terminal_core::{
    write_discovery_file, TerminalDiscoveryFile, DEFAULT_TERMINALD_BIND,
    DEFAULT_TERMINALD_WS_PATH, TERMINALD_PROTOCOL_VERSION,
};
use std::time::{SystemTime, UNIX_EPOCH};

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

fn main() {
    let args = TerminaldArgs::parse();
    let ws_path = normalize_ws_path(&args.ws_path);
    let ws_url = format!("ws://{}{}", args.bind.trim(), ws_path);
    let token = random_token(32);
    let discovery = TerminalDiscoveryFile {
        ws_url,
        token,
        version: TERMINALD_PROTOCOL_VERSION.to_string(),
        pid: std::process::id(),
        created_at: now_ts(),
        capabilities: Vec::new(),
    };
    if let Err(error) = write_discovery_file(&discovery) {
        eprintln!("Failed to write discovery file: {error}");
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
