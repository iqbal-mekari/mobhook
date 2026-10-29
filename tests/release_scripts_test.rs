//! Runs the plain-bash release-script test suite (tests/shell/release/run.sh).
//! Covers .github/scripts/*.sh and the structure of .github/workflows/*.yml.
//! No network access and no real GitHub calls are made.

use std::path::PathBuf;
use std::process::Command;

#[test]
fn release_scripts_and_workflows_pass_shell_suite() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let runner = root.join("tests/shell/release/run.sh");
    assert!(runner.exists(), "missing runner: {}", runner.display());

    let output = Command::new("bash")
        .arg(&runner)
        .current_dir(&root)
        .output()
        .expect("failed to spawn bash");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "release shell suite failed\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}"
    );
    assert!(
        stdout.contains("RELEASE TESTS: ALL PASSED"),
        "runner did not report success\n{stdout}"
    );
}
