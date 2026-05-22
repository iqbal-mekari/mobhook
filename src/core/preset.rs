use anyhow::Result;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// How a tool should be installed.
#[derive(Debug, Clone, PartialEq)]
pub enum InstallMethod {
    Download { repo: &'static str, binary_name: &'static str },
    Pipx,
    System { hint: &'static str },
}

/// A tool required by a preset.
#[derive(Debug, Clone)]
pub struct Tool {
    pub name: &'static str,
    pub install: InstallMethod,
}

/// A file belonging to a preset.
#[derive(Debug, Clone)]
pub struct PresetFile {
    pub relative_path: String,
    pub content: &'static [u8],
}

/// Trait implemented by each built-in preset.
pub trait Preset {
    fn name(&self) -> &str;
    fn files(&self) -> Vec<PresetFile>;
    fn required_tools(&self) -> Vec<Tool>;

    fn install(&self, hooks_dir: &Path) -> Result<PathBuf> {
        let dest = hooks_dir.join(self.name());
        fs::create_dir_all(&dest)?;

        for file in self.files() {
            let file_path = dest.join(&file.relative_path);
            fs::write(&file_path, file.content)?;

            if file.relative_path.ends_with(".sh") {
                let mut perms = fs::metadata(&file_path)?.permissions();
                perms.set_mode(0o755);
                fs::set_permissions(&file_path, perms)?;
            }
        }

        Ok(dest)
    }
}

/// Install a preset with optional remote file overrides.
pub fn install_preset_with_overrides(
    preset: &dyn Preset,
    hooks_dir: &Path,
    remote_files: &HashMap<String, PathBuf>,
) -> Result<PathBuf> {
    let dest = hooks_dir.join(preset.name());
    fs::create_dir_all(&dest)?;

    for file in preset.files() {
        let remote_key = format!("{}/{}", preset.name(), file.relative_path);
        let file_path = dest.join(&file.relative_path);

        if let Some(remote_path) = remote_files.get(&remote_key) {
            fs::copy(remote_path, &file_path)?;
        } else {
            fs::write(&file_path, file.content)?;
        }

        if file.relative_path.ends_with(".sh") {
            let mut perms = fs::metadata(&file_path)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&file_path, perms)?;
        }
    }

    // Install remote-only files not in bundled set
    let bundled_names: Vec<String> = preset.files().iter().map(|f| f.relative_path.clone()).collect();
    for (key, remote_path) in remote_files {
        let prefix = format!("{}/", preset.name());
        if let Some(filename) = key.strip_prefix(&prefix) {
            if filename.contains('/') { continue; }
            if bundled_names.contains(&filename.to_string()) { continue; }

            let file_path = dest.join(filename);
            fs::copy(remote_path, &file_path)?;
            if filename.ends_with(".sh") {
                let mut perms = fs::metadata(&file_path)?.permissions();
                perms.set_mode(0o755);
                fs::set_permissions(&file_path, perms)?;
            }
        }
    }

    Ok(dest)
}
