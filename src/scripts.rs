//! Linting the shell scripts sources import as text: `run = import
//! "scripts/x.sh" as 'Text` is how a script longer than a few lines gets
//! into a step (see [`crate::nickel::MAX_INLINE_SCRIPT_LINES`]), and it
//! is checked here as a script, which an inline string never was.
//!
//! Each `.sh` file is parsed with `bash -n`, checked with shellcheck
//! when it is installed, and must hold no `${{`: Actions expands
//! expressions in a step's `run:` before the shell sees it, so a value
//! there becomes code; it belongs in the step's `env:`.

use std::io::Write as _;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};

use crate::repo::Repo;

/// What a linted script's name ends in.
pub const SCRIPT_SUFFIX: &str = ".sh";

/// Runs `program` with `args` on `text` as its standard input. Returns
/// `None` if it succeeded, its output if it failed, and an error if it
/// couldn't be run.
fn run_on(program: &str, args: &[&str], text: &str) -> std::io::Result<Option<String>> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    // Written from a thread, so a large script can't deadlock against a
    // full output pipe.
    let mut stdin = child.stdin.take().expect("stdin is piped");
    let text = text.to_owned();
    let writer = std::thread::spawn(move || stdin.write_all(text.as_bytes()));
    let out = child.wait_with_output()?;
    // A linter that stops reading early closes the pipe; its status says
    // what happened.
    let _ = writer.join();
    if out.status.success() {
        return Ok(None);
    }
    let mut report = String::from_utf8_lossy(&out.stdout).into_owned();
    report.push_str(&String::from_utf8_lossy(&out.stderr));
    Ok(Some(report.trim_end().to_owned()))
}

/// Whether shellcheck can be run here.
fn have_shellcheck() -> bool {
    Command::new("shellcheck")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Lints each of `scripts` (paths relative to the root) that ends in
/// [`SCRIPT_SUFFIX`]. Returns the problems found.
pub fn check(root: &Repo, scripts: &[String]) -> Result<Vec<String>> {
    let scripts: Vec<&String> = scripts
        .iter()
        .filter(|s| s.ends_with(SCRIPT_SUFFIX))
        .collect();
    let mut problems = Vec::new();
    if scripts.is_empty() {
        return Ok(problems);
    }
    let shellcheck = have_shellcheck();
    if !shellcheck {
        eprintln!(
            "shellcheck isn't installed; checking {} scripts with bash -n only",
            scripts.len()
        );
    }
    for rel in scripts {
        let text = root
            .read(rel)?
            .with_context(|| format!("{rel} disappeared"))?;
        if let Some(line) = text.lines().position(|l| l.contains("${{")) {
            problems.push(format!(
                "{rel}:{}: a `${{{{` expression in a script is expanded into its code; pass the value in the step's `env:`",
                line + 1
            ));
        }
        if let Some(report) = run_on("bash", &["-n"], &text).context("running bash -n")? {
            problems.push(format!("{rel}: bash -n: {report}"));
        }
        if shellcheck
            && let Some(report) = run_on("shellcheck", &["--norc", "--shell=bash", "-"], &text)
                .context("running shellcheck")?
        {
            problems.push(format!("{rel}: shellcheck:\n{report}"));
        }
    }
    Ok(problems)
}
