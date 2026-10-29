use anyhow::Result;
use regex::Regex;
use std::sync::OnceLock;

/// Client-side git hook names mobhook will generate scripts for (see githooks(5)).
/// Keys in mobhook.yaml `hooks:` become file names in .mobhook/, so anything
/// outside this list is rejected.
pub const SUPPORTED_HOOK_TYPES: &[&str] = &[
    "applypatch-msg",
    "pre-applypatch",
    "post-applypatch",
    "pre-commit",
    "pre-merge-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-rebase",
    "post-checkout",
    "post-merge",
    "pre-push",
    "pre-auto-gc",
    "post-rewrite",
    "sendemail-validate",
    "fsmonitor-watchman",
    "post-index-change",
    "reference-transaction",
];

pub fn is_supported_hook_type(hook_type: &str) -> bool {
    SUPPORTED_HOOK_TYPES.contains(&hook_type)
}

/// Hook/step names: lowercase alphanumerics and inner hyphens (e.g. lint-check).
/// Shared by `mobhook create` and config parsing so both accept the same names.
pub fn is_valid_hook_name(name: &str) -> bool {
    static VALID_NAME: OnceLock<Regex> = OnceLock::new();
    VALID_NAME
        .get_or_init(|| Regex::new(r"^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$").unwrap())
        .is_match(name)
}

/// Last line of defense before a name is joined onto a directory: it must be a
/// single, non-empty path component that cannot climb out of that directory.
pub fn ensure_path_component(what: &str, name: &str) -> Result<()> {
    if name.is_empty()
        || name == "."
        || name.contains("..")
        || name.contains('/')
        || name.contains('\\')
        || name.contains('\0')
    {
        anyhow::bail!("Refusing to use {what} {name:?}: not a plain file name");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_names_follow_create_rule() {
        for ok in ["security", "flutter-test", "a", "lint2", "9-x-9"] {
            assert!(is_valid_hook_name(ok), "{ok} should be valid");
        }
        for bad in [
            "",
            "Security",
            "-lead",
            "trail-",
            "has space",
            "x$(touch pwned)",
            "x`id`",
            "x'y",
            "x\"y",
            "line\nbreak",
            "trailing\n",
            "../x",
            "a/b",
            "under_score",
        ] {
            assert!(!is_valid_hook_name(bad), "{bad:?} should be rejected");
        }
    }

    #[test]
    fn hook_types_are_allowlisted() {
        assert!(is_supported_hook_type("pre-commit"));
        assert!(is_supported_hook_type("pre-push"));
        assert!(is_supported_hook_type("commit-msg"));
        assert!(!is_supported_hook_type("post-receive")); // server-side
        assert!(!is_supported_hook_type("/tmp/evil"));
        assert!(!is_supported_hook_type("../x"));
        assert!(!is_supported_hook_type("Pre-Commit"));
    }

    #[test]
    fn path_component_rejects_traversal() {
        for bad in [
            "", ".", "..", "../x", "a/..", "/abs", "a/b", "a\\b", "nul\0",
        ] {
            assert!(ensure_path_component("test", bad).is_err(), "{bad:?}");
        }
        for ok in ["pre-push", "security", "script.sh", "gitleaks.toml"] {
            assert!(ensure_path_component("test", ok).is_ok(), "{ok:?}");
        }
    }
}
