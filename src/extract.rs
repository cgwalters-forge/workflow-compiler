//! Writing the tree of a commit into a directory as plain files, for
//! trusted-check to read as data: every blob exactly as committed.
//! `git archive` isn't used, since it applies the tree's own
//! .gitattributes (export-ignore drops files, export-subst and ident
//! rewrite them). Only regular files are written; a symlink or submodule
//! in the tree, or a path with `.` or `..` components, is refused, and
//! every file is written through a directory fd for `dest`.

use std::ffi::OsStr;
use std::io::Write as _;
use std::os::unix::ffi::OsStrExt as _;
use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};
use cap_std_ext::cap_std::ambient_authority;
use cap_std_ext::cap_std::fs::{Dir, OpenOptions, OpenOptionsExt as _};

fn git(git_dir: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(git_dir)
        .args(args)
        .output()
        .context("running git")?;
    if !out.status.success() {
        bail!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

/// Writes the tree of `commit` in the repository at `git_dir` under
/// `dest`, which must not exist. Returns the number of files written.
pub fn extract_tree(git_dir: &Path, commit: &str, dest: &Path) -> Result<usize> {
    let listing = git(git_dir, &["ls-tree", "-r", "-z", "--full-tree", commit])?;
    std::fs::create_dir(dest).with_context(|| format!("creating {}", dest.display()))?;
    let dir = Dir::open_ambient_dir(dest, ambient_authority())
        .with_context(|| format!("opening {}", dest.display()))?;
    let mut count = 0;
    for entry in listing.split(|&b| b == 0).filter(|e| !e.is_empty()) {
        let tab = entry
            .iter()
            .position(|&b| b == b'\t')
            .context("parsing git ls-tree")?;
        let meta = std::str::from_utf8(&entry[..tab]).context("parsing git ls-tree")?;
        let rel = Path::new(OsStr::from_bytes(&entry[tab + 1..]));
        let [mode, kind, oid] = meta.split(' ').collect::<Vec<_>>()[..] else {
            bail!("parsing git ls-tree: {meta}");
        };
        let mode = match (mode, kind) {
            ("100644", "blob") => 0o644,
            ("100755", "blob") => 0o755,
            ("120000", _) => bail!("{} is a symlink; refusing to read the tree", rel.display()),
            ("160000", _) => bail!(
                "{} is a submodule; refusing to read the tree",
                rel.display()
            ),
            _ => bail!(
                "{} is a mode {mode} entry; refusing to read the tree",
                rel.display()
            ),
        };
        // Bytewise: Path::components would skip a `.` inside the path.
        if rel
            .as_os_str()
            .as_bytes()
            .split(|&b| b == b'/')
            .any(|c| matches!(c, b"" | b"." | b".."))
        {
            bail!("refusing the path {:?}", rel);
        }
        if let Some(parent) = rel.parent().filter(|p| !p.as_os_str().is_empty()) {
            dir.create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        let blob = git(git_dir, &["cat-file", "blob", oid])?;
        dir.open_with(
            rel,
            OpenOptions::new().write(true).create_new(true).mode(mode),
        )
        .and_then(|mut f| f.write_all(&blob))
        .with_context(|| format!("writing {}", rel.display()))?;
        count += 1;
    }
    Ok(count)
}
