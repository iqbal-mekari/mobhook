use crate::core::preset::{InstallMethod, Preset, PresetFile, Tool};
use include_dir::{include_dir, Dir};

static QUALITY_REPORT_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/presets/quality-report");

pub struct QualityReportPreset;

impl Preset for QualityReportPreset {
    fn name(&self) -> &str {
        "quality-report"
    }

    fn files(&self) -> Vec<PresetFile> {
        QUALITY_REPORT_DIR
            .files()
            .map(|f| PresetFile {
                relative_path: f.path().file_name().unwrap().to_string_lossy().to_string(),
                content: f.contents(),
            })
            .collect()
    }

    fn required_tools(&self) -> Vec<Tool> {
        vec![
            Tool {
                name: "jq",
                install: InstallMethod::System {
                    hint: "brew install jq",
                },
            },
            Tool {
                name: "flutter",
                install: InstallMethod::System {
                    hint: "https://flutter.dev/docs/get-started/install",
                },
            },
            Tool {
                name: "jscpd",
                install: InstallMethod::System {
                    hint: "npm install -g jscpd",
                },
            },
            Tool {
                name: "detekt",
                install: InstallMethod::System {
                    hint: "brew install detekt",
                },
            },
            Tool {
                name: "swiftlint",
                install: InstallMethod::System {
                    hint: "brew install swiftlint",
                },
            },
        ]
    }
}
