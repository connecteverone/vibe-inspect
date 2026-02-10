use clap::Parser;
use quinn::{ClientConfig, Endpoint};
use rustls::client::danger::ServerCertVerifier;
use rustls::pki_types::CertificateDer;
use serde_json::json;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use std::time::Instant;
use tokio::io::AsyncWriteExt;

#[derive(Parser, Debug)]
#[command(name = "vnc-quic-smoke", about = "VNC QUIC handshake smoke test")]
struct Args {
    #[arg(long, default_value = "127.0.0.1")]
    host: String,
    #[arg(long, default_value_t = 0)]
    quic_port: u16,
    #[arg(long, default_value = "vibe-inspect")]
    server_name: String,
    #[arg(long)]
    session_id: String,
    #[arg(long)]
    token: String,
    #[arg(long)]
    auth_token: String,
    #[arg(long, default_value_t = 5)]
    iterations: usize,
    #[arg(long, default_value = "zlib")]
    encoding: String,
    #[arg(long)]
    incremental: bool,
    #[arg(long, default_value_t = 0)]
    width: u16,
    #[arg(long, default_value_t = 0)]
    height: u16,
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
        _server_name: &rustls::pki_types::ServerName<'_>,
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
    config.transport_config(Arc::new(transport));
    Ok(config)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args = Args::parse();
    if args.quic_port == 0 {
        return Err("quic_port must be provided".into());
    }
    let server_addr: SocketAddr = format!("{}:{}", args.host, args.quic_port).parse()?;

    let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(build_insecure_client_config()?);

    let connection = endpoint.connect(server_addr, &args.server_name)?.await?;
    let (mut send, mut recv) = connection.open_bi().await?;

    let hello = json!({
        "type": "vnc",
        "session_id": args.session_id,
        "token": args.token,
        "auth_token": args.auth_token,
        "client_id": "smoke",
        "client_name": "vnc-quic-smoke",
    });
    let hello_bytes = serde_json::to_vec(&hello)?;
    send.write_all(&(hello_bytes.len() as u32).to_be_bytes())
        .await?;
    send.write_all(&hello_bytes).await?;
    send.flush().await?;

    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut payload = vec![0u8; len];
    recv.read_exact(&mut payload).await?;
    let ready: serde_json::Value = serde_json::from_slice(&payload)?;
    println!("ready={ready}");

    // RFB handshake
    let mut version = [0u8; 12];
    recv.read_exact(&mut version).await?;
    send.write_all(&version).await?;

    let mut sec_types = [0u8; 2];
    recv.read_exact(&mut sec_types).await?;
    send.write_all(&[1]).await?; // none

    let mut sec_result = [0u8; 4];
    recv.read_exact(&mut sec_result).await?;
    send.write_all(&[1]).await?; // shared

    let mut server_init = [0u8; 24];
    recv.read_exact(&mut server_init).await?;
    let mut width = u16::from_be_bytes([server_init[0], server_init[1]]);
    let mut height = u16::from_be_bytes([server_init[2], server_init[3]]);
    let bits_per_pixel = server_init[4];
    let bytes_per_pixel = (bits_per_pixel / 8) as usize;
    let name_len = u32::from_be_bytes([
        server_init[20],
        server_init[21],
        server_init[22],
        server_init[23],
    ]) as usize;
    if name_len > 0 {
        let mut name_buf = vec![0u8; name_len];
        recv.read_exact(&mut name_buf).await?;
    }
    if args.width > 0 {
        width = args.width;
    }
    if args.height > 0 {
        height = args.height;
    }

    let encodings: Vec<i32> = if args.encoding == "raw" {
        vec![0, -239]
    } else {
        vec![6, -239]
    };
    let mut set_enc = Vec::with_capacity(4 + encodings.len() * 4);
    set_enc.push(2);
    set_enc.push(0);
    set_enc.push(((encodings.len() >> 8) & 0xFF) as u8);
    set_enc.push((encodings.len() & 0xFF) as u8);
    for enc in encodings {
        set_enc.extend_from_slice(&enc.to_be_bytes());
    }
    send.write_all(&set_enc).await?;
    send.flush().await?;

    for i in 0..args.iterations {
        let req = [
            3u8,
            if args.incremental { 1 } else { 0 },
            0,
            0,
            0,
            0,
            (width >> 8) as u8,
            (width & 0xFF) as u8,
            (height >> 8) as u8,
            (height & 0xFF) as u8,
        ];
        let start = Instant::now();
        send.write_all(&req).await?;
        send.flush().await?;

        let (rect_count, t_first) = loop {
            let mut msg_type = [0u8; 1];
            recv.read_exact(&mut msg_type).await?;
            if msg_type[0] != 0 {
                continue;
            }
            let mut _pad = [0u8; 1];
            recv.read_exact(&mut _pad).await?;
            let mut rc = [0u8; 2];
            recv.read_exact(&mut rc).await?;
            let rect_count = u16::from_be_bytes(rc);
            break (rect_count, Instant::now());
        };

        let mut total_bytes = 0usize;
        for _ in 0..rect_count {
            let mut header = [0u8; 12];
            recv.read_exact(&mut header).await?;
            let w = u16::from_be_bytes([header[4], header[5]]) as usize;
            let h = u16::from_be_bytes([header[6], header[7]]) as usize;
            let encoding = i32::from_be_bytes([header[8], header[9], header[10], header[11]]);
            if encoding == -239 {
                let pixel_bytes = w * h * bytes_per_pixel;
                let mask_stride = (w + 7) / 8;
                let mask_bytes = mask_stride * h;
                let mut buf = vec![0u8; pixel_bytes + mask_bytes];
                recv.read_exact(&mut buf).await?;
                total_bytes += buf.len();
            } else if encoding == 0 {
                let raw_len = w * h * bytes_per_pixel;
                let mut buf = vec![0u8; raw_len];
                recv.read_exact(&mut buf).await?;
                total_bytes += buf.len();
            } else if encoding == 6 {
                let mut len_buf = [0u8; 4];
                recv.read_exact(&mut len_buf).await?;
                let zlen = u32::from_be_bytes(len_buf) as usize;
                let mut buf = vec![0u8; zlen];
                recv.read_exact(&mut buf).await?;
                total_bytes += 4 + buf.len();
            } else {
                break;
            }
        }
        let end = Instant::now();
        let ttfb_ms = t_first.duration_since(start).as_secs_f64() * 1000.0;
        let total_ms = end.duration_since(start).as_secs_f64() * 1000.0;
        let payload_ms = end.duration_since(t_first).as_secs_f64() * 1000.0;
        println!(
            "iter={} rects={} bytes={} latency_ms={:.2} ttfb_ms={:.2} payload_ms={:.2}",
            i + 1,
            rect_count,
            total_bytes,
            total_ms,
            ttfb_ms,
            payload_ms
        );
    }

    Ok(())
}
