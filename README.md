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
   left behind (before the next step too) and hands back only
   `name=value` outputs and the step summary. `uses:` steps must be in
   `sandbox.allowed_actions`, and run as runner. An `upload` step
   (`{ upload = { name = "log", path = "test.log" } }`) is how the sandbox
   publishes an artifact: the wrapper's root side copies the path out of
   the workspace, refusing symlinks, and upload-artifact reads only that
   copy. Pointing an allowlisted action at a path the sandbox can write
   would let it read, as runner, whatever the sandbox links there.

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

The compiler is `wfc`, a Rust program that embeds nickel
(`nickel-lang-core`) and evaluates the sources in-process:

```sh
cargo run -- compile  # write .github/workflows/*.lock.yml
cargo run -- check    # fail on a stale lock file or an accepted reject test
cargo test            # wfc's own tests, and `check` of this repository
```

wfc reads and writes the repository only through a directory fd for its
root (cap-std), and reads only what a compile needs (`READABLE` in
`src/repo.rs`: the compiler's library and runtime, the sources, the tests
and what `check` compares with; not `.git` or the rest of the checkout),
following no symlinks. nickel would resolve an `import` against any path
(`/etc/passwd`, `../x`, a symlink out of the tree) and has no hook to read
through a directory fd, so wfc never gives it a path: it reads a source's
imports itself, transitively, and hands nickel their text. Stronger
isolation (no network, a read-only mount of the checkout) is up to what
runs wfc.

`nickel-lang-core` is outside nickel's 1.0 stability promise, so
`Cargo.toml` pins it exactly; a bump can change the lock files, so it
goes with `cargo run -- compile`. wfc builds with the toolchain in
`rust-toolchain.toml`. Sandboxed steps need `run0`, so systemd 256 or
later: ubuntu-26.04 and RHEL 10, not ubuntu-24.04
([#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6)).

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
  checkout, uploads through symlinks to `/proc/self/environ` and the
  runner's files, a step that times out with processes left behind, cron,
  at and lingering) fail, and `ci` checks that no artifact holds the token;
- `workflows/agent-review.ncl` on hosted ubuntu-26.04, with a stub agent
  (`runtime/agent-stub.sh`) that reads its prompt from the share and fails
  if it can rewrite it, use sudo or see the job's credentials.

Next, as issues in this repository (sub-issues of
[tracker#88](https://github.com/cgwalters-forge/tracker/issues/88),
the task compiler that will produce this compiler's input):

- [#7](https://github.com/cgwalters-forge/workflow-compiler/issues/7) run a real agent through the devspace harness (P1)
- [#4](https://github.com/cgwalters-forge/workflow-compiler/issues/4) agent-run as a compiler macro or a composite action (P1)
- [#16](https://github.com/cgwalters-forge/workflow-compiler/issues/16) reuse external actions: a typed workspace hand-off, a shim running pure actions in the sandbox, and `publish_steps` for credentialed ones (P1)
- [#5](https://github.com/cgwalters-forge/workflow-compiler/issues/5) use `cgwalters-forge/actions/secure-host-setup` (P1)
- [#13](https://github.com/cgwalters-forge/workflow-compiler/issues/13) the stale-lock check doesn't prove every workflow is compiled (P1)
- [#15](https://github.com/cgwalters-forge/workflow-compiler/issues/15) credentials left in the workspace reach the sandbox (P1)
- [#1](https://github.com/cgwalters-forge/workflow-compiler/issues/1) sandboxed step outputs reaching `with:` of allowlisted actions (P1)
- [#8](https://github.com/cgwalters-forge/workflow-compiler/issues/8) using the compiler from other repositories (P1)
- [#14](https://github.com/cgwalters-forge/workflow-compiler/issues/14) prompts from a trusted ref for PR-triggered agents (P2)
- [#2](https://github.com/cgwalters-forge/workflow-compiler/issues/2) post-steps of `runner_steps` actions (P2)
- [#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6) ubuntu-24.04, which has no `run0` (P2)
- [#9](https://github.com/cgwalters-forge/workflow-compiler/issues/9) replacing the runner's last sudo rule (P2)
- [#10](https://github.com/cgwalters-forge/workflow-compiler/issues/10) blocking the cloud metadata service for the sandbox (P2)
- [#11](https://github.com/cgwalters-forge/workflow-compiler/issues/11) embedding `share.cjs` once per job (P2)

## License

MIT OR Apache-2.0; see [LICENSE](LICENSE).
