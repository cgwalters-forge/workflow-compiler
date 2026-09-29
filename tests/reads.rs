//! Must-fail tests for what wfc reads: compiling or checking a source
//! that imports something outside the readable part of the repository, or
//! through a symlink, fails, and prints none of it.

use std::os::unix::fs::symlink;
use std::path::Path;
use std::process::{Command, Output};

const SECRET: &str = "outside-the-root-marker";

fn wfc(root: &Path, subcommand: &str) -> Output {
    Command::new(env!("CARGO_BIN_EXE_wfc"))
        .args([subcommand, "--root"])
        .arg(root)
        .output()
        .unwrap()
}

/// Runs `check` and `compile` on `root`, which must fail without printing
/// [`SECRET`] or `/etc/passwd`, and with `expect` in the error.
fn assert_refused(root: &Path, name: &str, expect: &str) {
    for subcommand in ["check", "compile"] {
        let out = wfc(root, subcommand);
        let (stdout, stderr) = (
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr),
        );
        assert!(
            !out.status.success(),
            "{name} {subcommand}: compiled:\n{stderr}"
        );
        assert!(
            !stdout.contains(SECRET) && !stderr.contains(SECRET) && !stderr.contains("root:x:0:0"),
            "{name} {subcommand}: output holds the file:\n{stdout}\n{stderr}"
        );
        assert!(
            stderr.contains(expect),
            "{name} {subcommand}: expected {expect:?}:\n{stderr}"
        );
    }
    assert!(
        !root.join(".github/workflows/x.lock.yml").exists(),
        "{name}: wrote a lock file"
    );
}

#[test]
fn imports_outside_the_readable_tree_fail() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    std::fs::create_dir_all(root.join("lib")).unwrap();
    std::fs::create_dir_all(root.join(".github/workflows")).unwrap();
    std::fs::write(dir.path().join("outside.txt"), SECRET).unwrap();
    symlink(dir.path().join("outside.txt"), root.join("link.txt")).unwrap();
    // A symlink out of the tree inside a readable directory, as a pull
    // request could add, and one to a readable file.
    symlink("../../outside.txt", root.join("workflows/link.txt")).unwrap();
    std::fs::write(root.join("lib/ok.txt"), "fine").unwrap();
    symlink("../lib/ok.txt", root.join("workflows/inner.txt")).unwrap();
    // Inside the root but not something a compile reads.
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join(".git/config"), SECRET).unwrap();
    let outside = dir.path().join("outside.txt");
    let cases = [
        (
            "absolute",
            format!("import {:?} as 'Text", outside.display().to_string()),
            "an absolute path",
        ),
        (
            "dotdot",
            "import \"../../outside.txt\" as 'Text".to_owned(),
            "outside the repository",
        ),
        (
            "symlink",
            "import \"../link.txt\" as 'Text".to_owned(),
            "outside what a compile reads",
        ),
        (
            "inner-symlink",
            "import \"link.txt\" as 'Text".to_owned(),
            "not a regular file",
        ),
        (
            "symlink-in-tree",
            "import \"inner.txt\" as 'Text".to_owned(),
            "not a regular file",
        ),
        (
            "device",
            "import \"/dev/zero\" as 'Text".to_owned(),
            "an absolute path",
        ),
        (
            "etc",
            "import \"/etc/passwd\" as 'Text".to_owned(),
            "an absolute path",
        ),
        (
            "git",
            "import \"../.git/config\" as 'Text".to_owned(),
            "outside what a compile reads",
        ),
        (
            "missing",
            "import \"../lib/missing.ncl\"".to_owned(),
            "does not exist",
        ),
        (
            "nested",
            "import \"../lib/nested.ncl\"".to_owned(),
            "outside the repository",
        ),
    ];
    std::fs::write(
        root.join("lib/nested.ncl"),
        "import \"../../outside.txt\" as 'Text\n",
    )
    .unwrap();
    for (name, body, expect) in cases {
        std::fs::write(root.join("workflows/x.ncl"), format!("{{ x = {body} }}\n")).unwrap();
        assert_refused(&root, name, expect);
    }
}

/// A readable directory that is a symlink (here `runtime` to `.git`), or
/// is reached through one (`.github` to elsewhere in the root), is
/// refused rather than read through.
#[test]
fn symlinked_directories_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join(".git/config"), SECRET).unwrap();
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    symlink(".git", root.join("runtime")).unwrap();
    std::fs::write(
        root.join("workflows/x.ncl"),
        "{ x = import \"../runtime/config\" as 'Text }\n",
    )
    .unwrap();
    assert_refused(root, "runtime", "a symlink is refused");

    std::fs::write(root.join("workflows/x.ncl"), "{ x = 1 }\n").unwrap();
    std::fs::create_dir_all(root.join("elsewhere/workflows")).unwrap();
    std::fs::write(root.join("elsewhere/workflows/x.lock.yml"), SECRET).unwrap();
    symlink("elsewhere", root.join(".github")).unwrap();
    let out = wfc(root, "check");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success() && stderr.contains("a symlink is refused"),
        "{stderr}"
    );
    assert!(!stderr.contains(SECRET), "{stderr}");
}

/// A FIFO where a source is expected is refused, not opened (which would
/// block).
#[test]
fn special_files_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    let fifo = root.join("workflows/fifo.txt");
    let status = Command::new("mkfifo").arg(&fifo).status().unwrap();
    assert!(status.success());
    std::fs::write(
        root.join("workflows/x.ncl"),
        "{ x = import \"fifo.txt\" as 'Text }\n",
    )
    .unwrap();
    assert_refused(root, "fifo", "not a regular file");
}
