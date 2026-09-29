//! This repository's own check: every lock file matches its source, every
//! reject test fails with its message, and actions.lock.json matches the
//! action.yml files it holds.

use std::process::Command;

#[test]
fn the_repository_checks() {
    let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
        .args(["check", "--root", env!("CARGO_MANIFEST_DIR")])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
