# Requirements and threat model

This document says what the workflow compiler guarantees, to whom, against
whom, and which test proves each guarantee. The background (how the Actions
runner starts steps, why nothing inside a job can take the choice of user
away from a later step, and how gh-aw and others handle it) is in the
[design gist](https://gist.github.com/cgwalters-bot/2368b70fa941386025467421ce38b5b6);
this is the part that should stay true as the implementation changes.

Requirements are numbered (R1, R2, ...) so issues and commits can refer to
them. Each has a **Status**: *holds* (the proof of concept meets it and
`ci` tests it), *partial* (it meets part of it, and the rest is named), or
*planned* (the design, not yet implemented). Its **Proof** lists the tests
in this repository that fail if it is broken, which `ci` runs on every pull
request, and the issues for what isn't proven yet. A change that moves a
requirement's status updates this document in the same pull request.

## The problem in one paragraph

A GitHub Actions job runs every step as the runner's own user. That user
holds the job's tokens (in the `Runner.Worker` process, in the environment of
`uses:` steps, and in the files the runner writes), and on hosted runners it
has passwordless sudo. So any code a step runs, a build script from a pull
request, a compromised dependency, an agent following instructions it found
in an issue, can read the tokens, and nothing an earlier step sets up
(`defaults.run.shell`, `PATH`, a job container) stops a later step from
running as that user again. Jobs that build or test untrusted code, and jobs
that run agents, want the opposite: set the machine up with privileges, then
run everything else as a user that can't reach them.

## Actors

**Maintainers** own the repository: they review and merge the workflow
source and its lock file, and they control the repository settings the
guarantees depend on (the branch ruleset that requires `ci`, the Actions
permissions, environments and their protection rules, whether fork pull
requests need approval to run). They also decide which version of this
compiler and its runtime a repository uses. They are trusted; everything
below is relative to what they reviewed.

**Collaborators with write access** can push branches and run workflows
from them (`push`, `workflow_dispatch`). A workflow file on an unprotected
branch is not reviewed, so unless secrets and write tokens are limited to
protected refs (see R10), write access is as trusted as maintainership.

**The workflow author** writes the nickel source: the job's `runner_steps`,
`steps` and `publish_steps`, its shares and its actions. Usually a
maintainer, or someone whose change a maintainer reviews. The author is
trusted to mean what they wrote, but not to get every detail right: the
compiler exists partly to make the safe thing the only thing the source can
say, and to turn common mistakes (a secret in a sandboxed step, an unpinned
action) into compile errors.

**The pull request author** may be anyone, including someone who opened
their first pull request a minute ago. For jobs triggered by a pull request
they control the content of the checkout: build scripts, tests, lock files
and configuration of package managers, and any prompt read from the tree.
They also control text the job can see through expressions: the pull
request's title, body and branch name. On the `pull_request` trigger they
control the workflow file itself, since GitHub runs it as it is on the pull
request's head (see R10).

**Issue and comment authors** are anyone who can open an issue or comment
on one, which for a public repository is anyone. Jobs triggered by `issues`
or `issue_comment`, and the board-driven agents of
[tracker#88](https://github.com/cgwalters-forge/tracker/issues/88), put
their text in front of the job, as event data and as an agent's input. That
text is untrusted wherever it goes (R12).

**The agent** is a model-driven process, such as a coding agent run by
`agent_run`, working in the sandbox. It is treated exactly like a hostile
build payload: it may have been steered by text it read (an issue, a pull
request, a web page, a file in the checkout) and do anything its user can
do. It is never trusted with credentials, and its results are data for a
later, privileged phase or job to validate.

**Action authors** publish the actions a job uses. An action runs with
whatever the phase it is in gives it, so the phase decides how much its
author is trusted: a setup action in `runner_steps` is fully trusted, a pure
action run in the sandbox is not trusted at all, and a credentialed action in
`publish_steps` is trusted with the job's tokens but only given staged data.
Every action is pinned by commit, so its author can't change it after
review, though what it pulls in at run time is not pinned (R9).

**The platform**, GitHub's runner and the runner image's kernel, systemd,
sudo and node, and the compiler's own toolchain (nickel, and the node that
runs `compile.mjs`), is trusted. The compiler hardens the image where it is
known to be weak (world-writable system paths, sudo, docker), but a kernel or
systemd privilege escalation is out of scope (see [Non-goals](#non-goals)).
So are **the runner's neighbours**, whatever else on the host or network
the sandbox can talk to: services `runner_steps` started on localhost,
world-writable sockets such as tailscaled's on the devspace runners, the
cloud metadata service, and peers on a tailnet the runner joined. They are
not attackers, but they are reachable from the sandbox, which is a limit of
the uid boundary (R2, R3).

## Trust boundaries

There are four boundaries, and every guarantee below is one of them.

The **review boundary** is between what maintainers reviewed and everything
else. The lock file in `.github/workflows/` is a deterministic function of
the reviewed source and of this repository's contracts and runtime scripts,
which the lock file embeds; the stale-lock check fails `ci` on any
difference. So reviewing the source is reviewing the job, and the source's
schema has no way to say "run this later step as runner". The check itself
runs from the pull request's own `ci.yml`, `compile.mjs`, `lib/` and
`runtime/`, with a nickel binary it downloads, so those files are inside
the boundary too: a pull request that changes them can make a stale lock
file pass, and they need the same review as the lock files
([#26](https://github.com/cgwalters-forge/workflow-compiler/issues/26)).

The **uid boundary** is between the runner user and the sandbox user
(`runner-sandbox`). It is the one that holds at run time against hostile
code: the sandbox user can't read the runner's processes, files, or tokens,
can't become root, and can't leave anything running once its step ends. It
is established by a generated step (the *enter* step) after the privileged
phase, and it is only as strong as the kernel's separation of users. It
covers files and processes, not local IPC: world-writable unix sockets,
abstract sockets and localhost services are reachable across it
([#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27)).

The **wrapper**, the root half of the step wrapper (`runtime/run.cjs`), is
the reference monitor on that boundary. It is the only root code that runs
after the enter step, it treats every request as untrusted, and it moves
data across the boundary in both directions: into the sandbox as a copy
owned by the sandbox user, and out of it as a copy owned by root, read
without following symlinks, after every process of the step is gone.

The **job boundary** is between jobs: another VM, another token, as in
gh-aw. It is stronger than the uid boundary and is what the task layer
([tracker#88](https://github.com/cgwalters-forge/tracker/issues/88)) uses
to apply an agent's results with write credentials. The workflow compiler
works inside one job; `publish_steps` (R8) is the in-job equivalent for
credentials whose loss is tolerable, such as the runtime token that uploads
artifacts.

## Phases and data flow

A compiled job always has the same shape. The source names three of the
phases; the compiler generates the rest, and nothing in the source can
reorder them. All six exist.

```text
runner_steps      as runner, with sudo      setup actions, packages, checkout, shares
secure the host   as root (generated)       close what the image leaves open to other users
enter             as root (generated)       hand-off: create the sandbox user, copy the
                                            declared workspace in; take root from runner
steps             as runner-sandbox         run: steps and pure actions; stage outputs
seal              as root (generated)       stop the sandbox, hide its files from runner
publish_steps     as runner, no sudo        credentialed actions, reading staged outputs
```

Data crosses the uid boundary at these points. **In**: the hand-off
copies the workspace into a directory the sandbox user owns, and `share`
runner steps publish files as root-owned, world-readable copies under
`/etc/agent-share` that the sandbox can read but not change. **Out**: a
sandboxed step's outputs and step summary, validated by the wrapper; and
*staged outputs*, files or directories a `stage` or `upload` step names,
which the wrapper copies to a root-owned directory refusing symlinks and
special files. A step also always hands out its exit status (and so the
step's outcome and whether later `success()` steps run) and its standard
output and error, which the runner logs and parses for workflow commands
(R7). Until the seal, whatever the sandbox wrote to its workspace or to
shared directories such as `/dev/shm` stays readable to runner.

Actions fall into three classes, and the phase decides the class:

- **Setup actions** (checkout, `setup-*`, cache restore) run in
  `runner_steps`, as the runner, before any untrusted code runs. Their
  results reach the sandbox through the hand-off or a share. They must not
  execute the checkout, which includes tools that run configuration they
  read from it (R10).
- **Pure actions** (linters, formatters, a `setup-*` used mid-job) run in
  `steps`, inside the sandbox, through a shim: a generated privileged step
  fetches the action at its pinned commit into a root-owned directory, and
  the sandboxed step runs it as the sandbox user with its inputs and its own
  `GITHUB_OUTPUT`, `GITHUB_ENV`, `GITHUB_PATH` and step summary files, which
  the wrapper validates on the way out. Composite actions are expanded into
  their steps at compile time. Actions that need the job's credentials can't
  run this way, and Docker container actions can't either, since the
  sandbox has no container engine running as root
  ([#31](https://github.com/cgwalters-forge/workflow-compiler/issues/31)).
- **Credentialed actions** (upload-artifact, cache save, commenting on a
  pull request) run in `publish_steps`, as runner, and read only staged
  outputs. This is gh-aw's *safe outputs* pattern moved inside the job.

## Requirements

### R1. Later steps can't leave the sandbox

Every step after the enter step runs as the sandbox user, except the
generated seal step and the `publish_steps`, and nothing in the source can
change that. The source contracts are closed records, so a field the
compiler can't keep sandboxed is a compile error rather than a pass-through:
a step's `shell:` or `working-directory`, a job's `container:`, `defaults`
or `services`, workflow- or job-level `env:`, and a `uses:` in `steps` that
the shim can't run.

**Status:** holds, with the gap below.

**Proof:** the reject tests in `tests/reject/` (`shell-override`,
`working-directory`, `job-container`, `job-defaults`, and the others), which
`node compile.mjs --check` requires to fail with their expected message,
`job-services`, `job-env` and `workflow-env` among them. Gap:
`--check` proves each lock file matches its source, not that every
workflow in `.github/workflows/` is a lock file or that a source went
through `gha.compile` unmodified
([#13](https://github.com/cgwalters-forge/workflow-compiler/issues/13)).

### R2. A sandboxed step runs as another user, in a session of its own

A sandboxed step's payload starts as the sandbox user through `run0`, in a
logind session of its own, with a fixed `PATH`, a private `/tmp` and
`/var/tmp`, the runner's home inaccessible, no `SUDO_*` variables, and only
the environment the source gave the step (plus a fixed list of non-secret
`GITHUB_*` context). The sandbox user has no sudo rule.

**Status:** holds, for files and processes. Local IPC crosses the boundary
([#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27)).

**Proof:** `workflows/sandbox-test.ncl` on hosted ubuntu-26.04, steps "Runs
as the sandbox user", "Runs in a login session of its own", "sudo is
refused", "The sudo step failed", and "Each step gets a private /tmp and
/var/tmp".

### R3. The sandbox holds no credentials

No sandboxed step can read the job's tokens or the runner's secrets: the
token variables (`ACTIONS_RUNTIME_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_*`,
`GITHUB_TOKEN`) are not in its environment, `Runner.Worker`'s environment
and memory and the runner's home are unreadable, and no docker daemon is
running. The hand-off doesn't carry credentials in either: a checkout must
set `persist-credentials: false`, and the copy is refused if it finds
credentials a setup step left in the workspace.

**Status:** partial. The environment, `Runner.Worker`, the runner's home
and the hand-off hold: it copies only what git tracks unless the job says
otherwise (`handoff.workspace`, `handoff.include`), refuses known
credential files and GitHub tokens in any file that differs from what git
tracks (a value that only names an environment variable, like an
`.npmrc`'s `${NPM_TOKEN}`, is fine), and the compiler refuses a checkout
without `persist-credentials: false`. The scan knows a list of files; a
credential elsewhere in another format isn't found. The runner's files are hidden by closing its
home, which assumes the hosted layout, where the workspace, the runner's
installation and its `.credentials` all live under `/home/runner`. The
cloud metadata service
([#10](https://github.com/cgwalters-forge/workflow-compiler/issues/10)) and
local sockets and services
([#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27)) are
reachable.

**Proof:** `sandbox-test` steps "The job's credentials are out of reach"
and "Gets the handed-off workspace and nothing else", and the
`sandbox-test-artifacts` job, which fails if any artifact holds the
runtime token or the runner's secret marker; the hand-off's unit tests in
`tests/runtime/handoff.test.cjs` (credential files, symlinks, special
files); `tests/reject/checkout-persist-credentials.ncl`.

### R4. The runner loses root before untrusted code runs

With `sandbox.lock_runner_sudo` (the default), the enter step replaces the
runner's sudo with a single rule, for the wrapper, and stops docker and
containerd, whose group the runner keeps. It fails the job unless `sudo -n
true` as runner is refused afterwards. So a compromised credentialed action
in `publish_steps` holds the job's tokens but can't become root, and with
Yama's `ptrace_scope` at 1 (set by the secure-host step) it can't read
`Runner.Worker`'s memory either.

**Status:** holds. The source can turn the lock off only for a job
without `publish_steps`, where no runner code runs after the sandbox
([#32](https://github.com/cgwalters-forge/workflow-compiler/issues/32)); the
remaining rule depends on sudo and sudo-rs agreeing on sudoers semantics
([#9](https://github.com/cgwalters-forge/workflow-compiler/issues/9)).

**Proof:** the enter step's own fail-closed check, in every compiled job;
its log shows `sudo -l -U runner`. `sandbox-test`'s publish step "The
sandbox is sealed" checks that runner has no sudo and can't open
`/proc/<Runner.Worker>/mem`; `tests/reject/publish-without-sudo-lock.ncl`.

### R5. Nothing outlives its step

When a sandboxed step ends, for any reason, every process it started is
gone before anything reads what it wrote, and before the next step starts.
The sandbox user can't start processes outside a step: cron, at and
lingering are denied to it, as is every polkit action.

**Status:** holds on an ephemeral runner. The wrapper stops the sandbox's
processes after each step and before the next, and the seal after the last
one, so a step killed by its timeout or a cancel leaves processes running
at most until the next sandboxed step or the seal. This assumes an
ephemeral runner: the enter step refuses a runner that already has the
sandbox's directory, but a persistent runner would still carry the sandbox
user's own files and processes over into the next job
([#28](https://github.com/cgwalters-forge/workflow-compiler/issues/28)).

**Proof:** `sandbox-test` steps "Leave a process behind", "Leave a process
behind and time out", "Cron, at and lingering are denied" and "The escapes
failed"; the publish step "The sandbox is sealed", which fails if a
sandbox process survived the seal.

### R6. Instructions the sandbox can trust come only from shares

The sandbox can read anything world-readable on the host and anything on
the network, and it owns its copy of the workspace. What it can trust not to
have been changed by an earlier sandboxed step is what the privileged phase
put in a share: root-owned and read-only to it. So a share is where
instructions go, such as an agent's prompt and skills. A share never
follows a symlink out of the workspace.

**Status:** holds. On a pull request trigger, though, the shared prompt
comes from the pull request's own checkout, so its author wrote it
([#14](https://github.com/cgwalters-forge/workflow-compiler/issues/14)).

**Proof:** `sandbox-test` step "Read the shares, and fail to change them",
and the `share-symlink` steps that try to share `/etc/shadow` through a
symlink. `agent-review.lock.yml`, whose stub agent fails if it can rewrite
its prompt.

### R7. What leaves the sandbox is validated data

What a sandboxed step hands to anything running as runner is data the
wrapper validated: its outputs (`name=value` lines, with names checked), its
step summary, and staged outputs, each read without following symlinks and
with a size cap, after every process of the step is gone. Two channels are
not validated, and everything downstream must treat them as untrusted: the
step's exit status, which decides its outcome and whether later
`success()` steps run; and its standard output and error, which go to the
job's log.

**Status:** partial. Outputs are `name=value` lines or the heredoc form
`@actions/core` writes for every value, re-encoded by the runner side with
a delimiter of its own, so a value can't end early and set another name.
`GITHUB_ENV` and `GITHUB_PATH` apply to later sandboxed steps only, never
to the runner, and can't set what the wrapper sets itself (`PATH`, `LD_*`,
`NODE_*`, `RUNNER_*` and the like). Standard output reaches the runner's parser of
workflow commands, so a step can still use `::set-output` or `::add-mask::`
([#17](https://github.com/cgwalters-forge/workflow-compiler/issues/17)).
Staged outputs have no size cap
([#18](https://github.com/cgwalters-forge/workflow-compiler/issues/18)),
and files the sandbox leaves in `/dev/shm` or its workspace stay readable
to runner until the seal, which hides or removes them.

**Proof:** `sandbox-test` steps "Write a step output", "Read it back",
"Point GITHUB_OUTPUT at a root-only file" and "Smuggle an output with a
bad name"; `actions-test` steps "Set environment for later sandboxed
steps", "Read it back", "The sandbox can't set what the wrapper sets", "An
unterminated heredoc output fails the step" and the publish step "Nothing
the sandbox set reached the runner"; `tests/runtime/filecmd.test.cjs`; the
upload steps that point at
`/proc/self/environ` and the runner's files through symlinks, and
`sandbox-test-artifacts`.

### R8. Credentialed steps read only staged outputs

`publish_steps` are the only steps after the enter step that run as
runner. Before they start, the seal step stops every sandbox process and
makes the sandbox's workspace and home unreadable to runner, and removes
what the sandbox left in sticky world-writable directories (found on the
root filesystem and every memory-backed one), owned by its uid or gid or by
the subordinate ids rootless podman maps its containers to. So a publish
step can only read what the sandbox staged. If the seal fails, no publish
step runs. The compiler rejects expressions in a publish step's `run`,
`working-directory`, `with` or `env` that use a sandboxed step's outputs,
since those are strings the sandbox chose. A
step's `outcome` and `conclusion` are allowed: they are one of four fixed
values, so the most the sandbox can do with them (by its exit status) is
decide whether a publish step runs, which it can do anyway.

**Status:** holds for files the sandbox's ids own (and settles
[#1](https://github.com/cgwalters-forge/workflow-compiler/issues/1)). The
outputs check is a lint, like R11. A publish step can still reach what the
sandbox can reach over local IPC or the network
([#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27)).

**Proof:** `tests/reject/publish-sandbox-output-*.ncl` (outputs in `run`,
`working-directory`, `with` and `env`, `toJSON(steps)`, `steps['x']`,
`steps.*` filters) and `publish-if-unbalanced.ncl`; `sandbox-test`'s
publish steps "Read the staged report, as runner" and "The sandbox is
sealed", which fail if a publish step can read the sandbox's workspace, its
home, or files it left in `/dev/shm` (one owned by a subordinate uid, made
with `podman unshare chown`), or if the wrapper still accepts a request
after the seal. Every publish step's condition includes the seal's
success, which the lock files show.

### R9. Every action is pinned and runs in the phase its class allows

Every `uses:` names a full commit SHA. In `runner_steps` any pinned action
may run. In `steps`, an action runs in the sandbox through the shim, or is a
compile error; there is no allowlist of actions that run as runner in the
middle of the sandbox. In `publish_steps` any pinned action may run. A
composite action is expanded into its steps at compile time, so each of
them lands in the phase the composite was used in.

**Status:** partial. Pinning holds, nothing runs as runner in the middle
of `steps`, and the shim runs JavaScript actions there; the
[README](../README.md#actions-in-the-sandbox) lists the actions it can't
run, which are compile errors. The fetch step checks each action's
`action.yml` against the sha256 in `actions.lock.json`, so the metadata
the compiler used is that commit's. A pin covers the action's own files,
not a composite's nested `uses:`, a Docker image or what the action
downloads, and GitHub resolves a SHA from anywhere in the repository's
fork network
([#30](https://github.com/cgwalters-forge/workflow-compiler/issues/30)).
Post-steps of setup actions run as runner at the end of the job
([#2](https://github.com/cgwalters-forge/workflow-compiler/issues/2)).

**Proof:** `tests/reject/unpinned-action.ncl`,
`tests/reject/credentialed-action-in-steps.ncl`; `workflows/actions-test.ncl`
on hosted ubuntu-26.04, which runs DavidAnson/markdownlint-cli2-action
and actions/setup-node (into the sandbox's tool cache, with its post
step).

### R10. What the guarantee depends on

"No later step can undo it" holds under these conditions, and means
nothing without them.

**Nobody without write access can change the workflow that runs.** Which
workflow file runs depends on the trigger. On `schedule`, `issues`,
`issue_comment`, `workflow_run` and `pull_request_target`, it is the
default branch's, so the reviewed one. On `push` it is the pushed ref's,
on `workflow_dispatch` the chosen ref's, and on `workflow_call` whatever
ref the caller chose, so anyone who can push a branch can run an edited
lock file there. On `pull_request` it is the pull request's head: from a
fork, GitHub gives that run a read-only token and no secrets, which is the
boundary there; from a branch in the repository, its author has write
access anyway. So secrets and write tokens must be limited to protected
refs, through environments with branch rules, or be absent. The sandbox
still protects any run from code its author didn't write, such as a
dependency.

**The triggers that mix untrusted input with credentials are handled.**
`pull_request_target`, `issues`, `issue_comment` and `workflow_run` run the
reviewed workflow with the repository's secrets, on input from anyone:
there, the pull request's code may only be checked out and run inside the
sandbox ([#19](https://github.com/cgwalters-forge/workflow-compiler/issues/19)),
and event text may only reach privileged steps as data (R12).

**The repository requires `ci`**, including the stale-lock check, before
anything merges, and its maintainers review changes to `ci.yml`,
`compile.mjs`, `lib/` and `runtime/` like lock files
([#26](https://github.com/cgwalters-forge/workflow-compiler/issues/26)).

**The privileged phase doesn't run code from an untrusted checkout.**
`runner_steps` run as runner with sudo: a `run: make deps` there, on a
pull request's checkout, hands the job to the pull request's author before
the sandbox exists. Reading the checkout is not always safe either, when the
tool that reads it executes configuration from it; as far as we know,
setup-node's yarn cache lookup honors `.yarnrc.yml`'s `yarnPath`, and
rustup a `path` in `rust-toolchain.toml`
([#19](https://github.com/cgwalters-forge/workflow-compiler/issues/19)).

**The runner is ephemeral**, as GitHub's hosted runners are
([#28](https://github.com/cgwalters-forge/workflow-compiler/issues/28)),
and **the job's token has only the permissions it needs**, which the
source doesn't require it to say
([#29](https://github.com/cgwalters-forge/workflow-compiler/issues/29)).

**Status:** conditions, not behaviors, and nothing checks them yet
([#21](https://github.com/cgwalters-forge/workflow-compiler/issues/21) for
the repository settings).

### R11. Lints are not boundaries

The compiler also rejects some things that are mistakes rather than
escapes: expressions naming a secret or the job's token in a sandboxed step
or a share (in any case, and in the spellings `secrets['X']`,
`toJSON(secrets)`, `format(...)`), and `env:` names in a sandboxed step
that would change how the runner side of the wrapper starts (`NODE_*`,
`LD_*`, `PATH`, `RUNNER_*`, and the like). These are lints. A value a
runner step put in `GITHUB_ENV` still reaches a sandboxed step through
`env.X`, for one. They catch the obvious mistake; the uid is what holds
when the mistake is subtle.

**Status:** holds.

**Proof:** the `secret*`, `token*`, `github-*` and `env-*` reject tests.

### R12. Untrusted text never becomes privileged code

Text others control reaches privileged steps only as data, in `env:`: the
event data written by pull request, issue and comment authors
(`github.event.*` other than numbers and ids, `github.head_ref`), the
`inputs` of whoever calls or dispatches the workflow, and `needs.*.outputs`
of other jobs, which may come from their sandboxes. It is never expanded
into the scripts of `runner_steps` or `publish_steps`: their `run:`,
github-script's `script:`, or any `with:` of a publish step. Nor is an
`env:` value holding it expanded there again as `${{ env.X }}`. Actions
splices `${{ }}` into a script's source before it runs, so this is the
classic Actions script injection, and it doesn't need the sandbox at all to
give an attacker the runner. Like R11 it is a lint on the expression text;
the task layer must also keep such text out of privileged steps entirely,
putting it only in shares or sandbox inputs.

**Status:** holds, as a lint. It doesn't see text a privileged step reads
from a file or the API itself, nor `with:` of actions in `runner_steps`
other than github-script, which take data (checkout's `ref:`) but could
evaluate it.

**Proof:** `tests/reject/runner-run-event-text.ncl`,
`publish-run-head-ref.ncl`, `runner-run-github-index.ncl`,
`runner-run-github-filter.ncl`, `runner-run-env-reexpansion.ncl`,
`runner-run-inputs.ncl`, `publish-run-needs-outputs.ncl` and
`publish-github-script-event.ncl`.

### R13. Nothing the sandbox produced is run as runner later

Artifacts, caches and staged outputs the sandbox produced are untrusted
data wherever they go, in later steps, jobs and runs. In particular a cache
saved from sandbox output, or by a `pull_request_target` run or a workflow
that isn't compiled, must never be restored into a workspace that runner
executes, since that would be an escape across runs.

**Status:** not enforced
([#20](https://github.com/cgwalters-forge/workflow-compiler/issues/20)).

## Non-goals

**A kernel boundary.** The sandbox is a different uid on the same kernel,
so a local privilege escalation in the kernel, systemd, polkit or sudo
breaks it. A VM per sandboxed phase (bcvk on a devspace's KVM) would replace
the uid boundary without changing the compiler's interface, and is the next
step, not this one.

**Protecting against the workflow author or the maintainers.** They can
write any `runner_steps`, run any setup action, and give `publish_steps`
any token. The compiler makes the safe structure the only one a later step
can have; it doesn't decide what the privileged phases may do.

**Confidentiality of what the sandbox can read.** The sandbox has the
checkout and the shares, and network access, so it can send them anywhere.
For a public repository that is fine; for private code it needs an egress
policy ([#22](https://github.com/cgwalters-forge/workflow-compiler/issues/22)),
which the uid boundary doesn't provide.

**Availability.** A sandboxed step can use all of the machine's CPU,
memory and disk until its `timeout-minutes`, or the job's (six hours by
default). That breaks the job, which is the sandbox's own to break, on an
ephemeral runner that serves only this job. Shared or persistent
self-hosted runners are not supported (R10).

**Validating results for other jobs.** Staged outputs, artifacts and
outputs are untrusted data wherever they go next (R13). A job that applies
an agent's results (the task layer's `apply` job) validates them itself, as
gh-aw's safe-outputs job does.

**Runners other than systemd 256 or later.** Sandboxed steps need `run0`:
ubuntu-26.04 and RHEL 10, not ubuntu-24.04
([#6](https://github.com/cgwalters-forge/workflow-compiler/issues/6)).

## Relation to gh-aw and to a board that drives agents

[gh-aw](https://github.com/github/gh-aw) compiles a Markdown task into a
workflow whose agent job runs in a container behind an egress firewall,
with read-only permissions, and whose writes happen in separate jobs that
validate the agent's *safe outputs*. Its custom `steps:` run outside that
sandbox, as runner with sudo, in the same job as the agent. The workflow
compiler takes the same approach one level down: it compiles an ordinary
job, not an agent task, and adds the boundary gh-aw's agent job doesn't
have, a different uid inside the job, so the steps around the agent are
constrained too. It keeps the host's podman and `/dev/kvm` usable in the
sandbox, which a firewall container that hides the container socket rules
out, and which the bot's work (building bootable container images, booting
VMs) needs. `publish_steps` borrows the safe-outputs idea for the
credentials that are reasonable to keep in the job.

The two compose rather than compete. The task layer
([tracker#88](https://github.com/cgwalters-forge/tracker/issues/88), and
[agentic-job](https://github.com/cgwalters-forge/agentic-job)'s task
format) compiles a task into gh-aw's job graph (agent, collect, apply,
conclusion), and its agent job is a workflow-compiler job. "The agent runs
as an unprivileged user with no access to the job's credentials" is then a
property the compiler checks, not a convention every task has to remember.

[Paperclip](https://paperclip.ing/) drives agents from a board of issues and
comments, which is the model agentic-job aims for with the forge's own
issues and projects as the board. Paperclip's local adapters run agents
unsandboxed on the host, and its sandbox targets are optional. A board that
anyone can write to is a prompt-injection channel, so the agent it wakes
has to be treated as hostile, which is this document's assumption. Here,
every run triggered from the board is a compiled job in which the agent is
the sandbox user, its instructions come from a share it can't rewrite, and
its only effects are staged outputs that a privileged phase or a separate
job validates. That makes the board a safe input only if the task layer
keeps board text out of the privileged phases and out of every expression
(R12), putting it only in shares or sandbox inputs; the workflow compiler
is the layer that enforces the rest.

## Gaps tracked as issues

Besides the issues that existed before it, writing this document turned up
these gaps, all sub-issues of
[tracker#88](https://github.com/cgwalters-forge/tracker/issues/88) and in
the roadmap in the [README](../README.md#status-and-roadmap):

- [#17](https://github.com/cgwalters-forge/workflow-compiler/issues/17): workflow commands on a sandboxed step's standard output (R7);
- [#18](https://github.com/cgwalters-forge/workflow-compiler/issues/18): no size cap on staged outputs (R7);
- [#19](https://github.com/cgwalters-forge/workflow-compiler/issues/19): `runner_steps` that execute a pull request's checkout (R10);
- [#20](https://github.com/cgwalters-forge/workflow-compiler/issues/20): caches from the sandbox or untrusted runs restored as runner (R13);
- [#21](https://github.com/cgwalters-forge/workflow-compiler/issues/21): nothing checks the repository settings (R10);
- [#22](https://github.com/cgwalters-forge/workflow-compiler/issues/22): unrestricted network egress ([Non-goals](#non-goals));
- [#25](https://github.com/cgwalters-forge/workflow-compiler/issues/25): expressions from events in privileged `run:` steps (R12) (fixed);
- [#26](https://github.com/cgwalters-forge/workflow-compiler/issues/26): the stale-lock check runs the pull request's own compiler (review boundary, R10);
- [#27](https://github.com/cgwalters-forge/workflow-compiler/issues/27): local sockets and localhost services (R2, R3);
- [#28](https://github.com/cgwalters-forge/workflow-compiler/issues/28): the ephemeral-runner assumption (R5, R10);
- [#29](https://github.com/cgwalters-forge/workflow-compiler/issues/29): explicit token permissions (R10);
- [#30](https://github.com/cgwalters-forge/workflow-compiler/issues/30): what pinned actions pull in (R9);
- [#31](https://github.com/cgwalters-forge/workflow-compiler/issues/31): Docker container actions in the sandbox (R9);
- [#32](https://github.com/cgwalters-forge/workflow-compiler/issues/32): the runner's loss of root depends on an opt-out and an untested setting (R4) (fixed).
