# workflow-compiler

Compile GitHub Actions jobs so that everything after a privileged setup
phase runs as an unprivileged user, in a way no later step can undo.

The Actions runner runs every step as its own `runner` user, which holds the
job's tokens and, on hosted runners, has passwordless sudo. Nothing a step
can set (`defaults.run.shell`, `PATH`, `BASH_ENV`, a job container) stops a
later step from running as `runner` again. What decides how each step runs
is the workflow file, so this project generates that file: a job is written
in [nickel](https://nickel-lang.org/) as two phases, and the compiler emits
a `.lock.yml` in which the second phase has no way to leave the sandbox.
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
   sandbox, which the sandbox can read but not change.
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
   left behind (before the next step too) and hands back only
   `name=value` outputs and the step summary. A `stage` step
   (`{ stage = { name = "log", path = "test.log" } }`) is how the sandbox
   hands out a file or directory: the wrapper's root side copies it out of
   the workspace, refusing symlinks, to `gha.staged "log"`. An `upload`
   step stages the path and uploads that copy as an artifact. `steps` has
   no actions yet; pure ones will run in the sandbox through a shim
   ([#16](https://github.com/cgwalters-forge/workflow-compiler/issues/16)).
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

`lib/agent-run.ncl` builds a whole agent job from a prompt;
`workflows/agent-review.ncl` is the complete source of one:

```nickel
jobs.review = agent_run { prompt = "/etc/agent-share/agentskills/review.md" }
```

It checks out the repository, shares `agentskills/`, installs the agent,
and runs it in the sandbox on a prompt nothing in the sandbox could have
rewritten. It is a compiler macro rather than a composite action because a
composite action runs as `runner` and can't constrain the job around it
([#4](https://github.com/cgwalters-forge/workflow-compiler/issues/4)).

## Building

```sh
node compile.mjs          # write .github/workflows/*.lock.yml
node compile.mjs --check  # fail on a stale lock file or an accepted reject test
```

It needs `nickel` on `PATH` (or `$NICKEL`); `ci.yml` shows how to fetch the
pinned release. Sandboxed steps need `run0`, so systemd 256 or later:
ubuntu-26.04 and RHEL 10, not ubuntu-24.04 ([#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6)).

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
- `workflows/agent-review.ncl` on hosted ubuntu-26.04, with a stub agent
  (`runtime/agent-stub.sh`) that reads its prompt from the share and fails
  if it can rewrite it, use sudo or see the job's credentials.

Next, as issues in this repository (sub-issues of
[tracker#88](https://github.com/cgwalters-forge/tracker/issues/88),
the task compiler that will produce this compiler's input):

- [#7](https://github.com/cgwalters-forge/workflow-compiler/issues/7) run a real agent through the devspace harness (P1)
- [#4](https://github.com/cgwalters-forge/workflow-compiler/issues/4) agent-run as a compiler macro or a composite action (P1)
- [#16](https://github.com/cgwalters-forge/workflow-compiler/issues/16) reuse external actions: the shim running pure actions in the sandbox (the hand-off and `publish_steps` are done) (P1)
- [#5](https://github.com/cgwalters-forge/workflow-compiler/issues/5) use `cgwalters-forge/actions/secure-host-setup` (P1)
- [#13](https://github.com/cgwalters-forge/workflow-compiler/issues/13) the stale-lock check doesn't prove every workflow is compiled (P1)
- [#8](https://github.com/cgwalters-forge/workflow-compiler/issues/8) using the compiler from other repositories (P1)
- [#17](https://github.com/cgwalters-forge/workflow-compiler/issues/17) workflow commands on a sandboxed step's standard output (P1)
- [#19](https://github.com/cgwalters-forge/workflow-compiler/issues/19) `runner_steps` that execute a pull request's checkout (P1)
- [#20](https://github.com/cgwalters-forge/workflow-compiler/issues/20) caches saved from sandbox output and restored in `runner_steps` (P1)
- [#25](https://github.com/cgwalters-forge/workflow-compiler/issues/25) expressions from issues, comments and pull requests in privileged `run:` steps (P1)
- [#26](https://github.com/cgwalters-forge/workflow-compiler/issues/26) the stale-lock check runs the pull request's own compiler (P1)
- [#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27) local sockets and localhost services reachable from the sandbox (P1)
- [#14](https://github.com/cgwalters-forge/workflow-compiler/issues/14) prompts from a trusted ref for PR-triggered agents (P2)
- [#3](https://github.com/cgwalters-forge/workflow-compiler/issues/3) embed `nickel-lang-core` in a Rust front end, replacing the pinned `nickel` binary (decided, P2)
- [#2](https://github.com/cgwalters-forge/workflow-compiler/issues/2) post-steps of `runner_steps` actions (P2)
- [#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6) ubuntu-24.04, which has no `run0` (P2)
- [#9](https://github.com/cgwalters-forge/workflow-compiler/issues/9) replacing the runner's last sudo rule (P2)
- [#10](https://github.com/cgwalters-forge/workflow-compiler/issues/10) blocking the cloud metadata service for the sandbox (P2)
- [#11](https://github.com/cgwalters-forge/workflow-compiler/issues/11) embedding `share.cjs` once per job (P2)
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
