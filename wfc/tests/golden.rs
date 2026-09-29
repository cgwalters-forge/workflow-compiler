//! Golden tests: the embedded nickel produces, byte for byte, the lock
//! files `compile.mjs` wrote with the nickel CLI, for every source in
//! workflows/, and the expected output of every source in tests/accept/,
//! and rejects what tests/reject/ must reject.

use std::path::{Path, PathBuf};

use workflow_compiler::{
    SOURCES_DIR, compile_lock, confine_reads, export_yaml, first_difference, lock_path,
};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("wfc/ is inside the repository")
        .to_path_buf()
}

/// The `.ncl` files in `dir`, relative to the repository root, sorted.
fn sources(dir: &str) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(repo_root().join(dir))
        .unwrap_or_else(|e| panic!("reading {dir}: {e}"))
        .map(|e| {
            e.expect("directory entry")
                .file_name()
                .into_string()
                .expect("UTF-8 name")
        })
        .filter(|n| n.ends_with(".ncl"))
        .map(|n| format!("{dir}/{n}"))
        .collect();
    v.sort();
    v
}

#[test]
fn lock_files_match_the_nickel_cli() {
    let root = repo_root();
    // As wfc compiles: each test runs on a thread of its own, which this
    // confines, and nothing else.
    confine_reads(&root, &[]).unwrap();
    let sources = sources(SOURCES_DIR);
    assert!(!sources.is_empty(), "no sources in {SOURCES_DIR}");
    let mut problems = Vec::new();
    for source in sources {
        let path = lock_path(&source).unwrap();
        let committed = std::fs::read_to_string(root.join(&path))
            .unwrap_or_else(|e| panic!("reading {path}: {e}"));
        match compile_lock(&root, &source) {
            Err(e) => problems.push(format!("{e:#}")),
            Ok(lock) => {
                if let Some((line, want, got)) = first_difference(&committed, &lock) {
                    problems.push(format!(
                        "{path} differs from what wfc compiles from {source}, from line {line}:\n  committed: {want}\n  compiled:  {got}"
                    ));
                }
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn accept_tests_match_the_nickel_cli() {
    let root = repo_root();
    confine_reads(&root, &[]).unwrap();
    let mut problems = Vec::new();
    for source in sources("tests/accept") {
        let expected_path = source.replace(".ncl", ".expected.yml");
        let expected = std::fs::read_to_string(root.join(&expected_path))
            .unwrap_or_else(|e| panic!("reading {expected_path}: {e}"));
        match export_yaml(&root, &source) {
            Err(e) => problems.push(format!("{e:#}")),
            Ok(out) => {
                if let Some((line, want, got)) = first_difference(&expected, &out) {
                    problems.push(format!(
                        "{expected_path} differs from what wfc compiles from {source}, from line {line}:\n  expected: {want}\n  compiled: {got}"
                    ));
                }
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn reject_tests_fail_with_their_message() {
    let root = repo_root();
    confine_reads(&root, &[]).unwrap();
    let mut problems = Vec::new();
    for source in sources("tests/reject") {
        let text = std::fs::read_to_string(root.join(&source)).unwrap();
        let Some(expect) = text.lines().find_map(|l| l.strip_prefix("# expect: ")) else {
            problems.push(format!("{source} has no # expect: line"));
            continue;
        };
        match export_yaml(&root, &source) {
            Ok(_) => problems.push(format!(
                "{source} compiled, but should fail with {expect:?}"
            )),
            Err(e) => {
                let msg = format!("{e:#}");
                if !msg.contains(expect) {
                    problems.push(format!("{source} failed without {expect:?}:\n{msg}"));
                }
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}
