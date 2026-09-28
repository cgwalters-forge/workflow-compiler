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
The background, the runner source analysis and the alternatives considered
are in the [design gist](https://gist.github.com/cgwalters-bot/2368b70fa941386025467421ce38b5b6).

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
      { run = "make check CONFIG=/etc/agent-share/config" },
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
   creates `runner-sandbox`, gives it a copy of the workspace, and leaves
   `runner` a single sudo rule, for the step wrapper.
4. its `steps`, each `run:` step with the wrapper as its shell
   (`runtime/exec.cjs` as runner, `runtime/run.cjs` as root). The wrapper
   runs the script with `run0` as `runner-sandbox`, in a logind session of
   its own, with a fixed environment, then stops every process the step
   left behind and hands back only `name=value` outputs and the step
   summary. `uses:` steps must be in `sandbox.allowed_actions`.

The contracts in `lib/gha.ncl` are closed records, so whatever the compiler
can't keep sandboxed is a compile error: a step `shell:` or
`working-directory`, a job `container:` or `defaults`, an unpinned action,
a secret or `github.token` in a sandboxed step or a share. Each such case
has a source in `tests/reject/` that must fail with its message.

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

- compiling `runner_steps`, `share` and `steps` to lock files, with the
  stale-lock check and the reject tests;
- `workflows/sandbox-test.ncl` on hosted ubuntu-26.04: steps run as
  `runner-sandbox` in a logind session, `sudo` is refused, the job's tokens,
  `Runner.Worker`'s environment and `/home/runner` are out of reach, shares
  are readable but not writable, and escape attempts (symlinked outputs,
  multi-line outputs, processes left behind, a symlink shared from the
  checkout) fail;
- `workflows/agent-review.ncl` on hosted ubuntu-26.04, with a stub agent
  (`runtime/agent-stub.sh`) that reads its prompt from the share and fails
  if it can rewrite it, use sudo or see the job's credentials.

Next, as issues in this repository (sub-issues of
[tracker#88](https://github.com/cgwalters-forge/tracker/issues/88),
the task compiler that will produce this compiler's input):

- [#7](https://github.com/cgwalters-forge/workflow-compiler/issues/7) run a real agent through the devspace harness (P1)
- [#4](https://github.com/cgwalters-forge/workflow-compiler/issues/4) agent-run as a compiler macro or a composite action (P1)
- [#5](https://github.com/cgwalters-forge/workflow-compiler/issues/5) use `cgwalters-forge/actions/secure-host-setup` (P1)
- [#1](https://github.com/cgwalters-forge/workflow-compiler/issues/1) sandboxed step outputs reaching `with:` of allowlisted actions (P1)
- [#8](https://github.com/cgwalters-forge/workflow-compiler/issues/8) using the compiler from other repositories (P1)
- [#3](https://github.com/cgwalters-forge/workflow-compiler/issues/3) nickel packaging, or a Rust front end (P2)
- [#2](https://github.com/cgwalters-forge/workflow-compiler/issues/2) post-steps of `runner_steps` actions (P2)
- [#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6) ubuntu-24.04, which has no `run0` (P2)
- [#9](https://github.com/cgwalters-forge/workflow-compiler/issues/9) replacing the runner's last sudo rule (P2)
- [#10](https://github.com/cgwalters-forge/workflow-compiler/issues/10) blocking the cloud metadata service for the sandbox (P2)
- [#11](https://github.com/cgwalters-forge/workflow-compiler/issues/11) embedding `share.cjs` once per job (P2)

## License

MIT OR Apache-2.0; see [LICENSE](LICENSE).
