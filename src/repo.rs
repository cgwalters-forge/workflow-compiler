//! The repository wfc compiles, by the path of its root.
//!
//! wfc reads and writes files relative to the root with plain `std::fs`,
//! and nickel resolves a source's imports by itself. Confining what a
//! compile can reach (no network, a read-only checkout) is up to what
//! runs wfc.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// A repository, by its root.
pub struct Repo {
    root: PathBuf,
}

impl Repo {
    /// The repository whose root is `path`.
    pub fn open(path: &Path) -> Result<Self> {
        let root = path
            .canonicalize()
            .with_context(|| format!("resolving {}", path.display()))?;
        Ok(Self { root })
    }

    /// `rel`, relative to the root, as a path.
    pub fn path(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    /// The text of `rel`, or `None` if it doesn't exist.
    pub fn read(&self, rel: &str) -> Result<Option<String>> {
        match std::fs::read_to_string(self.path(rel)) {
            Ok(text) => Ok(Some(text)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e).with_context(|| format!("reading {rel}")),
        }
    }

    /// Whether `rel` is a regular file, not following symlinks; false if
    /// it doesn't exist.
    pub fn is_file(&self, rel: &str) -> Result<bool> {
        match std::fs::symlink_metadata(self.path(rel)) {
            Ok(meta) => Ok(meta.is_file()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e).with_context(|| format!("reading {rel}")),
        }
    }

    /// The names in the directory `rel` that end in `suffix`, as paths
    /// relative to the root, sorted; none if it doesn't exist.
    pub fn list(&self, rel: &str, suffix: &str) -> Result<Vec<String>> {
        let entries = match std::fs::read_dir(self.path(rel)) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).with_context(|| format!("reading {rel}")),
        };
        let mut files = Vec::new();
        for entry in entries {
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

    /// Replaces `rel` with `text`.
    pub fn write(&self, rel: &str, text: &str) -> Result<()> {
        std::fs::write(self.path(rel), text).with_context(|| format!("writing {rel}"))
    }
}
