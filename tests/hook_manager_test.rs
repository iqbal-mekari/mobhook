mod common;
use mobhook::core::config::MobhookConfig;
use mobhook::core::hook_manager::HookManager;
use std::fs;

#[test]
fn test_generate_hook_script_single_step() {
    let toml = r#"
mode = "blocking"
[hooks.pre-push]
order = ["security"]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());

    let script = mgr.generate_hook_script("pre-push", &config.hooks["pre-push"].order, config.mode);

    assert!(script.contains("#!/bin/bash"));
    assert!(script.contains("[1/1] pre-push"));
    assert!(script.contains("security/script.sh"));
    assert!(script.contains("exit $EXIT_CODE"));
}

#[test]
fn test_generate_hook_script_multiple_steps() {
    let toml = r#"
mode = "blocking"
[hooks.pre-push]
order = ["flutter-test", "security"]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());

    let script = mgr.generate_hook_script("pre-push", &config.hooks["pre-push"].order, config.mode);

    assert!(script.contains("[1/2] pre-push"));
    assert!(script.contains("[2/2] pre-push"));
    assert!(script.contains("flutter-test/script.sh"));
    assert!(script.contains("security/script.sh"));
}

#[test]
fn test_generate_hook_script_warning_mode() {
    let toml = r#"
mode = "warning"
[hooks.pre-push]
order = ["security"]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());

    let script = mgr.generate_hook_script("pre-push", &config.hooks["pre-push"].order, config.mode);

    assert!(script.contains("WARN_COUNT"));
    assert!(script.contains("warning mode"));
}

#[test]
fn test_generate_hook_script_per_entry_override() {
    let toml = r#"
mode = "warning"
[hooks.pre-push]
order = [
    { name = "security", mode = "blocking" },
    "flutter-test",
]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());

    let script = mgr.generate_hook_script("pre-push", &config.hooks["pre-push"].order, config.mode);

    // security is blocking -- should have exit
    assert!(script.contains("exit $EXIT_CODE"));
    // flutter-test inherits warning -- should have WARN_COUNT
    assert!(script.contains("WARN_COUNT"));
}

#[test]
fn test_setup_sets_hooks_path() {
    let (_dir, root) = common::create_temp_git_repo();
    let mgr = HookManager::new(&root);
    mgr.setup().unwrap();

    let output = std::process::Command::new("git")
        .args(["-C", root.to_str().unwrap(), "config", "core.hooksPath"])
        .output()
        .unwrap();
    let hooks_path = String::from_utf8(output.stdout).unwrap();
    assert_eq!(hooks_path.trim(), ".mobhook");
}

#[test]
fn test_setup_adds_gitignore_entry() {
    let (_dir, root) = common::create_temp_git_repo();
    fs::write(root.join(".gitignore"), "node_modules/\n").unwrap();

    let mgr = HookManager::new(&root);
    mgr.setup().unwrap();

    let gitignore = fs::read_to_string(root.join(".gitignore")).unwrap();
    assert!(gitignore.contains(".hook-reports/"));
}

#[test]
fn test_uninstall_removes_mobhook_dir() {
    let (_dir, root) = common::create_temp_git_repo();
    let mobhook_dir = root.join(".mobhook");
    fs::create_dir_all(&mobhook_dir).unwrap();
    fs::write(mobhook_dir.join("pre-push"), "#!/bin/bash\n").unwrap();

    let mgr = HookManager::new(&root);
    mgr.uninstall().unwrap();

    assert!(!mobhook_dir.exists());
}
