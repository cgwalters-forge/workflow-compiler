//! `wfc`: the Rust front end of the workflow compiler, embedding nickel.
//!
//!   wfc [--root DIR] SOURCE...          print each SOURCE's lock file
//!   wfc [--root DIR] --check SOURCE...  fail if a lock file differs
//!
//! SOURCE is relative to the repository root (default: the current
//! directory), such as `workflows/sandbox-test.ncl`. Before compiling
//! anything, wfc confines its reads to the root with Landlock
//! (`--no-confine` skips that, for kernels without it).

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use workflow_compiler::{
    compile_lock, confine_reads, first_difference, lock_path, normalize_source,
};

const USAGE: &str = "usage: wfc [--root DIR] [--check] [--no-confine] SOURCE...";

fn run() -> Result<bool> {
    let mut root = PathBuf::from(".");
    let mut check = false;
    let mut confine = true;
    let mut sources = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().context("--root needs a directory")?.into(),
            "--check" => check = true,
            "--no-confine" => confine = false,
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(true);
            }
            a if a.starts_with('-') => bail!("unknown option {a}\n{USAGE}"),
            _ => sources.push(normalize_source(&arg)?),
        }
    }
    if sources.is_empty() {
        bail!("{USAGE}");
    }
    let root = root
        .canonicalize()
        .with_context(|| format!("resolving {}", root.display()))?;
    if confine {
        // Each source may be read itself, wherever it is (a source outside
        // READABLE grants only that file, never its directory).
        let files: Vec<PathBuf> = sources.iter().map(PathBuf::from).collect();
        confine_reads(&root, &files)?;
    }
    let mut ok = true;
    for source in &sources {
        let lock = match compile_lock(&root, source) {
            Ok(lock) => lock,
            Err(e) => {
                eprintln!("error: {e:#}");
                ok = false;
                continue;
            }
        };
        if !check {
            print!("{lock}");
            continue;
        }
        let path = lock_path(source)?;
        let committed = match std::fs::read_to_string(root.join(&path)) {
            Ok(text) => text,
            Err(e) => {
                eprintln!("error: reading {path}: {e}");
                ok = false;
                continue;
            }
        };
        match first_difference(&committed, &lock) {
            None => eprintln!("ok: {path}"),
            Some((line, want, got)) => {
                eprintln!(
                    "error: {path} does not match {source}, from line {line}:\n  committed: {want}\n  compiled:  {got}"
                );
                ok = false;
            }
        }
    }
    Ok(ok)
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::FAILURE
        }
    }
}
