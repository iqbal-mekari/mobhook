use anyhow::Result;
use std::process;

use crate::core::config::MobhookConfig;
use crate::core::hook_manager::HookManager;
use crate::core::logger::Logger;
use crate::presets;

pub fn run(verbose: bool) -> Result<()> {
    let logger = Logger::new(verbose);
    logger.header("mobhook update");

    let project_root = std::env::current_dir()?;
    let config_path = project_root.join("mobhook.yaml");

    if !config_path.exists() {
        logger.error("mobhook.yaml not found. Run \"mobhook init\" first.");
        process::exit(1);
    }

    let config = MobhookConfig::load(&config_path)?;

    // Regeneration only uses bundled presets; remote rules are consumed by
    // `mobhook fetch`, which syncs on demand.
    if config.remote.is_some() {
        logger.info("Remote rules are synced when you run \"mobhook fetch <preset>\".");
        logger.line();
    }

    logger.info("Regenerating .mobhook/ from mobhook.yaml...");
    let mgr = HookManager::with_logger(&project_root, &logger);
    let builtin = presets::builtin_presets();
    mgr.run(&config, &builtin)?;

    logger.line();
    logger.success("Update complete!");
    Ok(())
}
