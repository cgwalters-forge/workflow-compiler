//! Tests for the shape check: a job of the compiled shape passes, and
//! each way of leaving the sandbox that a hand-built "compiled" workflow
//! could take is found.

use std::path::Path;
use std::sync::LazyLock;

use serde_json::{Value, json};
use workflow_compiler::repo::Repo;
use workflow_compiler::shape::{Runtime, check_tree, check_workflow, read_runtime};

const EXEC: &str = "/usr/local/bin/runner-sandbox-exec";
const SEAL: &str = "steps.runner-sandbox-seal.outcome == 'success'";
const UPLOAD: &str = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a";

static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    read_runtime(&Repo::open(Path::new(env!("CARGO_MANIFEST_DIR"))).unwrap()).unwrap()
});

fn rt(name: &str) -> &'static str {
    RUNTIME
        .get(name)
        .unwrap_or_else(|| panic!("no runtime/{name}"))
}

fn config() -> Value {
    json!({
        "user": "runner-sandbox",
        "lockRunnerSudo": true,
        "handoff": { "workspace": "tracked", "include": [".git"] },
        "workspace": "${{ github.workspace }}",
    })
}

fn with(base: Value, changes: Value) -> Value {
    let mut base = base;
    for (k, v) in changes.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

fn wrap(run: &str) -> Value {
    json!({ "shell": format!("{EXEC} {{0}}"), "run": run })
}

/// A workflow of the compiled shape, with `sandboxed` steps between
/// enter and seal and `publish` steps after the seal, and `job` and `top`
/// merged into the job and the workflow.
struct Workflow {
    sandboxed: Vec<Value>,
    publish: Vec<Value>,
    job: Value,
    top: Value,
    config: Value,
}

impl Default for Workflow {
    fn default() -> Self {
        Workflow {
            sandboxed: vec![wrap("id")],
            publish: vec![],
            job: json!({}),
            top: json!({}),
            config: config(),
        }
    }
}

impl Workflow {
    fn build(self) -> Value {
        let env = json!({
            "RUNNER_SANDBOX_EXEC_JS": rt("exec.cjs"),
            "RUNNER_SANDBOX_RUN_JS": rt("run.cjs"),
            "RUNNER_SANDBOX_HANDOFF_JS": rt("handoff.cjs"),
            "RUNNER_SANDBOX_FILECMD_JS": rt("filecmd.cjs"),
            "RUNNER_SANDBOX_LAUNCH_JS": rt("launch.cjs"),
        });
        let mut steps = vec![
            json!({ "uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "with": { "persist-credentials": false } }),
            json!({ "name": "Secure the host (generated)", "shell": "sudo node {0}", "run": rt("secure-host.cjs") }),
            json!({
                "name": "Enter the sandbox (generated)",
                "shell": "sudo --preserve-env=RUNNER_SANDBOX_EXEC_JS,RUNNER_SANDBOX_RUN_JS,RUNNER_SANDBOX_HANDOFF_JS,RUNNER_SANDBOX_FILECMD_JS,RUNNER_SANDBOX_LAUNCH_JS node {0}",
                "env": env,
                "run": format!("const CONFIG = {};\n{}", self.config, rt("install.cjs")),
            }),
        ];
        steps.extend(self.sandboxed);
        steps.push(json!({ "name": "Seal the sandbox (generated)", "id": "runner-sandbox-seal", "if": "always()", "shell": "bash", "run": format!("{EXEC} --seal") }));
        steps.extend(self.publish);
        let job = with(json!({ "runs-on": "ubuntu-26.04" }), self.job);
        let job = with(job, json!({ "steps": steps }));
        with(
            with(json!({ "name": "t" }), self.top),
            json!({ "jobs": { "t": job } }),
        )
    }
}

fn problems(w: Workflow) -> Vec<String> {
    check_workflow(&w.build(), &RUNTIME)
}

fn sandboxed(steps: Vec<Value>) -> Workflow {
    Workflow {
        sandboxed: steps,
        ..Default::default()
    }
}

fn publish(steps: Vec<Value>) -> Workflow {
    Workflow {
        publish: steps,
        ..Default::default()
    }
}

fn job(job: Value) -> Workflow {
    Workflow {
        job,
        ..Default::default()
    }
}

fn with_config(config: Value) -> Workflow {
    Workflow {
        config,
        ..Default::default()
    }
}

#[test]
fn the_compiled_shape_passes() {
    let ok = Workflow {
        sandboxed: vec![
            json!({ "shell": format!("{EXEC} {{0}}"), "run": "make", "env": { "CC": "gcc", "RUNNER_SANDBOX_ENV": "CC" } }),
            json!({ "shell": format!("{EXEC} --action {{0}}"), "run": "{}", "env": { "RUNNER_SANDBOX_ENV_NAMES": "INPUT_X", "RUNNER_SANDBOX_VAR_0": "1" } }),
            json!({ "shell": format!("{EXEC} --action-path o/r@{} {{0}}", "a".repeat(40)), "run": "true" }),
            json!({ "id": "stage-log", "shell": "bash", "run": format!("{EXEC} --stage log out/test.log") }),
        ],
        publish: vec![
            json!({ "if": format!("!cancelled() && steps.stage-log.outcome == 'success' && {SEAL}"), "uses": UPLOAD }),
            json!({ "if": format!("(always()) && {SEAL}"), "run": "gh pr comment" }),
        ],
        ..Default::default()
    };
    assert_eq!(problems(ok), Vec::<String>::new());
    // Without steps after the seal, a job may keep runner's sudo (as
    // PublishNeedsLock in gha.ncl allows).
    let no_lock = with_config(with(config(), json!({ "lockRunnerSudo": false })));
    assert_eq!(problems(no_lock), Vec::<String>::new());
    // What the compiler emits for these passes: a publish step's own
    // outputs, an event number, outcomes.
    let ok = publish(vec![
        json!({ "if": format!("(success()) && {SEAL}"), "id": "read", "run": "echo n=1 >>\"$GITHUB_OUTPUT\"" }),
        json!({ "if": format!("(steps.x.outcome == 'success') && {SEAL}"), "run": "echo ${{ steps.read.outputs.n }} ${{ github.event.pull_request.number }}" }),
    ]);
    assert_eq!(problems(ok), Vec::<String>::new());
}

#[test]
fn finds_each_way_out_of_the_sandbox() {
    let stage = |run: &str| json!({ "shell": "bash", "run": run });
    let cases = [
        (
            "an action mid-sandbox",
            sandboxed(vec![json!({ "uses": UPLOAD })]),
            "has uses, which a sandboxed step never has",
        ),
        (
            "a plain shell",
            sandboxed(vec![json!({ "shell": "bash", "run": "id" })]),
            "not the sandbox wrapper",
        ),
        (
            "a default shell",
            sandboxed(vec![json!({ "run": "id" })]),
            "not the sandbox wrapper",
        ),
        (
            "a stage that runs more",
            sandboxed(vec![stage(&format!("{EXEC} --stage x y; curl evil"))]),
            "not the sandbox wrapper",
        ),
        (
            "NODE_OPTIONS for the wrapper",
            sandboxed(vec![with(
                wrap("id"),
                json!({ "env": { "NODE_OPTIONS": "--require /tmp/x" } }),
            )]),
            "sets NODE_OPTIONS",
        ),
        (
            "a second seal id",
            sandboxed(vec![with(
                wrap("true"),
                json!({ "id": "runner-sandbox-seal" }),
            )]),
            "exactly one generated seal step",
        ),
        (
            "publish without the seal",
            publish(vec![json!({ "run": "id" })]),
            "without requiring the seal",
        ),
        (
            "publish escaping the seal",
            publish(vec![
                json!({ "if": format!("(always()) || (true) && {SEAL}"), "run": "id" }),
            ]),
            "without requiring the seal",
        ),
        (
            "publish as a template",
            publish(vec![
                json!({ "if": format!("${{{{ 'a' }}}} && {SEAL}"), "run": "id" }),
            ]),
            "without requiring the seal",
        ),
        (
            "a job env",
            job(json!({ "env": { "LD_PRELOAD": "/tmp/x.so" } })),
            "sets env",
        ),
        (
            "a job container",
            job(json!({ "container": "alpine" })),
            "sets container",
        ),
        (
            "job services",
            job(json!({ "services": { "db": { "image": "postgres" } } })),
            "sets services",
        ),
        (
            "job defaults",
            job(json!({ "defaults": { "run": { "shell": "bash" } } })),
            "sets defaults",
        ),
        (
            "a reusable workflow",
            job(json!({ "uses": "o/r/.github/workflows/x.yml@main" })),
            "sets uses",
        ),
        (
            "a key GitHub may add",
            job(json!({ "snapshot": "x" })),
            "sets snapshot",
        ),
        (
            "a workflow env",
            Workflow {
                top: json!({ "env": { "BASH_ENV": "/tmp/x" } }),
                ..Default::default()
            },
            "the workflow sets env",
        ),
        (
            "working-directory",
            sandboxed(vec![with(wrap("id"), json!({ "working-directory": "/" }))]),
            "has working-directory",
        ),
        (
            "a stage step with env",
            sandboxed(vec![with(
                stage(&format!("{EXEC} --stage x y")),
                json!({ "env": { "SHELLOPTS": "xtrace", "PS4": "$(id)" } }),
            )]),
            "has env, which a stage step never has",
        ),
        (
            "an unknown step key",
            sandboxed(vec![with(wrap("id"), json!({ "with": { "a": "b" } }))]),
            "has with",
        ),
    ];
    for (name, w, want) in cases {
        let found = problems(w);
        assert!(found.iter().any(|p| p.contains(want)), "{name}: {found:?}");
    }
}

#[test]
fn finds_changes_to_the_generated_steps() {
    type Edit = fn(&mut Vec<Value>);
    let edits: &[(&str, Edit, &str)] = &[
        (
            "a modified enter step",
            |st| {
                let run = format!(
                    "{}\nrequire('child_process').execSync('echo pwned');",
                    st[2]["run"].as_str().unwrap()
                );
                st[2]["run"] = run.into();
            },
            "0 generated steps entering the sandbox",
        ),
        (
            "no enter step",
            |st| {
                st.remove(2);
            },
            "0 generated steps entering the sandbox",
        ),
        (
            "an enter step that can be skipped",
            |st| {
                st[2]["if"] = "false".into();
            },
            "0 generated steps entering the sandbox",
        ),
        (
            "a missing secure-host step",
            |st| {
                st.remove(1);
            },
            "isn't the generated secure-host step",
        ),
        (
            "a modified secure-host step",
            |st| {
                let run = format!("{}\n", st[1]["run"].as_str().unwrap());
                st[1]["run"] = run.into();
            },
            "isn't the generated secure-host step",
        ),
        (
            "a secure-host step allowed to fail",
            |st| {
                st[1]["continue-on-error"] = true.into();
            },
            "isn't the generated secure-host step",
        ),
        (
            "a modified seal",
            |st| {
                st.last_mut().unwrap()["run"] = format!("{EXEC} --seal || true").into();
            },
            "exactly one generated seal step",
        ),
        (
            "a seal that can be skipped",
            |st| {
                st.last_mut().unwrap()["if"] = "false".into();
            },
            "exactly one generated seal step",
        ),
        (
            "a seal with a timeout",
            |st| {
                st.last_mut().unwrap()["timeout-minutes"] = 0.into();
            },
            "exactly one generated seal step",
        ),
        (
            "a seal before entering",
            |st| {
                let seal = st.pop().unwrap();
                st.insert(2, seal);
            },
            "exactly one generated seal step",
        ),
    ];
    for (name, edit, want) in edits {
        let mut w = Workflow::default().build();
        edit(w["jobs"]["t"]["steps"].as_array_mut().unwrap());
        let found = check_workflow(&w, &RUNTIME).join("\n");
        assert!(found.contains(want), "{name}: {found}");
    }
}

#[test]
fn finds_configs_other_than_the_compilers() {
    let after = json!({ "if": format!("(success()) && {SEAL}"), "run": "id" });
    let cases = [
        (
            "the runner as sandbox user",
            json!({ "user": "runner" }),
            "sandbox user \"runner\"",
            vec![],
        ),
        (
            "root as sandbox user",
            json!({ "user": "root" }),
            "sandbox user \"root\"",
            vec![],
        ),
        (
            "no sudo lock with publish steps",
            json!({ "lockRunnerSudo": false }),
            "lockRunnerSudo false with steps after the seal",
            vec![after],
        ),
        (
            "another workspace",
            json!({ "workspace": "/home/runner" }),
            "hands off \"/home/runner\"",
            vec![],
        ),
        (
            "a hand-off out of the workspace",
            json!({ "handoff": { "workspace": "tracked", "include": ["../x"] } }),
            "the hand-off",
            vec![],
        ),
        (
            "an unknown hand-off mode",
            json!({ "handoff": { "workspace": "some", "include": [] } }),
            "the hand-off",
            vec![],
        ),
        ("an extra key", json!({ "extra": 1 }), "CONFIG keys", vec![]),
    ];
    for (name, change, want, publish) in cases {
        let w = Workflow {
            config: with(config(), change),
            publish,
            ..Default::default()
        };
        let found = problems(w).join("\n");
        assert!(found.contains(want), "{name}: {found}");
    }
}

/// The review's probe cases, and the values the compiler's lints check:
/// each must be found.
#[test]
fn finds_what_the_compilers_contracts_refuse() {
    let sha = "a".repeat(40);
    let pubstep = |step: Value| {
        publish(vec![with(
            json!({ "if": format!("(success()) && {SEAL}") }),
            step,
        )])
    };
    let cases: Vec<(&str, Value)> = vec![
        ("runner as user without sudo lock", Workflow { config: with(config(), json!({ "user": "runner", "lockRunnerSudo": false, "workspace": "/home/runner" })), publish: vec![json!({ "if": format!("(always()) && {SEAL}"), "run": "x" })], ..Default::default() }.build()),
        ("an empty CONFIG", with_config(json!({})).build()),
        ("a stage path with ..", sandboxed(vec![json!({ "shell": "bash", "run": format!("{EXEC} --stage x ../../home/runner/.credentials") })]).build()),
        ("an unknown key on a sandboxed step", sandboxed(vec![with(wrap("sleep 1000"), json!({ "background": true }))]).build()),
        ("OPENSSL_CONF for the wrapper's node", sandboxed(vec![with(wrap("id"), json!({ "env": { "OPENSSL_CONF": "/tmp/x.cnf", "RUNNER_SANDBOX_ENV": "OPENSSL_CONF" } }))]).build()),
        ("an action path with ..", sandboxed(vec![json!({ "shell": format!("{EXEC} --action-path o/../../x@{sha} {{0}}"), "run": "id" })]).build()),
        ("job permissions as a string", job(json!({ "permissions": "write-all" })).build()),
        ("a job environment", job(json!({ "environment": "prod" })).build()),
        ("workflow permissions as a string", Workflow { top: json!({ "permissions": "write-all" }), ..Default::default() }.build()),
        ("jobs as a string", json!({ "jobs": "abc" })),
        ("a workflow that isn't a map", json!(["jobs"])),
        ("a step that isn't a map", sandboxed(vec![json!("id")]).build()),
        ("a hand-off include with an expression", with_config(with(config(), json!({ "handoff": { "workspace": "tracked", "include": ["${{ github.event.issue.title }}"] } }))).build()),
        ("a secret in a sandboxed run", sandboxed(vec![wrap("echo ${{ secrets.X }}")]).build()),
        ("the token in a sandboxed env", sandboxed(vec![with(wrap("id"), json!({ "env": { "T": "${{ github.token }}", "RUNNER_SANDBOX_ENV": "T" } }))]).build()),
        ("github.* in a sandboxed step", sandboxed(vec![wrap("echo '${{ join(github.*, ',') }}'")]).build()),
        ("an unpinned publish action", pubstep(json!({ "uses": "evil/x@main" })).build()),
        ("a publish step with an unknown key", pubstep(json!({ "run": "id", "services": {} })).build()),
        ("a publish step with run and uses", pubstep(json!({ "run": "id", "uses": format!("o/r@{sha}") })).build()),
        ("sandbox outputs in a publish run", pubstep(json!({ "run": "echo ${{ steps.out.outputs.v }}" })).build()),
        ("sandbox outputs in a publish with", pubstep(json!({ "uses": format!("o/r@{sha}"), "with": { "x": "${{ toJSON(steps) }}" } })).build()),
        ("sandbox outputs in working-directory", pubstep(json!({ "run": "ls", "working-directory": "${{ steps.out.outputs.dir }}" })).build()),
        ("event text in a publish run", pubstep(json!({ "run": "echo '${{ github.event.issue.title }}'" })).build()),
        ("event text re-expanded from env", pubstep(json!({ "run": "echo '${{ env.T }}'", "env": { "T": "${{ github.head_ref }}" } })).build()),
        ("event text in github-script", pubstep(json!({ "uses": format!("actions/github-script@{sha}"), "with": { "script": "core.info('${{ github.event.comment.body }}')" } })).build()),
    ];
    for (name, w) in cases {
        assert!(
            !check_workflow(&w, &RUNTIME).is_empty(),
            "{name}: not found"
        );
    }
}

#[test]
fn every_workflow_file_is_compiled_or_a_listed_exception() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join(".github/workflows")).unwrap();
    std::fs::create_dir_all(root.join("workflows")).unwrap();
    std::fs::create_dir_all(root.join("runtime")).unwrap();
    for (name, text) in RUNTIME.iter() {
        std::fs::write(root.join("runtime").join(name), text).unwrap();
    }
    let put = |rel: &str, text: &str| std::fs::write(root.join(rel), text).unwrap();
    put(".github/workflows/ci.yml", "on: push\n");
    put(".github/workflows/extra.YML", "on: push\n");
    put(".github/workflows/orphan.lock.yml", "on: push\n");
    put(
        ".github/uncompiled-workflows",
        "# comment\nci.yml  # our own checks\nnoreason.yml\ngone.yml  # was here\n",
    );
    let found = check_tree(&Repo::open(root).unwrap()).unwrap().join("\n");
    for want in [
        "extra.YML isn't compiled",
        "orphan.lock.yml has no source",
        "\"noreason.yml\" has no \"# reason\"",
        "lists gone.yml, which doesn't exist",
    ] {
        assert!(found.contains(want), "{want}: {found}");
    }
    assert!(!found.contains("ci.yml isn't compiled"), "{found}");
}
