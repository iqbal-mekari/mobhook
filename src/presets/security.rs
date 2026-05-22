use include_dir::{include_dir, Dir};
use crate::core::preset::{Preset, PresetFile, Tool, InstallMethod};

static SECURITY_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/presets/security");

pub struct SecurityPreset;

impl Preset for SecurityPreset {
    fn name(&self) -> &str {
        "security"
    }

    fn files(&self) -> Vec<PresetFile> {
        SECURITY_DIR
            .files()
            .map(|f| PresetFile {
                relative_path: f.path()
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .to_string(),
                content: f.contents(),
            })
            .collect()
    }

    fn required_tools(&self) -> Vec<Tool> {
        vec![
            Tool {
                name: "gitleaks",
                install: InstallMethod::Download {
                    repo: "gitleaks/gitleaks",
                    binary_name: "gitleaks",
                },
            },
            Tool {
                name: "mobsfscan",
                install: InstallMethod::Pipx,
            },
        ]
    }
}
