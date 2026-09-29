//! Must-fail tests for confinement: `wfc` compiling a source that imports
//! something outside its root fails, and prints none of it.

use std::os::unix::fs::symlink;
use std::process::Command;

const SECRET: &str = "outside-the-root-marker";

#[test]
fn imports_outside_the_root_fail() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    std::fs::write(dir.path().join("outside.txt"), SECRET).unwrap();
    symlink(dir.path().join("outside.txt"), root.join("link.txt")).unwrap();
    // Inside the root but not something a compile reads.
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join(".git/config"), SECRET).unwrap();
    let outside = dir.path().join("outside.txt");
    let cases = [
        (
            "absolute",
            format!("import {:?} as 'Text", outside.display().to_string()),
        ),
        ("dotdot", "import \"../outside.txt\" as 'Text".to_owned()),
        ("symlink", "import \"../link.txt\" as 'Text".to_owned()),
        ("device", "import \"/dev/zero\" as 'Text".to_owned()),
        ("etc", "import \"/etc/passwd\" as 'Text".to_owned()),
        ("git", "import \"../.git/config\" as 'Text".to_owned()),
    ];
    for (name, body) in cases {
        let source = format!("workflows/{name}.ncl");
        std::fs::write(root.join(&source), format!("{{ x = {body} }}\n")).unwrap();
        let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
            .arg("--root")
            .arg(&root)
            .arg(&source)
            .output()
            .unwrap();
        let (stdout, stderr) = (
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr),
        );
        assert!(!out.status.success(), "{name}: compiled:\n{stdout}");
        assert!(
            !stdout.contains(SECRET) && !stderr.contains(SECRET) && !stdout.contains("root:x:0:0"),
            "{name}: output holds the file:\n{stdout}\n{stderr}"
        );
        assert!(
            stderr.contains("import"),
            "{name}: unexpected error:\n{stderr}"
        );
    }
}

/// A listed path that is a symlink (here `runtime` to `.git`) is refused,
/// and a source in the root grants only itself, not the root.
#[test]
fn symlinked_paths_and_root_sources_grant_nothing_more() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join(".git/config"), SECRET).unwrap();
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    symlink(".git", root.join("runtime")).unwrap();
    std::fs::write(root.join("workflows/x.ncl"), "{ x = 1 }\n").unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
        .arg("--root")
        .arg(&root)
        .arg("workflows/x.ncl")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success() && stderr.contains("runtime is a symlink"),
        "{stderr}"
    );
    std::fs::remove_file(root.join("runtime")).unwrap();
    std::fs::write(
        root.join("top.ncl"),
        "{ x = import \".git/config\" as 'Text }\n",
    )
    .unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
        .arg("--root")
        .arg(&root)
        .arg("top.ncl")
        .output()
        .unwrap();
    let (stdout, stderr) = (
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    assert!(!out.status.success(), "compiled:\n{stdout}");
    assert!(
        !stdout.contains(SECRET) && !stderr.contains(SECRET),
        "{stdout}\n{stderr}"
    );
}

#[test]
fn sources_are_normalized() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
        .arg("--root")
        .arg(root)
        .args(["--check", "./workflows/agent-review.ncl"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let out = Command::new(env!("CARGO_BIN_EXE_wfc"))
        .arg("--root")
        .arg(root)
        .arg("../workflows/agent-review.ncl")
        .output()
        .unwrap();
    assert!(!out.status.success());
}
