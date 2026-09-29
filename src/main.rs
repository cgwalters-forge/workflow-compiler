//! `wfc`, the workflow compiler.

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use workflow_compiler::{Mode, run};

#[derive(Parser)]
#[command(
    name = "wfc",
    about = "Compile nickel workflow sources into sandboxed GitHub Actions lock files"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Write .github/workflows/*.lock.yml from workflows/*.ncl, and
    /// tests/accept/*.expected.yml, locking the metadata of new actions
    /// in actions.lock.json.
    Compile(Repo),
    /// Fail if a lock file or expected output is stale or hand-edited, if
    /// actions.lock.json doesn't match the action.yml files it holds, if
    /// a source in tests/reject/ compiles, or if a workflow in
    /// .github/workflows/ is neither a lock file with the compiled shape
    /// nor listed in .github/uncompiled-workflows.
    Check(Repo),
}

#[derive(Args)]
struct Repo {
    /// The repository's root.
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

fn main_inner() -> Result<bool> {
    let (repo, mode) = match Cli::parse().command {
        Command::Compile(repo) => (repo, Mode::Compile),
        Command::Check(repo) => (repo, Mode::Check),
    };
    let problems = run(&repo.root, mode)?;
    for p in &problems {
        eprintln!("error: {p}");
    }
    Ok(problems.is_empty())
}

fn main() -> ExitCode {
    match main_inner() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::FAILURE
        }
    }
}
