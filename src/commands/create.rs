use anyhow::Result;
use regex::Regex;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process;

use crate::core::logger::Logger;

pub fn run(name: &str) -> Result<()> {
    let logger = Logger::new(false);

    let valid_name = Regex::new(r"^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$").unwrap();
    if !valid_name.is_match(name) {
        logger.error(&format!(
            "Invalid hook name \"{name}\". Use lowercase alphanumeric characters and hyphens only (e.g. lint-check, run-tests)."
        ));
        process::exit(64);
    }

    let project_root = std::env::current_dir()?;
    let hooks_dir = project_root.join(".mobhook");

    if !hooks_dir.exists() {
        logger.error(".mobhook/ not found. Run \"mobhook init\" first.");
        process::exit(1);
    }

    let hook_dir = hooks_dir.join(name);
    if hook_dir.exists() {
        logger.error(&format!(
            "Hook \"{name}\" already exists at .mobhook/{name}/. Remove it first or choose a different name."
        ));
        process::exit(1);
    }

    logger.header("mobhook create");

    fs::create_dir_all(&hook_dir)?;
    let script_path = hook_dir.join("script.sh");
    fs::write(&script_path, template(name))?;

    let mut perms = fs::metadata(&script_path)?.permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&script_path, perms)?;

    logger.success(&format!("Created .mobhook/{name}/script.sh"));
    logger.line();
    logger.info("Next steps:");
    logger.info(&format!("  1. Edit .mobhook/{name}/script.sh with your logic"));
    logger.info(&format!("  2. Add \"{name}\" to mobhook.toml under the hook type you want:"));
    logger.info("");
    logger.info("     hooks:");
    logger.info("       pre-commit:        # or pre-push, commit-msg, etc.");
    logger.info(&format!("         order = [\"{name}\"]"));
    logger.info("");
    logger.info("  3. Run \"mobhook update\" to regenerate hooks");

    Ok(())
}

fn template(name: &str) -> String {
    format!(r#"#!/bin/bash
# =============================================================================
# {name} - Custom Hook
# =============================================================================
# Created by: mobhook create {name}
#
# HOW TO USE:
#   1. Add your logic in the "YOUR LOGIC HERE" section below.
#   2. Register this hook in mobhook.toml under the desired hook type.
#   3. Run "mobhook update" to regenerate hooks.
#
# CONVENTIONS:
#   - Exit 0 = success, Exit 1 = failure
#   - Use $@ to access arguments passed by git
#   - This script runs from the project root directory
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_ROOT="$(git rev-parse --show-toplevel)"

echo -e "${{BLUE}}Running {name}...${{NC}}"

# =============================================================================
# YOUR LOGIC HERE
# =============================================================================

# =============================================================================

echo -e "${{GREEN}} {name} passed${{NC}}"
exit 0
"#)
}
