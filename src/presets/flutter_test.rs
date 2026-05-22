use include_dir::{include_dir, Dir};
use crate::core::preset::{Preset, PresetFile, Tool, InstallMethod};

static FLUTTER_TEST_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/presets/flutter-test");

pub struct FlutterTestPreset;

impl Preset for FlutterTestPreset {
    fn name(&self) -> &str {
        "flutter-test"
    }

    fn files(&self) -> Vec<PresetFile> {
        FLUTTER_TEST_DIR
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
                name: "flutter",
                install: InstallMethod::System {
                    hint: "https://flutter.dev/docs/get-started/install",
                },
            },
        ]
    }
}
