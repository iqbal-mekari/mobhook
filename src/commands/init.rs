use anyhow::Result;
use std::fs;
use std::path::PathBuf;

use crate::core::config::MobhookConfig;
use crate::core::hook_manager::HookManager;
use crate::core::logger::Logger;
use crate::core::remote_sync::RemoteSync;
use crate::core::tools;
use crate::presets;

pub fn run(force: bool, verbose: bool, path: Option<String>) -> Result<()> {
    let logger = Logger::new(verbose);
    let project_root = path
        .map(|p| {
            PathBuf::from(&p)
                .canonicalize()
                .unwrap_or_else(|_| PathBuf::from(p))
        })
        .unwrap_or_else(|| std::env::current_dir().unwrap());

    let config_path = project_root.join("mobhook.yaml");

    logger.header("mobhook init");

    if config_path.exists() {
        if force {
            fs::write(&config_path, MobhookConfig::default_yaml())?;
            logger.success("Recreated mobhook.yaml (--force)");
        } else {
            logger.info("mobhook.yaml already exists -- using existing config.");
            logger.info("Use --force to overwrite with defaults.");
        }
    } else {
        fs::write(&config_path, MobhookConfig::default_yaml())?;
        logger.success("Created mobhook.yaml");
    }

    logger.line();

    let config = MobhookConfig::load(&config_path)?;
    let mgr = HookManager::with_logger(&project_root, &logger);

    mgr.setup()?;
    logger.line();

    if let Some(ref remote) = config.remote {
        logger.info("Syncing remote preset rules...");
        let sync = RemoteSync::new(&logger);
        sync.sync_and_get_files(remote)?;
        logger.line();
    }

    logger.info("Generating .mobhook/ hooks...");
    let builtin = presets::builtin_presets();
    mgr.run(&config, &builtin)?;

    logger.line();
    check_required_tools(&logger);

    logger.line();
    logger.success("mobhook initialized successfully!");
    logger.line();
    logger.info("Edit mobhook.yaml to configure hooks, then run:");
    logger.info("  mobhook update -- sync remote presets + regenerate .mobhook/");
    logger.info("  mobhook create -- scaffold a new custom hook template");
    logger.info("  mobhook remove -- fully remove mobhook from the project");
    logger.info("To skip hooks: git push --no-verify");
    logger.info("To disable globally: MOBHOOK=0");

    Ok(())
}

fn check_required_tools(logger: &Logger) {
    logger.info("Checking required tools...");
    logger.line();

    let tools_list = [
        ("gitleaks", "auto-downloaded on first use"),
        ("mobsfscan", "auto-installed via pipx on first use"),
        ("flutter", "https://flutter.dev/docs/get-started/install"),
    ];

    for (name, hint) in tools_list {
        if tools::find_tool(name).is_some() {
            logger.success(&format!("{name} found"));
        } else {
            logger.warn(&format!("{name} not found"));
            logger.detail(&format!("  {hint}"));
        }
    }
}
