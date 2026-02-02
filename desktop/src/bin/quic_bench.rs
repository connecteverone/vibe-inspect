use bytes::Bytes;
use clap::{Parser, Subcommand};
use quinn::{ClientConfig, Connection, Endpoint, ServerConfig};
use rcgen::generate_simple_self_signed;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Parser)]
#[command(author, version, about = "QUIC datagram micro-benchmark for VNC/ROI tuning")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Start a QUIC datagram echo server.
    Server {
        /// Bind address (host:port).
        #[arg(long, default_value = "0.0.0.0:5000")]
        bind: String,
        /// Write the generated certificate DER to a file.
        #[arg(long)]
        cert_out: Option<PathBuf>,
        /// Log interval (seconds).
        #[arg(long, default_value_t = 2)]
        log_interval_secs: u64,
    },
    /// Run a QUIC datagram client and print latency stats.
    Client {
        /// Server address (host:port).
        #[arg(long, default_value = "127.0.0.1:5000")]
        addr: String,
        /// Path to the server certificate DER.
        #[arg(long)]
        cert: PathBuf,
        /// Server name (SNI).
        #[arg(long, default_value = "vibe-inspect")]
        server_name: String,
        /// Datagrams per second (0 = best effort).
        #[arg(long, default_value_t = 1000)]
        pps: u64,
        /// Duration (seconds).
        #[arg(long, default_value_t = 10)]
        duration_secs: u64,
        /// Warmup time before sampling (seconds).
        #[arg(long, default_value_t = 1)]
        warmup_secs: u64,
        /// Payload size in bytes (minimum 12).
        #[arg(long, default_value_t = 1200)]
        size: usize,
        /// Number of concurrent connections.
        #[arg(long, default_value_t = 1)]
        connections: usize,
        /// Maximum number of RTT samples to retain.
        #[arg(long, default_value_t = 200_000)]
        max_samples: usize,
    },
}

type AnyError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Default)]
struct Stats {
    sent: AtomicU64,
    sent_bytes: AtomicU64,
    recv: AtomicU64,
    recv_bytes: AtomicU64,
    send_blocked: AtomicU64,
    send_errors: AtomicU64,
    recv_errors: AtomicU64,
    connections: AtomicU64,
}

#[tokio::main]
async fn main() -> Result<(), AnyError> {
    let cli = Cli::parse();
    match cli.command {
        Command::Server {
            bind,
            cert_out,
            log_interval_secs,
        } => run_server(&bind, cert_out.as_deref(), log_interval_secs).await?,
        Command::Client {
            addr,
            cert,
            server_name,
            pps,
            duration_secs,
            warmup_secs,
            size,
            connections,
            max_samples,
        } => {
            run_client(
                &addr,
                &cert,
                &server_name,
                pps,
                Duration::from_secs(duration_secs),
                Duration::from_secs(warmup_secs),
                size,
                connections,
                max_samples,
            )
            .await?
        }
    }
    Ok(())
}

async fn run_server(
    bind: &str,
    cert_out: Option<&Path>,
    log_interval_secs: u64,
) -> Result<(), AnyError> {
    let bind_addr: SocketAddr = bind.parse()?;
    let stats = Arc::new(Stats::default());
    let (server_config, cert_der) = build_server_config()?;
    if let Some(path) = cert_out {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, cert_der.as_ref())?;
        eprintln!("wrote cert: {}", path.display());
    }
    let endpoint = Endpoint::server(server_config, bind_addr)?;
    eprintln!("quic bench server listening on {bind}");
    let log_stats = stats.clone();
    tokio::spawn(async move {
        let interval = Duration::from_secs(log_interval_secs.max(1));
        loop {
            tokio::time::sleep(interval).await;
            let sent = log_stats.sent.load(Ordering::Relaxed);
            let recv = log_stats.recv.load(Ordering::Relaxed);
            let bytes = log_stats.recv_bytes.load(Ordering::Relaxed);
            let conns = log_stats.connections.load(Ordering::Relaxed);
            eprintln!(
                "server stats: conns={} recv={} sent={} recv_bytes={}",
                conns, recv, sent, bytes
            );
        }
    });

    while let Some(connecting) = endpoint.accept().await {
        let stats = stats.clone();
        tokio::spawn(async move {
            let connection = match connecting.await {
                Ok(conn) => conn,
                Err(err) => {
                    eprintln!("accept error: {err}");
                    return;
                }
            };
            stats.connections.fetch_add(1, Ordering::Relaxed);
            if let Err(err) = handle_server_connection(connection, stats.clone()).await {
                eprintln!("connection error: {err}");
            }
        });
    }
    Ok(())
}

async fn handle_server_connection(
    connection: Connection,
    stats: Arc<Stats>,
) -> Result<(), AnyError> {
    loop {
        let datagram = match connection.read_datagram().await {
            Ok(payload) => payload,
            Err(err) => {
                stats.recv_errors.fetch_add(1, Ordering::Relaxed);
                return Err(Box::new(err));
            }
        };
        stats.recv.fetch_add(1, Ordering::Relaxed);
        stats
            .recv_bytes
            .fetch_add(datagram.len() as u64, Ordering::Relaxed);
        if let Err(err) = connection.send_datagram_wait(datagram).await {
            stats.send_errors.fetch_add(1, Ordering::Relaxed);
            return Err(Box::new(err));
        }
        stats.sent.fetch_add(1, Ordering::Relaxed);
    }
}

async fn run_client(
    addr: &str,
    cert_path: &Path,
    server_name: &str,
    pps: u64,
    duration: Duration,
    warmup: Duration,
    size: usize,
    connections: usize,
    max_samples: usize,
) -> Result<(), AnyError> {
    let stats = Arc::new(Stats::default());
    let rtts = Arc::new(Mutex::new(Vec::new()));
    let addr: SocketAddr = addr.parse()?;
    let client_config = build_client_config(cert_path)?;
    let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(client_config);

    let mut tasks = Vec::new();
    let start = tokio::time::Instant::now();
    let end = start + duration;
    let warmup_end = start + warmup;
    for _ in 0..connections.max(1) {
        let endpoint = endpoint.clone();
        let stats = stats.clone();
        let rtts = rtts.clone();
        let server_name = server_name.to_string();
        tasks.push(tokio::spawn(async move {
            run_client_connection(
                endpoint,
                addr,
                &server_name,
                pps,
                size,
                end,
                warmup_end,
                max_samples,
                stats,
                rtts,
            )
            .await
        }));
    }

    for task in tasks {
        task.await??;
    }

    report_client_stats(stats, rtts, duration);
    Ok(())
}

async fn run_client_connection(
    endpoint: Endpoint,
    addr: SocketAddr,
    server_name: &str,
    pps: u64,
    size: usize,
    end: tokio::time::Instant,
    warmup_end: tokio::time::Instant,
    max_samples: usize,
    stats: Arc<Stats>,
    rtts: Arc<Mutex<Vec<u64>>>,
) -> Result<(), AnyError> {
    let conn = endpoint.connect(addr, server_name)?.await?;
    let max_datagram = conn.max_datagram_size().unwrap_or(1200) as usize;
    let payload_size = size.max(12).min(max_datagram);
    let send_conn = conn.clone();
    let recv_conn = conn.clone();

    let recv_stats = stats.clone();
    let recv_task = tokio::spawn(async move {
        loop {
            let now = tokio::time::Instant::now();
            if now > end + Duration::from_secs(1) {
                break;
            }
            let datagram = match recv_conn.read_datagram().await {
                Ok(payload) => payload,
                Err(err) => {
                    recv_stats.recv_errors.fetch_add(1, Ordering::Relaxed);
                    return Err(Box::new(err) as AnyError);
                }
            };
            recv_stats.recv.fetch_add(1, Ordering::Relaxed);
            recv_stats
                .recv_bytes
                .fetch_add(datagram.len() as u64, Ordering::Relaxed);
            if datagram.len() >= 12 && now >= warmup_end {
                let ts = u64::from_be_bytes(datagram[..8].try_into().unwrap());
                let now_us = unix_micros();
                if now_us >= ts {
                    let rtt = now_us - ts;
                    let mut guard = rtts.lock().unwrap();
                    if guard.len() < max_samples {
                        guard.push(rtt);
                    }
                }
            }
        }
        Ok::<(), AnyError>(())
    });

    let send_stats = stats.clone();
    let send_task = tokio::spawn(async move {
        let interval = if pps == 0 {
            None
        } else {
            Some(Duration::from_nanos(1_000_000_000u64 / pps.max(1)))
        };
        let mut seq: u32 = 0;
        let mut payload = vec![0u8; payload_size];
        while tokio::time::Instant::now() < end {
            let ts = unix_micros().to_be_bytes();
            payload[..8].copy_from_slice(&ts);
            payload[8..12].copy_from_slice(&seq.to_be_bytes());
            let bytes = Bytes::copy_from_slice(&payload);
            if let Err(err) = send_conn.send_datagram_wait(bytes).await {
                send_stats.send_errors.fetch_add(1, Ordering::Relaxed);
                return Err(Box::new(err) as AnyError);
            }
            send_stats.sent.fetch_add(1, Ordering::Relaxed);
            send_stats
                .sent_bytes
                .fetch_add(payload_size as u64, Ordering::Relaxed);
            seq = seq.wrapping_add(1);
            if let Some(interval) = interval {
                tokio::time::sleep(interval).await;
            } else {
                tokio::task::yield_now().await;
            }
        }
        Ok::<(), AnyError>(())
    });

    let (send_result, recv_result) = tokio::join!(send_task, recv_task);
    send_result??;
    recv_result??;
    Ok(())
}

fn report_client_stats(stats: Arc<Stats>, rtts: Arc<Mutex<Vec<u64>>>, duration: Duration) {
    let sent = stats.sent.load(Ordering::Relaxed);
    let recv = stats.recv.load(Ordering::Relaxed);
    let blocked = stats.send_blocked.load(Ordering::Relaxed);
    let send_errors = stats.send_errors.load(Ordering::Relaxed);
    let recv_errors = stats.recv_errors.load(Ordering::Relaxed);
    let bytes = stats.recv_bytes.load(Ordering::Relaxed);
    let loss = if sent == 0 {
        0.0
    } else {
        (sent.saturating_sub(recv) as f64) / sent as f64
    };
    let mut rtts = rtts.lock().unwrap();
    rtts.sort_unstable();
    let avg = if rtts.is_empty() {
        0.0
    } else {
        rtts.iter().sum::<u64>() as f64 / rtts.len() as f64
    };
    let p50 = percentile(&rtts, 50.0);
    let p95 = percentile(&rtts, 95.0);
    let p99 = percentile(&rtts, 99.0);
    let seconds = duration.as_secs_f64();
    let recv_mbps = if seconds > 0.0 {
        (bytes as f64 * 8.0) / (1_000_000.0 * seconds)
    } else {
        0.0
    };
    println!(
        "sent={} recv={} loss={:.2}% blocked={} send_errors={} recv_errors={}",
        sent,
        recv,
        loss * 100.0,
        blocked,
        send_errors,
        recv_errors
    );
    println!(
        "rtt_us: avg={:.1} p50={} p95={} p99={} samples={}",
        avg,
        p50,
        p95,
        p99,
        rtts.len()
    );
    println!("recv_mbps={:.2}", recv_mbps);
}

fn percentile(samples: &[u64], percentile: f64) -> u64 {
    if samples.is_empty() {
        return 0;
    }
    let idx = ((percentile / 100.0) * (samples.len() as f64 - 1.0)).round() as usize;
    samples[idx.min(samples.len() - 1)]
}

fn unix_micros() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_micros() as u64)
        .unwrap_or_default()
}

fn build_server_config() -> Result<(ServerConfig, CertificateDer<'static>), AnyError> {
    let cert = generate_simple_self_signed(vec!["vibe-inspect".to_string()])?;
    let key = PrivateKeyDer::Pkcs8(cert.serialize_private_key_der().into());
    let cert_der = CertificateDer::from(cert.serialize_der()?);
    let mut server_config = ServerConfig::with_single_cert(vec![cert_der.clone()], key)?;
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    transport.max_idle_timeout(Some(Duration::from_secs(20).try_into()?));
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    server_config.transport = Arc::new(transport);
    Ok((server_config, cert_der))
}

fn build_client_config(cert_path: &Path) -> Result<ClientConfig, AnyError> {
    let cert = fs::read(cert_path)?;
    let mut roots = rustls::RootCertStore::empty();
    roots.add(CertificateDer::from(cert))?;
    let crypto = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let crypto = quinn::crypto::rustls::QuicClientConfig::try_from(crypto)?;
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    transport.max_idle_timeout(Some(Duration::from_secs(20).try_into()?));
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    let mut client_config = ClientConfig::new(Arc::new(crypto));
    client_config.transport_config(Arc::new(transport));
    Ok(client_config)
}
