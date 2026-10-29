use mobhook::core::preset::{install_preset_with_overrides, Preset, PresetFile, Tool};
use mobhook::presets;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

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

    let perms = std::fs::metadata(&script).unwrap().permissions();
    assert!(perms.mode() & 0o111 != 0);
}

struct FixturePreset;

impl Preset for FixturePreset {
    fn name(&self) -> &str {
        "fixture"
    }

    fn files(&self) -> Vec<PresetFile> {
        vec![
            PresetFile {
                relative_path: "script.sh".to_string(),
                content: b"#!/bin/bash\necho bundled\n",
            },
            PresetFile {
                relative_path: "rules.toml".to_string(),
                content: b"bundled = true\n",
            },
        ]
    }

    fn required_tools(&self) -> Vec<Tool> {
        Vec::new()
    }
}

fn remote_file(dir: &Path, name: &str, content: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, content).unwrap();
    path
}

#[test]
fn test_install_with_overrides_uses_regular_remote_files() {
    let tmp = tempfile::TempDir::new().unwrap();
    let cache = tmp.path().join("cache");
    let hooks = tmp.path().join("hooks");
    fs::create_dir_all(&cache).unwrap();
    fs::create_dir_all(&hooks).unwrap();

    let mut remote = HashMap::new();
    remote.insert(
        "fixture/rules.toml".to_string(),
        remote_file(&cache, "rules.toml", "remote = true\n"),
    );
    remote.insert(
        "fixture/extra.sh".to_string(),
        remote_file(&cache, "extra.sh", "#!/bin/bash\n"),
    );

    let dest = install_preset_with_overrides(&FixturePreset, &hooks, &remote).unwrap();
    assert_eq!(
        fs::read_to_string(dest.join("rules.toml")).unwrap(),
        "remote = true\n"
    );
    assert!(fs::read_to_string(dest.join("script.sh"))
        .unwrap()
        .contains("bundled"));
    let mode = fs::metadata(dest.join("extra.sh"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o755);
}

#[test]
fn test_install_with_overrides_refuses_symlinked_remote_files() {
    let tmp = tempfile::TempDir::new().unwrap();
    let cache = tmp.path().join("cache");
    fs::create_dir_all(&cache).unwrap();
    let secret = remote_file(tmp.path(), "secret.txt", "local secret");
    let link = cache.join("rules.toml");
    std::os::unix::fs::symlink(&secret, &link).unwrap();

    for key in ["fixture/rules.toml", "fixture/leak.txt"] {
        let hooks = tmp.path().join(format!("hooks-{}", key.replace('/', "_")));
        fs::create_dir_all(&hooks).unwrap();
        let mut remote = HashMap::new();
        remote.insert(key.to_string(), link.clone());

        let err = install_preset_with_overrides(&FixturePreset, &hooks, &remote).unwrap_err();
        assert!(format!("{err:#}").contains("not a regular file"), "{err:#}");
        for name in ["rules.toml", "leak.txt"] {
            let copied = fs::read_to_string(hooks.join("fixture").join(name)).unwrap_or_default();
            assert!(!copied.contains("local secret"), "{key}");
        }
    }
}

#[test]
fn test_install_with_overrides_rejects_traversal_names() {
    let tmp = tempfile::TempDir::new().unwrap();
    let hooks = tmp.path().join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    let file = remote_file(tmp.path(), "x", "x");

    let mut remote = HashMap::new();
    remote.insert("fixture/..".to_string(), file);
    assert!(install_preset_with_overrides(&FixturePreset, &hooks, &remote).is_err());
}
