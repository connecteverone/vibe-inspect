use clap::{Parser, Subcommand};

use desktop::terminal_core::DEFAULT_TERMINALD_WS_URL;

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
    match cli.command {
        Command::Defaults => {
            println!("{DEFAULT_TERMINALD_WS_URL}");
        }
    }
}
