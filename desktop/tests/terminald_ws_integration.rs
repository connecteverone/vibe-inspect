#![cfg(not(target_os = "windows"))]

use desktop::terminal_core::{
    terminal_discovery_path, TerminalDiscoveryFile, TERMINALD_PROTOCOL_VERSION,
};
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
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

fn lock_test_env() -> std::sync::MutexGuard<'static, ()> {
    TEST_ENV_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .expect("lock test env")
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

async fn wait_for_discovery(
    child: &mut Child,
    path: &Path,
) -> TerminalDiscoveryFile {
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

    let discovery_path =
        terminal_discovery_path().expect("terminal discovery path");
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

async fn wait_for_event(
    socket: &mut WsStream,
    event: &str,
    session_id: Option<&str>,
) -> Value {
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

async fn connect_authed(ws_url: &str, token: &str) -> WsStream {
    let (mut socket, _) = connect_async(ws_url)
        .await
        .expect("connect websocket");
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

async fn wait_for_output(
    socket: &mut WsStream,
    session_id: &str,
    marker: &str,
) {
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
    attach_session(
        &mut socket,
        &format!("reattach-{request_id}"),
        &session_id,
    )
    .await;

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
    attach_session(&mut socket_a, &format!("attach-a-{request_id}"), &session_id).await;

    request_id += 1;
    attach_session(&mut socket_b, &format!("attach-b-{request_id}"), &session_id).await;

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
}
