//! Checks the shape of a compiled workflow, independently of its source:
//! that it holds exactly what `gha.compile` emits. Each job has the
//! generated steps, byte for byte what this repository's runtime scripts
//! make them, and everything between entering the sandbox and sealing it
//! runs through the step wrapper. Keys are allowlisted, mirroring
//! gha.ncl's closed contracts, so anything GitHub adds later is refused
//! until the compiler knows it. The stale-lock check proves a lock file
//! matches its source; this proves the source went through
//! `gha.compile`, rather than building a record of its own that merely
//! looks like a workflow (#13).

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::LazyLock;

use anyhow::{Context, Result};
use regex::Regex;
use serde_json::{Map, Value};

use crate::repo::Repo;
use crate::{LOCKS_DIR, SOURCES_DIR, UNCOMPILED, nickel};

/// The texts of the runtime scripts the generated steps embed, by file
/// name.
pub type Runtime = BTreeMap<String, String>;

/// Where a repository keeps the compiler's runtime scripts, by default:
/// this repository's own.
pub const RUNTIME_DIR: &str = "runtime";
const EXEC: &str = "/usr/local/bin/runner-sandbox-exec";
const SEAL_ID: &str = "runner-sandbox-seal";
const SEAL_CONDITION: &str = "steps.runner-sandbox-seal.outcome == 'success'";
/// The enter step's embedded scripts, by variable.
const ENTER_ENV: &[(&str, &str)] = &[
    ("RUNNER_SANDBOX_EXEC_JS", "exec.cjs"),
    ("RUNNER_SANDBOX_RUN_JS", "run.cjs"),
    ("RUNNER_SANDBOX_HANDOFF_JS", "handoff.cjs"),
    ("RUNNER_SANDBOX_FILECMD_JS", "filecmd.cjs"),
    ("RUNNER_SANDBOX_LAUNCH_JS", "launch.cjs"),
];
/// The keys gha.ncl's Workflow and Job contracts let through to the output.
const WORKFLOW_KEYS: &[&str] = &[
    "name",
    "run-name",
    "on",
    "permissions",
    "concurrency",
    "jobs",
];
const JOB_KEYS: &[&str] = &[
    "name",
    "runs-on",
    "timeout-minutes",
    "if",
    "needs",
    "permissions",
    "steps",
];
/// The keys of a sandboxed step, by kind; a stage step has no env, which
/// would apply to the bash that runs it as runner.
const WRAPPER_STEP_KEYS: &[&str] = &[
    "name",
    "id",
    "if",
    "continue-on-error",
    "timeout-minutes",
    "shell",
    "run",
    "env",
];
const STAGE_STEP_KEYS: &[&str] = &[
    "name",
    "id",
    "if",
    "continue-on-error",
    "timeout-minutes",
    "shell",
    "run",
];
const PUBLISH_STEP_KEYS: &[&str] = &[
    "name",
    "id",
    "if",
    "run",
    "shell",
    "uses",
    "with",
    "env",
    "working-directory",
    "continue-on-error",
    "timeout-minutes",
];
const CONFIG_KEYS: &[&str] = &["user", "lockRunnerSudo", "handoff", "workspace"];
/// Never the sandbox user.
const NOT_SANDBOX_USERS: &[&str] = &["root", "runner"];
const HANDOFF_MODES: &[&str] = &["tracked", "all", "none"];

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("valid regex")
}

/// The wrapper forms a sandboxed step's shell may take.
static SANDBOX_SHELLS: LazyLock<[Regex; 3]> = LazyLock::new(|| {
    let exec = regex::escape(EXEC);
    [
        re(&format!(r"^{exec} \{{0\}}$")),
        re(&format!(r"^{exec} --action \{{0\}}$")),
        re(&format!(
            r"^{exec} --action-path [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{{40}} \{{0\}}$"
        )),
    ]
});
static STAGE_RUN: LazyLock<Regex> = LazyLock::new(|| {
    re(&format!(
        r"^{} --stage [A-Za-z0-9_-]+ ([A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*)$",
        regex::escape(EXEC)
    ))
});
static ACTION_PATH: LazyLock<Regex> = LazyLock::new(|| re(r"--action-path (\S+)@"));
/// `.` and `..` path components, which gha.ncl's path contracts refuse.
static DOT_COMPONENT: LazyLock<Regex> = LazyLock::new(|| re(r"(^|/)\.\.?(/|$)"));
static PINNED: LazyLock<Regex> =
    LazyLock::new(|| re(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$"));
// Expressions, as gha.ncl's lints read them: CREDENTIALS_RE
// (NoCredentials), STEP_OUTPUTS_RE and WHOLE_STEPS_RE
// (NoSandboxOutputs), UNTRUSTED_TEXT_RE and SAFE_EVENT_RE
// (NoUntrustedTextInScript). `\b` is ASCII's, as in their JavaScript
// originals.
static CREDENTIALS: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?-u:\b)secrets(?-u:\b)|(?-u:\b)github\s*(\[|[,)}]|\.\s*token(?-u:\b)|\.\s*\*)")
});
static STEP_OUTPUTS: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?i)(?-u:\b)steps\s*\.\s*([A-Za-z0-9_-]+)\s*\.\s*outputs(?-u:\b)"));
static WHOLE_STEPS: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?-u:\b)steps(?-u:\b)\s*(\[|[,)}]|$|\.\s*\*|\.\s*[A-Za-z0-9_-]+\s*(\[|\.\s*\*))")
});
static UNTRUSTED_TEXT: LazyLock<Regex> = LazyLock::new(|| {
    re(
        r"(?i)(?-u:\b)github\s*(\.\s*(event|head_ref)(?-u:\b)|\.\s*\*|\[|[,)}]|$)|(?-u:\b)inputs(?-u:\b)|(?-u:\b)needs\s*(\.\s*[A-Za-z0-9_*-]+\s*(\.\s*outputs(?-u:\b)|\[)|\[|\.\s*\*|[,)}]|$)",
    )
});
// ASCII case folding only (`-u`): this one exempts text, and Unicode's
// would also fold `ſ` and the Kelvin sign into its names.
static SAFE_EVENT: LazyLock<Regex> = LazyLock::new(|| {
    re(
        r"(?i-u)\bgithub\s*\.\s*event\s*\.\s*(number|(issue|pull_request|comment|review|review_comment|discussion|discussion_comment|release|milestone|workflow_run|check_run|check_suite|deployment|repository|sender)\s*\.\s*(number|id))\b",
    )
});
static WHOLE_ENV: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)(?-u:\b)env\s*(\[|\.\s*\*|[,)}]|$)"));
/// As DENIED_ENV_RE in lib/gha.ncl: names that would change how the
/// runner side of the wrapper starts. The wrapper's own are allowed.
static DENIED_ENV: LazyLock<Regex> = LazyLock::new(|| {
    re(
        r"^(ACTIONS_|RUNNER_|GITHUB_(TOKEN|ENV|PATH|OUTPUT|STATE|STEP_SUMMARY)$|LD_|NODE_|OPENSSL_(CONF|MODULES)$|(BASH_ENV|ENV|PATH|HOME|USER|LOGNAME|SHELL)$)",
    )
});
static WRAPPER_ENV: LazyLock<Regex> =
    LazyLock::new(|| re(r"^RUNNER_SANDBOX_(ENV|ENV_NAMES|VAR_[0-9]+|ANNOTATIONS)$"));
/// As USER_RE in lib/gha.ncl.
static USER: LazyLock<Regex> = LazyLock::new(|| re(r"^[a-z_][a-z0-9_-]{0,30}$"));
static WORKSPACE_PATH: LazyLock<Regex> = LazyLock::new(|| re(r"^[^/]+(/[^/]+)*$"));
static QUOTED: LazyLock<Regex> = LazyLock::new(|| re(r"'([^']|'')*'"));
static AFTER_SEAL_WRAPPED: LazyLock<Regex> = LazyLock::new(|| {
    re(&format!(
        r"(?s)^\((.*)\) && {}$",
        regex::escape(SEAL_CONDITION)
    ))
});
static AFTER_SEAL_OUTCOME: LazyLock<Regex> = LazyLock::new(|| {
    re(&format!(
        r"^!cancelled\(\) && steps\.[A-Za-z0-9_-]+\.outcome == 'success' && {}$",
        regex::escape(SEAL_CONDITION)
    ))
});
static UNCOMPILED_LINE: LazyLock<Regex> = LazyLock::new(|| re(r"^\s*(\S+)\s+#\s*(\S.*)$"));

fn enter_shell() -> String {
    let names: Vec<&str> = ENTER_ENV.iter().map(|(k, _)| *k).collect();
    format!("sudo --preserve-env={} node {{0}}", names.join(","))
}

/// The `${{ ... }}` expressions in `v`, each up to the end of `v`.
fn expressions(v: &str) -> impl Iterator<Item = &str> {
    v.split("${{").skip(1)
}

/// Every string in `v`, however deep.
fn strings(v: &Value) -> Vec<&str> {
    match v {
        Value::String(s) => vec![s],
        Value::Array(a) => a.iter().flat_map(strings).collect(),
        Value::Object(o) => o.values().flat_map(strings).collect(),
        _ => vec![],
    }
}

fn untrusted(e: &str) -> bool {
    UNTRUSTED_TEXT.is_match(&SAFE_EVENT.replace_all(e, "0"))
}

fn json(v: Option<&Value>) -> String {
    v.map_or_else(|| "undefined".into(), Value::to_string)
}

/// The keys of `obj` not in `allowed`.
fn keys_outside<'a>(obj: &'a Map<String, Value>, allowed: &[&str]) -> Vec<&'a str> {
    obj.keys()
        .map(String::as_str)
        .filter(|k| !allowed.contains(k))
        .collect()
}

/// Whether `v` is a map with exactly `keys`.
fn has_keys(v: &Value, keys: &[&str]) -> bool {
    v.as_object()
        .is_some_and(|o| o.len() == keys.len() && keys.iter().all(|k| o.contains_key(*k)))
}

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

/// Problems with `config`, the enter step's configuration.
fn config_problems(config: &Value, has_publish: bool) -> Vec<String> {
    let mut problems = Vec::new();
    if !has_keys(config, CONFIG_KEYS) {
        let keys: Vec<String> = config
            .as_object()
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        problems.push(format!("has CONFIG keys {}", Value::from(keys)));
    }
    let user = str_of(config, "user");
    if !user.is_some_and(|u| USER.is_match(u) && !NOT_SANDBOX_USERS.contains(&u)) {
        problems.push(format!("has the sandbox user {}", json(config.get("user"))));
    }
    if str_of(config, "workspace") != Some("${{ github.workspace }}") {
        problems.push(format!(
            "hands off {}, not the workspace",
            json(config.get("workspace"))
        ));
    }
    // As PublishNeedsLock in gha.ncl: runner code after the sandbox only
    // with runner's root taken away.
    let lock = config.get("lockRunnerSudo");
    if lock != Some(&Value::Bool(true)) && (lock != Some(&Value::Bool(false)) || has_publish) {
        problems.push(format!(
            "has lockRunnerSudo {}{}",
            json(lock),
            if has_publish {
                " with steps after the seal"
            } else {
                ""
            }
        ));
    }
    let handoff = config.get("handoff");
    let handoff_ok = handoff.is_some_and(|h| {
        has_keys(h, &["workspace", "include"])
            && str_of(h, "workspace").is_some_and(|m| HANDOFF_MODES.contains(&m))
            && h["include"].as_array().is_some_and(|include| {
                include.iter().all(|p| {
                    p.as_str().is_some_and(|p| {
                        WORKSPACE_PATH.is_match(p)
                            && !DOT_COMPONENT.is_match(p)
                            && !p.contains("${{")
                    })
                })
            })
    });
    if !handoff_ok {
        problems.push(format!("has the hand-off {}", json(handoff)));
    }
    problems
}

/// The CONFIG of `run` if it is `const CONFIG = <JSON object>;\n`
/// followed by install.cjs.
fn install_config(runtime: &Runtime, run: Option<&Value>) -> Option<Value> {
    let install = runtime.get("install.cjs")?;
    let config = run?
        .as_str()?
        .strip_suffix(install.as_str())?
        .strip_prefix("const CONFIG = ")?
        .strip_suffix(";\n")?;
    serde_json::from_str::<Value>(config)
        .ok()
        .filter(Value::is_object)
}

fn is_enter(runtime: &Runtime, s: &Value) -> bool {
    has_keys(s, &["name", "shell", "env", "run"])
        && str_of(s, "name") == Some("Enter the sandbox (generated)")
        && str_of(s, "shell") == Some(enter_shell().as_str())
        && install_config(runtime, s.get("run")).is_some()
        && has_keys(
            &s["env"],
            &ENTER_ENV.iter().map(|(k, _)| *k).collect::<Vec<_>>(),
        )
        && ENTER_ENV.iter().all(|(k, f)| {
            runtime
                .get(*f)
                .is_some_and(|text| str_of(&s["env"], k) == Some(text))
        })
}

fn is_secure_host(runtime: &Runtime, s: &Value) -> bool {
    has_keys(s, &["name", "shell", "run"])
        && str_of(s, "name") == Some("Secure the host (generated)")
        && str_of(s, "shell") == Some("sudo node {0}")
        && runtime
            .get("secure-host.cjs")
            .is_some_and(|text| str_of(s, "run") == Some(text))
}

fn is_seal(s: &Value) -> bool {
    has_keys(s, &["name", "id", "if", "shell", "run"])
        && str_of(s, "name") == Some("Seal the sandbox (generated)")
        && str_of(s, "id") == Some(SEAL_ID)
        && str_of(s, "if") == Some("always()")
        && str_of(s, "shell") == Some("bash")
        && str_of(s, "run") == Some(format!("{EXEC} --seal").as_str())
}

/// Whether `cond` has balanced parentheses outside string literals.
fn balanced(cond: &str) -> bool {
    let mut depth = 0i64;
    for c in QUOTED.replace_all(cond, "''").chars() {
        depth += match c {
            '(' => 1,
            ')' => -1,
            _ => 0,
        };
        if depth < 0 {
            return false;
        }
    }
    depth == 0
}

/// Whether a publish step's condition requires the seal to have succeeded.
fn after_seal(cond: Option<&Value>) -> bool {
    let Some(cond) = cond.and_then(Value::as_str) else {
        return false;
    };
    if cond.contains("${{") || cond.contains("}}") {
        return false;
    }
    if let Some(caps) = AFTER_SEAL_WRAPPED.captures(cond) {
        return balanced(&caps[1]);
    }
    AFTER_SEAL_OUTCOME.is_match(cond)
}

/// Problems with `step`, a step between entering the sandbox and the seal.
fn sandbox_step_problems(step: &Map<String, Value>) -> Vec<String> {
    let mut problems = Vec::new();
    let get = |k: &str| step.get(k).and_then(Value::as_str);
    let shell = get("shell").unwrap_or("");
    let stage = (shell == "bash")
        .then(|| STAGE_RUN.captures(get("run").unwrap_or("")))
        .flatten();
    let extra = keys_outside(
        step,
        if stage.is_some() {
            STAGE_STEP_KEYS
        } else {
            WRAPPER_STEP_KEYS
        },
    );
    if !extra.is_empty() {
        problems.push(format!(
            "has {}, which a {} step never has",
            extra.join(", "),
            if stage.is_some() {
                "stage"
            } else {
                "sandboxed"
            }
        ));
    }
    if get("id") == Some(SEAL_ID) {
        problems.push(format!("has the seal's id {SEAL_ID}"));
    }
    if stage.is_none() && !SANDBOX_SHELLS.iter().any(|re| re.is_match(shell)) {
        problems.push(format!(
            "runs with shell {}, not the sandbox wrapper",
            step.get("shell").unwrap_or(&Value::Null)
        ));
    }
    let stage_path = stage
        .as_ref()
        .map_or("", |c| c.get(1).map_or("", |m| m.as_str()));
    let action_path = ACTION_PATH
        .captures(shell)
        .map_or("", |c| c.get(1).map_or("", |m| m.as_str()));
    if [stage_path, action_path]
        .iter()
        .any(|p| DOT_COMPONENT.is_match(p))
    {
        problems.push("names a path with `.` or `..`".into());
    }
    if step
        .values()
        .flat_map(strings)
        .any(|v| expressions(v).any(|e| CREDENTIALS.is_match(e)))
    {
        problems.push("references secrets or the job's token, which a sandboxed step can't".into());
    }
    if let Some(env) = step.get("env").and_then(Value::as_object) {
        for name in env.keys() {
            if !WRAPPER_ENV.is_match(name) && DENIED_ENV.is_match(name) {
                problems.push(format!("sets {name} for the wrapper's runner side"));
            }
        }
    }
    problems
}

/// Problems with `step`, a step after the seal, as gha.ncl's PublishStep
/// has them (`ids`: the ids of the publish steps, whose outputs are
/// runner's, lowercased).
fn publish_step_problems(step: &Map<String, Value>, ids: &[String]) -> Vec<String> {
    let mut problems = Vec::new();
    let extra = keys_outside(step, PUBLISH_STEP_KEYS);
    if !extra.is_empty() {
        problems.push(format!(
            "has {}, which a publish step never has",
            extra.join(", ")
        ));
    }
    if step.contains_key("run") == step.contains_key("uses") {
        problems.push("needs exactly one of run or uses".into());
    }
    if let Some(uses) = step.get("uses")
        && !uses.as_str().is_some_and(|u| PINNED.is_match(u))
    {
        problems.push(format!("uses {uses}, which isn't pinned by commit"));
    }
    let null = Value::Null;
    let field = |k: &str| step.get(k).unwrap_or(&null);
    let data: Vec<&str> = [field("run"), field("working-directory")]
        .into_iter()
        .filter_map(Value::as_str)
        .chain(strings(field("with")))
        .chain(strings(field("env")))
        .collect();
    let sandbox_outputs = |e: &str| {
        WHOLE_STEPS.is_match(e)
            || STEP_OUTPUTS
                .captures_iter(e)
                .any(|c| !ids.contains(&c[1].to_lowercase()))
    };
    if data.iter().any(|v| expressions(v).any(sandbox_outputs)) {
        problems.push("uses sandboxed steps' outputs, strings the sandbox chose".into());
    }
    // Scripts: the run, and every with (github-script's script and the
    // like), including env values re-expanded into them.
    let tainted: Vec<Regex> = field("env")
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(_, v)| v.as_str().is_some_and(|v| expressions(v).any(untrusted)))
        .map(|(k, _)| {
            re(&format!(
                r"(?i)(?-u:\b)env\s*\.\s*{}(?-u:\b)",
                regex::escape(k)
            ))
        })
        .collect();
    let expands_env = |e: &str| {
        !tainted.is_empty() && (WHOLE_ENV.is_match(e) || tainted.iter().any(|t| t.is_match(e)))
    };
    let scripts: Vec<&str> = field("run")
        .as_str()
        .into_iter()
        .chain(strings(field("with")))
        .collect();
    if scripts
        .iter()
        .any(|v| expressions(v).any(|e| untrusted(e) || expands_env(e)))
    {
        problems.push("expands text others control into a script run as runner".into());
    }
    problems
}

/// The problems with `workflow`, a parsed lock file, given the runtime
/// scripts its generated steps must embed.
pub fn check_workflow(workflow: &Value, runtime: &Runtime) -> Vec<String> {
    let mut problems = Vec::new();
    let Some(top) = workflow.as_object() else {
        return vec!["the workflow isn't a map".into()];
    };
    let extra = keys_outside(top, WORKFLOW_KEYS);
    if !extra.is_empty() {
        problems.push(format!(
            "the workflow sets {}, which a compiled one never has",
            extra.join(", ")
        ));
    }
    if top.get("permissions").is_some_and(|p| !p.is_object()) {
        problems.push("the workflow's permissions aren't a map".into());
    }
    let Some(jobs) = top.get("jobs").and_then(Value::as_object) else {
        problems.push("the workflow has no jobs map".into());
        return problems;
    };
    for (name, job) in jobs {
        let Some(job) = job.as_object() else {
            problems.push(format!("job {name} isn't a map"));
            continue;
        };
        let extra = keys_outside(job, JOB_KEYS);
        if !extra.is_empty() {
            problems.push(format!(
                "job {name} sets {}, which a compiled job never has",
                extra.join(", ")
            ));
        }
        if job.get("permissions").is_some_and(|p| !p.is_object()) {
            problems.push(format!("job {name}'s permissions aren't a map"));
        }
        let steps: &[Value] = job
            .get("steps")
            .and_then(Value::as_array)
            .map_or(&[], Vec::as_slice);
        let at = |i: usize, s: &Value| match str_of(s, "name") {
            Some(n) if !n.is_empty() => format!("job {name}, step {} ({n})", i + 1),
            _ => format!("job {name}, step {}", i + 1),
        };
        let enters: Vec<usize> = (0..steps.len())
            .filter(|&i| is_enter(runtime, &steps[i]))
            .collect();
        let seals: Vec<usize> = (0..steps.len())
            .filter(|&i| str_of(&steps[i], "id") == Some(SEAL_ID))
            .collect();
        let &[enter] = enters.as_slice() else {
            problems.push(format!(
                "job {name} has {} generated steps entering the sandbox, not 1 (or it differs from what the compiler generates)",
                enters.len()
            ));
            continue;
        };
        if enter == 0 || !is_secure_host(runtime, &steps[enter - 1]) {
            problems.push(format!(
                "job {name}: the step before entering the sandbox isn't the generated secure-host step"
            ));
        }
        let seal = match seals.as_slice() {
            &[seal] if seal > enter && is_seal(&steps[seal]) => seal,
            _ => {
                problems.push(format!(
                    "job {name} doesn't have exactly one generated seal step after entering the sandbox"
                ));
                continue;
            }
        };
        let config = install_config(runtime, steps[enter].get("run")).expect("checked by is_enter");
        for p in config_problems(&config, seal < steps.len() - 1) {
            problems.push(format!("job {name}: the enter step {p}"));
        }
        for (i, step) in steps.iter().enumerate().take(seal).skip(enter + 1) {
            let Some(fields) = step.as_object() else {
                problems.push(format!("{} isn't a map", at(i, step)));
                continue;
            };
            for p in sandbox_step_problems(fields) {
                problems.push(format!("{} {p}", at(i, step)));
            }
        }
        let publish_ids: Vec<String> = steps[seal + 1..]
            .iter()
            .filter_map(|s| str_of(s, "id"))
            .map(str::to_lowercase)
            .collect();
        for (i, step) in steps.iter().enumerate().skip(seal + 1) {
            let Some(fields) = step.as_object() else {
                problems.push(format!("{} isn't a map", at(i, step)));
                continue;
            };
            if !after_seal(fields.get("if")) {
                problems.push(format!(
                    "{} runs as runner after the sandbox without requiring the seal to have succeeded",
                    at(i, step)
                ));
            }
            for p in publish_step_problems(fields, &publish_ids) {
                problems.push(format!("{} {p}", at(i, step)));
            }
        }
    }
    problems
}

/// The names `text` (the uncompiled-workflows list) holds, and its lines
/// without a reason.
fn read_uncompiled(text: &str) -> (Vec<String>, Vec<String>) {
    let mut names = Vec::new();
    let mut unexplained = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        match UNCOMPILED_LINE.captures(line) {
            Some(c) => names.push(c[1].to_owned()),
            None => unexplained.push(trimmed.to_owned()),
        }
    }
    (names, unexplained)
}

/// The names of the entries in the directory `rel`, sorted; none if it
/// doesn't exist.
fn files_in(root: &Repo, rel: &str) -> Result<Vec<String>> {
    let prefix = format!("{rel}/");
    Ok(root
        .list(rel, "")?
        .into_iter()
        .map(|p| p.strip_prefix(&prefix).unwrap_or(&p).to_owned())
        .collect())
}

/// The runtime scripts in `dir` of the repository at `root`.
pub fn read_runtime(root: &Repo, dir: &str) -> Result<Runtime> {
    let mut runtime = Runtime::new();
    for name in files_in(root, dir)? {
        let rel = format!("{dir}/{name}");
        // Only files are scripts; a directory or symlink there is skipped.
        if root.is_file(&rel)?
            && let Some(text) = root.read(&rel)?
        {
            runtime.insert(name, text);
        }
    }
    Ok(runtime)
}

/// Checks that every file in `root`'s [`LOCKS_DIR`] is a lock file with a
/// source in [`SOURCES_DIR`] and the compiled shape, or listed in
/// [`UNCOMPILED`], one name per line with its reason after `#`: each runs
/// with none of the compiler's guarantees, so each is a reviewed
/// exception. Returns the problems.
pub fn check_tree(root: &Repo, runtime_dir: &str) -> Result<Vec<String>> {
    let mut found = Vec::new();
    let list_name = Path::new(UNCOMPILED)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(UNCOMPILED);
    let list = root.read(UNCOMPILED)?.unwrap_or_default();
    let (listed, unexplained) = read_uncompiled(&list);
    for line in unexplained {
        found.push(format!(
            "{list_name}: {} has no \"# reason\"",
            Value::from(line)
        ));
    }
    let runtime = read_runtime(root, runtime_dir)?;
    let files = files_in(root, LOCKS_DIR)?;
    for file in &files {
        let rel = format!("{LOCKS_DIR}/{file}");
        let Some(stem) = file.strip_suffix(".lock.yml") else {
            if !listed.contains(file) {
                found.push(format!(
                    "{rel} isn't compiled; compile it from {SOURCES_DIR}/, or list it in {list_name} with the reason"
                ));
            }
            continue;
        };
        if root.read(&format!("{SOURCES_DIR}/{stem}.ncl"))?.is_none() {
            found.push(format!("{rel} has no source in {SOURCES_DIR}/"));
            continue;
        }
        if runtime.is_empty() {
            found.push(format!(
                "{rel}: no runtime scripts in {runtime_dir}/ to check its enter step against; pass --runtime with the runtime/ directory of the compiler the sources import"
            ));
            continue;
        }
        let text = root
            .read(&rel)?
            .with_context(|| format!("{rel} disappeared"))?;
        // YAML only: nickel parses it as data, with no imports to follow.
        match nickel::yaml_to_json(&rel, &text) {
            Err(e) => found.push(format!("{rel} can't be parsed: {e:#}")),
            Ok(workflow) => {
                for p in check_workflow(&workflow, &runtime) {
                    found.push(format!("{rel}: {p}"));
                }
            }
        }
    }
    for name in listed {
        if !files.contains(&name) {
            found.push(format!("{list_name} lists {name}, which doesn't exist"));
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conditions_after_the_seal() {
        let seal = SEAL_CONDITION;
        for (cond, ok) in [
            (format!("(success()) && {seal}"), true),
            (format!("(a || (b)) && {seal}"), true),
            (
                format!("!cancelled() && steps.x.outcome == 'success' && {seal}"),
                true,
            ),
            (format!("(always()) || (true) && {seal}"), false),
            (format!("(')') && {seal}"), true),
            (format!("(a)) || ((b) && {seal}"), false),
            (format!("${{{{ x }}}} && {seal}"), false),
            (seal.to_owned(), false),
        ] {
            assert_eq!(after_seal(Some(&Value::from(cond.clone()))), ok, "{cond}");
        }
        assert!(!after_seal(None));
    }

    #[test]
    fn untrusted_text() {
        for (e, want) in [
            (" github.event.issue.title }}", true),
            (" github.event.pull_request.number }}", false),
            (" GITHUB.EVENT.number }}", false),
            (" github.head_ref }}", true),
            (" toJSON(github) }}", true),
            (" inputs.x }}", true),
            (" needs.a.outputs.b }}", true),
            (" needs.a.result }}", false),
            (" github.sha }}", false),
        ] {
            assert_eq!(untrusted(e), want, "{e}");
        }
    }

    #[test]
    fn uncompiled_list() {
        let (names, unexplained) =
            read_uncompiled("# c\n\nci.yml  # ours\n  x.yml #why\nbare.yml\n");
        assert_eq!(names, ["ci.yml", "x.yml"]);
        assert_eq!(unexplained, ["bare.yml"]);
    }
}
