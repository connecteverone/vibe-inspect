use clap::Parser;
use hbb_common::rendezvous_proto::ConnType;
use hbb_common::tcp::FramedStream;
use hbb_common::Stream as RustDeskStream;
use librustdesk::{set_preconnected_stream, Data, InvokeUiSession, QualityStatus, Remote, Session};
use quinn::{ClientConfig, Endpoint};
use rustls::client::danger::ServerCertVerifier;
use rustls::pki_types::{CertificateDer, ServerName};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use hbb_common::message_proto::{
    CaptureDisplays, CursorData, CursorPosition, DisplayInfo, FileEntry, Message, Misc, PeerInfo,
    SwitchDisplay, TerminalResponse, WindowsSession,
};

use hbb_common::tokio::sync::mpsc;
use tokio::io::AsyncWriteExt;

#[derive(Parser, Debug)]
#[command(
    name = "remote-quic-smoke",
    about = "Remote QUIC smoke test with RustDesk client"
)]
struct Args {
    #[arg(long, default_value = "127.0.0.1")]
    host: String,
    #[arg(long, default_value_t = 58888)]
    command_port: u16,
    #[arg(long, default_value_t = 0)]
    quic_port: u16,
    #[arg(long, default_value = "vibe-inspect")]
    server_name: String,
    #[arg(long, default_value_t = 3.0)]
    duration: f64,
    #[arg(long)]
    auth_token_path: Option<PathBuf>,
    #[arg(long)]
    no_stop: bool,
    #[arg(long)]
    probe: bool,
}

#[derive(Debug, Deserialize, Serialize)]
struct RemoteHello {
    #[serde(rename = "type")]
    message_type: String,
    session_id: String,
    token: String,
    auth_token: Option<String>,
    client_id: Option<String>,
    client_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RemoteReady {
    status: String,
    session_id: String,
    data_stream: String,
}

#[derive(Debug)]
struct FrameStats {
    ready_at: Instant,
    first_frame_at: Option<Instant>,
    frames: usize,
    last_size: Option<(usize, usize)>,
}

impl FrameStats {
    fn new(ready_at: Instant) -> Self {
        Self {
            ready_at,
            first_frame_at: None,
            frames: 0,
            last_size: None,
        }
    }

    fn record_frame(&mut self, width: usize, height: usize) {
        self.frames += 1;
        self.last_size = Some((width, height));
        if self.first_frame_at.is_none() {
            self.first_frame_at = Some(Instant::now());
        }
    }
}

#[derive(Clone)]
struct TestUi {
    password: Arc<String>,
    sender: Arc<Mutex<Option<mpsc::UnboundedSender<Data>>>>,
    stats: Arc<Mutex<FrameStats>>,
    capture_sent: Arc<AtomicBool>,
}

impl Default for TestUi {
    fn default() -> Self {
        Self {
            password: Arc::new(String::new()),
            sender: Arc::new(Mutex::new(None)),
            stats: Arc::new(Mutex::new(FrameStats::new(Instant::now()))),
            capture_sent: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl TestUi {
    fn new(
        password: String,
        sender: mpsc::UnboundedSender<Data>,
        stats: Arc<Mutex<FrameStats>>,
    ) -> Self {
        Self {
            password: Arc::new(password),
            sender: Arc::new(Mutex::new(Some(sender))),
            stats,
            capture_sent: Arc::new(AtomicBool::new(false)),
        }
    }

    fn send_login(&self, password: String) {
        if let Ok(lock) = self.sender.lock() {
            if let Some(sender) = lock.as_ref() {
                let _ = sender.send(Data::Login((String::new(), String::new(), password, true)));
            }
        }
    }

    fn send_switch_display(&self, display: i32) {
        if self
            .capture_sent
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            return;
        }
        if let Ok(lock) = self.sender.lock() {
            if let Some(sender) = lock.as_ref() {
                let mut misc = Misc::new();
                misc.set_switch_display(SwitchDisplay {
                    display,
                    width: 0,
                    height: 0,
                    ..Default::default()
                });
                let mut msg = Message::new();
                msg.set_misc(misc);
                let _ = sender.send(Data::Message(msg));

                let mut misc = Misc::new();
                misc.set_capture_displays(CaptureDisplays {
                    add: vec![],
                    sub: vec![],
                    set: vec![display],
                    ..Default::default()
                });
                let mut msg = Message::new();
                msg.set_misc(misc);
                let _ = sender.send(Data::Message(msg));
            }
        }
    }
}

impl InvokeUiSession for TestUi {
    fn set_cursor_data(&self, _cd: CursorData) {}
    fn set_cursor_id(&self, _id: String) {}
    fn set_cursor_position(&self, _cp: CursorPosition) {}
    fn set_display(&self, x: i32, y: i32, w: i32, h: i32, _cursor_embedded: bool, scale: f64) {
        println!("set_display: x={x} y={y} w={w} h={h} scale={scale}");
    }
    fn switch_display(&self, _display: &SwitchDisplay) {}
    fn set_peer_info(&self, peer_info: &PeerInfo) {
        println!(
            "peer_info: version={} platform={} displays={} current_display={}",
            peer_info.version,
            peer_info.platform,
            peer_info.displays.len(),
            peer_info.current_display
        );
        let mut display = peer_info.current_display as i32;
        if display < 0 || display as usize >= peer_info.displays.len() {
            display = 0;
        }
        self.send_switch_display(display);
    }
    fn set_displays(&self, _displays: &Vec<DisplayInfo>) {}
    fn set_platform_additions(&self, _data: &str) {}
    fn on_connected(&self, conn_type: ConnType) {
        println!("on_connected: {:?}", conn_type);
    }
    fn update_privacy_mode(&self) {}
    fn set_permission(&self, _name: &str, _value: bool) {}
    fn close_success(&self) {
        println!("login success");
    }
    fn update_quality_status(&self, _qs: QualityStatus) {}
    fn set_connection_type(&self, _is_secured: bool, _direct: bool, _stream_type: &str) {}
    fn set_fingerprint(&self, _fingerprint: String) {}
    fn job_error(&self, _id: i32, _err: String, _file_num: i32) {}
    fn job_done(&self, _id: i32, _file_num: i32) {}
    fn clear_all_jobs(&self) {}
    fn new_message(&self, _msg: String) {}
    fn update_transfer_list(&self) {}
    fn load_last_job(&self, _cnt: i32, _job_json: &str, _auto_start: bool) {}
    fn update_folder_files(
        &self,
        _id: i32,
        _entries: &Vec<FileEntry>,
        _path: String,
        _is_local: bool,
        _only_count: bool,
    ) {
    }
    fn confirm_delete_files(&self, _id: i32, _i: i32, _name: String) {}
    fn override_file_confirm(
        &self,
        _id: i32,
        _file_num: i32,
        _to: String,
        _is_upload: bool,
        _is_identical: bool,
    ) {
    }
    fn update_block_input_state(&self, _on: bool) {}
    fn job_progress(&self, _id: i32, _file_num: i32, _speed: f64, _finished_size: f64) {}
    fn adapt_size(&self) {}

    fn on_rgba(&self, display: usize, rgba: &mut scrap::ImageRgb) {
        if let Ok(mut stats) = self.stats.lock() {
            stats.record_frame(rgba.w, rgba.h);
            if stats.frames == 1 {
                println!(
                    "first rgba frame: display={} size={}x{}",
                    display, rgba.w, rgba.h
                );
            }
        }
    }

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, _link: &str, _retry: bool) {
        println!("msgbox: type={msgtype} title={title} text={text}");
        match msgtype {
            "input-password" | "re-input-password" => {
                self.send_login((*self.password).clone());
            }
            _ => {}
        }
    }

    fn cancel_msgbox(&self, _tag: &str) {}
    fn switch_back(&self, _id: &str) {}
    fn portable_service_running(&self, _running: bool) {}
    fn on_voice_call_started(&self) {}
    fn on_voice_call_closed(&self, _reason: &str) {}
    fn on_voice_call_waiting(&self) {}
    fn on_voice_call_incoming(&self) {}

    fn get_rgba(&self, _display: usize) -> *const u8 {
        std::ptr::null()
    }

    fn next_rgba(&self, _display: usize) {}

    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}
    fn set_current_display(&self, _disp_idx: i32) {}
    fn update_record_status(&self, _start: bool) {}
    fn printer_request(&self, _id: i32, _path: String) {}
    fn handle_screenshot_resp(&self, _sid: String, _msg: String) {}
    fn handle_terminal_response(&self, _response: TerminalResponse) {}
}

#[derive(Debug)]
struct QuicBiStream {
    send: quinn::SendStream,
    recv: quinn::RecvStream,
    read_bytes: usize,
    write_bytes: usize,
}

impl tokio::io::AsyncRead for QuicBiStream {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let poll = std::pin::Pin::new(&mut self.recv).poll_read(cx, buf);
        if let std::task::Poll::Ready(Ok(())) = &poll {
            let after = buf.filled().len();
            if after > before {
                let delta = after - before;
                self.read_bytes = self.read_bytes.saturating_add(delta);
                if self.read_bytes == delta {
                    println!("quic recv bytes: {}", delta);
                }
            }
        }
        poll
    }
}

impl tokio::io::AsyncWrite for QuicBiStream {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        data: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        match std::pin::Pin::new(&mut self.send).poll_write(cx, data) {
            std::task::Poll::Ready(Ok(size)) => {
                if size > 0 {
                    let before = self.write_bytes;
                    self.write_bytes = self.write_bytes.saturating_add(size);
                    if before == 0 {
                        println!("quic send bytes: {}", size);
                    }
                }
                std::task::Poll::Ready(Ok(size))
            }
            std::task::Poll::Ready(Err(error)) => {
                std::task::Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::Other, error)))
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match std::pin::Pin::new(&mut self.send).poll_flush(cx) {
            std::task::Poll::Ready(Ok(())) => std::task::Poll::Ready(Ok(())),
            std::task::Poll::Ready(Err(error)) => {
                std::task::Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::Other, error)))
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match std::pin::Pin::new(&mut self.send).poll_shutdown(cx) {
            std::task::Poll::Ready(Ok(())) => std::task::Poll::Ready(Ok(())),
            std::task::Poll::Ready(Err(error)) => {
                std::task::Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::Other, error)))
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    }
}

#[derive(Debug)]
struct SkipServerVerification;

impl SkipServerVerification {
    fn new() -> Arc<Self> {
        Arc::new(Self)
    }
}

impl ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
        ]
    }
}

fn build_insecure_client_config() -> Result<ClientConfig, String> {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }
    let crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(SkipServerVerification::new())
        .with_no_client_auth();
    let mut config = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(crypto).map_err(|err| err.to_string())?,
    ));
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    let idle_timeout =
        quinn::IdleTimeout::try_from(Duration::from_secs(20)).map_err(|e| e.to_string())?;
    transport.max_idle_timeout(Some(idle_timeout));
    transport.max_concurrent_bidi_streams(100u32.into());
    config.transport_config(Arc::new(transport));
    Ok(config)
}

fn load_auth_token(path: Option<PathBuf>) -> Result<String, String> {
    if let Some(path) = path {
        let data = fs::read_to_string(path).map_err(|e| e.to_string())?;
        let json: Value = serde_json::from_str(&data).map_err(|e| e.to_string())?;
        return json
            .get("auth_token")
            .and_then(|v| v.as_str())
            .map(|v| v.to_string())
            .ok_or_else(|| "auth_token missing".to_string());
    }
    let home = std::env::var("HOME").map_err(|_| "HOME missing".to_string())?;
    let default_path = PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("com.vibe.vibe-inspect")
        .join("agent_identity.json");
    let data = fs::read_to_string(default_path).map_err(|e| e.to_string())?;
    let json: Value = serde_json::from_str(&data).map_err(|e| e.to_string())?;
    json.get("auth_token")
        .and_then(|v| v.as_str())
        .map(|v| v.to_string())
        .ok_or_else(|| "auth_token missing".to_string())
}

fn command_request(
    host: &str,
    port: u16,
    auth_token: &str,
    payload: Value,
) -> Result<Value, String> {
    let client = reqwest::blocking::Client::new();
    let resp = client
        .post(format!("http://{host}:{port}/command"))
        .header("Content-Type", "application/json")
        .header("x-agent-token", auth_token)
        .json(&payload)
        .send()
        .map_err(|e| e.to_string())?;
    let json: Value = resp.json().map_err(|e| e.to_string())?;
    if json.get("status").and_then(|v| v.as_str()) != Some("ok") {
        return Err(format!("command failed: {json}"));
    }
    Ok(json.get("payload").cloned().unwrap_or(Value::Null))
}

fn now_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn fetch_identity(host: &str, port: u16, auth_token: &str) -> Result<Value, String> {
    let payload = serde_json::json!({
        "request_id": format!("bench-identity-{}", now_millis()),
        "command": "identity",
        "payload": {}
    });
    command_request(host, port, auth_token, payload)
}

fn start_remote(host: &str, port: u16, auth_token: &str) -> Result<Value, String> {
    let payload = serde_json::json!({
        "request_id": format!("bench-remote-{}", now_millis()),
        "command": "remote",
        "payload": { "action": "start" }
    });
    command_request(host, port, auth_token, payload)
}

fn stop_remote(host: &str, port: u16, auth_token: &str, session_id: &str) -> Result<(), String> {
    let payload = serde_json::json!({
        "request_id": format!("bench-remote-stop-{}", now_millis()),
        "command": "remote",
        "payload": { "action": "stop", "session_id": session_id }
    });
    let _ = command_request(host, port, auth_token, payload)?;
    Ok(())
}

async fn send_json<T: Serialize>(
    send: &mut quinn::SendStream,
    message: &T,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let payload = serde_json::to_vec(message)?;
    let len = payload.len() as u32;
    send.write_all(&len.to_be_bytes()).await?;
    send.write_all(&payload).await?;
    send.flush().await?;
    Ok(())
}

async fn read_json<T: for<'de> Deserialize<'de>>(
    recv: &mut quinn::RecvStream,
) -> Result<T, Box<dyn std::error::Error + Send + Sync>> {
    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut payload = vec![0u8; len];
    recv.read_exact(&mut payload).await?;
    let message = serde_json::from_slice(&payload)?;
    Ok(message)
}

fn parse_peer_id(connect_uri: Option<&str>) -> Option<String> {
    connect_uri
        .and_then(|uri| uri.strip_prefix("rustdesk://"))
        .map(|id| id.to_string())
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if std::env::var("RUST_LOG").is_err() {
        std::env::set_var("RUST_LOG", "info");
    }
    let _ = hbb_common::init_log(false, "remote_quic_smoke");
    let args = Args::parse();
    let auth_token = load_auth_token(args.auth_token_path)
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::Other, err))?;

    let identity = fetch_identity(&args.host, args.command_port, &auth_token)
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::Other, err))?;
    let quic_port = if args.quic_port != 0 {
        args.quic_port
    } else {
        identity
            .get("roi_quic_port")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as u16
    };
    if quic_port == 0 {
        return Err("missing quic port".into());
    }

    let remote_payload = start_remote(&args.host, args.command_port, &auth_token)
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::Other, err))?;
    let session_info = remote_payload.get("session").and_then(|v| v.as_object());
    let session_id = remote_payload
        .get("session_id")
        .and_then(|v| v.as_str())
        .or_else(|| {
            session_info
                .and_then(|info| info.get("session_id"))
                .and_then(|v| v.as_str())
        })
        .ok_or("missing session_id")?
        .to_string();
    let token = remote_payload
        .get("token")
        .and_then(|v| v.as_str())
        .or_else(|| {
            session_info
                .and_then(|info| info.get("token"))
                .and_then(|v| v.as_str())
        })
        .ok_or("missing token")?
        .to_string();
    let connect_uri = session_info
        .and_then(|info| info.get("connect_uri"))
        .and_then(|v| v.as_str());
    let peer_id = parse_peer_id(connect_uri).ok_or("missing peer id")?;

    println!("remote session: {}", session_id);
    println!("peer id: {}", peer_id);
    println!("quic port: {}", quic_port);

    let runtime = tokio::runtime::Runtime::new()?;
    let stats = Arc::new(Mutex::new(FrameStats::new(Instant::now())));
    let stats_clone = stats.clone();
    let auth_token_clone = auth_token.clone();
    let host_clone = args.host.clone();
    let command_port = args.command_port;
    let duration = Duration::from_secs_f64(args.duration.max(0.1));
    let server_name = args.server_name.clone();
    let probe = args.probe;

    let session_id_for_hello = session_id.clone();
    runtime.block_on(async move {
        let client_config = build_insecure_client_config().map_err(|err| {
            let err: Box<dyn std::error::Error + Send + Sync> = err.into();
            err
        })?;
        let mut endpoint = Endpoint::client("[::]:0".parse::<SocketAddr>()?)?;
        endpoint.set_default_client_config(client_config);
        let addr = format!("{}:{}", host_clone, quic_port);
        let connecting = endpoint.connect(addr.parse::<SocketAddr>()?, &server_name)?;
        let connection = connecting.await?;

        let (mut ctrl_send, mut ctrl_recv) = connection.open_bi().await?;
        let hello = RemoteHello {
            message_type: "remote".to_string(),
            session_id: session_id_for_hello.clone(),
            token: token.clone(),
            auth_token: Some(auth_token_clone),
            client_id: Some("bench".to_string()),
            client_name: Some("remote-quic-smoke".to_string()),
        };
        send_json(&mut ctrl_send, &hello).await?;
        let ready: RemoteReady = read_json(&mut ctrl_recv).await?;
        if ready.status != "ready" {
            return Err(format!("remote not ready: {:?}", ready).into());
        }
        println!(
            "remote ready: status={} data_stream={}",
            ready.status, ready.data_stream
        );

        let ready_at = Instant::now();
        if let Ok(mut lock) = stats_clone.lock() {
            lock.ready_at = ready_at;
        }

        let (data_send, mut data_recv) = match ready.data_stream.as_str() {
            "server_bi" => connection.accept_bi().await?,
            "client_bi" | "next_bi" => connection.open_bi().await?,
            other => {
                println!("remote ready data_stream '{other}', defaulting to open_bi");
                connection.open_bi().await?
            }
        };
        if probe {
            let mut buf = vec![0u8; 1024];
            match tokio::time::timeout(Duration::from_millis(500), data_recv.read(&mut buf)).await {
                Ok(Ok(Some(n))) => println!("probe read bytes: {n}"),
                Ok(Ok(None)) => println!("probe read eof"),
                Ok(Err(err)) => println!("probe read error: {err}"),
                Err(_) => println!("probe read timeout"),
            }
            return Ok::<(), Box<dyn std::error::Error + Send + Sync>>(());
        }
        let stream = QuicBiStream {
            send: data_send,
            recv: data_recv,
            read_bytes: 0,
            write_bytes: 0,
        };
        let framed = FramedStream::from(stream, connection.remote_address());
        set_preconnected_stream(RustDeskStream::Tcp(framed));

        let (sender, receiver) = mpsc::unbounded_channel::<Data>();
        let ui = TestUi::new(token.clone(), sender.clone(), stats_clone.clone());
        let session: Session<TestUi> = Session {
            password: token.clone(),
            sender: Arc::new(RwLock::new(Some(sender.clone()))),
            ui_handler: ui,
            server_keyboard_enabled: Arc::new(RwLock::new(true)),
            server_file_transfer_enabled: Arc::new(RwLock::new(true)),
            server_clipboard_enabled: Arc::new(RwLock::new(true)),
            reconnect_count: Arc::new(AtomicUsize::new(0)),
            ..Default::default()
        };

        session.lc.write().unwrap().initialize(
            peer_id.clone(),
            ConnType::DEFAULT_CONN,
            None,
            false,
            None,
            None,
            None,
        );
        let round = session.connection_round_state.lock().unwrap().new_round();
        let mut remote = Remote::new(session, receiver, sender);

        tokio::select! {
            _ = remote.io_loop("", &token, round) => {
                println!("remote io_loop exited");
            },
            _ = tokio::time::sleep(duration) => {
                println!("duration reached, stopping");
            },
        }

        Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
    })?;

    if !args.no_stop {
        let _ = stop_remote(&args.host, command_port, &auth_token, &session_id);
    }

    if let Ok(stats) = stats.lock() {
        let first_ms = stats
            .first_frame_at
            .map(|t| t.duration_since(stats.ready_at).as_millis());
        println!("frames: {}", stats.frames);
        if let Some(size) = stats.last_size {
            println!("last_size: {}x{}", size.0, size.1);
        }
        match first_ms {
            Some(ms) => println!("first_frame_ms: {}", ms),
            None => println!("first_frame_ms: null"),
        }
    }

    Ok(())
}
