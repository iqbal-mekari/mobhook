mod common;
use mobhook::core::config::{HookConfig, HookEntry, HookMode, MobhookConfig};
use mobhook::core::validate::SUPPORTED_HOOK_TYPES;

#[test]
fn test_parse_minimal_config() {
    let yaml = "mode: blocking\n";
    let config = MobhookConfig::parse(yaml).unwrap();
    assert_eq!(config.mode, HookMode::Blocking);
    assert!(config.hooks.is_empty());
    assert!(config.remote.is_none());
}

#[test]
fn test_parse_warning_mode() {
    let yaml = "mode: warning\n";
    let config = MobhookConfig::parse(yaml).unwrap();
    assert_eq!(config.mode, HookMode::Warning);
}

#[test]
fn test_parse_remote_config() {
    let yaml = r#"
mode: blocking
remote:
  url: "https://github.com/org/rules.git"
  ref: develop
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let remote = config.remote.unwrap();
    assert_eq!(remote.url, "https://github.com/org/rules.git");
    assert_eq!(remote.ref_, "develop");
}

#[test]
fn test_parse_remote_default_ref() {
    let yaml = r#"
mode: blocking
remote:
  url: "https://github.com/org/rules.git"
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let remote = config.remote.unwrap();
    assert_eq!(remote.ref_, "main");
}

#[test]
fn test_parse_hooks_with_short_form() {
    let yaml = r#"
mode: warning
hooks:
  pre-push:
    order:
      - security
      - flutter-test
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let hook = config.hooks.get("pre-push").unwrap();
    assert_eq!(hook.order.len(), 2);
    assert_eq!(hook.order[0].name, "security");
    assert_eq!(hook.order[0].mode, None);
    assert_eq!(hook.order[1].name, "flutter-test");
}

#[test]
fn test_parse_hooks_with_long_form() {
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
    let hook = config.hooks.get("pre-push").unwrap();
    assert_eq!(hook.order[0].name, "security");
    assert_eq!(hook.order[0].mode, Some(HookMode::Blocking));
    assert_eq!(hook.order[1].name, "flutter-test");
    assert_eq!(hook.order[1].mode, None);
}

#[test]
fn test_parse_empty_order() {
    let yaml = r#"
mode: blocking
hooks:
  pre-commit:
    order: []
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let hook = config.hooks.get("pre-commit").unwrap();
    assert!(hook.order.is_empty());
}

#[test]
fn test_installed_presets() {
    let yaml = r#"
mode: warning
hooks:
  pre-push:
    order:
      - security
      - flutter-test
  pre-commit:
    order:
      - security
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let installed = config.installed_presets();
    assert!(installed.contains("security"));
    assert!(installed.contains("flutter-test"));
    assert_eq!(installed.len(), 2);
}

#[test]
fn test_invalid_yaml_returns_error() {
    let yaml = "this: {is: invalid: yaml: [[[";
    let result = MobhookConfig::parse(yaml);
    assert!(result.is_err());
}

#[test]
fn test_default_yaml_is_valid() {
    let default = MobhookConfig::default_yaml();
    let result = MobhookConfig::parse(&default);
    assert!(
        result.is_ok(),
        "Default template failed to parse: {:?}",
        result.err()
    );
}

fn hooks_yaml(hook_type: &str, step: &str) -> String {
    format!("mode: blocking\nhooks:\n  {hook_type}:\n    order:\n      - {step}\n")
}

#[test]
fn test_rejects_path_like_hook_types() {
    for key in [
        "/tmp/evil",
        "'../x'",
        "'../../.bashrc'",
        "'a/b'",
        "'..'",
        "'pre-commit/../../x'",
        "'a\\b'",
    ] {
        let err = MobhookConfig::parse(&hooks_yaml(key, "security")).unwrap_err();
        assert!(
            format!("{err:#}").contains("Unsupported hook type"),
            "{key}: {err:#}"
        );
    }
}

#[test]
fn test_rejects_unknown_hook_types() {
    for key in ["post-receive", "Pre-Commit", "precommit", "''"] {
        assert!(
            MobhookConfig::parse(&hooks_yaml(key, "security")).is_err(),
            "{key}"
        );
    }
}

#[test]
fn test_accepts_all_supported_hook_types() {
    for hook_type in SUPPORTED_HOOK_TYPES {
        let config = MobhookConfig::parse(&hooks_yaml(hook_type, "security")).unwrap();
        assert!(config.hooks.contains_key(*hook_type));
    }
}

#[test]
fn test_rejects_invalid_step_names() {
    for name in [
        "''",
        "Security",
        "'x$(touch pwned)'",
        "'x`touch pwned`'",
        "\"a'b\"",
        "'a\"b'",
        "'has space'",
        "\"line\\nbreak\"",
        "'../x'",
        "'-lead'",
    ] {
        let short = MobhookConfig::parse(&hooks_yaml("pre-push", name));
        assert!(short.is_err(), "short form accepted {name}");
        let long = MobhookConfig::parse(&hooks_yaml(
            "pre-push",
            &format!("name: {name}\n        mode: warning"),
        ));
        let err = long.expect_err(name);
        assert!(format!("{err:#}").contains("Invalid step name"), "{err:#}");
    }
}

#[test]
fn test_rejects_invalid_entry_mode() {
    let yaml = r#"
mode: warning
hooks:
  pre-push:
    order:
      - name: security
        mode: blokcing
"#;
    let err = MobhookConfig::parse(yaml).unwrap_err();
    let msg = format!("{err:#}");
    assert!(msg.contains("Invalid mode"), "{msg}");
    assert!(msg.contains("blokcing"), "{msg}");
}

#[test]
fn test_entry_mode_aliases_still_accepted() {
    let yaml = r#"
mode: blocking
hooks:
  pre-push:
    order:
      - name: security
        mode: warn
      - name: flutter-test
        mode: BLOCK
"#;
    let config = MobhookConfig::parse(yaml).unwrap();
    let order = &config.hooks["pre-push"].order;
    assert_eq!(order[0].mode, Some(HookMode::Warning));
    assert_eq!(order[1].mode, Some(HookMode::Blocking));
}

fn remote_yaml(url: &str) -> String {
    format!("mode: blocking\nremote:\n  url: \"{url}\"\n")
}

#[test]
fn test_rejects_insecure_remote_urls() {
    for url in [
        "http://github.com/org/rules.git",
        "git://github.com/org/rules.git",
        "file:///etc",
        "/home/user/rules",
        "ftp://example.com/rules.tar.gz",
    ] {
        let err = MobhookConfig::parse(&remote_yaml(url)).unwrap_err();
        assert!(format!("{err:#}").contains("remote.url"), "{url}: {err:#}");
    }
}

#[test]
fn test_rejects_remote_url_with_credentials_without_echoing_them() {
    let err = MobhookConfig::parse(&remote_yaml(
        "https://ghp_du****my@github.com/org/rules.git",
    ))
    .unwrap_err();
    let msg = format!("{err:#}");
    assert!(msg.contains("embeds credentials"), "{msg}");
    assert!(!msg.contains("ghp_du"), "{msg}");
}

#[test]
fn test_accepts_https_and_ssh_remote_urls() {
    for url in [
        "https://github.com/org/rules.git",
        "ssh://git@github.com/org/rules.git",
        "git@github.com:org/rules.git",
    ] {
        let config = MobhookConfig::parse(&remote_yaml(url)).unwrap();
        assert_eq!(config.remote.unwrap().url, url);
    }
}

#[test]
fn test_validate_catches_config_built_in_code() {
    let mut config = MobhookConfig::parse("mode: blocking\n").unwrap();
    config.hooks.insert(
        "../escape".to_string(),
        HookConfig {
            order: vec![HookEntry {
                name: "security".to_string(),
                mode: None,
            }],
        },
    );
    assert!(config.validate().is_err());

    let mut config = MobhookConfig::parse("mode: blocking\n").unwrap();
    config.hooks.insert(
        "pre-push".to_string(),
        HookConfig {
            order: vec![HookEntry {
                name: "$(id)".to_string(),
                mode: None,
            }],
        },
    );
    assert!(config.validate().is_err());
}
