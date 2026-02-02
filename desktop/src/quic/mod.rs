use crate::auth::{
    ensure_auth_not_blocked, ensure_client_allowed, record_client_activity, track_client_connection,
    validate_auth_token, AuthError,
};
use crate::pairing::PairingState;
use crate::roi::{
    build_tiles, RoiCapturer, RoiFrame, RoiManager, RoiSessionInfo, RoiTile, RoiTileCache,
    RoiViewport,
};
use crate::vnc::serve_vnc_quic;
use bytes::Bytes;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use quinn::{Endpoint, ServerConfig};
use rcgen::generate_simple_self_signed;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::io::Write;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

pub mod protocol;
use protocol::{
    RoiHello, RoiReady, RoiRequest, VncError, VncHello, VncReady, ROI_CODEC_RAW, ROI_CODEC_ZLIB,
    ROI_DATAGRAM_HEADER_SIZE, ROI_DATAGRAM_MAGIC,
};

#[derive(Clone)]
pub struct QuicServerConfig {
    pub port: u16,
    pub roi: Option<Arc<Mutex<RoiManager>>>,
    pub vnc: Option<Arc<Mutex<crate::vnc::VncManager>>>,
    pub pairing: Option<Arc<Mutex<PairingState>>>,
}

pub struct QuicServerHandle {
    pub port: u16,
    running: Arc<AtomicBool>,
}

impl QuicServerHandle {
    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }
}

pub fn start_quic_server(config: QuicServerConfig) -> Result<QuicServerHandle, std::io::Error> {
    let running = Arc::new(AtomicBool::new(true));
    let port = config.port;
    if port == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "ROI QUIC port must be between 1 and 65535.",
        ));
    }
    let roi = config.roi;
    let vnc = config.vnc;
    let pairing = config.pairing;
    if roi.is_none() && vnc.is_none() {
        return Ok(QuicServerHandle { port, running });
    }
    let (tx, rx) = mpsc::channel();
    let running_handle = running.clone();
    let roi_handle = roi.clone();
    let vnc_handle = vnc.clone();
    let pairing_handle = pairing.clone();
    thread::spawn(move || {
        let runtime = match tokio::runtime::Runtime::new() {
            Ok(runtime) => runtime,
            Err(error) => {
                let _ = tx.send(Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    error.to_string(),
                )));
                return;
            }
        };
        runtime.block_on(async move {
            let result: Result<(Endpoint, u16), std::io::Error> = (|| {
                let bind_addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, port));
                let server_config = build_server_config().map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::Other, error.to_string())
                })?;
                let endpoint = Endpoint::server(server_config, bind_addr)?;
                let actual_port = endpoint.local_addr()?.port();
                if actual_port != port {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::AddrInUse,
                        format!("ROI QUIC port {port} unavailable."),
                    ));
                }
                Ok((endpoint, actual_port))
            })();

            match result {
                Ok((endpoint, actual_port)) => {
                    let _ = tx.send(Ok(actual_port));
                    run_quic_server(
                        endpoint,
                        roi_handle,
                        vnc_handle,
                        pairing_handle,
                        running_handle,
                    )
                    .await;
                }
                Err(error) => {
                    let _ = tx.send(Err(error));
                }
            }
        });
    });
    match rx.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok(port)) => Ok(QuicServerHandle { port, running }),
        Ok(Err(error)) => Err(error),
        Err(error) => Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!("ROI QUIC server start timed out: {error}"),
        )),
    }
}

async fn run_quic_server(
    endpoint: Endpoint,
    roi: Option<Arc<Mutex<RoiManager>>>,
    vnc: Option<Arc<Mutex<crate::vnc::VncManager>>>,
    pairing: Option<Arc<Mutex<PairingState>>>,
    running: Arc<AtomicBool>,
) {
    while running.load(Ordering::SeqCst) {
        let Some(connecting) = endpoint.accept().await else {
            continue;
        };
        let roi = roi.clone();
        let vnc = vnc.clone();
        let pairing = pairing.clone();
        tokio::spawn(async move {
            if let Ok(connection) = connecting.await {
                let remote = connection.remote_address();
                eprintln!("QUIC accepted: remote={remote}");
                if let Err(error) = handle_connection(connection, roi, vnc, pairing).await {
                eprintln!("QUIC connection error: {error}");
                }
            }
        });
    }
}

async fn handle_connection(
    connection: quinn::Connection,
    roi: Option<Arc<Mutex<RoiManager>>>,
    vnc: Option<Arc<Mutex<crate::vnc::VncManager>>>,
    pairing: Option<Arc<Mutex<PairingState>>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (mut send, mut recv) = connection.accept_bi().await?;
    let hello_value: JsonValue = read_json_message(&mut recv).await?;
    let protocol = hello_value
        .get("type")
        .and_then(|value| value.as_str())
        .unwrap_or("roi");
    if protocol == "vnc" {
        let Some(vnc) = vnc else {
            send_json_message(
                &mut send,
                &VncError {
                    status: "error".to_string(),
                    code: "unsupported".to_string(),
                    message: "VNC over QUIC is not enabled.".to_string(),
                    retry_after: None,
                },
            )
            .await?;
            return Ok(());
        };
        let Some(pairing) = pairing else {
            send_json_message(
                &mut send,
                &VncError {
                    status: "error".to_string(),
                    code: "state_locked".to_string(),
                    message: "Pairing state unavailable.".to_string(),
                    retry_after: None,
                },
            )
            .await?;
            return Ok(());
        };
        return handle_vnc_quic_connection(connection, vnc, pairing, hello_value, send, recv).await;
    }
    let roi = match roi {
        Some(manager) => manager,
        None => {
            return Err(Box::new(std::io::Error::new(
                std::io::ErrorKind::Other,
                "roi disabled",
            )))
        }
    };
    let hello: RoiHello = serde_json::from_value(hello_value)?;
    eprintln!(
        "ROI QUIC hello: session_id={} token_len={}",
        hello.session_id,
        hello.token.len()
    );
    let info = {
        let guard = roi.lock().map_err(|_| "roi lock")?;
        guard
            .get_session(&hello.session_id, &hello.token)
            .ok_or("invalid roi session")?
    };
    let max_datagram = connection.max_datagram_size().unwrap_or(0);
    let ready = RoiReady {
        status: "ready".to_string(),
        session_id: info.session_id.clone(),
        max_datagram_size: max_datagram,
        quic_port: info.quic_port,
        display_index: info.display_index,
        framebuffer_width: info.framebuffer_width,
        framebuffer_height: info.framebuffer_height,
        screen_width: info.screen_width,
        screen_height: info.screen_height,
    };
    send_json_message(&mut send, &ready).await?;
    eprintln!(
        "ROI QUIC ready: session_id={} quic_port={} max_datagram={} framebuffer={}x{} screen={}x{}",
        ready.session_id,
        ready.quic_port,
        ready.max_datagram_size,
        ready.framebuffer_width,
        ready.framebuffer_height,
        ready.screen_width,
        ready.screen_height,
    );

    let running = Arc::new(AtomicBool::new(true));
    let request_state = Arc::new(Mutex::new(None::<RoiRequest>));
    let reader_running = running.clone();
    let reader_state = request_state.clone();
    tokio::spawn(async move {
        let mut logged_request = false;
        loop {
            match read_json_message::<RoiRequest>(&mut recv).await {
                Ok(request) => {
                    if !request.is_valid() {
                        eprintln!("ROI QUIC request ignored: invalid numeric values");
                        continue;
                    }
                    if !logged_request {
                        eprintln!(
                            "ROI QUIC request: center=({:.1},{:.1}) zoom={:.2} viewport={:.1}x{:.1} prefetch={:.1}",
                            request.center_x,
                            request.center_y,
                            request.zoom,
                            request.viewport_width,
                            request.viewport_height,
                            request.prefetch_radius
                        );
                        logged_request = true;
                    }
                    if let Ok(mut guard) = reader_state.lock() {
                        *guard = Some(request);
                    }
                }
                Err(_) => break,
            }
        }
        reader_running.store(false, Ordering::SeqCst);
    });

    let send_connection = connection.clone();
    let session_id = info.session_id.clone();
    let capture_running = running.clone();
    let capture_state = request_state.clone();
    thread::spawn(move || {
        run_roi_stream(send_connection, info, capture_state, capture_running);
    });

    while running.load(Ordering::SeqCst) {
        tokio::time::sleep(Duration::from_millis(120)).await;
    }
    eprintln!("ROI QUIC closed: session_id={}", session_id);
    Ok(())
}

async fn handle_vnc_quic_connection(
    connection: quinn::Connection,
    vnc: Arc<Mutex<crate::vnc::VncManager>>,
    pairing: Arc<Mutex<PairingState>>,
    hello_value: JsonValue,
    mut send: quinn::SendStream,
    recv: quinn::RecvStream,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let hello: VncHello = serde_json::from_value(hello_value)?;
    let auth_token = hello.auth_token.clone().unwrap_or_default();
    let client_id = hello.client_id.clone();
    let client_name = hello.client_name.clone();
    if let Err(error) = ensure_auth_not_blocked(&pairing, client_id.as_deref()) {
        send_vnc_error(&mut send, error).await?;
        return Ok(());
    }
    if let Err(error) = validate_auth_token(&pairing, &auth_token, client_id.as_deref()) {
        send_vnc_error(&mut send, error).await?;
        return Ok(());
    }
    if let Err(error) = ensure_client_allowed(&pairing, &client_id) {
        send_vnc_error(&mut send, error).await?;
        return Ok(());
    }
    record_client_activity(&pairing, client_id.clone(), client_name, None);
    let _guard = track_client_connection(&pairing, client_id);
    let session_valid = {
        let manager = vnc.lock().map_err(|_| "vnc lock")?;
        manager.session_exists(&hello.session_id, &hello.token)
    };
    if !session_valid {
        send_json_message(
            &mut send,
            &VncError {
                status: "error".to_string(),
                code: "invalid_session".to_string(),
                message: "Invalid VNC session.".to_string(),
                retry_after: None,
            },
        )
        .await?;
        return Ok(());
    }
    send_json_message(
        &mut send,
        &VncReady {
            status: "ready".to_string(),
            session_id: hello.session_id.clone(),
        },
    )
    .await?;
    if let Err(error) = serve_vnc_quic(
        send,
        recv,
        connection,
        vnc,
        hello.session_id.clone(),
        hello.token,
    )
    .await
    {
        eprintln!("VNC QUIC session error: {error}");
    }
    Ok(())
}

async fn send_vnc_error(
    send: &mut quinn::SendStream,
    error: AuthError,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    send_json_message(
        send,
        &VncError {
            status: "error".to_string(),
            code: error.code.to_string(),
            message: error.message,
            retry_after: error.retry_after,
        },
    )
    .await?;
    Ok(())
}

async fn read_json_message<T: for<'de> Deserialize<'de>>(
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

async fn send_json_message<T: Serialize>(
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

fn build_server_config() -> Result<ServerConfig, Box<dyn std::error::Error + Send + Sync>> {
    let cert = generate_simple_self_signed(vec!["vibe-inspect".to_string()])?;
    let key = PrivateKeyDer::Pkcs8(cert.serialize_private_key_der().into());
    let cert_der = CertificateDer::from(cert.serialize_der()?);
    let mut server_config = ServerConfig::with_single_cert(vec![cert_der], key)?;
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    transport.max_idle_timeout(Some(Duration::from_secs(20).try_into()?));
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    server_config.transport = Arc::new(transport);
    Ok(server_config)
}

fn run_roi_stream(
    connection: quinn::Connection,
    info: RoiSessionInfo,
    request_state: Arc<Mutex<Option<RoiRequest>>>,
    running: Arc<AtomicBool>,
) {
    let fake_capture = std::env::var("ROI_FAKE_CAPTURE")
        .ok()
        .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let fake_frame = if fake_capture {
        Some(build_fake_frame(&info))
    } else {
        None
    };
    let mut capturer = if fake_capture {
        None
    } else {
        match RoiCapturer::new(
            info.display_index,
            info.screen_width,
            info.screen_height,
        ) {
            Ok(capturer) => Some(capturer),
            Err(error) => {
                eprintln!("ROI capture init failed: {error}");
                return;
            }
        }
    };
    let mut cache = RoiTileCache::new();
    let mut frame_id: u32 = 0;
    let max_datagram = connection.max_datagram_size().unwrap_or(1200);
    let tile_size = 64u32;
    while running.load(Ordering::SeqCst) {
        let request = {
            if let Ok(guard) = request_state.lock() {
                guard.clone()
            } else {
                None
            }
        };
        let Some(request) = request else {
            thread::sleep(Duration::from_millis(80));
            continue;
        };
        let interval = resolve_roi_interval(request.zoom);
        let budget = resolve_roi_budget(request.zoom);
        if let Some(frame) = fake_frame.as_ref() {
            frame_id = frame_id.wrapping_add(1);
            let viewport = RoiViewport {
                center_x: request.center_x,
                center_y: request.center_y,
                viewport_width: request.viewport_width,
                viewport_height: request.viewport_height,
                prefetch_radius: request.prefetch_radius,
                zoom: request.zoom,
            };
            let tiles = build_tiles(
                frame,
                &info,
                &viewport,
                tile_size,
                frame_id,
                frame_id & 1 == 1,
                budget,
                &mut cache,
            );
            for tile in tiles {
                if send_tile_datagrams(&connection, &tile, max_datagram).is_err() {
                    running.store(false, Ordering::SeqCst);
                    break;
                }
            }
        } else if let Some(capturer) = capturer.as_mut() {
            if let Some(frame) = capturer.capture() {
            frame_id = frame_id.wrapping_add(1);
            let viewport = RoiViewport {
                center_x: request.center_x,
                center_y: request.center_y,
                viewport_width: request.viewport_width,
                viewport_height: request.viewport_height,
                prefetch_radius: request.prefetch_radius,
                zoom: request.zoom,
            };
            let tiles = build_tiles(
                &frame,
                &info,
                &viewport,
                tile_size,
                frame_id,
                frame_id & 1 == 1,
                budget,
                &mut cache,
            );
            for tile in tiles {
                if send_tile_datagrams(&connection, &tile, max_datagram).is_err() {
                    running.store(false, Ordering::SeqCst);
                    break;
                }
            }
            }
        }
        thread::sleep(interval);
    }
}

fn resolve_roi_interval(zoom: f64) -> Duration {
    if !zoom.is_finite() || zoom <= 0.0 {
        return Duration::from_millis(32);
    }
    if zoom >= 2.0 {
        Duration::from_millis(12)
    } else if zoom >= 1.5 {
        Duration::from_millis(16)
    } else if zoom >= 1.2 {
        Duration::from_millis(24)
    } else {
        Duration::from_millis(32)
    }
}

fn resolve_roi_budget(zoom: f64) -> usize {
    if !zoom.is_finite() || zoom <= 0.0 {
        return 180;
    }
    if zoom >= 2.0 {
        320
    } else if zoom >= 1.5 {
        260
    } else if zoom >= 1.2 {
        220
    } else {
        180
    }
}

fn build_fake_frame(info: &RoiSessionInfo) -> RoiFrame {
    let width = info.screen_width.max(info.framebuffer_width).max(1) as usize;
    let height = info.screen_height.max(info.framebuffer_height).max(1) as usize;
    let mut data = vec![0u8; width * height * 4];
    for y in 0..height {
        for x in 0..width {
            let idx = (y * width + x) * 4;
            data[idx] = (x % 255) as u8;
            data[idx + 1] = (y % 255) as u8;
            data[idx + 2] = ((x + y) % 255) as u8;
            data[idx + 3] = 255;
        }
    }
    RoiFrame { data, width, height }
}

fn send_tile_datagrams(
    connection: &quinn::Connection,
    tile: &RoiTile,
    max_datagram: usize,
) -> Result<(), ()> {
    if max_datagram <= ROI_DATAGRAM_HEADER_SIZE + 8 {
        return Err(());
    }
    let max_payload = max_datagram - ROI_DATAGRAM_HEADER_SIZE;
    let raw_payload = &tile.pixels;
    let mut codec = ROI_CODEC_RAW;
    let payload = if raw_payload.len() > max_payload {
        if let Ok(compressed) = compress_zlib(raw_payload) {
            if compressed.len() < raw_payload.len() {
                codec = ROI_CODEC_ZLIB;
                compressed
            } else {
                raw_payload.to_vec()
            }
        } else {
            raw_payload.to_vec()
        }
    } else {
        raw_payload.to_vec()
    };
    let chunk_count = ((payload.len() + max_payload - 1) / max_payload).max(1);
    if chunk_count > u16::MAX as usize {
        return Err(());
    }
    for chunk_index in 0..chunk_count {
        let start = chunk_index * max_payload;
        let end = (start + max_payload).min(payload.len());
        let chunk = &payload[start..end];
        let mut buffer = Vec::with_capacity(ROI_DATAGRAM_HEADER_SIZE + chunk.len());
        buffer.extend_from_slice(ROI_DATAGRAM_MAGIC);
        buffer.extend_from_slice(&tile.frame_id.to_le_bytes());
        buffer.extend_from_slice(&tile.logical_x.to_le_bytes());
        buffer.extend_from_slice(&tile.logical_y.to_le_bytes());
        buffer.extend_from_slice(&tile.logical_w.to_le_bytes());
        buffer.extend_from_slice(&tile.logical_h.to_le_bytes());
        buffer.extend_from_slice(&tile.pixel_w.to_le_bytes());
        buffer.extend_from_slice(&tile.pixel_h.to_le_bytes());
        buffer.push(1u8);
        buffer.push(codec);
        buffer.extend_from_slice(&(chunk_index as u16).to_le_bytes());
        buffer.extend_from_slice(&(chunk_count as u16).to_le_bytes());
        buffer.extend_from_slice(&(chunk.len() as u16).to_le_bytes());
        buffer.extend_from_slice(chunk);
        if connection.send_datagram(Bytes::from(buffer)).is_err() {
            return Err(());
        }
    }
    Ok(())
}

fn compress_zlib(payload: &[u8]) -> Result<Vec<u8>, std::io::Error> {
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(payload)?;
    encoder.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roi::{RoiManager, RoiSessionRequest};
    use quinn::Endpoint;
    use rustls::client::danger::ServerCertVerifier;
    use std::net::SocketAddr;
    use std::sync::{Arc, Mutex};
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn quic_roi_handshake_and_datagram() {
        std::env::set_var("ROI_FAKE_CAPTURE", "1");
        let roi_manager = Arc::new(Mutex::new(RoiManager::new(0)));
        let server_config = build_server_config().expect("server config");
        let endpoint = Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap())
            .expect("endpoint");
        let port = endpoint.local_addr().expect("addr").port();
        let running = Arc::new(AtomicBool::new(true));
        let runner = {
            let roi = roi_manager.clone();
            let running = running.clone();
            tokio::spawn(async move {
                run_quic_server(endpoint, Some(roi), None, None, running).await;
            })
        };

        let info = {
            let mut manager = roi_manager.lock().unwrap();
            manager.start_session(RoiSessionRequest {
                session_id: "roi-test".to_string(),
                vnc_session_id: "vnc-test".to_string(),
                client_id: None,
                client_name: None,
                display_index: None,
                framebuffer_width: 640,
                framebuffer_height: 360,
                screen_width: 1280,
                screen_height: 720,
            })
        };

        let mut client_endpoint =
            Endpoint::client("0.0.0.0:0".parse::<SocketAddr>().unwrap())
                .expect("client endpoint");
        client_endpoint.set_default_client_config(build_insecure_client_config());
        let connection = client_endpoint
            .connect(SocketAddr::from(([127, 0, 0, 1], port)), "vibe-inspect")
            .expect("connect")
            .await
            .expect("connected");

        let (mut send, mut recv) = connection.open_bi().await.expect("open bi");
        let hello = serde_json::to_vec(&RoiHello {
            session_id: info.session_id.clone(),
            token: info.token.clone(),
        })
        .expect("hello");
        let mut hello_buf = Vec::with_capacity(4 + hello.len());
        hello_buf.extend_from_slice(&(hello.len() as u32).to_be_bytes());
        hello_buf.extend_from_slice(&hello);
        send.write_all(&hello_buf).await.expect("send hello");
        send.flush().await.expect("flush");

        let mut len_buf = [0u8; 4];
        recv.read_exact(&mut len_buf).await.expect("read len");
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut payload = vec![0u8; len];
        recv.read_exact(&mut payload).await.expect("read payload");
        let _ready: RoiReady = serde_json::from_slice(&payload).expect("ready");

        let request = serde_json::to_vec(&RoiRequest {
            center_x: 320.0,
            center_y: 180.0,
            zoom: 2.0,
            viewport_width: 240.0,
            viewport_height: 135.0,
            prefetch_radius: 120.0,
        })
        .expect("request");
        let mut req_buf = Vec::with_capacity(4 + request.len());
        req_buf.extend_from_slice(&(request.len() as u32).to_be_bytes());
        req_buf.extend_from_slice(&request);
        send.write_all(&req_buf).await.expect("send request");
        send.flush().await.expect("flush request");

        let datagram = timeout(Duration::from_secs(2), connection.read_datagram())
            .await
            .expect("timeout")
            .expect("datagram");
        assert!(datagram.len() > 8);

        running.store(false, Ordering::SeqCst);
        drop(connection);
        drop(client_endpoint);
        let _ = timeout(Duration::from_millis(200), runner).await;
    }

    fn build_insecure_client_config() -> quinn::ClientConfig {
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            let _ = rustls::crypto::ring::default_provider().install_default();
        }
        let crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(SkipServerVerification::new())
            .with_no_client_auth();
        let mut config = quinn::ClientConfig::new(
            Arc::new(
                quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
                    .expect("quic client config"),
            ),
        );
        let mut transport = quinn::TransportConfig::default();
        transport.max_concurrent_bidi_streams(100u32.into());
        config.transport_config(Arc::new(transport));
        config
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
            _end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            vec![
                rustls::SignatureScheme::RSA_PKCS1_SHA256,
                rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
                rustls::SignatureScheme::ED25519,
            ]
        }
    }
}
