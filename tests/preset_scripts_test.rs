//! Runs the plain-bash test suite for the security preset scripts
//! (tests/shell/presets/run_tests.sh) so that `cargo test` covers them.
//! The suite uses stub scanners and a private temp directory; it never
//! installs anything or touches the network.

use std::path::PathBuf;
use std::process::Command;

#[test]
fn security_preset_shell_scripts_pass_shell_suite() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let runner = root.join("tests/shell/presets/run_tests.sh");
    assert!(runner.exists(), "missing runner: {}", runner.display());

    let output = Command::new("bash")
        .arg(&runner)
        .current_dir(&root)
        .output()
        .expect("failed to launch bash test runner");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        output.status.success(),
        "shell suite failed (status {:?})\n--- stdout ---\n{}\n--- stderr ---\n{}",
        output.status.code(),
        stdout,
        stderr
    );
    assert!(stdout.contains("FAIL 0"), "unexpected summary:\n{}", stdout);
}
