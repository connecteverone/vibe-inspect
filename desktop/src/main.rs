#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod command;
mod pairing;

fn main() {
    tauri::Builder::default()
        .manage(std::sync::Mutex::new(pairing::PairingState::default()))
        .invoke_handler(tauri::generate_handler![
            command::handle_agent_command,
            pairing::create_pairing_session,
            pairing::confirm_pairing_session
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
