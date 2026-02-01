use clap::{Parser, Subcommand};

use desktop::terminal_core::{read_discovery_file, terminal_discovery_path, DEFAULT_TERMINALD_WS_URL};
use std::env;
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(
    name = "vibe-ctl",
    about = "CLI for managing terminald sessions",
    version,
    arg_required_else_help = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Print the default terminald endpoint.
    Defaults,
}

fn main() {
    let cli = Cli::parse();
    let config = match resolve_config() {
        Ok(config) => config,
        Err(error) => {
            eprintln!("{}: {}", error.code, error.message);
            std::process::exit(1);
        }
    };
    match cli.command {
        Command::Defaults => {
            println!("{}", config.ws_url);
        }
    }
}

struct ResolvedConfig {
    ws_url: String,
    token: Option<String>,
}

struct ConfigError {
    code: &'static str,
    message: String,
}

fn resolve_config() -> Result<ResolvedConfig, ConfigError> {
    let config_override = read_env_value("VIBE_CTL_CONFIG").map(PathBuf::from);
    let default_config = terminal_discovery_path();
    let config_path = config_override.clone().or(default_config);
    let discovery = match config_path {
        Some(path) => match read_discovery_file(&path) {
            Ok(file) => Some(file),
            Err(error) => {
                if config_override.is_some() {
                    return Err(ConfigError {
                        code: "connection_failed",
                        message: format!("Failed to read config {}: {error}", path.display()),
                    });
                }
                None
            }
        },
        None => None,
    };
    let ws_url = read_env_value("VIBE_CTL_ENDPOINT")
        .or_else(|| discovery.as_ref().map(|file| file.ws_url.clone()))
        .unwrap_or_else(|| DEFAULT_TERMINALD_WS_URL.to_string());
    let token = read_env_value("VIBE_CTL_TOKEN")
        .or_else(|| discovery.as_ref().map(|file| file.token.clone()));
    Ok(ResolvedConfig { ws_url, token })
}

fn read_env_value(key: &str) -> Option<String> {
    match env::var(key) {
        Ok(value) => {
            let trimmed = value.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        }
        Err(_) => None,
    }
}
