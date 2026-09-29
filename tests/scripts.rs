//! Tests for scripts in sources: a long inline `run` is refused, and
//! `check` lints the shell scripts a source imports.

use std::path::Path;
use std::process::Command;

fn check(root: &Path) -> String {
    let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
        .args(["check", "--root"])
        .arg(root)
        .output()
        .unwrap();
    assert!(!out.status.success());
    String::from_utf8_lossy(&out.stderr).into_owned()
}

#[test]
fn long_inline_scripts_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    let script: String = (1..=11).map(|i| format!("  echo {i}\n")).collect();
    std::fs::write(
        root.join("workflows/x.ncl"),
        format!("{{\n  short = {{ run = \"echo ok\" }},\n  long = {{ run = m%\"\n{script}  \"%, }},\n}}\n"),
    )
    .unwrap();
    let stderr = check(root);
    assert!(
        stderr.contains("workflows/x.ncl:3: an inline `run` script of 11 lines"),
        "{stderr}"
    );
}

#[test]
fn imported_scripts_are_linted() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("workflows/scripts")).unwrap();
    for (name, text) in [
        ("ok.sh", "echo \"fine\"\n"),
        ("syntax.sh", "if true; then echo\n"),
        ("expr.sh", "echo \"${{ github.event.issue.title }}\"\n"),
        // Not a shell script, so not linted.
        ("data.txt", "if ${{\n"),
    ] {
        std::fs::write(root.join("workflows/scripts").join(name), text).unwrap();
    }
    std::fs::write(
        root.join("workflows/x.ncl"),
        "{ a = import \"scripts/ok.sh\" as 'Text, b = import \"scripts/syntax.sh\" as 'Text, \
         c = import \"scripts/expr.sh\" as 'Text, d = import \"scripts/data.txt\" as 'Text }\n",
    )
    .unwrap();
    let stderr = check(root);
    for want in [
        "workflows/scripts/syntax.sh: bash -n:",
        "workflows/scripts/expr.sh:1: a `${{` expression",
    ] {
        assert!(stderr.contains(want), "{want}: {stderr}");
    }
    for unwanted in ["ok.sh:", "data.txt:"] {
        assert!(!stderr.contains(unwanted), "{unwanted}: {stderr}");
    }
}
