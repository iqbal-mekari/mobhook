use std::env;
use std::process;

mod cli;
mod core;
mod presets;
mod commands;

fn main() {
    // Global kill switch
    if env::var("MOBHOOK").as_deref() == Ok("0") {
        return;
    }

    if let Err(e) = cli::run() {
        eprintln!("Error: {e:#}");
        process::exit(1);
    }
}
