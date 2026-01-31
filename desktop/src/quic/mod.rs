use crate::roi::{
    build_tiles, RoiCapturer, RoiManager, RoiSessionInfo, RoiTile, RoiTileCache, RoiViewport,
};
use bytes::Bytes;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use quinn::{Endpoint, ServerConfig};
use rcgen::generate_simple_self_signed;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

#[derive(Clone)]
pub struct QuicServerConfig {
    pub port: u16,
    pub roi: Option<Arc<Mutex<RoiManager>>>,
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
    if config.port == 0 {
        return Ok(QuicServerHandle { port: 0, running });
    }
    let roi = match config.roi {
        Some(manager) => manager,
        None => {
            return Ok(QuicServerHandle {
                port: config.port,
                running,
            })
        }
    };
    let bind_addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, config.port));
    let server_config = build_server_config().map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::Other, error.to_string())
    })?;
    let endpoint = Endpoint::server(server_config, bind_addr)?;
    let actual_port = endpoint.local_addr()?.port();
    let running_handle = running.clone();
    let roi_handle = roi.clone();
    thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new().expect("quic runtime");
        runtime.block_on(async move {
            run_quic_server(endpoint, roi_handle, running_handle).await;
        });
    });
    Ok(QuicServerHandle {
        port: actual_port,
        running,
    })
}

async fn run_quic_server(
    endpoint: Endpoint,
    roi: Arc<Mutex<RoiManager>>,
    running: Arc<AtomicBool>,
) {
    while running.load(Ordering::SeqCst) {
        let Some(connecting) = endpoint.accept().await else {
            continue;
        };
        let roi = roi.clone();
        tokio::spawn(async move {
            if let Ok(connection) = connecting.await {
                if let Err(error) = handle_connection(connection, roi).await {
                    eprintln!("ROI QUIC connection error: {error}");
                }
            }
        });
    }
}

#[derive(Debug, Deserialize)]
struct RoiHello {
    session_id: String,
    token: String,
}

#[derive(Debug, Serialize)]
struct RoiReady {
    status: String,
    session_id: String,
    max_datagram_size: usize,
    display_index: Option<usize>,
    framebuffer_width: u32,
    framebuffer_height: u32,
    screen_width: u32,
    screen_height: u32,
}

#[derive(Debug, Deserialize, Clone)]
struct RoiRequest {
    center_x: f64,
    center_y: f64,
    zoom: f64,
    viewport_width: f64,
    viewport_height: f64,
    prefetch_radius: f64,
}

async fn handle_connection(
    connection: quinn::Connection,
    roi: Arc<Mutex<RoiManager>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (mut send, mut recv) = connection.accept_bi().await?;
    let hello: RoiHello = read_json_message(&mut recv).await?;
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
        display_index: info.display_index,
        framebuffer_width: info.framebuffer_width,
        framebuffer_height: info.framebuffer_height,
        screen_width: info.screen_width,
        screen_height: info.screen_height,
    };
    send_json_message(&mut send, &ready).await?;

    let running = Arc::new(AtomicBool::new(true));
    let request_state = Arc::new(Mutex::new(None::<RoiRequest>));
    let reader_running = running.clone();
    let reader_state = request_state.clone();
    tokio::spawn(async move {
        loop {
            match read_json_message::<RoiRequest>(&mut recv).await {
                Ok(request) => {
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
    let capture_running = running.clone();
    let capture_state = request_state.clone();
    thread::spawn(move || {
        run_roi_stream(send_connection, info, capture_state, capture_running);
    });

    while running.load(Ordering::SeqCst) {
        tokio::time::sleep(Duration::from_millis(120)).await;
    }

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
    let mut capturer = match RoiCapturer::new(
        info.display_index,
        info.screen_width,
        info.screen_height,
    ) {
        Ok(capturer) => capturer,
        Err(error) => {
            eprintln!("ROI capture init failed: {error}");
            return;
        }
    };
    let mut cache = RoiTileCache::new();
    let mut frame_id: u32 = 0;
    let max_datagram = connection.max_datagram_size().unwrap_or(1200);
    let tile_size = 64u32;
    let budget = 120usize;
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
        thread::sleep(Duration::from_millis(80));
    }
}

fn send_tile_datagrams(
    connection: &quinn::Connection,
    tile: &RoiTile,
    max_datagram: usize,
) -> Result<(), ()> {
    const HEADER_SIZE: usize = 28;
    if max_datagram <= HEADER_SIZE + 8 {
        return Err(());
    }
    let max_payload = max_datagram - HEADER_SIZE;
    let raw_payload = &tile.pixels;
    let mut codec = 0u8;
    let payload = if raw_payload.len() > max_payload {
        if let Ok(compressed) = compress_zlib(raw_payload) {
            if compressed.len() < raw_payload.len() {
                codec = 1;
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
        let mut buffer = Vec::with_capacity(HEADER_SIZE + chunk.len());
        buffer.extend_from_slice(b"ROI1");
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
