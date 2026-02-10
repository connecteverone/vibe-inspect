#![cfg(not(target_os = "windows"))]

use desktop::terminal_core::{
    terminal_discovery_path, TerminalDiscoveryFile, TERMINALD_PROTOCOL_VERSION,
};
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use serde::Deserialize;
use serde_json::{json, Value};
use std::env;
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::time::{sleep, timeout};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

static TEST_ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

struct EnvGuard {
    vars: Vec<(&'static str, Option<String>)>,
}

impl EnvGuard {
    fn apply(pairs: &[(&'static str, String)]) -> Self {
        let mut vars = Vec::new();
        for (key, value) in pairs {
            vars.push((*key, env::var(*key).ok()));
            env::set_var(key, value);
        }
        Self { vars }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, value) in self.vars.drain(..) {
            match value {
                Some(value) => env::set_var(key, value),
                None => env::remove_var(key),
            }
        }
    }
}

struct TerminaldHandle {
    child: Child,
    _env_guard: EnvGuard,
    home_dir: PathBuf,
    ws_url: String,
    token: String,
}

impl Drop for TerminaldHandle {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.home_dir);
    }
}

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Debug, Deserialize)]
struct TerminalStreamGoldenFixture {
    name: String,
    script: String,
    markers: Vec<String>,
}

fn terminal_stream_golden_fixtures() -> Vec<TerminalStreamGoldenFixture> {
    serde_json::from_str(include_str!("fixtures/terminal_stream_golden.json"))
        .expect("parse terminal stream golden fixtures")
}

fn lock_test_env() -> std::sync::MutexGuard<'static, ()> {
    TEST_ENV_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
}

fn random_suffix(len: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(len)
        .map(char::from)
        .collect()
}

fn create_temp_home() -> PathBuf {
    let mut path = env::temp_dir();
    path.push(format!("terminald-test-{}", random_suffix(10)));
    fs::create_dir_all(&path).expect("create temp home");
    path
}

fn find_open_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    listener.local_addr().expect("local addr").port()
}

async fn wait_for_discovery(child: &mut Child, path: &Path) -> TerminalDiscoveryFile {
    let start = Instant::now();
    loop {
        if let Ok(contents) = fs::read_to_string(path) {
            if let Ok(discovery) = serde_json::from_str::<TerminalDiscoveryFile>(&contents) {
                return discovery;
            }
        }
        if let Ok(Some(status)) = child.try_wait() {
            panic!("terminald exited early: {status}");
        }
        if start.elapsed() > Duration::from_secs(5) {
            panic!("timed out waiting for discovery file at {}", path.display());
        }
        sleep(Duration::from_millis(50)).await;
    }
}

async fn start_terminald() -> TerminaldHandle {
    let home_dir = create_temp_home();
    let xdg_config = home_dir.join(".config");
    fs::create_dir_all(&xdg_config).expect("create xdg config");
    let env_guard = EnvGuard::apply(&[
        ("HOME", home_dir.to_string_lossy().into_owned()),
        ("XDG_CONFIG_HOME", xdg_config.to_string_lossy().into_owned()),
    ]);
    let bind = format!("127.0.0.1:{}", find_open_port());
    let mut child = Command::new(env!("CARGO_BIN_EXE_terminald"))
        .arg("--bind")
        .arg(&bind)
        .arg("--ws-path")
        .arg("/ws")
        .env("HOME", &home_dir)
        .env("XDG_CONFIG_HOME", &xdg_config)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn terminald");

    let discovery_path = terminal_discovery_path().expect("terminal discovery path");
    let discovery = wait_for_discovery(&mut child, &discovery_path).await;
    TerminaldHandle {
        child,
        _env_guard: env_guard,
        home_dir,
        ws_url: discovery.ws_url,
        token: discovery.token,
    }
}

fn build_request(
    request_id: &str,
    action: &str,
    session_id: Option<&str>,
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

async fn read_json(socket: &mut WsStream) -> Option<Value> {
    while let Some(message) = socket.next().await {
        match message {
            Ok(Message::Text(text)) => {
                if let Ok(value) = serde_json::from_str::<Value>(&text) {
                    return Some(value);
                }
            }
            Ok(Message::Close(_)) => return None,
            _ => {}
        }
    }
    None
}

async fn wait_for_response(socket: &mut WsStream, request_id: &str) -> Value {
    timeout(Duration::from_secs(6), async {
        loop {
            let Some(value) = read_json(socket).await else {
                panic!("socket closed before response {request_id}");
            };
            if value.get("type").and_then(Value::as_str) == Some("res")
                && value.get("id").and_then(Value::as_str) == Some(request_id)
            {
                return value;
            }
        }
    })
    .await
    .expect("response timeout")
}

async fn wait_for_event(socket: &mut WsStream, event: &str, session_id: Option<&str>) -> Value {
    timeout(Duration::from_secs(8), async {
        loop {
            let Some(value) = read_json(socket).await else {
                panic!("socket closed before event {event}");
            };
            if value.get("type").and_then(Value::as_str) != Some("event") {
                continue;
            }
            if value.get("event").and_then(Value::as_str) != Some(event) {
                continue;
            }
            if let Some(session_id) = session_id {
                if value.get("session_id").and_then(Value::as_str) != Some(session_id) {
                    continue;
                }
            }
            return value;
        }
    })
    .await
    .expect("event timeout")
}

async fn connect_ws(ws_url: &str) -> WsStream {
    let mut socket = None;
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(3) {
        match connect_async(ws_url).await {
            Ok((connected, _)) => {
                socket = Some(connected);
                break;
            }
            Err(_) => sleep(Duration::from_millis(60)).await,
        }
    }
    socket.expect("connect websocket")
}

async fn connect_authed(ws_url: &str, token: &str) -> WsStream {
    let mut socket = connect_ws(ws_url).await;
    let auth_id = "auth-1";
    let auth_payload = json!({
        "token": token,
        "version": TERMINALD_PROTOCOL_VERSION,
    });
    let auth_request = build_request(auth_id, "auth", None, Some(auth_payload));
    socket
        .send(Message::Text(auth_request.to_string().into()))
        .await
        .expect("send auth");
    let response = wait_for_response(&mut socket, auth_id).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    socket
}

async fn send_request(
    socket: &mut WsStream,
    request_id: &str,
    action: &str,
    session_id: Option<&str>,
    payload: Option<Value>,
) {
    let request = build_request(request_id, action, session_id, payload);
    socket
        .send(Message::Text(request.to_string().into()))
        .await
        .expect("send request");
}

#[derive(Debug, Default)]
struct DebugMetricsSnapshot {
    active_sessions: u64,
    active_connections: u64,
    dropped_chunks_total: u64,
    ws_backpressure_events_total: u64,
    ws_auth_attempts_total: u64,
    ws_auth_success_total: u64,
    reconnect_success_rate_percent: u64,
    pause_duration_p50_ms: u64,
    pause_duration_p95_ms: u64,
    pause_duration_samples_total: u64,
}

fn extract_debug_metric(metrics: &serde_json::Map<String, Value>, key: &str) -> u64 {
    metrics
        .get(key)
        .and_then(Value::as_u64)
        .unwrap_or_else(|| panic!("missing metric {key}"))
}

fn parse_debug_metrics(response: &Value) -> DebugMetricsSnapshot {
    let data = response
        .get("data")
        .and_then(Value::as_object)
        .expect("debug response data");
    let metrics = data
        .get("metrics")
        .and_then(Value::as_object)
        .expect("debug response metrics");

    DebugMetricsSnapshot {
        active_sessions: extract_debug_metric(metrics, "active_sessions"),
        active_connections: extract_debug_metric(metrics, "active_connections"),
        dropped_chunks_total: extract_debug_metric(metrics, "dropped_chunks_total"),
        ws_backpressure_events_total: extract_debug_metric(metrics, "ws_backpressure_events_total"),
        ws_auth_attempts_total: extract_debug_metric(metrics, "ws_auth_attempts_total"),
        ws_auth_success_total: extract_debug_metric(metrics, "ws_auth_success_total"),
        reconnect_success_rate_percent: extract_debug_metric(
            metrics,
            "reconnect_success_rate_percent",
        ),
        pause_duration_p50_ms: extract_debug_metric(metrics, "pause_duration_p50_ms"),
        pause_duration_p95_ms: extract_debug_metric(metrics, "pause_duration_p95_ms"),
        pause_duration_samples_total: extract_debug_metric(metrics, "pause_duration_samples_total"),
    }
}

async fn fetch_debug_metrics(socket: &mut WsStream, request_id: &str) -> DebugMetricsSnapshot {
    send_request(socket, request_id, "debug", None, None).await;
    let response = wait_for_response(socket, request_id).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    parse_debug_metrics(&response)
}

fn payload_output_text(payload: &Value) -> String {
    payload
        .get("output")
        .and_then(Value::as_array)
        .map(|output| {
            output
                .iter()
                .filter_map(|chunk| chunk.get("data").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

async fn wait_for_output(socket: &mut WsStream, session_id: &str, marker: &str) {
    timeout(Duration::from_secs(8), async {
        loop {
            let event = wait_for_event(socket, "terminal_payload", Some(session_id)).await;
            let Some(data) = event.get("data") else {
                continue;
            };
            let output = payload_output_text(data);
            if output.contains(marker) {
                return;
            }
        }
    })
    .await
    .expect("output timeout");
}

async fn wait_for_markers(socket: &mut WsStream, session_id: &str, markers: &[&str]) {
    let mut seen = vec![false; markers.len()];
    let mut recent = String::new();
    timeout(Duration::from_secs(10), async {
        loop {
            let event = wait_for_event(socket, "terminal_payload", Some(session_id)).await;
            let Some(data) = event.get("data") else {
                continue;
            };
            let output = payload_output_text(data);
            if !output.is_empty() {
                recent.push_str(&output);
                if recent.len() > 65_536 {
                    let drain_len = recent.len() - 65_536;
                    recent.drain(..drain_len);
                }
            }
            for (index, marker) in markers.iter().enumerate() {
                if recent.contains(marker) {
                    seen[index] = true;
                }
            }
            if seen.iter().all(|value| *value) {
                return;
            }
        }
    })
    .await
    .expect("markers timeout");
}

async fn run_terminal_stream_golden_fixture(
    socket: &mut WsStream,
    fixture: &TerminalStreamGoldenFixture,
    index: usize,
) {
    let session_id = start_session(socket, &format!("golden-start-{index}")).await;
    attach_session(socket, &format!("golden-attach-{index}"), &session_id).await;

    send_request(
        socket,
        &format!("golden-input-{index}"),
        "input",
        Some(&session_id),
        Some(json!({ "data": fixture.script })),
    )
    .await;

    let response = wait_for_response(socket, &format!("golden-input-{index}")).await;
    assert_eq!(
        response.get("ok").and_then(Value::as_bool),
        Some(true),
        "fixture {} input request failed",
        fixture.name
    );

    let marker_refs = fixture
        .markers
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    wait_for_markers(socket, &session_id, &marker_refs).await;

    send_request(
        socket,
        &format!("golden-stop-{index}"),
        "stop",
        Some(&session_id),
        None,
    )
    .await;
    let stop_response = wait_for_response(socket, &format!("golden-stop-{index}")).await;
    assert_eq!(
        stop_response.get("ok").and_then(Value::as_bool),
        Some(true),
        "fixture {} stop request failed",
        fixture.name
    );
}

async fn start_session(socket: &mut WsStream, request_id: &str) -> String {
    send_request(
        socket,
        request_id,
        "start",
        None,
        Some(json!({ "cols": 80, "rows": 24 })),
    )
    .await;
    let response = wait_for_response(socket, request_id).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    response
        .get("data")
        .and_then(|data| data.get("session_id"))
        .and_then(Value::as_str)
        .expect("session id")
        .to_string()
}

async fn attach_session(socket: &mut WsStream, request_id: &str, session_id: &str) {
    send_request(
        socket,
        request_id,
        "attach",
        Some(session_id),
        Some(json!({ "since": 0, "notify_since": 0 })),
    )
    .await;
    let response = wait_for_response(socket, request_id).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    let _ = wait_for_event(socket, "terminal_payload", Some(session_id)).await;
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_non_auth_first_message() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    send_request(&mut socket, "not-auth", "list", None, None).await;
    let response = wait_for_response(&mut socket, "not-auth").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("auth_required")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_invalid_auth_token() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    let request_id = "auth-invalid";
    let auth_payload = json!({
        "token": "totally-wrong-token",
        "version": TERMINALD_PROTOCOL_VERSION,
    });
    let auth_request = build_request(request_id, "auth", None, Some(auth_payload));
    socket
        .send(Message::Text(auth_request.to_string().into()))
        .await
        .expect("send auth");

    let response = wait_for_response(&mut socket, request_id).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("invalid_auth")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_oversized_auth_payload() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    let request_id = "auth-oversized";
    let auth_payload = json!({
        "token": "x".repeat(20_000),
        "version": TERMINALD_PROTOCOL_VERSION,
    });
    let auth_request = build_request(request_id, "auth", None, Some(auth_payload));
    socket
        .send(Message::Text(auth_request.to_string().into()))
        .await
        .expect("send auth");

    let response = timeout(Duration::from_secs(6), read_json(&mut socket))
        .await
        .expect("oversized auth timeout")
        .expect("oversized auth response");
    assert_eq!(response.get("type").and_then(Value::as_str), Some("res"));
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("auth_required")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn start_attach_echo_detach_reattach() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;
    let mut request_id = 0usize;

    request_id += 1;
    let session_id = start_session(&mut socket, &format!("start-{request_id}")).await;

    request_id += 1;
    attach_session(&mut socket, &format!("attach-{request_id}"), &session_id).await;

    let marker = format!("vibe-test-{}", random_suffix(6));
    request_id += 1;
    send_request(
        &mut socket,
        &format!("input-{request_id}"),
        "input",
        Some(&session_id),
        Some(json!({ "data": format!("echo {marker}\n") })),
    )
    .await;
    let response = wait_for_response(&mut socket, &format!("input-{request_id}")).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    wait_for_output(&mut socket, &session_id, &marker).await;

    request_id += 1;
    send_request(
        &mut socket,
        &format!("detach-{request_id}"),
        "detach",
        Some(&session_id),
        None,
    )
    .await;
    let response = wait_for_response(&mut socket, &format!("detach-{request_id}")).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    request_id += 1;
    attach_session(&mut socket, &format!("reattach-{request_id}"), &session_id).await;

    request_id += 1;
    send_request(
        &mut socket,
        &format!("stop-{request_id}"),
        "stop",
        Some(&session_id),
        None,
    )
    .await;
    let _ = wait_for_response(&mut socket, &format!("stop-{request_id}")).await;
}

#[tokio::test(flavor = "current_thread")]
async fn multi_attach_receives_output() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket_a = connect_authed(&terminald.ws_url, &terminald.token).await;
    let mut socket_b = connect_authed(&terminald.ws_url, &terminald.token).await;
    let mut request_id = 0usize;

    request_id += 1;
    let session_id = start_session(&mut socket_a, &format!("start-{request_id}")).await;

    request_id += 1;
    attach_session(
        &mut socket_a,
        &format!("attach-a-{request_id}"),
        &session_id,
    )
    .await;

    request_id += 1;
    attach_session(
        &mut socket_b,
        &format!("attach-b-{request_id}"),
        &session_id,
    )
    .await;

    let marker = format!("vibe-multi-{}", random_suffix(6));
    request_id += 1;
    send_request(
        &mut socket_a,
        &format!("input-{request_id}"),
        "input",
        Some(&session_id),
        Some(json!({ "data": format!("echo {marker}\n") })),
    )
    .await;
    let response = wait_for_response(&mut socket_a, &format!("input-{request_id}")).await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    let ((), ()) = tokio::join!(
        wait_for_output(&mut socket_a, &session_id, &marker),
        wait_for_output(&mut socket_b, &session_id, &marker)
    );
}

#[tokio::test(flavor = "current_thread")]
async fn utf8_ansi_and_clear_sequences_are_streamed() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-compat").await;
    attach_session(&mut socket, "attach-compat", &session_id).await;

    let script = r#"python3 -c 'import sys;sys.stdout.write("UTF8: 中文 😀 café\n");sys.stdout.write("\x1b[31mRED\x1b[0m \[1;34mBLUE\x1b[0m\n");[sys.stdout.write(f"\x1b[2J\x1b[Hframe-{i:02d}\n") for i in range(1, 21)];sys.stdout.flush()'
"#;

    send_request(
        &mut socket,
        "input-compat",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-compat").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &["UTF8: 中文 😀 café", "\u{1b}[31mRED\u{1b}[0m", "frame-20"],
    )
    .await;

    send_request(&mut socket, "stop-compat", "stop", Some(&session_id), None).await;
    let stop_response = wait_for_response(&mut socket, "stop-compat").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn osc8_truecolor_and_alt_screen_sequences_are_streamed() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-osc-alt").await;
    attach_session(&mut socket, "attach-osc-alt", &session_id).await;

    let script = r#"python3 -c 'import sys;e="\x1b";sys.stdout.write(f"{e}[38;2;1;200;120mTRUECOLOR_OK{e}[0m\n");sys.stdout.write(f"{e}]8;;https://example.com{e}\\OSC8_LINK{e}]8;;{e}\\\n");sys.stdout.write(f"{e}[?1049hALT_SCREEN_ON\n");[sys.stdout.write(f"{e}[2J{e}[Halt-frame-{i:02d}\n") for i in range(1, 16)];sys.stdout.write(f"{e}[?1049lALT_SCREEN_OFF\n");sys.stdout.flush()'
"#;

    send_request(
        &mut socket,
        "input-osc-alt",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-osc-alt").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &[
            "TRUECOLOR_OK",
            "\u{1b}]8;;https://example.com",
            "\u{1b}[?1049h",
            "alt-frame-15",
            "\u{1b}[?1049l",
            "ALT_SCREEN_OFF",
        ],
    )
    .await;

    send_request(&mut socket, "stop-osc-alt", "stop", Some(&session_id), None).await;
    let stop_response = wait_for_response(&mut socket, "stop-osc-alt").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn csi_sequences_and_bracketed_paste_are_streamed() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-csi").await;
    attach_session(&mut socket, "attach-csi", &session_id).await;

    let script = r#"python3 -c 'import sys;e="\x1b";sys.stdout.write(f"{e}[sCURSOR_SAVE{e}[uCURSOR_RESTORE\n");sys.stdout.write(f"{e}[2;5rSCROLL_REGION_SET\n{e}[rSCROLL_REGION_RESET\n");sys.stdout.write(f"{e}[LINSERT_LINE{e}[MDELETE_LINE\n");sys.stdout.write(f"{e}[?2004hBRACKET_MODE_ON\n{e}[200~PASTED_PAYLOAD{e}[201~\n{e}[?2004lBRACKET_MODE_OFF\n");sys.stdout.write("CSI_PHASE2_DONE\n");sys.stdout.flush()'
"#;

    send_request(
        &mut socket,
        "input-csi",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-csi").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &[
            "\u{1b}[sCURSOR_SAVE\u{1b}[uCURSOR_RESTORE",
            "\u{1b}[2;5r",
            "\u{1b}[rSCROLL_REGION_RESET",
            "\u{1b}[LINSERT_LINE\u{1b}[MDELETE_LINE",
            "\u{1b}[?2004h",
            "\u{1b}[200~PASTED_PAYLOAD\u{1b}[201~",
            "\u{1b}[?2004l",
            "CSI_PHASE2_DONE",
        ],
    )
    .await;

    send_request(&mut socket, "stop-csi", "stop", Some(&session_id), None).await;
    let stop_response = wait_for_response(&mut socket, "stop-csi").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn rapid_ansi_clear_stress_keeps_stream_alive() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-stress").await;
    attach_session(&mut socket, "attach-stress", &session_id).await;

    let script = r#"python3 -c 'import sys;e="\x1b";[sys.stdout.write(f"{e}[2J{e}[H{e}[38;5;{i%256}mstress-{i:03d} 😀 中文 {e}[0m\n") for i in range(1, 61)];sys.stdout.flush()'
"#;

    send_request(
        &mut socket,
        "input-stress",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-stress").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &["\u{1b}[2J\u{1b}[H", "stress-060", "😀 中文"],
    )
    .await;

    send_request(&mut socket, "stop-stress", "stop", Some(&session_id), None).await;
    let stop_response = wait_for_response(&mut socket, "stop-stress").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn golden_terminal_stream_fixtures_replay() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let fixtures = terminal_stream_golden_fixtures();
    assert!(
        !fixtures.is_empty(),
        "expected non-empty golden fixture set"
    );

    for (index, fixture) in fixtures.iter().enumerate() {
        run_terminal_stream_golden_fixture(&mut socket, fixture, index + 1).await;
    }

    let metrics = fetch_debug_metrics(&mut socket, "golden-debug").await;
    assert_eq!(
        metrics.dropped_chunks_total, 0,
        "golden replay should not drop terminal chunks"
    );
    assert_eq!(
        metrics.ws_backpressure_events_total, 0,
        "golden replay should stay under backpressure budget"
    );
    assert!(
        metrics.active_connections >= 1,
        "expected at least one active authenticated connection"
    );
    assert!(
        metrics.ws_auth_attempts_total >= 1 && metrics.ws_auth_success_total >= 1,
        "expected successful auth handshake metrics"
    );
    assert_eq!(
        metrics.reconnect_success_rate_percent, 100,
        "expected perfect reconnect success rate for nominal fixture run"
    );
    assert_eq!(
        metrics.pause_duration_samples_total, 0,
        "nominal fixture run should not accumulate pause duration samples"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn attach_requires_session_id() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    send_request(
        &mut socket,
        "attach-missing",
        "attach",
        None,
        Some(json!({ "since": 0, "notify_since": 0 })),
    )
    .await;
    let response = wait_for_response(&mut socket, "attach-missing").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    let error_code = response
        .get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_str);
    assert_eq!(error_code, Some("missing_session"));
}

#[tokio::test(flavor = "current_thread")]
async fn backpressure_triggers_snapshot_or_disconnect() {
    let _env_lock = lock_test_env();
    let _limits_guard = EnvGuard::apply(&[
        ("VIBE_TERMINALD_MAX_SEND_QUEUE_BYTES", "131072".to_string()),
        ("VIBE_TERMINALD_LOW_WATER_MARK_BYTES", "65536".to_string()),
    ]);
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;
    let mut request_id = 0usize;

    let mut session_ids = Vec::new();
    for _ in 0..4 {
        request_id += 1;
        session_ids.push(start_session(&mut socket, &format!("start-{request_id}")).await);
    }

    for session_id in &session_ids {
        request_id += 1;
        attach_session(&mut socket, &format!("attach-{request_id}"), session_id).await;
    }

    let payload = json!({ "data": "yes a | head -c 600000\n" });
    let mut paused = false;
    let mut snapshot_seen = false;
    let mut closed = false;

    for _ in 0..3 {
        for session_id in &session_ids {
            request_id += 1;
            let req_id = format!("input-{request_id}");
            send_request(
                &mut socket,
                &req_id,
                "input",
                Some(session_id),
                Some(payload.clone()),
            )
            .await;
            let response = wait_for_response(&mut socket, &req_id).await;
            assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
        }

        let deadline = Instant::now() + Duration::from_secs(6);
        while Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let message = timeout(remaining, socket.next()).await;
            match message {
                Ok(Some(Ok(Message::Text(text)))) => {
                    let Ok(value) = serde_json::from_str::<Value>(&text) else {
                        continue;
                    };
                    if value.get("type").and_then(Value::as_str) == Some("event") {
                        let event = value.get("event").and_then(Value::as_str).unwrap_or("");
                        match event {
                            "stream_paused" => paused = true,
                            "stream_resumed" => {}
                            "terminal_payload" => {
                                if let Some(data) = value.get("data") {
                                    let truncated = data
                                        .get("truncated")
                                        .and_then(Value::as_bool)
                                        .unwrap_or(false);
                                    let snapshot = data.get("snapshot").and_then(Value::as_str);
                                    if truncated && snapshot.is_some() {
                                        snapshot_seen = true;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Ok(Some(Ok(Message::Close(_)))) => {
                    closed = true;
                    break;
                }
                Ok(Some(Err(_))) | Ok(None) | Err(_) => break,
                _ => {}
            }
            if paused && (snapshot_seen || closed) {
                break;
            }
        }
        if paused && (snapshot_seen || closed) {
            break;
        }
    }

    assert!(paused, "expected stream_paused event");
    assert!(
        snapshot_seen || closed,
        "expected snapshot payload or disconnect after backpressure"
    );

    let mut metrics_socket = connect_authed(&terminald.ws_url, &terminald.token).await;
    let metrics = fetch_debug_metrics(&mut metrics_socket, "backpressure-debug").await;
    assert!(
        metrics.ws_backpressure_events_total >= 1,
        "expected backpressure metric to increment under stress"
    );
    assert!(
        metrics.active_sessions >= 1,
        "expected active terminal sessions to remain visible while stress test runs"
    );
    assert!(
        metrics.pause_duration_samples_total >= 1,
        "expected pause duration samples to be recorded after backpressure"
    );
    assert!(
        metrics.pause_duration_p95_ms >= metrics.pause_duration_p50_ms,
        "expected p95 pause duration to be >= p50"
    );
    assert!(
        metrics.reconnect_success_rate_percent <= 100,
        "reconnect success rate should stay within percentage bounds"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_auth_version_mismatch() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    let auth_request = build_request(
        "auth-version-mismatch",
        "auth",
        None,
        Some(json!({
            "token": terminald.token,
            "version": "2.0",
        })),
    );
    socket
        .send(Message::Text(auth_request.to_string().into()))
        .await
        .expect("send auth");

    let response = wait_for_response(&mut socket, "auth-version-mismatch").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("version_mismatch")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_missing_auth_token_payload() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    let auth_request = build_request(
        "auth-missing-token",
        "auth",
        None,
        Some(json!({ "version": TERMINALD_PROTOCOL_VERSION })),
    );
    socket
        .send(Message::Text(auth_request.to_string().into()))
        .await
        .expect("send auth");

    let response = wait_for_response(&mut socket, "auth-missing-token").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("invalid_auth")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_binary_message_during_auth_handshake() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    socket
        .send(Message::Binary(vec![0x89, 0x50, 0x4e, 0x47].into()))
        .await
        .expect("send binary auth frame");

    let response = timeout(Duration::from_secs(4), async {
        read_json(&mut socket).await
    })
    .await
    .expect("auth failure response timeout")
    .expect("auth failure response");

    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("auth_required")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn unicode_grapheme_clusters_and_zwj_sequences_are_streamed() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-unicode-grapheme").await;
    attach_session(&mut socket, "attach-unicode-grapheme", &session_id).await;

    let script = r#"python3 - <<'PY'
import sys, time
frames = [
    "e\u0301 COMBINING_OK\\n",
    "👩\u200d💻 ZWJ_OK\\n",
    "🏳️\u200d🌈 VS16_ZWJ_OK\\n",
    "\x1b[38;2;10;200;120mCOLOR_OK\x1b[0m\\n",
    "UNICODE_PHASE_DONE\\n",
]
for frame in frames:
    sys.stdout.write(frame)
    sys.stdout.flush()
    time.sleep(0.01)
PY
"#;

    send_request(
        &mut socket,
        "input-unicode-grapheme",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-unicode-grapheme").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &[
            "e\u{301} COMBINING_OK",
            "👩\u{200d}💻 ZWJ_OK",
            "🏳️\u{200d}🌈 VS16_ZWJ_OK",
            "\u{1b}[38;2;10;200;120mCOLOR_OK\u{1b}[0m",
            "UNICODE_PHASE_DONE",
        ],
    )
    .await;

    send_request(
        &mut socket,
        "stop-unicode-grapheme",
        "stop",
        Some(&session_id),
        None,
    )
    .await;
    let stop_response = wait_for_response(&mut socket, "stop-unicode-grapheme").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn split_escape_sequences_and_bel_osc8_are_streamed() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-split-esc").await;
    attach_session(&mut socket, "attach-split-esc", &session_id).await;

    let script = r#"python3 - <<'PY'
import sys, time
chunks = [
    b"\x1b[", b"2J", b"\x1b[", b"H", b"SPLIT_CLEAR_OK\\n",
    b"\x1b[38;2;255;0;120m", b"SPLIT_COLOR_OK", b"\x1b[0m\\n",
    b"\x1b]8;;https://example.com\x07", b"BEL_LINK", b"\x1b]8;;\x07\\n",
    b"SPLIT_ESCAPE_PHASE_DONE\\n",
]
out = sys.stdout.buffer
for chunk in chunks:
    out.write(chunk)
    out.flush()
    time.sleep(0.005)
PY
"#;

    send_request(
        &mut socket,
        "input-split-esc",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-split-esc").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &[
            "\u{1b}[2J\u{1b}[HSPLIT_CLEAR_OK",
            "\u{1b}[38;2;255;0;120mSPLIT_COLOR_OK\u{1b}[0m",
            "\u{1b}]8;;https://example.com\u{7}BEL_LINK\u{1b}]8;;\u{7}",
            "SPLIT_ESCAPE_PHASE_DONE",
        ],
    )
    .await;

    send_request(
        &mut socket,
        "stop-split-esc",
        "stop",
        Some(&session_id),
        None,
    )
    .await;
    let stop_response = wait_for_response(&mut socket, "stop-split-esc").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn sustained_high_volume_utf8_ansi_burst_keeps_tail_integrity() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_authed(&terminald.ws_url, &terminald.token).await;

    let session_id = start_session(&mut socket, "start-burst").await;
    attach_session(&mut socket, "attach-burst", &session_id).await;

    let script = r#"python3 -c 'import sys; e="\x1b"; [sys.stdout.write(f"{e}[38;5;{i%256}mline-{i:04d} 🚀 数据 {e}[0m\\n") for i in range(1, 901)]; sys.stdout.write("BURST_TAIL_OK\\n"); sys.stdout.flush()'
"#;

    send_request(
        &mut socket,
        "input-burst",
        "input",
        Some(&session_id),
        Some(json!({ "data": script })),
    )
    .await;
    let response = wait_for_response(&mut socket, "input-burst").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));

    wait_for_markers(
        &mut socket,
        &session_id,
        &["line-0900", "🚀 数据", "BURST_TAIL_OK"],
    )
    .await;

    send_request(&mut socket, "stop-burst", "stop", Some(&session_id), None).await;
    let stop_response = wait_for_response(&mut socket, "stop-burst").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}

#[tokio::test(flavor = "current_thread")]
async fn rejects_auth_timeout_when_client_sends_nothing() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;
    let mut socket = connect_ws(&terminald.ws_url).await;

    let response = timeout(Duration::from_secs(5), async {
        read_json(&mut socket).await
    })
    .await
    .expect("auth-timeout response timeout")
    .expect("auth-timeout response");

    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        response
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str),
        Some("auth_required")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn reconnect_attach_continues_session_stream_and_metrics() {
    let _env_lock = lock_test_env();
    let terminald = start_terminald().await;

    let mut socket1 = connect_authed(&terminald.ws_url, &terminald.token).await;
    let session_id = start_session(&mut socket1, "start-reconnect").await;
    attach_session(&mut socket1, "attach-reconnect-1", &session_id).await;

    let stage1_script = "printf 'RECONNECT_STAGE1\\n'\n";
    send_request(
        &mut socket1,
        "input-reconnect-1",
        "input",
        Some(&session_id),
        Some(json!({ "data": stage1_script })),
    )
    .await;
    let response = wait_for_response(&mut socket1, "input-reconnect-1").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    wait_for_markers(&mut socket1, &session_id, &["RECONNECT_STAGE1"]).await;

    let _ = socket1.send(Message::Close(None)).await;

    let mut socket2 = connect_authed(&terminald.ws_url, &terminald.token).await;
    attach_session(&mut socket2, "attach-reconnect-2", &session_id).await;

    let stage2_script = "printf 'RECONNECT_STAGE2\\n'\n";
    send_request(
        &mut socket2,
        "input-reconnect-2",
        "input",
        Some(&session_id),
        Some(json!({ "data": stage2_script })),
    )
    .await;
    let response = wait_for_response(&mut socket2, "input-reconnect-2").await;
    assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
    wait_for_markers(&mut socket2, &session_id, &["RECONNECT_STAGE2"]).await;

    let metrics = fetch_debug_metrics(&mut socket2, "debug-reconnect-metrics").await;
    assert!(
        metrics.ws_auth_attempts_total >= 2,
        "expected at least two auth attempts after reconnect"
    );
    assert!(
        metrics.ws_auth_success_total >= 2,
        "expected at least two auth successes after reconnect"
    );
    assert_eq!(
        metrics.reconnect_success_rate_percent, 100,
        "expected reconnect success rate to stay at 100 in reconnect test"
    );

    send_request(
        &mut socket2,
        "stop-reconnect",
        "stop",
        Some(&session_id),
        None,
    )
    .await;
    let stop_response = wait_for_response(&mut socket2, "stop-reconnect").await;
    assert_eq!(stop_response.get("ok").and_then(Value::as_bool), Some(true));
}
