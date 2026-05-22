use mobhook::presets;
use mobhook::core::preset::Preset;

#[test]
fn test_builtin_preset_names() {
    let names = presets::builtin_preset_names();
    assert!(names.contains(&"security"));
    assert!(names.contains(&"flutter-test"));
}

#[test]
fn test_security_preset_has_script_sh() {
    let preset = presets::find_builtin_preset("security").unwrap();
    let files = preset.files();
    assert!(files.iter().any(|f| f.relative_path == "script.sh"));
}

#[test]
fn test_security_preset_has_gitleaks_toml() {
    let preset = presets::find_builtin_preset("security").unwrap();
    let files = preset.files();
    assert!(files.iter().any(|f| f.relative_path == "gitleaks.toml"));
}

#[test]
fn test_flutter_test_preset_has_script_sh() {
    let preset = presets::find_builtin_preset("flutter-test").unwrap();
    let files = preset.files();
    assert!(files.iter().any(|f| f.relative_path == "script.sh"));
}

#[test]
fn test_unknown_preset_returns_none() {
    assert!(presets::find_builtin_preset("nonexistent").is_none());
}

#[test]
fn test_security_preset_install() {
    let dir = tempfile::TempDir::new().unwrap();
    let preset = presets::find_builtin_preset("security").unwrap();
    let result = preset.install(dir.path());
    assert!(result.is_ok());

    let script = dir.path().join("security").join("script.sh");
    assert!(script.exists());

    use std::os::unix::fs::PermissionsExt;
    let perms = std::fs::metadata(&script).unwrap().permissions();
    assert!(perms.mode() & 0o111 != 0);
}
