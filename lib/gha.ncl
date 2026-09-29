# A GitHub Actions workflow in which every job has two phases.
#
# `runner_steps` run as the stock `runner` user, with its sudo, and set the
# machine up: packages, checkout, network. The compiler then adds a step
# that secures the host (runtime/secure-host.cjs) and one that enters the
# sandbox (runtime/install.cjs). A `share` runner step publishes a file to
# the sandbox read-only, under SHARE_DIR. Every step in `steps` runs
# after that as the unprivileged sandbox user: `run:` steps get the sandbox
# wrapper as their shell, and `uses:` steps are limited to the job's
# `sandbox.allowed_actions`, pinned by commit.
#
# Fields otherwise map one to one onto the workflow syntax. The contracts
# are closed records, so anything the compiler doesn't know how to keep
# sandboxed (a step `shell:`, `defaults`, a job `container:`, workflow or job
# `env:`) is an error rather than silently passed through.
let EXEC = "/usr/local/bin/runner-sandbox-exec" in
let USER_RE = "^[a-z_][a-z0-9_-]{0,30}$" in
# Where `share` runner steps publish (runtime/share.cjs has it too).
let SHARE_DIR = "/etc/agent-share" in

let validator = fun pred msg =>
  std.contract.from_validator (fun v => if pred v then 'Ok else 'Error { message = msg v })
in

# owner/repo[/path]@<40 hex>: a tag or branch can be moved, a commit can't.
let Pinned = validator
  (fun s => std.string.is_match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$" s)
  (fun s => "`%{s}` must be pinned by full commit SHA (owner/repo@<40 hex>)")
in

# Whether S has an expression naming a secret or the job's token.
# Expressions are case-insensitive and have many spellings (secrets.X,
# secrets['X'], toJSON(secrets), format('{0}', secrets.X), github.token,
# github['token'], toJSON(github)), and a string literal inside one can
# hold `}}`, so rather than parse them this looks at all of S after each
# `${{`. It's a lint against mistakes, not a boundary: a value runner_steps
# put in GITHUB_ENV, for one, still reaches the sandbox through `env.X`.
let CREDENTIALS_RE = "(?i)\\bsecrets\\b|\\bgithub\\s*(\\[|[,)}]|\\.\\s*token\\b)" in
let mentions_credentials = fun s =>
  std.array.any
    (fun expr => std.string.is_match CREDENTIALS_RE expr)
    (std.array.drop_first (std.string.split "${{" s))
in

# Sandboxed steps never see the job's credentials, so they may not name them
# either: an expression expanding a secret or the token into a script or an
# env value would hand it to the sandbox.
let NoCredentials = validator
  (fun s => std.is_string s && !(mentions_credentials s))
  (fun s =>
    if std.is_string s then
      "sandboxed steps cannot reference secrets or github.token; pass data through runner_steps outputs instead"
    else
      "values in a sandboxed step's `with` and `env` must be strings (quote numbers and booleans)")
in

# A step's `env` applies to the runner side of the wrapper too, which runs
# as runner under node before anything is validated, so names that change
# how a program starts or where it finds others are refused here, along
# with the ones runner-sandbox-run refuses anyway.
let DENIED_ENV_RE = "^(ACTIONS_|RUNNER_|GITHUB_(TOKEN|ENV|PATH|OUTPUT|STATE|STEP_SUMMARY)$|LD_|NODE_|(BASH_ENV|ENV|PATH|HOME|USER|LOGNAME|SHELL)$)" in
let SafeEnvNames = validator
  (fun env => std.array.all (fun n => !(std.string.is_match DENIED_ENV_RE n)) (std.record.fields env))
  (fun env =>
    let bad = std.array.filter (fun n => std.string.is_match DENIED_ENV_RE n) (std.record.fields env) in
    "`%{std.array.first bad}` cannot be set in a sandboxed step's env: it would reach the runner side of the step wrapper, or is the sandbox's own")
in

let OneOfRunUses = validator
  (fun step => std.record.has_field "run" step != std.record.has_field "uses" step)
  (fun step => "a step needs exactly one of `run` or `uses`")
in

let Allowed = fun allowed => validator
  (fun step =>
    !(std.record.has_field "uses" step)
    || std.array.elem (std.array.first (std.string.split "@" step.uses)) allowed)
  (fun step => "`%{step.uses}` is not in sandbox.allowed_actions; after the privileged phase an action runs as the runner user with the job's tokens")
in

# checkout leaves the job's token in .git/config unless told not to, and
# the hand-off would give it to the sandbox (it also refuses such a copy).
let NoPersistedCredentials = validator
  (fun step =>
    !(std.record.has_field "uses" step)
    || !(std.string.is_match "(?i)^actions/checkout@" step.uses)
    || (std.record.has_field "with" step
      && std.record.has_field "persist-credentials" step.with
      && (step.with."persist-credentials" == false || step.with."persist-credentials" == "false")))
  (fun step => "`%{step.uses}` must set `with.persist-credentials = false`: the token it would leave in .git/config is readable by the sandbox after the hand-off")
in

let RunnerStep = std.contract.Sequence [
  {
    name | String | optional,
    id | String | optional,
    "if" | String | optional,
    run | String | optional,
    shell | String | optional,
    uses | Pinned | optional,
    with | { _ : Dyn } | optional,
    env | { _ : String } | optional,
    "working-directory" | String | optional,
    "continue-on-error" | Bool | optional,
    "timeout-minutes" | Number | optional,
  },
  OneOfRunUses,
  NoPersistedCredentials,
] in

# A `share` runner step publishes a file or directory tree from the
# runner's side as a root-owned, world-readable copy at
# SHARE_DIR/<name> (runtime/share.cjs): the sandbox can read it but not
# change it, so it's where the privileged phase hands the sandbox its
# instructions (an agent's prompt and skills, a config).
let ShareName = validator
  (fun s => std.string.is_match "^[A-Za-z0-9][A-Za-z0-9._-]*$" s)
  (fun s => "share name `%{s}` must be a single path component ([A-Za-z0-9][A-Za-z0-9._-]*)")
in

# Everything the sandbox can read, so no credentials either.
let ShareNoCredentials = validator
  (fun s => !(mentions_credentials s))
  (fun s => "a share is readable by the sandbox, so it cannot reference secrets or github.token")
in

let ShareStep = {
  name | String | optional,
  id | String | optional,
  "if" | String | optional,
  "continue-on-error" | Bool | optional,
  share | std.contract.Sequence [
    {
      name | ShareName,
      # A file or directory in the workspace; symlinks are refused.
      path | ShareNoCredentials | optional,
      # Or the file's content.
      content | ShareNoCredentials | optional,
    },
    validator
      (fun sh => std.record.has_field "path" sh != std.record.has_field "content" sh)
      (fun sh => "share `%{sh.name}` needs exactly one of `path` or `content`"),
  ],
} in

# An `upload` step in `steps` uploads a file or directory from the
# sandbox's workspace as an artifact. Allowlisted actions run as runner
# and follow symlinks, so upload-artifact pointed at the workspace would
# upload whatever the sandbox links there (/proc/self/environ holds the
# job's runtime token). The compiler emits instead a step that has the
# wrapper's root side copy the path, refusing symlinks, to a root-owned
# directory (runtime/run.cjs), then upload-artifact on that copy.
let UPLOAD_ARTIFACT = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in # v7.0.1
let COLLECT_DIR = "/run/runner-sandbox/collect" in
let UploadStep = {
  name | String | optional,
  # The collecting step's id (default `collect-<upload.name>`): its outcome
  # says whether the path could be uploaded.
  id | String | optional,
  "if" | String | optional,
  "continue-on-error" | Bool | optional,
  upload | {
    name | validator
      (fun s => std.string.is_match "^[A-Za-z0-9_-]+$" s)
      (fun s => "upload name `%{s}` must match [A-Za-z0-9_-]+"),
    # Relative to the sandbox's workspace.
    path | validator
      (fun s => std.string.is_match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" s && !(std.string.is_match "(^|/)\\.\\.?(/|$)" s))
      (fun s => "upload path `%{s}` must be relative to the workspace, without `.` or `..`"),
    "retention-days" | Number | optional,
  },
} in

# No `shell` (the compiler sets it) and no `working-directory` (the wrapper
# owns the working directory): both are errors here.
let SandboxStep = fun allowed => std.contract.Sequence [
  {
    name | String | optional,
    id | String | optional,
    "if" | String | optional,
    run | NoCredentials | optional,
    uses | Pinned | optional,
    with | { _ : NoCredentials } | optional,
    env | { _ : NoCredentials } | SafeEnvNames | optional,
    "continue-on-error" | Bool | optional,
    "timeout-minutes" | Number | optional,
  },
  OneOfRunUses,
  Allowed allowed,
] in

let Sandbox = {
  user | String | validator (fun s => std.string.is_match USER_RE s) (fun s => "invalid user name `%{s}`") | default = "runner-sandbox",
  # Take root away from the runner user too, once the sandbox is entered;
  # its only sudo rule left is the wrapper.
  lock_runner_sudo | Bool | default = true,
  # Actions (owner/repo[/path], without @ref) allowed in `steps`. They run as
  # the runner user, not in the sandbox, so keep this short, and never point
  # one at a path the sandbox can write: use an `upload` step for artifacts.
  allowed_actions | Array String | default = [],
} in

# A relative path in the workspace, without `.` or `..` components.
let WorkspacePath = fun what => validator
  (fun s => std.string.is_match "^[^/]+(/[^/]+)*$" s && !(std.string.is_match "(^|/)\\.\\.?(/|$)" s))
  (fun s => "%{what} `%{s}` must be relative to the workspace, without `.` or `..`")
in

# What the enter step copies from the runner's workspace into the
# sandbox's (runtime/handoff.cjs). Nothing else of the runner's crosses,
# and a copy holding credentials (checkout's token, an .npmrc token) is
# refused.
let Handoff = {
  # 'tracked: the files git tracks, so nothing a setup step generated or
  # downloaded comes along unless listed in `include`; 'all: the whole
  # workspace; 'none: an empty directory.
  workspace | [| 'tracked, 'all, 'none |] | default = 'tracked,
  # More workspace paths to copy with 'tracked (e.g. `.git`, or what
  # runner_steps generated).
  include | Array (WorkspacePath "handoff.include path") | default = [],
} in

let Job = {
  name | String | optional,
  "runs-on" | Dyn,
  "timeout-minutes" | Number | optional,
  "if" | String | optional,
  needs | Dyn | optional,
  permissions | { _ : String } | optional,
  sandbox | Sandbox | default = {},
  handoff | Handoff | default = {},
  # RunnerStep or ShareStep, checked in compile_job.
  runner_steps | Array Dyn | default = [],
  steps | Array Dyn,
} in

let Workflow = {
  name | String,
  "run-name" | String | optional,
  on | Dyn,
  permissions | { _ : String } | optional,
  concurrency | Dyn | optional,
  jobs | { _ : Job },
} in

let install_step = fun sandbox job_handoff =>
  let config = {
    user = sandbox.user,
    lockRunnerSudo = sandbox.lock_runner_sudo,
    handoff = { workspace = std.string.from_enum job_handoff.workspace, include = job_handoff.include },
    # Expanded by Actions when the step runs.
    workspace = "${{ github.workspace }}",
  }
  in
  {
    name = "Enter the sandbox (generated)",
    # sudo resets the environment; the runner's NOPASSWD: ALL rule allows
    # keeping these.
    shell = "sudo --preserve-env=RUNNER_SANDBOX_EXEC_JS,RUNNER_SANDBOX_RUN_JS,RUNNER_SANDBOX_HANDOFF_JS node {0}",
    env = {
      RUNNER_SANDBOX_EXEC_JS = import "../runtime/exec.cjs" as 'Text,
      RUNNER_SANDBOX_RUN_JS = import "../runtime/run.cjs" as 'Text,
      RUNNER_SANDBOX_HANDOFF_JS = import "../runtime/handoff.cjs" as 'Text,
    },
    run = "const CONFIG = %{std.serialize 'Json config};\n" ++ (import "../runtime/install.cjs" as 'Text),
  }
in

# Runs before the sandbox is entered, as root: closes what the runner
# image leaves open to local users other than runner.
# TODO: `uses = "cgwalters-forge/actions/secure-host-setup@<sha>"` once
# that action exists, in place of this inline copy of it.
let secure_host_step = {
  name = "Secure the host (generated)",
  shell = "sudo node {0}",
  run = import "../runtime/secure-host.cjs" as 'Text,
} in

let share_step = fun step =>
  let share = step.share in
  let source = if std.record.has_field "path" share then { SHARE_PATH = share.path } else { SHARE_CONTENT = share.content } in
  step
  |> std.record.remove "share"
  |> (fun s => if std.record.has_field "name" s then s else std.record.insert "name" "Share %{share.name} as %{SHARE_DIR}/%{share.name} (generated)" s)
  # Settings go through env, where Actions expands expressions into data, not
  # into the script's source.
  |> std.record.insert "env" ({ SHARE_NAME = share.name } & source)
  |> std.record.insert "shell" "sudo --preserve-env=SHARE_NAME,SHARE_PATH,SHARE_CONTENT node {0}"
  |> std.record.insert "run" (import "../runtime/share.cjs" as 'Text)
in

let runner_step = fun step =>
  if std.record.has_field "share" step then share_step (step | ShareStep) else step | RunnerStep
in

let sandbox_step = fun step =>
  if std.record.has_field "run" step then
    let env = if std.record.has_field "env" step then step.env else {} in
    let env_names = std.record.fields env in
    let step = step |> std.record.insert "shell" "%{EXEC} {0}" in
    if env_names == [] then
      step
    else
      step
      |> std.record.remove "env"
      |> std.record.insert "env" (std.record.insert "RUNNER_SANDBOX_ENV" (std.string.join "," env_names) env)
  else
    step
in

let upload_steps = fun step =>
  let up = step.upload in
  let id = if std.record.has_field "id" step then step.id else "collect-%{up.name}" in
  let collect_step =
    step
    |> std.record.remove "upload"
    |> std.record.filter (fun name _v => name != "id" && name != "name")
    |> std.record.insert "id" id
    |> std.record.insert "name" (if std.record.has_field "name" step then step.name else "Collect %{up.path} for upload (generated)")
    |> std.record.insert "shell" "bash"
    |> std.record.insert "run" "%{EXEC} --collect %{up.name} %{up.path}"
  in
  [
    collect_step,
    {
      name = "Upload %{up.name} (generated)",
      "if" = "!cancelled() && steps.%{id}.outcome == 'success'",
      uses = UPLOAD_ARTIFACT,
      with = { name = up.name, path = "%{COLLECT_DIR}/%{up.name}", if-no-files-found = "error" }
        & (if std.record.has_field "retention-days" up then { retention-days = up."retention-days" } else {}),
    },
  ]
in

let COMPILER_FIELDS = ["sandbox", "handoff", "runner_steps", "steps"] in

let compile_job = fun job =>
  let sandbox = job.sandbox in
  let steps =
    std.array.flat_map
      (fun s =>
        if std.record.has_field "upload" s then
          upload_steps (s | UploadStep)
        else
          [sandbox_step (s | SandboxStep sandbox.allowed_actions)])
      job.steps
  in
  job
  |> std.record.filter (fun name _v => !(std.array.elem name COMPILER_FIELDS))
  |> std.record.insert "steps" (std.array.map runner_step job.runner_steps @ [secure_host_step, install_step sandbox job.handoff] @ steps)
in

{
  share_dir = SHARE_DIR,
  compile = fun source =>
    let wf = source | Workflow in
    wf
    |> std.record.remove "jobs"
    |> std.record.insert "jobs" (std.record.map (fun _name job => compile_job job) wf.jobs),
}
