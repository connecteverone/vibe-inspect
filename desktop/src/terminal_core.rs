//! Shared terminal daemon core types and defaults.

/// Default WebSocket URL for terminald.
pub const DEFAULT_TERMINALD_WS_URL: &str = "ws://127.0.0.1:7078/ws";

/// Default bind address for terminald.
pub const DEFAULT_TERMINALD_BIND: &str = "127.0.0.1:7078";

/// Default WebSocket path for terminald.
pub const DEFAULT_TERMINALD_WS_PATH: &str = "/ws";
