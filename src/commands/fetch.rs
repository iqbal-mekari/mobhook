use anyhow::Result;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process;

use crate::core::config::MobhookConfig;
use crate::core::logger::Logger;
use crate::core::preset::install_preset_with_overrides;
use crate::core::remote_sync::RemoteSync;
use crate::presets;

pub fn run(preset_name: Option<String>) -> Result<()> {
    let logger = Logger::new(false);
    let project_root = std::env::current_dir()?;

    let config_path = project_root.join("mobhook.toml");
    let config = if config_path.exists() {
        Some(MobhookConfig::load(&config_path)?)
    } else {
        None
    };

    let remote_files: HashMap<String, PathBuf> = if let Some(ref cfg) = config {
        if let Some(ref remote) = cfg.remote {
            let quiet_logger = Logger::quiet();
            let sync = RemoteSync::new(&quiet_logger);
            sync.sync_and_get_files(remote).unwrap_or_default()
        } else {
            HashMap::new()
        }
    } else {
        HashMap::new()
    };

    let available_names = presets::builtin_preset_names();

    let name = match preset_name {
        Some(n) => n,
        None => {
            logger.error("Usage: mobhook fetch <preset_name>");
            logger.info("Available presets:");
            for n in &available_names {
                logger.info(&format!("  - {n}"));
            }
            process::exit(64);
        }
    };

    let hooks_dir = project_root.join(".mobhook");
    logger.header("mobhook fetch");

    if !hooks_dir.exists() {
        logger.error(".mobhook/ not found. Run \"mobhook init\" first.");
        process::exit(1);
    }

    if !available_names.contains(&name.as_str()) {
        logger.error(&format!(
            "Unknown preset \"{name}\". Available presets: {}",
            available_names.join(", ")
        ));
        process::exit(64);
    }

    let dest_dir = hooks_dir.join(&name);
    if dest_dir.exists() {
        logger.warn(&format!("Preset \"{name}\" is already installed at .mobhook/{name}/"));
        logger.info("Run \"mobhook update\" to regenerate hooks if needed.");
        return Ok(());
    }

    if let Some(preset) = presets::find_builtin_preset(&name) {
        install_preset_with_overrides(preset.as_ref(), &hooks_dir, &remote_files)?;
    }

    if !dest_dir.exists() {
        logger.error(&format!("Failed to install preset \"{name}\"."));
        process::exit(1);
    }

    let already_in_config = config
        .as_ref()
        .map(|c| c.installed_presets().contains(&name))
        .unwrap_or(false);

    logger.line();
    if already_in_config {
        logger.success(&format!(
            "Preset \"{name}\" already in mobhook.toml -- run \"mobhook update\" to regenerate hooks."
        ));
    } else {
        logger.info(&format!("Add \"{name}\" to mobhook.toml under the desired hook type:"));
        logger.info("");
        logger.info("  hooks:");
        logger.info("    pre-push:");
        logger.info(&format!("      order = [\"{name}\"]"));
        logger.info("");
        logger.info("Then run \"mobhook update\" to regenerate hooks.");
    }

    Ok(())
}
