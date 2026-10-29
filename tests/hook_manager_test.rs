mod common;
use mobhook::core::config::{HookConfig, HookEntry, HookMode, MobhookConfig};
use mobhook::core::hook_manager::HookManager;
use mobhook::presets;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

#[test]
fn test_generate_hook_script_single_step() {
    let yaml = r#"
mode: blocking
hooks:
  pre-push:
    order:
      - security
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
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
    let yaml = r#"
mode: blocking
hooks:
  pre-push:
    order:
      - flutter-test
      - security
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
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
    let yaml = r#"
mode: warning
hooks:
  pre-push:
    order:
      - security
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());

    let script = mgr.generate_hook_script("pre-push", &config.hooks["pre-push"].order, config.mode);

    assert!(script.contains("WARN_COUNT"));
    assert!(script.contains("warning mode"));
}

#[test]
fn test_generate_hook_script_per_entry_override() {
    let yaml = r#"
mode: warning
hooks:
  pre-push:
    order:
      - name: security
        mode: blocking
      - flutter-test
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
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

fn entry(name: &str, mode: Option<HookMode>) -> HookEntry {
    HookEntry {
        name: name.to_string(),
        mode,
    }
}

/// Git repo in a subdirectory, so a path escape would still land in the tempdir.
fn nested_repo() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::TempDir::new().unwrap();
    let root = dir.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    Command::new("git")
        .arg("init")
        .current_dir(&root)
        .output()
        .unwrap();
    (dir, root)
}

fn write_script(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, format!("#!/bin/bash\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// Write `script` as `.mobhook/<hook_type>` in `dir` and run it with bash from `dir`.
fn run_hook(dir: &Path, hook_type: &str, script: &str, mobhook_env: Option<&str>) -> Output {
    let hooks = dir.join(".mobhook");
    fs::create_dir_all(&hooks).unwrap();
    let hook = hooks.join(hook_type);
    fs::write(&hook, script).unwrap();
    let mut cmd = Command::new("bash");
    cmd.arg(&hook).arg("arg-from-git").current_dir(dir);
    cmd.env_remove("MOBHOOK");
    if let Some(v) = mobhook_env {
        cmd.env("MOBHOOK", v);
    }
    cmd.output().unwrap()
}

#[test]
fn test_generated_script_does_not_evaluate_malicious_names() {
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());
    // Built in code to bypass parse-time validation: quoting alone must hold.
    let steps = vec![
        entry("$(touch pwned1)", None),
        entry("`touch pwned2`", None),
        entry("'; touch pwned3; '", None),
        entry("\"; touch pwned4; \"", None),
        entry("x\ntouch pwned5", None),
        entry("${IFS}touch${IFS}pwned6", None),
    ];
    let script = mgr.generate_hook_script("pre-push", &steps, HookMode::Warning);

    let syntax = Command::new("bash")
        .arg("-n")
        .arg("-c")
        .arg(&script)
        .output()
        .unwrap();
    assert!(
        syntax.status.success(),
        "{}",
        String::from_utf8_lossy(&syntax.stderr)
    );

    let out = run_hook(dir.path(), "pre-push", &script, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    for i in 1..=6 {
        assert!(
            !dir.path().join(format!("pwned{i}")).exists(),
            "payload {i} executed"
        );
        assert!(!dir
            .path()
            .join(".mobhook")
            .join(format!("pwned{i}"))
            .exists());
    }
}

#[test]
fn test_generated_script_runs_legitimate_steps() {
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());
    write_script(
        &dir.path().join(".mobhook/lint-check/script.sh"),
        "echo \"$1\" > ran-lint-check",
    );
    let steps = vec![entry("lint-check", None)];
    let script = mgr.generate_hook_script("pre-commit", &steps, HookMode::Blocking);

    let out = run_hook(dir.path(), "pre-commit", &script, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let ran = fs::read_to_string(dir.path().join("ran-lint-check")).unwrap();
    assert_eq!(ran.trim(), "arg-from-git");
    assert!(String::from_utf8_lossy(&out.stdout).contains("[1/1] pre-commit -> lint-check"));
}

#[test]
fn test_generated_script_blocking_failure_aborts() {
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());
    write_script(&dir.path().join(".mobhook/failing/script.sh"), "exit 3");
    let script =
        mgr.generate_hook_script("pre-push", &[entry("failing", None)], HookMode::Blocking);

    let out = run_hook(dir.path(), "pre-push", &script, None);
    assert_eq!(out.status.code(), Some(3));
}

#[test]
fn test_generated_script_honors_mobhook_kill_switch() {
    let dir = tempfile::TempDir::new().unwrap();
    let mgr = HookManager::new(dir.path());
    write_script(
        &dir.path().join(".mobhook/failing/script.sh"),
        "touch ran-failing; exit 1",
    );
    let script =
        mgr.generate_hook_script("pre-push", &[entry("failing", None)], HookMode::Blocking);

    let out = run_hook(dir.path(), "pre-push", &script, Some("0"));
    assert!(out.status.success());
    assert!(!dir.path().join("ran-failing").exists());

    // Any other value keeps hooks active.
    let out = run_hook(dir.path(), "pre-push", &script, Some("1"));
    assert!(!out.status.success());
    assert!(dir.path().join("ran-failing").exists());
}

#[test]
fn test_run_rejects_path_escaping_hook_types() {
    let (dir, root) = nested_repo();
    let absolute = dir.path().join("abs-target");
    for key in [
        "../escaped".to_string(),
        absolute.to_string_lossy().to_string(),
    ] {
        let mut config = MobhookConfig::parse("mode: blocking\n").unwrap();
        config.hooks.insert(
            key.clone(),
            HookConfig {
                order: vec![entry("security", None)],
            },
        );
        let mgr = HookManager::new(&root);
        assert!(
            mgr.run(&config, &presets::builtin_presets()).is_err(),
            "{key}"
        );
    }
    assert!(!dir.path().join("escaped").exists());
    assert!(!absolute.exists());
}

#[test]
fn test_run_rejects_invalid_names_before_touching_hooks_dir() {
    let (_dir, root) = nested_repo();
    let existing = root.join(".mobhook/pre-push");
    fs::create_dir_all(existing.parent().unwrap()).unwrap();
    fs::write(&existing, "keep me").unwrap();

    let mut config = MobhookConfig::parse("mode: blocking\n").unwrap();
    config.hooks.insert(
        "pre-push".to_string(),
        HookConfig {
            order: vec![entry("../../escaped", None)],
        },
    );
    let mgr = HookManager::new(&root);
    assert!(mgr.run(&config, &presets::builtin_presets()).is_err());
    assert_eq!(fs::read_to_string(&existing).unwrap(), "keep me");
}

#[test]
fn test_run_generates_hooks_and_preserves_custom_hooks() {
    let (dir, root) = nested_repo();
    let custom = root.join(".mobhook/lint-check");
    write_script(&custom.join("script.sh"), "echo custom");
    fs::set_permissions(custom.join("script.sh"), fs::Permissions::from_mode(0o644)).unwrap();
    fs::write(custom.join("rules.txt"), "rule").unwrap();
    let secret = dir.path().join("secret.txt");
    fs::write(&secret, "outside").unwrap();
    std::os::unix::fs::symlink(&secret, custom.join("link")).unwrap();
    // Not referenced by the config: removed on regeneration.
    write_script(&root.join(".mobhook/stale/script.sh"), "echo stale");

    let yaml = r#"
mode: blocking
hooks:
  pre-push:
    order:
      - security
  pre-commit:
    order:
      - lint-check
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let mgr = HookManager::new(&root);
    mgr.run(&config, &presets::builtin_presets()).unwrap();
    // Idempotent: a second run preserves the restored hook again.
    mgr.run(&config, &presets::builtin_presets()).unwrap();

    let hooks = root.join(".mobhook");
    for hook in ["pre-push", "pre-commit"] {
        let mode = fs::metadata(hooks.join(hook)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o755, "{hook}");
    }
    assert!(hooks.join("security/script.sh").is_file());
    assert!(!hooks.join("stale").exists());

    let script = custom.join("script.sh");
    assert!(fs::read_to_string(&script).unwrap().contains("echo custom"));
    assert_eq!(
        fs::metadata(&script).unwrap().permissions().mode() & 0o777,
        0o755
    );
    assert_eq!(
        fs::read_to_string(custom.join("rules.txt")).unwrap(),
        "rule"
    );
    let link = fs::symlink_metadata(custom.join("link")).unwrap();
    assert!(
        link.file_type().is_symlink(),
        "symlink target was copied in"
    );

    // The old predictable backup location is no longer used.
    assert!(!std::env::temp_dir()
        .join("mobhook_preserve_lint-check")
        .exists());
}

fn mobhook_cli(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_mobhook"))
        .args(args)
        .current_dir(dir)
        .env("HOME", dir)
        .env_remove("MOBHOOK")
        .output()
        .unwrap()
}

#[test]
fn test_cli_update_rejects_malicious_config() {
    let (dir, root) = nested_repo();
    fs::write(
        root.join("mobhook.yaml"),
        "mode: blocking\nhooks:\n  ../escaped:\n    order:\n      - security\n",
    )
    .unwrap();
    let out = mobhook_cli(&root, &["update"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("Unsupported hook type"));
    assert!(!dir.path().join("escaped").exists());

    fs::write(
        root.join("mobhook.yaml"),
        "mode: blocking\nremote:\n  url: http://example.invalid/rules.git\n",
    )
    .unwrap();
    let out = mobhook_cli(&root, &["update"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("Unsupported remote URL scheme"));
}

#[test]
fn test_cli_create_uses_shared_name_rule() {
    let (_dir, root) = nested_repo();
    fs::create_dir_all(root.join(".mobhook")).unwrap();

    for bad in ["Bad", "x$(id)", "../x", "a b", ""] {
        let out = mobhook_cli(&root, &["create", bad]);
        assert_eq!(out.status.code(), Some(64), "{bad:?}");
    }
    let out = mobhook_cli(&root, &["create", "lint-check"]);
    assert!(out.status.success());
    assert!(root.join(".mobhook/lint-check/script.sh").is_file());
}
