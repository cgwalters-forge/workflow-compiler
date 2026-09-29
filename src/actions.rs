//! `actions.lock.json`: for every action that runs in the sandbox
//! (`owner/repo[/path]@sha`), its action.yml as fetched at that commit,
//! the file's sha256 (which the generated fetch step checks at run time)
//! and the metadata parsed from it, which `lib/gha.ncl` imports: nickel
//! can't fetch anything itself. `check` reparses each action.yml and
//! compares.
//!
//! Actions of the owner [`TEST_OWNER`] are fixtures for reject and accept
//! tests, read from [`TEST_ACTIONS`]`/<repo>/` instead of fetched; no
//! workflow can run them.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::io::Read as _;
use std::sync::LazyLock;

use anyhow::{Context, Result, anyhow, bail};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::repo::Repo;
use crate::{REGENERATE, nickel};

/// The lock file, relative to the repository root.
pub const LOCK_FILE: &str = "actions.lock.json";
/// The owner of fixture actions.
pub const TEST_OWNER: &str = "wfc-test";
/// Where fixture actions live, relative to the repository root.
pub const TEST_ACTIONS: &str = "tests/actions";
/// Metadata files an action may have, in the order GitHub looks for them.
const METADATA_FILES: &[&str] = &["action.yml", "action.yaml"];
/// Most an action.yml fetched from GitHub may be.
const MAX_ACTION_YML: u64 = 1 << 20;
/// How long fetching one may take.
const FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

static USES_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)((?:/[A-Za-z0-9_.-]+)*)@([0-9a-f]{40})$")
        .expect("valid regex")
});
/// `lib/gha.ncl`'s error for an action missing from the lock.
static MISSING_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"action `([^`]+)` is not in actions\.lock\.json").expect("valid regex")
});

/// One action's entry in the lock.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    /// The metadata file's path in the action's repository.
    pub file: String,
    /// What `lib/gha.ncl` reads: the action's name, inputs, outputs and
    /// `runs`, as parsed from `yaml`.
    pub metadata: Value,
    /// The sha256 of `yaml`, in hex.
    pub sha256: String,
    /// The metadata file, as fetched.
    pub yaml: String,
}

/// The lock, by `uses`.
pub type Lock = BTreeMap<String, Entry>;

/// A pinned `uses`, split up.
struct Uses<'a> {
    owner: &'a str,
    repo: &'a str,
    /// The path of the action in the repository, without a leading `/`;
    /// empty for its root.
    path: &'a str,
    sha: &'a str,
}

impl<'a> Uses<'a> {
    fn parse(uses: &'a str) -> Result<Self> {
        let caps = USES_RE
            .captures(uses)
            .ok_or_else(|| anyhow!("{uses} is not owner/repo[/path]@<sha>"))?;
        let get = |i| caps.get(i).map_or("", |m| m.as_str());
        let this = Uses {
            owner: get(1),
            repo: get(2),
            path: get(3).trim_start_matches('/'),
            sha: get(4),
        };
        let mut components = [this.owner, this.repo]
            .into_iter()
            .chain(this.path.split('/'));
        if components.any(|c| c == "." || c == "..") {
            bail!("{uses} has a `.` or `..` component");
        }
        Ok(this)
    }

    fn is_fixture(&self) -> bool {
        self.owner == TEST_OWNER
    }

    /// The metadata file `name` in the action's directory.
    fn file(&self, name: &str) -> String {
        if self.path.is_empty() {
            name.to_owned()
        } else {
            format!("{}/{name}", self.path)
        }
    }

    /// Where a fixture's action.yml is, relative to the repository root.
    fn fixture_path(&self) -> String {
        format!(
            "{TEST_ACTIONS}/{}/{}",
            self.repo,
            self.file(METADATA_FILES[0])
        )
    }
}

/// The action `lib/gha.ncl` reported missing from the lock in `report`,
/// if that is why a compile failed.
pub fn missing_action(report: &str) -> Option<String> {
    MISSING_RE.captures(report).map(|c| c[1].to_owned())
}

pub fn sha256_hex(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .fold(String::with_capacity(64), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

/// What `lib/gha.ncl` needs of an action.yml: its name, inputs, outputs
/// and `runs`.
pub fn metadata(yaml: &str) -> Result<Value> {
    let Value::Object(mut all) = nickel::yaml_to_json("action.yml", yaml)? else {
        bail!("action.yml isn't a map");
    };
    let mut metadata = Map::new();
    if let Some(name) = all.remove("name") {
        metadata.insert("name".into(), name);
    }
    for key in ["inputs", "outputs"] {
        let value = all
            .remove(key)
            .filter(|v| !v.is_null())
            .unwrap_or_else(|| Value::Object(Map::new()));
        metadata.insert(key.into(), value);
    }
    if let Some(runs) = all.remove("runs") {
        metadata.insert("runs".into(), runs);
    }
    Ok(Value::Object(metadata))
}

fn entry(file: String, yaml: String) -> Result<Entry> {
    let metadata = metadata(&yaml).with_context(|| format!("parsing {file}"))?;
    Ok(Entry {
        file,
        metadata,
        sha256: sha256_hex(&yaml),
        yaml,
    })
}

/// What a fixture's action.yml is now.
enum Fixture {
    /// The entry isn't a fixture.
    No,
    /// Its action.yml is gone from [`TEST_ACTIONS`].
    Gone,
    Yaml(String),
}

fn fixture(root: &Repo, uses: &str) -> Result<Fixture> {
    let parsed = Uses::parse(uses)?;
    if !parsed.is_fixture() {
        return Ok(Fixture::No);
    }
    Ok(match root.read(&parsed.fixture_path())? {
        Some(yaml) => Fixture::Yaml(yaml),
        None => Fixture::Gone,
    })
}

/// The lock entry of the fixture `uses`, from [`TEST_ACTIONS`]; `None`
/// if `uses` isn't a fixture.
pub fn lock_fixture(root: &Repo, uses: &str) -> Result<Option<Entry>> {
    let parsed = Uses::parse(uses)?;
    match fixture(root, uses)? {
        Fixture::No => Ok(None),
        Fixture::Gone => bail!("{uses}: no {}", parsed.fixture_path()),
        Fixture::Yaml(yaml) => {
            eprintln!("locked {uses} (fixture {})", parsed.fixture_path());
            entry(parsed.file(METADATA_FILES[0]), yaml).map(Some)
        }
    }
}

/// The lock entry of `uses`, fetched from GitHub at its pinned commit.
pub fn fetch(uses: &str) -> Result<Entry> {
    let parsed = Uses::parse(uses)?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .https_only(true)
        .timeout_global(Some(FETCH_TIMEOUT))
        .build()
        .into();
    for name in METADATA_FILES {
        let file = parsed.file(name);
        let url = format!(
            "https://raw.githubusercontent.com/{}/{}/{}/{file}",
            parsed.owner, parsed.repo, parsed.sha
        );
        let mut response = match agent.get(&url).call() {
            Ok(response) => response,
            Err(ureq::Error::StatusCode(404)) => continue,
            Err(e) => return Err(e).with_context(|| format!("fetching {url}")),
        };
        let mut yaml = String::new();
        response
            .body_mut()
            .as_reader()
            .take(MAX_ACTION_YML + 1)
            .read_to_string(&mut yaml)
            .with_context(|| format!("reading {url}"))?;
        if yaml.len() as u64 > MAX_ACTION_YML {
            bail!("{url} is over {MAX_ACTION_YML} bytes");
        }
        eprintln!("locked {uses} ({file})");
        return entry(file, yaml).with_context(|| format!("locking {uses}"));
    }
    bail!(
        "{}/{}@{} has no {} in {}",
        parsed.owner,
        parsed.repo,
        parsed.sha,
        METADATA_FILES.join(" or "),
        if parsed.path.is_empty() {
            "its root"
        } else {
            parsed.path
        }
    )
}

/// The lock of the repository at `root`; empty if it has none.
pub fn read_lock(root: &Repo) -> Result<Lock> {
    match root.read(LOCK_FILE)? {
        Some(text) => serde_json::from_str(&text).with_context(|| format!("parsing {LOCK_FILE}")),
        None => Ok(Lock::new()),
    }
}

/// `lock` as JSON with sorted keys, so its diffs are stable.
pub fn to_json(lock: &Lock) -> Result<String> {
    // Through a Value, whose maps sort their keys (the struct's fields
    // would otherwise come in declaration order).
    let value = serde_json::to_value(lock)?;
    Ok(serde_json::to_string_pretty(&value)? + "\n")
}

pub fn write_lock(root: &Repo, lock: &Lock) -> Result<()> {
    root.write(LOCK_FILE, &to_json(lock)?)
}

/// Relocks every fixture in `lock` whose action.yml changed, and drops
/// those whose action.yml is gone (a source that still uses one then
/// fails to lock it). Returns whether anything changed.
pub fn relock_fixtures(root: &Repo, lock: &mut Lock) -> Result<bool> {
    let mut changed = false;
    let uses: Vec<String> = lock.keys().cloned().collect();
    for uses in uses {
        match fixture(root, &uses)? {
            Fixture::No => {}
            Fixture::Gone => {
                lock.remove(&uses);
                changed = true;
            }
            Fixture::Yaml(yaml) if yaml != lock[&uses].yaml => {
                let entry = lock_fixture(root, &uses)?.expect("a fixture");
                lock.insert(uses, entry);
                changed = true;
            }
            Fixture::Yaml(_) => {}
        }
    }
    Ok(changed)
}

/// Checks that every entry's sha256 and metadata come from its action.yml,
/// and that a fixture's is the one in [`TEST_ACTIONS`].
pub fn check_lock(root: &Repo, lock: &Lock) -> Vec<String> {
    let mut problems = Vec::new();
    for (uses, entry) in lock {
        let mut problem = |p: String| problems.push(format!("{LOCK_FILE}: {uses}: {p}"));
        match fixture(root, uses) {
            Err(e) => problem(format!("{e:#}")),
            Ok(Fixture::Gone) => problem(format!(
                "its fixture in {TEST_ACTIONS}/ is gone; run `{REGENERATE}`"
            )),
            Ok(Fixture::Yaml(yaml)) if yaml != entry.yaml => problem(format!(
                "{TEST_ACTIONS}/ changed since it was locked; run `{REGENERATE}`"
            )),
            Ok(_) => {}
        }
        if sha256_hex(&entry.yaml) != entry.sha256 {
            problem("sha256 doesn't match its action.yml".into());
            continue;
        }
        match metadata(&entry.yaml) {
            Err(e) => problem(format!("{e:#}")),
            Ok(m) if m != entry.metadata => problem(format!(
                "metadata doesn't match its action.yml; run `{REGENERATE}`"
            )),
            Ok(_) => {}
        }
    }
    problems
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_is_parsed_strictly() {
        let sha = "a".repeat(40);
        let ok = format!("o/r/sub/dir@{sha}");
        let u = Uses::parse(&ok).unwrap();
        assert_eq!((u.owner, u.repo, u.path), ("o", "r", "sub/dir"));
        assert_eq!(u.file("action.yml"), "sub/dir/action.yml");
        for bad in [
            format!("o/r@{}", "a".repeat(39)),
            "o/r@main".to_owned(),
            format!("{TEST_OWNER}/../x@{sha}"),
            format!("{TEST_OWNER}/x/../../y@{sha}"),
            format!("o/./x@{sha}"),
        ] {
            assert!(Uses::parse(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn metadata_keeps_what_gha_ncl_reads() {
        let m =
            metadata("name: x\ndescription: d\ninputs:\nruns:\n  using: node24\n  main: i.js\n")
                .unwrap();
        assert_eq!(
            m,
            serde_json::json!({
                "name": "x",
                "inputs": {},
                "outputs": {},
                "runs": { "using": "node24", "main": "i.js" },
            })
        );
        assert!(metadata("- a\n").is_err());
    }

    #[test]
    fn lock_json_is_sorted() {
        let mut lock = Lock::new();
        lock.insert(
            "b/b@x".into(),
            Entry {
                file: "action.yml".into(),
                metadata: serde_json::json!({ "runs": 1, "name": "b" }),
                sha256: sha256_hex(""),
                yaml: String::new(),
            },
        );
        let json = to_json(&lock).unwrap();
        let order: Vec<usize> = [
            "\"file\"",
            "\"metadata\"",
            "\"name\"",
            "\"runs\"",
            "\"sha256\"",
            "\"yaml\"",
        ]
        .iter()
        .map(|k| json.find(k).unwrap())
        .collect();
        assert!(order.is_sorted(), "{json}");
        assert!(json.ends_with("}\n"));
        assert_eq!(
            sha256_hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn missing_action_is_found_in_reports() {
        let report = "error: action `o/r@abc` is not in actions.lock.json; run it";
        assert_eq!(missing_action(report).as_deref(), Some("o/r@abc"));
        assert_eq!(missing_action("error: something else"), None);
    }
}
