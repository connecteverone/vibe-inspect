#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod command;
#[cfg(target_os = "macos")]
mod cursor_macos;
mod identity;
mod pairing;
mod terminal;
mod server;
mod vnc;

fn main() {
    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::UI::HiDpi::{
            SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        };
        unsafe {
            let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
    }
    tauri::Builder::default()
        .manage(std::sync::Arc::new(std::sync::Mutex::new(
            pairing::PairingState::default(),
        )))
        .invoke_handler(tauri::generate_handler![
            command::handle_agent_command,
            pairing::create_pairing_session,
            pairing::confirm_pairing_session,
            pairing::get_pairing_status,
            pairing::set_pairing_requires_approval,
            pairing::approve_pairing_request,
            pairing::deny_pairing_request,
            pairing::reset_auth_token,
            pairing::set_frp_url,
            pairing::create_auth_token,
            pairing::add_auth_token,
            pairing::set_primary_auth_token,
            pairing::revoke_auth_token,
            pairing::rename_client,
            pairing::set_client_blocked,
            pairing::kick_client,
            pairing::forget_client
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
