use anyhow::Result;

use crate::core::config::MobhookConfig;
use crate::core::logger::Logger;
use crate::core::tools;

pub fn run() -> Result<()> {
    let logger = Logger::new(false);
    logger.header("mobhook doctor");

    let project_root = std::env::current_dir()?;
    let mut issues = 0;

    // Check mobhook.yaml
    logger.info("Configuration:");
    let config_path = project_root.join("mobhook.yaml");
    if config_path.exists() {
        match MobhookConfig::load(&config_path) {
            Ok(config) => {
                logger.success("mobhook.yaml is valid");
                if config.remote.is_some() {
                    logger.success("Remote sync configured");
                } else {
                    logger.info("No remote configured (optional)");
                }
                let hook_count: usize = config.hooks.values().map(|h| h.order.len()).sum();
                logger.info(&format!("{hook_count} hook step(s) configured"));
            }
            Err(e) => {
                logger.error(&format!("mobhook.yaml has errors: {e}"));
                issues += 1;
            }
        }
    } else {
        logger.warn("mobhook.yaml not found -- run \"mobhook init\" first");
        issues += 1;
    }

    logger.line();

    // Check .mobhook/
    logger.info("Hooks directory:");
    let hooks_dir = project_root.join(".mobhook");
    if hooks_dir.exists() {
        logger.success(".mobhook/ exists");
    } else {
        logger.warn(".mobhook/ not found -- run \"mobhook init\" first");
        issues += 1;
    }

    logger.line();

    // Check git config
    logger.info("Git configuration:");
    let output = std::process::Command::new("git")
        .args([
            "-C",
            project_root.to_str().unwrap_or("."),
            "config",
            "core.hooksPath",
        ])
        .output();
    match output {
        Ok(o) if o.status.success() => {
            let path = String::from_utf8_lossy(&o.stdout);
            if path.trim() == ".mobhook" {
                logger.success("core.hooksPath = .mobhook");
            } else {
                logger.warn(&format!(
                    "core.hooksPath = {} (expected .mobhook)",
                    path.trim()
                ));
                issues += 1;
            }
        }
        _ => {
            logger.warn("core.hooksPath not set -- run \"mobhook init\"");
            issues += 1;
        }
    }

    logger.line();

    // Check tools
    logger.info("Required tools:");
    for name in &["gitleaks", "mobsfscan", "flutter"] {
        if tools::find_tool(name).is_some() {
            logger.success(&format!("{name}: available"));
        } else {
            logger.warn(&format!(
                "{name}: not found (will be auto-installed on first use)"
            ));
        }
    }

    logger.line();

    if issues == 0 {
        logger.success("All checks passed!");
    } else {
        logger.warn(&format!("{issues} issue(s) found"));
    }

    Ok(())
}
