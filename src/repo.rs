//! The repository, as a directory fd.
//!
//! wfc opens the repository's root once, as a cap-std [`Dir`], and reads
//! and writes only relative to it: an absolute path or a `..` can't leave
//! it. Reads are further limited to [`READABLE`] and follow no symlinks,
//! so a source from a pull request can't reach `.git`, the rest of the
//! checkout, or a file a symlink in it points to. nickel resolves imports
//! against the filesystem by itself, so it is never given a path to read:
//! [`crate::nickel`] reads a source's imports through this and evaluates
//! them from memory.

use std::io::Read;
use std::path::{Component, Path};

use anyhow::{Context, Result, bail};
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std_ext::cap_std::ambient_authority;
use cap_std_ext::cap_std::fs::{Dir, OpenOptions};
use cap_std_ext::dirext::CapStdExtDirExt;

use crate::{LOCKS_DIR, SOURCES_DIR, actions};

/// What a compile may read, relative to the repository root: the
/// compiler's library and runtime, which the lock files embed, the
/// sources, the tests, the actions' metadata, and the lock files `check`
/// compares with. Not `.git`, nor anything else in the checkout.
pub const READABLE: &[&str] = &[
    "lib",
    "runtime",
    SOURCES_DIR,
    "tests",
    actions::LOCK_FILE,
    LOCKS_DIR,
];

/// The largest file wfc reads. Everything it reads is a source, a script
/// or a lock file, so a larger one is a mistake or an attack.
const MAX_FILE_SIZE: u64 = 16 << 20;

/// The components of `rel`, a relative path made only of names; `..`,
/// `.`, an absolute path or an empty one is refused.
pub fn components(rel: &str) -> Result<Vec<&str>> {
    let mut parts = Vec::new();
    for c in Path::new(rel).components() {
        match c {
            Component::Normal(name) => parts.push(
                name.to_str()
                    .with_context(|| format!("{rel} is not UTF-8"))?,
            ),
            _ => bail!("{rel} is not a plain relative path"),
        }
    }
    if parts.is_empty() {
        bail!("empty path");
    }
    Ok(parts)
}

/// Whether `rel` is one of [`READABLE`] or under one.
pub fn is_readable(rel: &str) -> bool {
    READABLE.iter().any(|r| {
        rel.strip_prefix(r)
            .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
    })
}

/// A repository opened as a directory.
pub struct Repo {
    dir: Dir,
}

impl Repo {
    /// Opens the repository at `path`: the only path wfc resolves.
    pub fn open(path: &Path) -> Result<Self> {
        let dir = Dir::open_ambient_dir(path, ambient_authority())
            .with_context(|| format!("opening {}", path.display()))?;
        Ok(Self { dir })
    }

    /// Opens the directory `parts` without following symlinks, or `None`
    /// if it doesn't exist.
    fn open_dir(&self, rel: &str, parts: &[&str]) -> Result<Option<Dir>> {
        let mut dir = self.dir.try_clone().context("duplicating the root fd")?;
        for (i, name) in parts.iter().enumerate() {
            dir = match dir.open_dir_nofollow(name) {
                Ok(d) => d,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(e) => {
                    let at = parts[..=i].join("/");
                    return Err(e)
                        .with_context(|| format!("opening {at} for {rel} (a symlink is refused)"));
                }
            };
        }
        Ok(Some(dir))
    }

    /// The text of `rel`, or `None` if it doesn't exist. `rel` must be
    /// under [`READABLE`], and neither it nor a directory on the way may
    /// be a symlink; only a regular file of at most [`MAX_FILE_SIZE`] is
    /// read.
    pub fn read(&self, rel: &str) -> Result<Option<String>> {
        let parts = components(rel)?;
        if !is_readable(rel) {
            bail!("{rel} is outside what wfc reads ({})", READABLE.join(", "));
        }
        let (name, parents) = parts.split_last().expect("components is never empty");
        let Some(dir) = self.open_dir(rel, parents)? else {
            return Ok(None);
        };
        // Look before opening, so a FIFO isn't opened (which would block);
        // the open below doesn't follow a symlink either way.
        match dir.symlink_metadata_optional(name) {
            Ok(None) => return Ok(None),
            Ok(Some(meta)) if meta.is_file() => {}
            Ok(Some(_)) => bail!("{rel} is not a regular file"),
            Err(e) => return Err(e).with_context(|| format!("reading {rel}")),
        }
        let mut options = OpenOptions::new();
        options.read(true).follow(FollowSymlinks::No);
        let file = dir
            .open_with(name, &options)
            .with_context(|| format!("opening {rel}"))?;
        let meta = file.metadata().with_context(|| format!("reading {rel}"))?;
        if !meta.is_file() {
            bail!("{rel} is not a regular file");
        }
        if meta.len() > MAX_FILE_SIZE {
            bail!("{rel} is larger than {MAX_FILE_SIZE} bytes");
        }
        let mut text = String::new();
        file.take(MAX_FILE_SIZE + 1)
            .read_to_string(&mut text)
            .with_context(|| format!("reading {rel}"))?;
        // It may have grown since the check above.
        if text.len() as u64 > MAX_FILE_SIZE {
            bail!("{rel} is larger than {MAX_FILE_SIZE} bytes");
        }
        Ok(Some(text))
    }

    /// The names in the directory `rel` that end in `suffix`, as paths
    /// relative to the root, sorted; none if it doesn't exist.
    pub fn list(&self, rel: &str, suffix: &str) -> Result<Vec<String>> {
        let parts = components(rel)?;
        if !is_readable(rel) {
            bail!("{rel} is outside what wfc reads ({})", READABLE.join(", "));
        }
        let Some(dir) = self.open_dir(rel, &parts)? else {
            return Ok(Vec::new());
        };
        let mut files = Vec::new();
        for entry in dir.entries().with_context(|| format!("reading {rel}"))? {
            let name = entry.with_context(|| format!("reading {rel}"))?.file_name();
            let name = name
                .to_str()
                .with_context(|| format!("a name in {rel} is not UTF-8"))?;
            if name.ends_with(suffix) {
                files.push(format!("{rel}/{name}"));
            }
        }
        files.sort();
        Ok(files)
    }

    /// Replaces `rel` with `text`, atomically.
    pub fn write(&self, rel: &str, text: &str) -> Result<()> {
        components(rel)?;
        self.dir
            .atomic_write(rel, text)
            .with_context(|| format!("writing {rel}"))
    }
}
