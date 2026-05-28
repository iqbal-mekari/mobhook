mod common;
use mobhook::core::config::{HookEntry, HookMode, MobhookConfig};

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
