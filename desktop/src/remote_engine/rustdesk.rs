use super::{
    input_prefs::detect_input_preferences, RemoteBackend, RemoteBackendKind, RemoteCapabilities,
    RemoteQuicContext, RemoteSessionInfo, RemoteStartRequest, RemoteStatus,
};
use hbb_common::config::{self, Config};
use hbb_common::password_security;
use hbb_common::tcp::FramedStream;
use hbb_common::Stream as RustDeskStream;
use librustdesk::{Connection as RustDeskConnection, ServerPtr};
use rand::{distributions::Alphanumeric, Rng};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};

const SESSION_TTL: Duration = Duration::from_secs(15 * 60);

struct RustDeskSession {
    token: String,
    display_index: Option<usize>,
    width: Option<u32>,
    height: Option<u32>,
    started_at: Instant,
}

#[derive(Default)]
pub struct RustDeskBackend {
    running: bool,
    last_error: Option<String>,
    server: Option<ServerPtr>,
    sessions: HashMap<String, RustDeskSession>,
}

impl RustDeskBackend {
    pub fn new() -> Self {
        std::env::set_var("VIBE_RUSTDESK_DISABLE_CM", "1");
        if std::env::var("VIBE_RUSTDESK_CODEC_PREF").is_err() {
            std::env::set_var("VIBE_RUSTDESK_CODEC_PREF", "auto");
        }
        Config::set_option(
            config::keys::OPTION_CODEC_PREFERENCE.to_string(),
            "auto".to_string(),
        );
        Config::set_option(
            config::keys::OPTION_APPROVE_MODE.to_string(),
            "password".to_string(),
        );
        Config::set_option(
            config::keys::OPTION_VERIFICATION_METHOD.to_string(),
            "use-permanent-password".to_string(),
        );
        Config::set_option(
            config::keys::OPTION_ENABLE_HWCODEC.to_string(),
            "Y".to_string(),
        );
        #[cfg(feature = "rustdesk-hwcodec")]
        {
            let config = scrap::hwcodec::check_available_hwcodec();
            if !config.is_empty() {
                scrap::hwcodec::HwCodecConfig::set(config);
            }
        }
        Self {
            running: false,
            last_error: None,
            server: None,
            sessions: HashMap::new(),
        }
    }

    fn purge_expired(&mut self) {
        if self.sessions.is_empty() {
            return;
        }
        let now = Instant::now();
        self.sessions
            .retain(|_, session| now.duration_since(session.started_at) <= SESSION_TTL);
        if self.sessions.is_empty() {
            self.running = false;
        }
    }

    fn has_active_session(&self) -> bool {
        let now = Instant::now();
        self.sessions
            .values()
            .any(|session| now.duration_since(session.started_at) <= SESSION_TTL)
    }

    fn ensure_server(&mut self) -> Result<ServerPtr, String> {
        if let Some(server) = self.server.as_ref() {
            return Ok(server.clone());
        }
        librustdesk::common::global_init();
        librustdesk::common::set_server_running(true);
        let server = librustdesk::new();
        self.server = Some(server.clone());
        Ok(server)
    }

    fn new_session_id(&self) -> String {
        let suffix: String = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(10)
            .map(char::from)
            .collect();
        format!("rd-{suffix}")
    }

    fn build_connect_uri(&self) -> Option<String> {
        let id = Config::get_id();
        if id.is_empty() {
            None
        } else {
            Some(format!("rustdesk://{id}"))
        }
    }
}

impl RemoteBackend for RustDeskBackend {
    fn kind(&self) -> RemoteBackendKind {
        RemoteBackendKind::Rustdesk
    }

    fn capabilities(&self) -> RemoteCapabilities {
        RemoteCapabilities {
            h264: true,
            h265: true,
            av1: false,
            zero_copy: false,
        }
    }

    fn start(&mut self, request: RemoteStartRequest) -> Result<RemoteSessionInfo, String> {
        if !cfg!(feature = "rustdesk-hwcodec") {
            let message = "RustDesk hwcodec feature is required. Rebuild desktop with --features rustdesk-hwcodec.";
            self.last_error = Some(message.to_string());
            self.running = false;
            return Err(message.to_string());
        }
        let _server = self.ensure_server()?;
        self.purge_expired();
        let codec_pref = Config::get_option(config::keys::OPTION_CODEC_PREFERENCE);
        let codec_pref = codec_pref.trim().to_string();
        let codec_preference = if codec_pref.is_empty() {
            None
        } else {
            Some(codec_pref)
        };
        let hwcodec = Some(cfg!(feature = "rustdesk-hwcodec"));
        let capabilities = Some(self.capabilities());
        let input_preferences = Some(detect_input_preferences());
        if let Some(existing_id) = self.sessions.keys().next().cloned() {
            let mut token = String::new();
            let mut display_index = request.display_index;
            let mut width = request.width;
            let mut height = request.height;
            if let Some(session) = self.sessions.get_mut(&existing_id) {
                token = session.token.clone();
                if !token.is_empty() {
                    Config::set_permanent_password(&token);
                }
                session.started_at = Instant::now();
                if display_index.is_none() {
                    display_index = session.display_index;
                } else {
                    session.display_index = display_index;
                }
                if width.is_none() {
                    width = session.width;
                } else {
                    session.width = width;
                }
                if height.is_none() {
                    height = session.height;
                } else {
                    session.height = height;
                }
            }
            if self.sessions.len() > 1 {
                self.sessions
                    .retain(|session_id, _| *session_id == existing_id);
            }
            self.running = true;
            self.last_error = None;
            return Ok(RemoteSessionInfo {
                session_id: existing_id,
                backend: RemoteBackendKind::Rustdesk,
                connect_uri: self.build_connect_uri(),
                token: if token.is_empty() { None } else { Some(token) },
                display_index,
                width,
                height,
                quic_port: None,
                codec_preference,
                hwcodec,
                capabilities,
                input_preferences: input_preferences.clone(),
            });
        }
        password_security::update_temporary_password();
        let token = password_security::temporary_password();
        Config::set_permanent_password(&token);
        let session_id = self.new_session_id();
        self.sessions.insert(
            session_id.clone(),
            RustDeskSession {
                token: token.clone(),
                display_index: request.display_index,
                width: request.width,
                height: request.height,
                started_at: Instant::now(),
            },
        );
        self.running = true;
        self.last_error = None;
        Ok(RemoteSessionInfo {
            session_id,
            backend: RemoteBackendKind::Rustdesk,
            connect_uri: self.build_connect_uri(),
            token: Some(token),
            display_index: request.display_index,
            width: request.width,
            height: request.height,
            quic_port: None,
            codec_preference,
            hwcodec,
            capabilities,
            input_preferences,
        })
    }

    fn stop(&mut self, _session_id: &str) -> Result<(), String> {
        self.sessions.remove(_session_id);
        if self.sessions.is_empty() {
            self.running = false;
        }
        Ok(())
    }

    fn status(&self) -> RemoteStatus {
        RemoteStatus {
            backend: RemoteBackendKind::Rustdesk,
            running: self.running && self.has_active_session(),
            last_error: self.last_error.clone(),
        }
    }

    fn validate_session(&self, session_id: &str, token: &str) -> bool {
        if !self.has_active_session() {
            return false;
        }
        self.sessions
            .get(session_id)
            .map(|session| session.token == token)
            .unwrap_or(false)
    }

    fn handle_quic_stream(
        &mut self,
        connection: quinn::Connection,
        send: quinn::SendStream,
        recv: quinn::RecvStream,
        context: RemoteQuicContext,
        token: String,
    ) -> Result<(), String> {
        self.purge_expired();
        if !self.validate_session(&context.session_id, &token) {
            return Err("invalid session".to_string());
        }
        let server = self.ensure_server()?;
        let addr = connection.remote_address();
        let id = server
            .write()
            .map_err(|_| "rustdesk server lock")?
            .get_new_id();
        let stream = QuicBiStream { send, recv };
        let framed = FramedStream::from(stream, addr);
        let stream = RustDeskStream::Tcp(framed);
        let server_weak = Arc::downgrade(&server);
        tokio::spawn(async move {
            // Keep the QUIC connection alive for the lifetime of the RustDesk session.
            let _connection = connection;
            RustDeskConnection::start(addr, stream, id, server_weak, None).await;
        });
        Ok(())
    }
}

struct QuicBiStream {
    send: quinn::SendStream,
    recv: quinn::RecvStream,
}

// Quinn streams are not Sync; we only drive them from a single task but must
// satisfy the hbb_common FramedStream bounds.
unsafe impl Send for QuicBiStream {}
unsafe impl Sync for QuicBiStream {}

impl AsyncRead for QuicBiStream {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.recv).poll_read(cx, buf)
    }
}

impl AsyncWrite for QuicBiStream {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        data: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        match std::pin::Pin::new(&mut self.send).poll_write(cx, data) {
            std::task::Poll::Ready(Ok(size)) => std::task::Poll::Ready(Ok(size)),
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
