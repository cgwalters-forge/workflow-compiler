//! `wfc`, the workflow compiler.

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use workflow_compiler::{Mode, extract, run};

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
    /// a source in tests/reject/ compiles, if a workflow in
    /// .github/workflows/ is neither a lock file with the compiled shape
    /// nor listed in .github/uncompiled-workflows, or if a shell script a
    /// source imports fails `bash -n` or shellcheck.
    Check(Repo),
    /// Write the tree of COMMIT into DEST, which must not exist, as plain
    /// files: every blob exactly as committed, ignoring .gitattributes.
    /// Symlinks, submodules and `.` or `..` paths are refused.
    ExtractTree {
        /// A directory in the repository.
        git_dir: PathBuf,
        commit: String,
        dest: PathBuf,
    },
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
        Command::ExtractTree {
            git_dir,
            commit,
            dest,
        } => {
            let n = extract::extract_tree(&git_dir, &commit, &dest)?;
            eprintln!("extracted {n} files of {commit}");
            return Ok(true);
        }
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
