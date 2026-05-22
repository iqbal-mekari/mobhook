pub mod security;
pub mod flutter_test;

use crate::core::preset::Preset;

pub fn builtin_presets() -> Vec<Box<dyn Preset>> {
    vec![
        Box::new(security::SecurityPreset),
        Box::new(flutter_test::FlutterTestPreset),
    ]
}

pub fn builtin_preset_names() -> Vec<&'static str> {
    vec!["security", "flutter-test"]
}

pub fn find_builtin_preset(name: &str) -> Option<Box<dyn Preset>> {
    match name {
        "security" => Some(Box::new(security::SecurityPreset)),
        "flutter-test" => Some(Box::new(flutter_test::FlutterTestPreset)),
        _ => None,
    }
}
