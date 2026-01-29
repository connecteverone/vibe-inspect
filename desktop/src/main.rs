#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod command;
mod pairing;
mod terminal;
mod server;
mod vnc;

fn main() {
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
            pairing::deny_pairing_request
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
