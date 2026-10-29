use anyhow::{Context, Result};
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

use super::config::{HookEntry, HookMode, MobhookConfig};
use super::logger::Logger;
use super::preset::Preset;
use super::validate::ensure_path_component;

/// Deepest directory level copied when backing up custom hooks.
const MAX_COPY_DEPTH: usize = 32;

/// Custom hook folders copied aside while .mobhook/ is regenerated.
struct PreservedHooks {
    dir: TempDir,
    names: Vec<String>,
}

impl PreservedHooks {
    /// Keep the backup on disk and point the error at it, so a failed
    /// regeneration never silently deletes the user's custom hooks.
    fn abandon(self, err: anyhow::Error) -> anyhow::Error {
        let kept = self.dir.keep();
        err.context(format!(
            "Custom hooks were backed up to {} -- copy them back into .mobhook/ before retrying",
            kept.display()
        ))
    }
}

pub struct HookManager<'a> {
    project_root: PathBuf,
    logger: Option<&'a Logger>,
}

impl<'a> HookManager<'a> {
    pub fn new(project_root: &Path) -> Self {
        Self {
            project_root: project_root.to_path_buf(),
            logger: None,
        }
    }

    pub fn with_logger(project_root: &Path, logger: &'a Logger) -> Self {
        Self {
            project_root: project_root.to_path_buf(),
            logger: Some(logger),
        }
    }

    pub fn hooks_dir(&self) -> PathBuf {
        self.project_root.join(".mobhook")
    }

    fn log_info(&self, msg: &str) {
        if let Some(l) = self.logger {
            l.info(msg);
        }
    }

    fn log_success(&self, msg: &str) {
        if let Some(l) = self.logger {
            l.success(msg);
        }
    }

    fn log_warn(&self, msg: &str) {
        if let Some(l) = self.logger {
            l.warn(msg);
        }
    }

    /// Validate this is a git repository.
    pub fn validate_git_repo(&self) -> Result<()> {
        let git_dir = self.project_root.join(".git");
        if !git_dir.exists() {
            anyhow::bail!("Not a git repository: {}", self.project_root.display());
        }
        Ok(())
    }

    /// One-time git setup: set core.hooksPath and update .gitignore.
    pub fn setup(&self) -> Result<()> {
        self.validate_git_repo()?;
        self.set_hooks_path()?;
        self.ensure_gitignore_entry(".hook-reports/")?;
        self.remove_gitignore_entry(".mobhook/")?;
        Ok(())
    }

    /// Regenerate .mobhook/ from config. Fully idempotent.
    pub fn run(&self, config: &MobhookConfig, presets: &[Box<dyn Preset>]) -> Result<()> {
        self.validate_git_repo()?;
        // Configs can be built in code, not only parsed: re-check before any fs write.
        config.validate()?;

        let step_names = self.collect_step_names(config);
        let preserved = self.preserve_custom_hooks(&step_names)?;

        // Clean slate
        let hooks_dir = self.hooks_dir();
        if let Err(e) = reset_dir(&hooks_dir) {
            return Err(match preserved {
                Some(p) => p.abandon(e),
                None => e,
            });
        }

        // Restore custom hooks
        if let Some(p) = preserved {
            self.restore_custom_hooks(p)?;
        }

        // Install presets and generate scripts
        for (hook_type, hook_config) in &config.hooks {
            if hook_config.order.is_empty() {
                continue;
            }

            for entry in &hook_config.order {
                if let Some(preset) = presets.iter().find(|p| p.name() == entry.name) {
                    let dest = hooks_dir.join(preset.name());
                    if !dest.exists() {
                        preset.install(&hooks_dir)?;
                        self.log_success(&format!(
                            "Installed preset '{}/' to .mobhook/",
                            preset.name()
                        ));
                    }
                }
            }

            let script = self.generate_hook_script(hook_type, &hook_config.order, config.mode);
            ensure_path_component("hook type", hook_type)?;
            let hook_file = hooks_dir.join(hook_type);
            fs::write(&hook_file, &script)
                .with_context(|| format!("Failed to write {}", hook_file.display()))?;

            let mut perms = fs::metadata(&hook_file)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&hook_file, perms)?;

            let names: Vec<&str> = hook_config.order.iter().map(|e| e.name.as_str()).collect();
            self.log_success(&format!(
                "Generated {} hook ({} step(s): {})",
                hook_type,
                hook_config.order.len(),
                names.join(" -> "),
            ));
        }

        Ok(())
    }

    /// Remove .mobhook/ and reset git hooksPath.
    pub fn uninstall(&self) -> Result<()> {
        self.validate_git_repo()?;

        let hooks_dir = self.hooks_dir();
        if hooks_dir.exists() {
            fs::remove_dir_all(&hooks_dir)?;
            self.log_success("Removed .mobhook/ directory");
        } else {
            self.log_warn(".mobhook/ not found -- nothing to remove");
        }

        self.unset_hooks_path()?;
        self.log_success("Restored default git hooks path");
        Ok(())
    }

    /// Generate a combined bash script for a hook type.
    ///
    /// Names are validated at config parse time; every config-derived value is
    /// still emitted single-quoted so it can never be evaluated by bash.
    pub fn generate_hook_script(
        &self,
        hook_type: &str,
        steps: &[HookEntry],
        global_mode: HookMode,
    ) -> String {
        let total = steps.len();
        let has_any_warning = steps
            .iter()
            .any(|s| s.effective_mode(global_mode) == HookMode::Warning);

        let mut buf = String::new();
        buf.push_str("#!/bin/bash\n");
        buf.push_str("# Generated by mobhook -- do not edit manually.\n");
        buf.push_str("# Regenerate with: mobhook update\n\n");
        buf.push_str("set -e\n\n");
        buf.push_str("# MOBHOOK=0 skips all mobhook hooks.\n");
        buf.push_str("if [ \"${MOBHOOK:-}\" = \"0\" ]; then\n  exit 0\nfi\n\n");
        buf.push_str("HOOK_DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n");
        buf.push_str("RED='\\033[0;31m'\n");
        buf.push_str("GREEN='\\033[0;32m'\n");
        buf.push_str("YELLOW='\\033[0;33m'\n");
        buf.push_str("BLUE='\\033[0;34m'\n");
        buf.push_str("NC='\\033[0m'\n");

        if has_any_warning {
            buf.push_str("\nWARN_COUNT=0\n");
        }
        buf.push('\n');

        for (i, entry) in steps.iter().enumerate() {
            let num = i + 1;
            let effective_mode = entry.effective_mode(global_mode);

            let name = sh_quote(&entry.name);

            buf.push_str(&format!(
                "echo -e \"${{BLUE}}\"{}\"${{NC}}\"\n",
                sh_quote(&format!("[{num}/{total}] {hook_type} -> {}", entry.name)),
            ));
            buf.push_str("set +e\n");
            buf.push_str(&format!(
                "\"$HOOK_DIR\"/{} \"$@\"\n",
                sh_quote(&format!("{}/script.sh", entry.name))
            ));
            buf.push_str("EXIT_CODE=$?\n");
            buf.push_str("set -e\n");
            buf.push_str("if [ $EXIT_CODE -ne 0 ]; then\n");

            if effective_mode == HookMode::Warning {
                buf.push_str(&format!(
                    "  echo -e \"${{YELLOW}}WARNING: \"{name}\" failed (exit $EXIT_CODE). Continuing in warning mode.${{NC}}\" >&2\n",
                ));
                buf.push_str("  WARN_COUNT=$((WARN_COUNT + 1))\n");
                buf.push_str("else\n");
            } else {
                buf.push_str(&format!(
                    "  echo -e \"${{RED}}FAIL: \"{name}\" failed (exit $EXIT_CODE). Aborting.${{NC}}\" >&2\n",
                ));
                buf.push_str("  exit $EXIT_CODE\n");
                buf.push_str("else\n");
            }

            buf.push_str(&format!(
                "  echo -e \"${{GREEN}}OK \"{name}\" done${{NC}}\"\n"
            ));
            buf.push_str("fi\n\n");
        }

        if has_any_warning {
            buf.push_str("if [ $WARN_COUNT -gt 0 ]; then\n");
            buf.push_str("  echo -e \"${YELLOW}[WARN] $WARN_COUNT step(s) had issues but were non-blocking.${NC}\" >&2\n");
            buf.push_str("fi\n\n");
        }

        buf
    }

    fn collect_step_names(&self, config: &MobhookConfig) -> HashSet<String> {
        config
            .hooks
            .values()
            .flat_map(|h| h.order.iter().map(|e| e.name.clone()))
            .collect()
    }

    fn preserve_custom_hooks(
        &self,
        step_names: &HashSet<String>,
    ) -> Result<Option<PreservedHooks>> {
        let hooks_dir = self.hooks_dir();
        if !hooks_dir.exists() {
            return Ok(None);
        }

        let mut to_keep: Vec<&String> = step_names
            .iter()
            .filter(|name| {
                let step_dir = hooks_dir.join(name);
                step_dir.exists() && step_dir.join("script.sh").exists()
            })
            .collect();
        if to_keep.is_empty() {
            return Ok(None);
        }
        to_keep.sort();

        // Private, randomly named dir (0700) instead of a guessable shared temp path.
        let dir = tempfile::Builder::new()
            .prefix("mobhook-preserve-")
            .tempdir()
            .context("Failed to create backup dir for custom hooks")?;

        let mut names = Vec::new();
        for name in to_keep {
            ensure_path_component("hook name", name)?;
            let step_dir = hooks_dir.join(name);
            copy_dir_recursive(&step_dir, &dir.path().join(name), 0)
                .with_context(|| format!("Failed to back up custom hook '{name}'"))?;
            names.push(name.clone());
        }

        Ok(Some(PreservedHooks { dir, names }))
    }

    fn restore_custom_hooks(&self, preserved: PreservedHooks) -> Result<()> {
        let hooks_dir = self.hooks_dir();
        let restored = preserved.names.iter().try_for_each(|name| {
            let dest = hooks_dir.join(name);
            if dest.exists() {
                return Ok(());
            }
            restore_one(&preserved.dir.path().join(name), &dest)
                .with_context(|| format!("Failed to restore custom hook '{name}'"))
        });
        if let Err(e) = restored {
            return Err(preserved.abandon(e));
        }

        let backup_path = preserved.dir.path().to_path_buf();
        if let Err(e) = preserved.dir.close() {
            self.log_warn(&format!(
                "Could not remove backup dir {}: {e}",
                backup_path.display()
            ));
        }
        Ok(())
    }

    fn set_hooks_path(&self) -> Result<()> {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.project_root)
            .args(["config", "core.hooksPath", ".mobhook"])
            .output()
            .context("Failed to run git config")?;
        if output.status.success() {
            self.log_success("Set core.hooksPath to .mobhook");
        }
        Ok(())
    }

    fn unset_hooks_path(&self) -> Result<()> {
        Command::new("git")
            .arg("-C")
            .arg(&self.project_root)
            .args(["config", "--local", "--unset", "core.hooksPath"])
            .output()
            .context("Failed to run git config")?;
        Ok(())
    }

    fn ensure_gitignore_entry(&self, entry: &str) -> Result<()> {
        let gitignore = self.project_root.join(".gitignore");
        if gitignore.exists() {
            let content = fs::read_to_string(&gitignore)?;
            if content.lines().any(|l| l.trim() == entry) {
                return Ok(());
            }
            let prefix = if !content.is_empty() && !content.ends_with('\n') {
                "\n"
            } else {
                ""
            };
            let mut f = fs::OpenOptions::new().append(true).open(&gitignore)?;
            writeln!(f, "{}{}", prefix, entry)?;
        } else {
            fs::write(&gitignore, format!("{}\n", entry))?;
        }
        Ok(())
    }

    fn remove_gitignore_entry(&self, entry: &str) -> Result<()> {
        let gitignore = self.project_root.join(".gitignore");
        if !gitignore.exists() {
            return Ok(());
        }
        let content = fs::read_to_string(&gitignore)?;
        let filtered: Vec<&str> = content.lines().filter(|l| l.trim() != entry).collect();
        if filtered.len() < content.lines().count() {
            fs::write(&gitignore, format!("{}\n", filtered.join("\n")))?;
        }
        Ok(())
    }
}

/// Single-quote a value for bash; embedded quotes become '\''.
fn sh_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn reset_dir(dir: &Path) -> Result<()> {
    if dir.exists() {
        fs::remove_dir_all(dir).with_context(|| format!("Failed to remove {}", dir.display()))?;
    }
    fs::create_dir_all(dir).with_context(|| format!("Failed to create {}", dir.display()))?;
    Ok(())
}

fn restore_one(backup: &Path, dest: &Path) -> Result<()> {
    copy_dir_recursive(backup, dest, 0)?;
    let script = dest.join("script.sh");
    // Never chmod through a symlink: only a real script file is made executable.
    let is_regular = fs::symlink_metadata(&script)
        .map(|m| m.file_type().is_file())
        .unwrap_or(false);
    if is_regular {
        let mut perms = fs::metadata(&script)
            .with_context(|| format!("Failed to read {}", script.display()))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&script, perms)
            .with_context(|| format!("Failed to chmod {}", script.display()))?;
    }
    Ok(())
}

/// Copy a tree without following symlinks: links are recreated as links, so a
/// backup can never pull in content from outside the source tree.
fn copy_dir_recursive(src: &Path, dst: &Path, depth: usize) -> Result<()> {
    if depth > MAX_COPY_DEPTH {
        anyhow::bail!("Directory nesting too deep at {}", src.display());
    }

    let file_type = fs::symlink_metadata(src)
        .with_context(|| format!("Failed to read {}", src.display()))?
        .file_type();
    if file_type.is_symlink() {
        let target = fs::read_link(src)?;
        std::os::unix::fs::symlink(&target, dst)
            .with_context(|| format!("Failed to copy symlink {}", src.display()))?;
    } else if file_type.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_dir_recursive(&entry.path(), &dst.join(entry.file_name()), depth + 1)?;
        }
    } else if file_type.is_file() {
        fs::copy(src, dst).with_context(|| format!("Failed to copy {}", src.display()))?;
    }
    // Sockets, FIFOs and device nodes are skipped.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sh_quote_neutralises_quotes() {
        assert_eq!(sh_quote("security"), "'security'");
        assert_eq!(sh_quote("a'b"), "'a'\\''b'");
        assert_eq!(sh_quote("$(id)"), "'$(id)'");
    }

    #[test]
    fn copy_keeps_symlinks_as_links() {
        let tmp = tempfile::TempDir::new().unwrap();
        let outside = tmp.path().join("outside.txt");
        fs::write(&outside, "do not copy me").unwrap();

        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("script.sh"), "#!/bin/bash\n").unwrap();
        std::os::unix::fs::symlink(&outside, src.join("leak")).unwrap();
        std::os::unix::fs::symlink("..", src.join("sub").join("loop")).unwrap();

        let dst = tmp.path().join("dst");
        copy_dir_recursive(&src, &dst, 0).unwrap();

        assert!(dst.join("script.sh").is_file());
        let leak = fs::symlink_metadata(dst.join("leak")).unwrap();
        assert!(
            leak.file_type().is_symlink(),
            "content behind a symlink was copied"
        );
        assert_eq!(fs::read_link(dst.join("leak")).unwrap(), outside);
        let looped = fs::symlink_metadata(dst.join("sub").join("loop")).unwrap();
        assert!(looped.file_type().is_symlink());
    }

    #[test]
    fn copy_caps_depth() {
        let tmp = tempfile::TempDir::new().unwrap();
        let mut deep = tmp.path().join("src");
        for i in 0..=MAX_COPY_DEPTH + 1 {
            deep = deep.join(format!("d{i}"));
        }
        fs::create_dir_all(&deep).unwrap();
        let err =
            copy_dir_recursive(&tmp.path().join("src"), &tmp.path().join("dst"), 0).unwrap_err();
        assert!(err.to_string().contains("too deep"));
    }

    #[test]
    fn restore_does_not_chmod_through_symlink() {
        let tmp = tempfile::TempDir::new().unwrap();
        let outside = tmp.path().join("victim");
        fs::write(&outside, "x").unwrap();
        let mut perms = fs::metadata(&outside).unwrap().permissions();
        perms.set_mode(0o600);
        fs::set_permissions(&outside, perms).unwrap();

        let backup = tmp.path().join("backup");
        fs::create_dir_all(&backup).unwrap();
        std::os::unix::fs::symlink(&outside, backup.join("script.sh")).unwrap();

        restore_one(&backup, &tmp.path().join("dest")).unwrap();
        let mode = fs::metadata(&outside).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn abandon_keeps_backup_and_names_it() {
        let dir = tempfile::Builder::new()
            .prefix("mobhook-preserve-test-")
            .tempdir()
            .unwrap();
        let path = dir.path().to_path_buf();
        let preserved = PreservedHooks {
            dir,
            names: vec!["lint".into()],
        };
        let err = preserved.abandon(anyhow::anyhow!("boom"));
        assert!(path.exists());
        assert!(format!("{err:#}").contains(&path.display().to_string()));
        fs::remove_dir_all(&path).unwrap();
    }
}
