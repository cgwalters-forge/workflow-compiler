//! Tests for `wfc extract-tree`: every blob as committed, nothing else.

use std::path::{Path, PathBuf};
use std::process::Command;

use workflow_compiler::extract::extract_tree;

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// A repository in a new temporary directory with `files` committed,
/// after `extra` changed its work tree and index; and where to extract it.
fn repo(
    files: &[(&str, &str)],
    extra: impl FnOnce(&Path),
) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let r = dir.path().join("r");
    std::fs::create_dir(&r).unwrap();
    git(&r, &["init", "-q"]);
    for (rel, text) in files {
        let path = r.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    git(&r, &["add", "-A"]);
    extra(&r);
    git(
        &r,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "t",
        ],
    );
    let dest = dir.path().join("out");
    (dir, r, dest)
}

#[test]
fn writes_every_blob_as_committed_ignoring_gitattributes() {
    let (_dir, r, dest) = repo(
        &[
            (
                ".gitattributes",
                "hidden.yml export-ignore\nsubst.txt export-subst\nident.txt ident\n",
            ),
            (".github/workflows/hidden.yml", "on: push\n"),
            ("subst.txt", "$Format:%H$\n"),
            ("ident.txt", "$Id$\n"),
        ],
        |_| {},
    );
    assert_eq!(extract_tree(&r, "HEAD", &dest).unwrap(), 4);
    for (rel, want) in [
        (".github/workflows/hidden.yml", "on: push\n"),
        ("subst.txt", "$Format:%H$\n"),
        ("ident.txt", "$Id$\n"),
    ] {
        assert_eq!(
            std::fs::read_to_string(dest.join(rel)).unwrap(),
            want,
            "{rel}"
        );
    }
}

#[test]
fn refuses_symlinks_and_submodules() {
    let (_dir, r, dest) = repo(&[("a.txt", "a")], |r| {
        std::os::unix::fs::symlink(".git", r.join("runtime")).unwrap();
        git(r, &["add", "runtime"]);
    });
    let e = extract_tree(&r, "HEAD", &dest).unwrap_err();
    assert!(format!("{e:#}").contains("runtime is a symlink"), "{e:#}");

    let sub = format!("160000,{},vendor/sub", "1".repeat(40));
    let (_dir, r, dest) = repo(&[("a.txt", "a")], |r| {
        git(r, &["update-index", "--add", "--cacheinfo", &sub]);
    });
    let e = extract_tree(&r, "HEAD", &dest).unwrap_err();
    assert!(
        format!("{e:#}").contains("vendor/sub is a submodule"),
        "{e:#}"
    );
}

#[test]
fn refuses_an_existing_destination() {
    let (_dir, r, dest) = repo(&[("a.txt", "a")], |_| {});
    std::fs::create_dir(&dest).unwrap();
    assert!(extract_tree(&r, "HEAD", &dest).is_err());
}
