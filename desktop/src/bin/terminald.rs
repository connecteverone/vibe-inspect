use clap::Parser;

use desktop::terminal_core::{DEFAULT_TERMINALD_BIND, DEFAULT_TERMINALD_WS_PATH};

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
    let _args = TerminaldArgs::parse();
}
