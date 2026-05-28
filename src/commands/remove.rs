use anyhow::Result;
use std::fs;

use crate::core::hook_manager::HookManager;
use crate::core::logger::Logger;

pub fn run() -> Result<()> {
    let logger = Logger::new(false);
    logger.header("mobhook remove");

    let project_root = std::env::current_dir()?;
    let mgr = HookManager::with_logger(&project_root, &logger);

    mgr.uninstall()?;

    let config_file = project_root.join("mobhook.yaml");
    if config_file.exists() {
        fs::remove_file(&config_file)?;
        logger.success("Deleted mobhook.yaml");
    } else {
        logger.info("mobhook.yaml not found -- already removed.");
    }

    logger.line();
    logger.success("mobhook has been fully removed from this project.");
    Ok(())
}
