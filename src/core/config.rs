use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;

/// Hook execution mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HookMode {
    Blocking,
    Warning,
}

/// Top-level mobhook.yaml configuration.
#[derive(Debug, Clone)]
pub struct MobhookConfig {
    pub mode: HookMode,
    pub remote: Option<RemoteConfig>,
    pub hooks: BTreeMap<String, HookConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RemoteConfig {
    pub url: String,
    #[serde(rename = "ref", default = "default_ref")]
    pub ref_: String,
}

fn default_ref() -> String {
    "main".to_string()
}

#[derive(Debug, Clone)]
pub struct HookConfig {
    pub order: Vec<HookEntry>,
}

/// A single entry in a hook's order list.
#[derive(Debug, Clone, PartialEq)]
pub struct HookEntry {
    pub name: String,
    pub mode: Option<HookMode>,
}

impl HookEntry {
    pub fn effective_mode(&self, global: HookMode) -> HookMode {
        self.mode.unwrap_or(global)
    }
}

// --- Serde deserialization helpers ---

#[derive(Deserialize)]
#[serde(untagged)]
enum RawOrderEntry {
    Short(String),
    Long { name: String, mode: Option<String> },
}

#[derive(Deserialize)]
struct RawHookConfig {
    order: Vec<RawOrderEntry>,
}

#[derive(Deserialize)]
struct RawConfig {
    #[serde(default = "default_mode")]
    mode: String,
    remote: Option<RemoteConfig>,
    #[serde(default)]
    hooks: BTreeMap<String, RawHookConfig>,
}

fn default_mode() -> String {
    "blocking".to_string()
}

fn parse_hook_mode(s: &str) -> Option<HookMode> {
    match s.trim().to_lowercase().as_str() {
        "warning" | "warn" => Some(HookMode::Warning),
        "blocking" | "block" => Some(HookMode::Blocking),
        _ => None,
    }
}

impl MobhookConfig {
    /// Parse from a YAML string.
    pub fn parse(yaml_str: &str) -> Result<Self> {
        let raw: RawConfig =
            serde_yaml::from_str(yaml_str).context("Failed to parse mobhook.yaml")?;

        let mode = parse_hook_mode(&raw.mode).unwrap_or(HookMode::Blocking);

        let mut hooks = BTreeMap::new();
        for (hook_type, raw_hook) in raw.hooks {
            let mut order = Vec::new();
            for entry in raw_hook.order {
                match entry {
                    RawOrderEntry::Short(name) => {
                        order.push(HookEntry { name, mode: None });
                    }
                    RawOrderEntry::Long { name, mode } => {
                        let entry_mode = mode.as_deref().and_then(parse_hook_mode);
                        order.push(HookEntry {
                            name,
                            mode: entry_mode,
                        });
                    }
                }
            }
            hooks.insert(hook_type, HookConfig { order });
        }

        Ok(MobhookConfig {
            mode,
            remote: raw.remote,
            hooks,
        })
    }

    /// Load from a file path.
    pub fn load(path: &Path) -> Result<Self> {
        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read {}", path.display()))?;
        Self::parse(&content)
    }

    /// All preset names referenced in any hook's order list.
    pub fn installed_presets(&self) -> HashSet<String> {
        self.hooks
            .values()
            .flat_map(|h| h.order.iter().map(|e| e.name.clone()))
            .collect()
    }

    /// Generate the default mobhook.yaml template.
    pub fn default_yaml() -> String {
        r#"# mobhook.yaml - Git hooks configuration
# Docs: https://github.com/iqbal-mekari/mobhook
#
# Hooks directory: .mobhook/ (committed to git, shared with your team)
# Run `mobhook update` to regenerate hooks after editing this file.

# Global hook execution mode: "blocking" (default) or "warning"
# - blocking: exit 1 and abort the git operation on any hook failure
# - warning: print a warning but always exit 0 (non-blocking)
# Per-entry mode can override this globally (see hooks section below).
mode: warning

# Optional: sync preset rules from a remote git repo.
# remote:
#   url: https://github.com/your-org/mobhook-rules.git
#   ref: main

# Hook definitions - each key is a git hook type.
# Short form (string, inherits global mode) or long form (mapping with per-entry mode).
hooks:
  pre-commit:
    order: []
    # Example long form:
    # order:
    #   - name: security
    #     mode: warning
    #   - custom-hook-script

  commit-msg:
    order: []

  pre-push:
    order:
      - name: security
        mode: blocking
"#
        .to_string()
    }
}
