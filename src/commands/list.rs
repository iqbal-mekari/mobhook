use anyhow::Result;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use crate::core::config::MobhookConfig;
use crate::core::logger::Logger;
use crate::core::remote_sync::RemoteSync;
use crate::presets;

pub fn run() -> Result<()> {
    let logger = Logger::new(false);
    let project_root = std::env::current_dir()?;

    logger.header("mobhook list");

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

    let _ = remote_files; // used for future remote preset discovery

    let bundled = presets::builtin_preset_names();
    let installed_in_config = config
        .as_ref()
        .map(|c| c.installed_presets())
        .unwrap_or_default();

    logger.info("Pre-defined hooks (presets):");
    if bundled.is_empty() {
        logger.info("  (no bundled presets found)");
    } else {
        for name in &bundled {
            let marker = if installed_in_config.contains(*name) {
                "[installed]"
            } else {
                "[available]"
            };
            logger.info(&format!("  {name}  {marker}"));
        }
    }

    logger.line();

    let hooks_dir = project_root.join(".mobhook");
    let mut custom_hooks: Vec<String> = Vec::new();

    if hooks_dir.exists() {
        let bundled_set: std::collections::HashSet<&str> = bundled.iter().copied().collect();
        if let Ok(entries) = fs::read_dir(&hooks_dir) {
            for entry in entries.flatten() {
                if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if !bundled_set.contains(name.as_str()) {
                        let script = entry.path().join("script.sh");
                        if script.exists() {
                            custom_hooks.push(name);
                        }
                    }
                }
            }
        }
    }

    logger.info("Custom local hooks:");
    if custom_hooks.is_empty() {
        logger.info("  (none)");
    } else {
        custom_hooks.sort();
        for name in &custom_hooks {
            logger.info(&format!("  {name}"));
        }
    }

    logger.line();

    let total_installed = bundled.iter().filter(|n| installed_in_config.contains(**n)).count();
    logger.info(&format!(
        "Summary: {} of {} preset(s) installed, {} custom hook(s)",
        total_installed, bundled.len(), custom_hooks.len(),
    ));

    Ok(())
}
