mod common;
use mobhook::core::config::{HookEntry, HookMode, MobhookConfig};

#[test]
fn test_parse_minimal_config() {
    let toml = r#"
mode = "blocking"
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    assert_eq!(config.mode, HookMode::Blocking);
    assert!(config.hooks.is_empty());
    assert!(config.remote.is_none());
}

#[test]
fn test_parse_warning_mode() {
    let toml = r#"
mode = "warning"
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    assert_eq!(config.mode, HookMode::Warning);
}

#[test]
fn test_parse_remote_config() {
    let toml = r#"
mode = "blocking"

[remote]
url = "https://github.com/org/rules.git"
ref = "develop"
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let remote = config.remote.unwrap();
    assert_eq!(remote.url, "https://github.com/org/rules.git");
    assert_eq!(remote.ref_, "develop");
}

#[test]
fn test_parse_remote_default_ref() {
    let toml = r#"
mode = "blocking"

[remote]
url = "https://github.com/org/rules.git"
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let remote = config.remote.unwrap();
    assert_eq!(remote.ref_, "main");
}

#[test]
fn test_parse_hooks_with_short_form() {
    let toml = r#"
mode = "warning"

[hooks.pre-push]
order = ["security", "flutter-test"]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let hook = config.hooks.get("pre-push").unwrap();
    assert_eq!(hook.order.len(), 2);
    assert_eq!(hook.order[0].name, "security");
    assert_eq!(hook.order[0].mode, None);
    assert_eq!(hook.order[1].name, "flutter-test");
}

#[test]
fn test_parse_hooks_with_long_form() {
    let toml = r#"
mode = "warning"

[hooks.pre-push]
order = [
    { name = "security", mode = "blocking" },
    "flutter-test",
]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let hook = config.hooks.get("pre-push").unwrap();
    assert_eq!(hook.order[0].name, "security");
    assert_eq!(hook.order[0].mode, Some(HookMode::Blocking));
    assert_eq!(hook.order[1].name, "flutter-test");
    assert_eq!(hook.order[1].mode, None);
}

#[test]
fn test_parse_empty_order() {
    let toml = r#"
mode = "blocking"

[hooks.pre-commit]
order = []
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let hook = config.hooks.get("pre-commit").unwrap();
    assert!(hook.order.is_empty());
}

#[test]
fn test_installed_presets() {
    let toml = r#"
mode = "warning"

[hooks.pre-push]
order = ["security", "flutter-test"]

[hooks.pre-commit]
order = ["security"]
"#;
    let config = MobhookConfig::parse(toml).unwrap();
    let installed = config.installed_presets();
    assert!(installed.contains("security"));
    assert!(installed.contains("flutter-test"));
    assert_eq!(installed.len(), 2);
}

#[test]
fn test_invalid_toml_returns_error() {
    let toml = "this is not valid toml [[[";
    let result = MobhookConfig::parse(toml);
    assert!(result.is_err());
}

#[test]
fn test_default_toml_is_valid() {
    let default = MobhookConfig::default_toml();
    let result = MobhookConfig::parse(&default);
    assert!(
        result.is_ok(),
        "Default template failed to parse: {:?}",
        result.err()
    );
}
