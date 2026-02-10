use clap::Parser;
use desktop::{start_local_server, PairingState};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Debug, Parser)]
#[command(
    name = "vnc-headless",
    about = "Start the local VNC/ROI server without Tauri UI"
)]
struct Args {
    /// HTTP command server port.
    #[arg(long)]
    port: Option<u16>,
    /// QUIC port for VNC/ROI.
    #[arg(long)]
    quic_port: Option<u16>,
}

fn main() {
    if std::env::var("RUST_LOG").is_err() {
        std::env::set_var("RUST_LOG", "info");
    }
    let _ = hbb_common::init_log(false, "vnc_headless");
    let args = Args::parse();
    let state = Arc::new(Mutex::new(PairingState::default()));
    let (port, quic_port, auth_token) = {
        let guard = state.lock().expect("pairing state lock");
        (
            args.port.unwrap_or_else(|| guard.listen_port()),
            args.quic_port.unwrap_or_else(|| guard.roi_quic_port()),
            guard.auth_token().to_string(),
        )
    };
    let _server =
        start_local_server(state, port, Some(quic_port)).expect("failed to start local server");
    println!("VNC headless server started.");
    println!("HTTP_PORT={port}");
    println!("QUIC_PORT={quic_port}");
    println!("AUTH_TOKEN={auth_token}");
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}
