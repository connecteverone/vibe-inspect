extern crate self as desktop;

mod auth;
mod command;
#[cfg(target_os = "macos")]
mod cursor_macos;
mod identity;
mod pairing;
mod quic;
mod remote_media;
mod remote_engine;
mod roi;
mod server;
mod terminal;
mod vnc;

pub use pairing::PairingState;
pub use server::start_local_server;
pub use server::LocalServerHandle;

pub mod terminal_core;
