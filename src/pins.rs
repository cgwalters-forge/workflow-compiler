//! The rule that keeps the sources' action pins updatable: every
//! `"owner/repo[/path]@<sha>"` in `lib/` and the workflow sources is
//! followed, on its line, by a `# <tag or branch>` comment, which is what
//! renovate.json's regex managers read to find a newer commit (see
//! "Updating pinned versions" in the README).

use std::sync::LazyLock;

use anyhow::Result;
use regex::Regex;

use crate::SOURCES_DIR;
use crate::repo::Repo;

/// Where pins are checked: the compiler's library and the sources.
const PINNED_DIRS: &[&str] = &["lib", SOURCES_DIR];

static PIN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#""([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40})""#).expect("valid regex")
});
static REF_COMMENT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"#\s*[A-Za-z0-9]").expect("valid regex"));

/// The pins in `text` (the file `rel`) without a `# <ref>` comment after
/// them on their line.
pub fn unannotated(rel: &str, text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for (n, line) in text.lines().enumerate() {
        for m in PIN_RE.captures_iter(line) {
            let whole = m.get(0).expect("a match");
            if !REF_COMMENT_RE.is_match(&line[whole.end()..]) {
                found.push(format!(
                    "{rel}:{}: {} has no `# <tag or branch>` comment after it on its line, which Renovate needs to update it",
                    n + 1,
                    &m[1]
                ));
            }
        }
    }
    found
}

/// Checks every nickel file in [`PINNED_DIRS`]. Returns the problems.
pub fn check(root: &Repo) -> Result<Vec<String>> {
    let mut problems = Vec::new();
    for dir in PINNED_DIRS {
        for rel in root.list(dir, ".ncl")? {
            let text = root.read(&rel)?.unwrap_or_default();
            problems.extend(unannotated(&rel, &text));
        }
    }
    Ok(problems)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_need_a_ref_comment() {
        let sha = "3d3c42e5aac5ba805825da76410c181273ba90b1";
        for (line, ok) in [
            (
                format!("let c = \"actions/checkout@{sha}\" in # v7.0.1"),
                true,
            ),
            (format!("{{ uses = \"o/r/sub/dir@{sha}\" }}, # main"), true),
            (format!("let c = \"actions/checkout@{sha}\" in"), false),
            (format!("let c = \"actions/checkout@{sha}\" in #"), false),
            (format!("# \"actions/checkout@{sha}\" v7"), false),
            ("let c = \"actions/checkout@v7\" in".to_owned(), true),
        ] {
            assert_eq!(unannotated("x.ncl", &line).is_empty(), ok, "{line}");
        }
    }
}
