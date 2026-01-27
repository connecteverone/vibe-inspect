#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod command;

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![command::handle_agent_command])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
