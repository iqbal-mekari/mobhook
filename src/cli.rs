use clap::{Parser, Subcommand};
use anyhow::Result;

#[derive(Parser)]
#[command(name = "mobhook", version, about = "Mobile-first git hooks manager")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Initialize mobhook: create mobhook.toml and set up .mobhook/
    Init {
        /// Overwrite existing mobhook.toml
        #[arg(short, long)]
        force: bool,
        /// Show detailed output
        #[arg(short, long)]
        verbose: bool,
        /// Project root to initialize (defaults to current directory)
        path: Option<String>,
    },
    /// Sync remote presets and regenerate .mobhook/
    Update {
        /// Show detailed output
        #[arg(short, long)]
        verbose: bool,
    },
    /// Scaffold a new custom hook
    Create {
        /// Hook name (lowercase alphanumeric + hyphens)
        name: String,
    },
    /// Install a bundled preset into .mobhook/
    Fetch {
        /// Preset name to install
        preset: Option<String>,
    },
    /// List available presets and custom hooks
    List,
    /// Remove mobhook entirely from the project
    Remove,
    /// Check required tools and validate configuration
    Doctor,
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init { force, verbose, path } => {
            crate::commands::init::run(force, verbose, path)
        }
        Commands::Update { verbose } => {
            crate::commands::update::run(verbose)
        }
        Commands::Create { name } => {
            crate::commands::create::run(&name)
        }
        Commands::Fetch { preset } => {
            crate::commands::fetch::run(preset)
        }
        Commands::List => {
            crate::commands::list::run()
        }
        Commands::Remove => {
            crate::commands::remove::run()
        }
        Commands::Doctor => {
            crate::commands::doctor::run()
        }
    }
}
