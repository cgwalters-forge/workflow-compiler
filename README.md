# workflow-compiler

Compile GitHub Actions jobs so that everything after a privileged setup
phase runs as an unprivileged user, in a way no later step can undo.

The Actions runner runs every step as its own `runner` user, which holds the
job's tokens and, on hosted runners, has passwordless sudo. Nothing a step
can set (`defaults.run.shell`, `PATH`, `BASH_ENV`, a job container) stops a
later step from running as `runner` again. What decides how each step runs
is the workflow file, so this project generates that file: a job is written
in [nickel](https://nickel-lang.org/) as two phases, and the compiler (Rust,
embedding nickel) emits a `.lock.yml` in which the second phase has no
way to leave the sandbox.
What it guarantees, against whom, and the tests that prove it are in
[docs/requirements.md](docs/requirements.md). The background, the runner
source analysis and the alternatives considered are in the
[design gist](https://gist.github.com/cgwalters-bot/2368b70fa941386025467421ce38b5b6).

## How a job is written

```nickel
let gha = import "../lib/gha.ncl" in
gha.compile {
  name = "Build",
  on = { pull_request = {} },
  jobs.build = {
    "runs-on" = "ubuntu-26.04",
    runner_steps = [                  # as runner, with sudo
      { uses = "actions/checkout@<sha>", with = { persist-credentials = false } },
      { share = { name = "config", path = "ci/config.toml" } },
    ],
    steps = [                         # as runner-sandbox, no sudo
      { run = "make check CONFIG=/etc/agent-share/config >report.txt" },
      { upload = { name = "report", path = "report.txt" } },
    ],
    publish_steps = [                 # as runner, no sudo, reading staged outputs
      {
        run = m%"gh pr comment "$PR" --body-file %{gha.staged "report"}/report.txt"%,
        env = { PR = "${{ github.event.pull_request.number }}", GH_TOKEN = "${{ github.token }}" },
      },
    ],
  },
}
```

The compiler turns each job into:

1. its `runner_steps`, as written. A `share` step publishes a file or
   directory as a root-owned, world-readable copy at
   `/etc/agent-share/<name>`: the channel from the privileged phase to the
   sandbox, which the sandbox can read but not change. It compiles to the
   `sandbox-share` action from
   [cgwalters-forge/actions](https://github.com/cgwalters-forge/actions),
   where the compiler's generated steps move from `runtime/`, used at the
   commit `SHARED_ACTIONS` in `lib/gha.ncl` pins.
2. a generated step that secures the host (`runtime/secure-host.cjs`;
   to be replaced by `cgwalters-forge/actions/secure-host-setup`, see [#5](https://github.com/cgwalters-forge/workflow-compiler/issues/5)).
3. a generated step that enters the sandbox (`runtime/install.cjs`): it
   creates `runner-sandbox`, hands it the workspace (`handoff.workspace`:
   by default only what git tracks, plus `handoff.include`; refused if it
   holds credentials, `runtime/handoff.cjs`), and leaves `runner` a single
   sudo rule, for the step wrapper.
4. its `steps`, each `run:` step with the wrapper as its shell
   (`runtime/exec.cjs` as runner, `runtime/run.cjs` as root). The wrapper
   runs the script with `run0` as `runner-sandbox`, in a logind session of
   its own, with a fixed environment, then stops every process the step
   left behind (before the next step too) and hands back only its
   outputs and step summary. A `stage` step
   (`{ stage = { name = "log", path = "test.log" } }`) is how the sandbox
   hands out a file or directory: the wrapper's root side copies it out of
   the workspace, refusing symlinks, to `gha.staged "log"`. An `upload`
   step stages the path and uploads that copy as an artifact. A `uses:`
   step runs the action in the sandbox, through the shim described below.
5. a generated step that seals the sandbox: it stops the sandbox's
   processes for good and makes its workspace, home and leftovers
   unreadable to runner.
6. its `publish_steps`, as runner (still without sudo) and with the job's
   tokens, for credentialed actions: upload-artifact for the `upload`
   steps, then the job's own. They can read only what was staged, and the
   compiler refuses expressions in their `run`, `with` or `env` that use a
   sandboxed step's outputs, which are strings the sandbox chose.

The contracts in `lib/gha.ncl` are closed records, so whatever the compiler
can't keep sandboxed is a compile error: a step `shell:` or
`working-directory`, a job `container:` or `defaults`, an unpinned action,
or a sandboxed step `env:` that would change how the runner side of the
wrapper starts (`NODE_*`, `LD_*`, `PATH` and the like). Each such case has
a source in `tests/reject/` that must fail with its message.

The compiler also rejects expressions naming a secret or the job's token
in a sandboxed step or a share, in any case and in the spellings in
`tests/reject/` (`secrets['X']`, `toJSON(github)`, `format(...)`). That is
a lint against mistakes, not a boundary: a value a runner step put in
`GITHUB_ENV` still reaches a sandboxed step through `env.X`, for one. The
boundary is the uid: the sandbox can't read the runner's processes, files
or tokens, whatever the workflow text says.

## Actions in the sandbox

A `uses:` step in `steps` runs the action as the sandbox user, not as
runner. A generated step before the sandbox is entered fetches each such
action at its pinned commit into a root-owned directory under
`/opt/runner-sandbox/actions` (`runtime/fetch-actions.cjs`), checking its
`action.yml` against `actions.lock.json`. The sandboxed step then runs the
action's entry point with the host's node (`runtime/launch.cjs`),
with its inputs as `INPUT_*` and its own `GITHUB_OUTPUT`, `GITHUB_ENV`,
`GITHUB_PATH`, `GITHUB_STATE` and step summary files, which the wrapper
reads back like a `run:` step's. Outputs go to the runner, re-encoded;
environment and `PATH` changes apply to later sandboxed steps only; state
goes to the action's post step, which runs after the last sandboxed step.
`GITHUB_WORKSPACE`, `RUNNER_TEMP` and `RUNNER_TOOL_CACHE` are the
sandbox's own directories, so setup actions install into a tool cache the
sandbox owns. A composite action is expanded at compile time into sandboxed
steps, with `inputs.*`, `github.action_path` and its step ids rewritten
into the caller's job.

What an action's metadata says is its author's text, not the workflow
author's, yet it ends up in the lock file, where Actions evaluates its
expressions with the job's contexts. So the compiler holds it to
allowlists. Names and entry points must be plain. Expressions in input
defaults, composite steps' `run`, `env`, `with`, `if` and names, and
outputs may use only literals, operators, a few functions, the action's
own inputs and steps, and contexts that hold no credentials
(`github.repository`, `github.sha`, `runner.os`, the sandbox's paths and
the like). The caller's steps, `env`, `vars`, `needs`, `secrets`,
`github.token` and `github.event` are all out. The step's env names never
become the runner-side wrapper's own variables: each value goes under a
fixed name, and `exec.cjs` gives it its name in the request, which the
root side checks again. Fixtures in `tests/actions/` (locked as
`wfc-test/<name>`) are hostile actions that the reject tests require to
fail, and well-behaved ones whose compiled output `tests/accept/` checks.

`wfc compile` locks the metadata of every such action: nickel can't fetch
anything, so it adds an action to `actions.lock.json` when a source needs
one, and `wfc check` verifies each entry against the `action.yml` it holds.
`workflows/actions-test.ncl` runs DavidAnson/markdownlint-cli2-action,
actions/setup-node (Node 22 into the sandbox's tool cache) and
crate-ci/typos (a composite action) on hosted ubuntu-26.04.

Some actions can't run this way, and the compiler says so:

- actions that need the job's credentials: upload-artifact,
  download-artifact and the cache actions, which the compiler knows by
  name, and any action whose inputs default to `github.token` and that
  fails without one (the default is dropped, so it sees an empty token);
  these go in `publish_steps`, reading staged outputs;
- Docker container actions: the sandbox has no container engine running as
  root ([#31](https://github.com/cgwalters-forge/workflow-compiler/issues/31));
- actions with a `pre` entry point;
- actions whose text uses a context outside the allowlist above (an input
  default naming the token or secrets is dropped instead, so the action
  sees an empty input);
- composite actions whose steps use another shell than bash or sh, set
  `working-directory`, use an action that isn't pinned by commit or is a
  local `./` path, or pass `inputs` in a form the compiler can't rewrite
  (an input that mixes text and expressions);
- actions that assume they run as runner: writing outside the workspace,
  `RUNNER_TEMP` and `RUNNER_TOOL_CACHE`, using sudo, or reading the event
  payload (`GITHUB_EVENT_PATH` isn't set in the sandbox). Those belong in
  `runner_steps` as setup actions, if they need no sandbox.

Actions run with the host's root-owned node rather than the runner's
bundled node20 or node24.

`lib/agent-run.ncl` builds a whole agent job from a prompt;
`workflows/agent-review.ncl` is the complete source of one:

```nickel
jobs.review = agent_run { prompt = "/etc/agent-share/agentskills/review.md" }
```

It checks out the repository and shares `agentskills/`. It then runs the
agent in the sandbox, on a prompt nothing in the sandbox could have
rewritten, through bot-harness, the Agent Client Protocol client from
cgwalters-devspace-sandbox. bot-harness records the transcript, answers
permission requests from its policy, enforces the timeout and budget, and
writes the task layer's `summary.json` (`runtime/agent-run.cjs`). The run
summary and transcript come out as `agent-run` and `agent-transcript`
artifacts, through the stage, seal and publish phases.

Those harness features hold only for an agent that cooperates. The agent
runs as the same user as bot-harness, so a hostile one can skip
permission requests, kill or outlive the harness, and rewrite what it
wrote. So the summary and transcript are the agent's own data, as
untrusted as anything else from the sandbox. What bounds a hostile agent
is the sandbox: the step's `timeout-minutes`, the agent's timeout plus a
few minutes' grace, after which the wrapper stops every process of the
step, and the uid boundary. Spend caps will be praxis's, not the
harness's (#36). The scripted agent also tries the escapes the old stub
checked for: rewriting its prompt, adding to a share, sudo, reading
`Runner.Worker`'s environment or the runner's home, and seeing the job's
tokens. `ci` requires every one to have failed, from the transcript.

bot-harness runs inside the sandbox together with the agent. It holds
nothing the agent may not see, so unlike in devspace-sandbox's `agent.yml`
it needs no sudo to start the agent as another user. The privileged phase
builds it from a pinned commit of cgwalters-devspace-sandbox, as a setup
step. That takes a few minutes, but it needs no release infrastructure. It
isn't a shimmed action, because it isn't one. The better form is a release
artifact pinned by sha256, which the compiler would download and check,
once that repository publishes one. Only the scripted `fake` agent runs
for now; `fake_script` appends a source's own actions to its session
(say, execute, read, write), to stand in for a model's work in a demo or
a test. How real inference plugs in (praxis run tokens, registered in the
privileged phase, handed to the sandbox alone, ended in the publish phase)
is [#36](https://github.com/cgwalters-forge/workflow-compiler/issues/36).

`agent_run` is a compiler macro rather than a composite action because a
composite action runs as `runner` and can't constrain the job around it
([#4](https://github.com/cgwalters-forge/workflow-compiler/issues/4)).

## Building

The compiler is `wfc`, a Rust program that embeds nickel
(`nickel-lang-core`) and evaluates the sources in-process:

```sh
cargo run -- compile  # write .github/workflows/*.lock.yml
cargo run -- check    # fail on a stale lock file, an accepted reject test,
                      # or a workflow that isn't compiled (see below)
cargo test            # wfc's own tests, and `check` of this repository
```

`check` also checks every workflow in `.github/workflows/`: a lock file
must have a source and the compiled shape (`src/shape.rs`: the generated
enter and seal steps, byte for byte, and nothing between them that
leaves the wrapper), and anything else must be listed, with its reason,
in `.github/uncompiled-workflows`. `trusted-check.yml` runs the same
checks on every pull request with the base branch's code, the pull
request's tree only as data, and needs a maintainer's `compiler-change`
label on pull requests that change the compiler itself (R14).

A `run` script of more than 10 lines doesn't go inline in a source: it
goes in a file of its own, imported as text (`run = import
"sandbox-test/read-shares.sh" as 'Text`), and the compile refuses a
longer inline one. `check` lints every `.sh` file a source imports: it
must pass `bash -n` and, when it is installed (as on the hosted runners
ci uses), shellcheck, and must hold no `${{ }}` expression, which Actions
would expand into the script's code; values go in the step's `env:`.

`ci` also runs [zizmor](https://docs.zizmor.sh/) on every workflow, lock
files included, the way gh-aw vendors it: its release image pinned by
digest, offline, failing on findings of medium severity or worse, with
the reviewed exceptions in `.github/zizmor.yml`. It covers what a
workflow's YAML shows (template injection, unpinned or mismatched `uses:`,
excessive permissions, persisted credentials, cache poisoning, dangerous
triggers) but parses no shell, so scripts are left to `check`'s own lint.

`compile` also fetches new actions' metadata from GitHub; `check` never
uses the network. `trusted-check` compiles a pull request's sources (R14
in [docs/requirements.md](docs/requirements.md)), and nickel resolves
their imports against any path the job can read; confining that step is
[#57](https://github.com/cgwalters-forge/workflow-compiler/issues/57).

`nickel-lang-core` is outside nickel's 1.0 stability promise, so
`Cargo.toml` pins it exactly; a bump can change the lock files, so it
goes with `cargo run -- compile`. wfc builds with the toolchain in
`rust-toolchain.toml`. Sandboxed steps need `run0`, so systemd 256 or
later: ubuntu-26.04, which a job runs on unless it sets `runs-on`, and
RHEL 10, not ubuntu-24.04
([#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6)).

## Updating pinned versions

Everything a job depends on is pinned, and [Renovate](https://docs.renovatebot.com/)
keeps the pins current, with the managers in `renovate.json`. Like
[gh-aw](https://github.com/github/gh-aw/blob/main/docs/src/content/docs/reference/compilation-process.md)
does for its lock files, updates go to the sources and the lock files are
recompiled from them; a bot never edits a lock file. The rules:

- An action is pinned in a source or in `lib/` as the string
  `"owner/repo[/path]@<full commit sha>"`, followed on its line by a
  comment naming what the commit is: a release tag (`# v7.0.1`), which
  Renovate follows through the repository's tags, or `# main`, a branch,
  which it follows commit by commit. `wfc check` refuses a pin without
  that comment. The compiler's own actions come from one such pin,
  `SHARED_ACTIONS` in `lib/gha.ncl`.
- A runner image is an `"ubuntu-NN.NN"` string; `DEFAULT_RUNNER` in
  `lib/gha.ncl` is the one jobs get unless they set `runs-on`. Renovate
  bumps these through its GitHub runners datasource.
- The hand-written workflows (`ci.yml`, `trusted-check.yml`) are updated
  by Renovate's own GitHub Actions manager, and `.github/workflows/*.lock.yml`
  are ignored: they are outputs.
- After a bump, `wfc check` fails until `cargo run -- compile` has
  regenerated the lock files and locked the new commit's `action.yml` in
  `actions.lock.json`, so a bump can't merge without its compiled result.
  Renovate's hosted app can't run the compiler (`postUpgradeTasks` needs a
  self-hosted Renovate), so a maintainer runs it on the Renovate branch and
  pushes the result.
- `nickel-lang-core` is pinned exactly in `Cargo.toml` and a bump of it
  can change the output, so it goes the same way.
- Dependabot can't read the sources, and its GitHub Actions updater edits
  any YAML file in `.github/workflows/`, lock files included. A repository
  that uses it for its other workflows excludes the lock files
  (`exclude-paths: [".github/workflows/*.lock.yml"]`); a Dependabot change
  to a lock file fails `wfc check` and is closed, not merged.

## Status and roadmap

This is a proof of concept. What works now, checked by `ci` on every pull
request:

- compiling `runner_steps`, `share`, `steps`, `stage`/`upload` and
  `publish_steps` to lock files, with the stale-lock check and the reject
  tests, and unit tests of the workspace hand-off (`tests/runtime/`);
- `workflows/sandbox-test.ncl` on hosted ubuntu-26.04: steps run as
  `runner-sandbox` in a logind session, `sudo` is refused, the job's tokens,
  `Runner.Worker`'s environment and `/home/runner` are out of reach, shares
  are readable but not writable, and escape attempts (symlinked outputs,
  multi-line outputs, processes left behind, a symlink shared from the
  checkout, uploads through symlinks to `/proc/self/environ` and the
  runner's files, a step that times out with processes left behind, cron,
  at and lingering) fail, and `ci` checks that no artifact holds the token;
  the sandbox gets only the tracked and included files; and after the
  seal, publish steps read the staged report as runner but not the
  sandbox's workspace, home or leftovers in `/dev/shm`;
- `workflows/actions-test.ncl` on hosted ubuntu-26.04: marketplace actions
  run in the sandbox through the shim (a linter, setup-node, and the
  composite crate-ci/typos), and `GITHUB_ENV`, `GITHUB_PATH` and multi-line
  outputs work there without reaching the runner;
- `workflows/agent-review.ncl` on hosted ubuntu-26.04: bot-harness, built
  at a pinned commit in the privileged phase, runs its scripted ACP agent
  in the sandbox on a prompt from a share, and `ci` checks the
  `agent-run` (summary.json, summary.md, condensed.log) and
  `agent-transcript` (acp.jsonl) artifacts that come out of the publish
  phase.

Next, as issues in this repository (sub-issues of
[tracker#88](https://github.com/cgwalters-forge/tracker/issues/88),
the task compiler that will produce this compiler's input):

- [#36](https://github.com/cgwalters-forge/workflow-compiler/issues/36) `agent_run` with real inference through praxis run tokens (P1)
- [#4](https://github.com/cgwalters-forge/workflow-compiler/issues/4) agent-run as a compiler macro or a composite action (P1)
- [#5](https://github.com/cgwalters-forge/workflow-compiler/issues/5) use `cgwalters-forge/actions/secure-host-setup` (P1)
- [#45](https://github.com/cgwalters-forge/workflow-compiler/issues/45) the enter step's runtime as a shared `sandbox-enter` action (P1)
- [#47](https://github.com/cgwalters-forge/workflow-compiler/issues/47) repinning `SHARED_ACTIONS` once cgwalters-forge/actions#7 merges (P1)
- [#8](https://github.com/cgwalters-forge/workflow-compiler/issues/8) using the compiler from other repositories (P1)
- [#19](https://github.com/cgwalters-forge/workflow-compiler/issues/19) `runner_steps` that execute a pull request's checkout (P1)
- [#20](https://github.com/cgwalters-forge/workflow-compiler/issues/20) caches saved from sandbox output and restored in `runner_steps` (P1)
- [#25](https://github.com/cgwalters-forge/workflow-compiler/issues/25) expressions from issues, comments and pull requests in privileged `run:` steps (P1)
- [#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27) local sockets and localhost services reachable from the sandbox (P1)
- [#14](https://github.com/cgwalters-forge/workflow-compiler/issues/14) prompts from a trusted ref for PR-triggered agents (P2)
- [#2](https://github.com/cgwalters-forge/workflow-compiler/issues/2) post-steps of `runner_steps` actions (P2)
- [#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6) ubuntu-24.04, which has no `run0` (P2)
- [#46](https://github.com/cgwalters-forge/workflow-compiler/issues/46) `fetch-actions.cjs` as a shared action (P2)
- [#48](https://github.com/cgwalters-forge/workflow-compiler/issues/48) recompiling the lock files on Renovate branches (P2)
- [#49](https://github.com/cgwalters-forge/workflow-compiler/issues/49) literal action defaults, which zizmor flags as obfuscation (P2)
- [#9](https://github.com/cgwalters-forge/workflow-compiler/issues/9) replacing the runner's last sudo rule (P2)
- [#10](https://github.com/cgwalters-forge/workflow-compiler/issues/10) blocking the cloud metadata service for the sandbox (P2)
- [#18](https://github.com/cgwalters-forge/workflow-compiler/issues/18) a size cap on staged outputs (P2)
- [#21](https://github.com/cgwalters-forge/workflow-compiler/issues/21) checking the repository settings the guarantee depends on (P2)
- [#22](https://github.com/cgwalters-forge/workflow-compiler/issues/22) restricting the sandbox's network egress (P2)
- [#28](https://github.com/cgwalters-forge/workflow-compiler/issues/28) the enter step assumes an ephemeral runner (P2)
- [#29](https://github.com/cgwalters-forge/workflow-compiler/issues/29) explicit token permissions (P2)
- [#30](https://github.com/cgwalters-forge/workflow-compiler/issues/30) what pinned actions pull in (P2)
- [#31](https://github.com/cgwalters-forge/workflow-compiler/issues/31) Docker container actions under rootless podman in the sandbox (P2)
- [#32](https://github.com/cgwalters-forge/workflow-compiler/issues/32) the runner's loss of root depends on an opt-out and an untested setting (P2)

## License

MIT OR Apache-2.0; see [LICENSE](LICENSE).
