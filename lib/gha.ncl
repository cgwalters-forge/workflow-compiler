# A GitHub Actions workflow in which every job has three phases
# (docs/requirements.md has the whole picture).
#
# `runner_steps` run as the stock `runner` user, with its sudo, and set the
# machine up: packages, checkout, network. The compiler then adds a step
# that secures the host (runtime/secure-host.cjs) and one that enters the
# sandbox (runtime/install.cjs), handing it the workspace. A `share` runner
# step publishes a file to the sandbox read-only, under SHARE_DIR. Every
# step in `steps` runs after that as the unprivileged sandbox user: `run:`
# steps get the sandbox wrapper as their shell, and `stage` and `upload`
# steps hand files out of it. A generated step then seals the sandbox, and
# `publish_steps` run as runner, without sudo, with the job's tokens,
# reading only what was staged.
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
# The text after each `${{` in S (split gives [] for "").
let expressions = fun s =>
  let parts = std.string.split "${{" s in
  if parts == [] then [] else std.array.drop_first parts
in
let CREDENTIALS_RE = "(?i)\\bsecrets\\b|\\bgithub\\s*(\\[|[,)}]|\\.\\s*token\\b|\\.\\s*\\*)" in
let mentions_credentials = fun s =>
  std.array.any
    (fun expr => std.string.is_match CREDENTIALS_RE expr)
    (expressions s)
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

# Until the shim runs pure actions in the sandbox (#16), `steps` has no
# actions at all: one there would run as runner, with the job's tokens.
let NoActionInSandbox = validator
  (fun step => !(std.record.has_field "uses" step))
  (fun step => "`%{step.uses}` can't run in `steps` yet: credentialed actions go in `publish_steps`, which read staged outputs, and pure actions will run in the sandbox through a shim (#16)")
in

# Text others control (an issue's, a comment's or a pull request's, in
# `github.event.*` and `github.head_ref`; a caller's or dispatcher's
# `inputs`; another job's `needs.*.outputs`, which may come from its
# sandbox) must not be spliced into a privileged step's script: Actions
# expands `${{ }}` in `run:`, and github-script evaluates its `script:`, so
# that would be code execution as runner. In `env:` it stays data, as long
# as the script doesn't expand that env value again. The numbers and ids
# GitHub assigns (an issue's, a pull request's, a comment's) are allowed;
# a payload's own `id` or `number` fields are not. A lint on the expression text, like the secrets
# check (#25).
let UNTRUSTED_TEXT_RE = "(?i)\\bgithub\\s*(\\.\\s*(event|head_ref)\\b|\\.\\s*\\*|\\[|[,)}]|$)|\\binputs\\b|\\bneeds\\s*(\\.\\s*[A-Za-z0-9_*-]+\\s*(\\.\\s*outputs\\b|\\[)|\\[|\\.\\s*\\*|[,)}]|$)" in
let SAFE_EVENT_RE = "(?i)\\bgithub\\s*\\.\\s*event\\s*\\.\\s*(number|(issue|pull_request|comment|review|review_comment|discussion|discussion_comment|release|milestone|workflow_run|check_run|check_suite|deployment|repository|sender)\\s*\\.\\s*(number|id))\\b" in
let untrusted_expression = fun e => std.string.is_match UNTRUSTED_TEXT_RE (std.string.replace_regex SAFE_EVENT_RE "0" e) in
let has_untrusted_text = fun s => std.is_string s && std.array.any untrusted_expression (expressions s) in
# The step's env names whose values hold such text, and whether an
# expression expands one of them (or all of `env`) again.
let tainted_env = fun step =>
  if std.record.has_field "env" step then
    std.array.filter (fun n => has_untrusted_text step.env."%{n}") (std.record.fields step.env)
  else
    []
in
let expands_env = fun names e =>
  names != []
  && (std.string.is_match "(?i)\\benv\\s*(\\[|\\.\\s*\\*|[,)}]|$)" e
    || std.array.any (fun n => std.string.is_match "(?i)\\benv\\s*\\.\\s*%{n}\\b" e) names)
in
# The strings of a privileged step that are code: its `run`, and in
# `with`, github-script's `script` or, for a publish step (which reads
# only staged data otherwise), every value.
let script_strings = fun all_with step =>
  (if std.record.has_field "run" step then [step.run] else [])
  @ (
    if !(std.record.has_field "with" step) then
      []
    else if all_with then
      std.record.values step.with
    else if std.record.has_field "script" step.with then
      [step.with.script]
    else
      []
  )
in
let NoUntrustedTextInScript = fun all_with => validator
  (fun step =>
    let tainted = tainted_env step in
    !(std.array.any
      (fun s => has_untrusted_text s || (std.is_string s && std.array.any (expands_env tainted) (expressions s)))
      (script_strings all_with step)))
  (fun _step => "a privileged step's script can't expand text others control (`github.event`, `github.head_ref`, `inputs`, `needs.*.outputs`, or an env value holding them): whoever wrote it would be writing code that runs as runner; pass it in `env:` and use the shell variable")
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
  NoUntrustedTextInScript false,
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

# A `stage` step in `steps` hands a file or directory out of the sandbox's
# workspace: the wrapper's root side copies it, refusing symlinks and
# special files, to a root-owned directory, STAGED_DIR/<name>/, where
# publish_steps read it (`gha.staged "<name>"`). Actions in publish_steps
# run as runner and follow symlinks, so they must never read a path the
# sandbox can write; after the seal they can't anyway.
#
# An `upload` step is a stage step plus an upload-artifact publish step
# for it.
let UPLOAD_ARTIFACT = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in # v7.0.1
let STAGED_DIR = "/run/runner-sandbox/staged" in
# The id of the generated seal step, which publish steps check.
let SEAL_ID = "runner-sandbox-seal" in
let StageName = validator
  (fun s => std.string.is_match "^[A-Za-z0-9_-]+$" s)
  (fun s => "stage name `%{s}` must match [A-Za-z0-9_-]+")
in
let StagePath = validator
  (fun s => std.string.is_match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" s && !(std.string.is_match "(^|/)\\.\\.?(/|$)" s))
  (fun s => "stage path `%{s}` must be relative to the workspace, without `.` or `..`")
in
let StageFields = {
  name | String | optional,
  # The staging step's id (default `stage-<name>`): its outcome says
  # whether the path could be staged.
  id | String | optional,
  "if" | String | optional,
  "continue-on-error" | Bool | optional,
} in
let StageStep = StageFields & { stage | { name | StageName, path | StagePath } } in
let UploadStep = StageFields & {
  upload | {
    name | StageName,
    # Relative to the sandbox's workspace.
    path | StagePath,
    "retention-days" | Number | optional,
  },
} in

# No `shell` (the compiler sets it) and no `working-directory` (the wrapper
# owns the working directory): both are errors here.
let SandboxStep = std.contract.Sequence [
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
  NoActionInSandbox,
] in

# Expressions in a publish step's `run`, `with` and `env` may not use a
# sandboxed step's outputs: they are strings the sandbox chose, and a
# publish step runs as runner with the job's tokens, so they would be
# script injection into it (#1). Only outputs of publish steps are
# allowed, and whole-context spellings (`toJSON(steps)`, `steps['x']`) not
# at all. A step's `outcome` and `conclusion` are set by the runner, and
# `if:` is not checked. Like the secrets check, it looks at all of S after
# each `${{`.
let STEP_OUTPUTS_RE = "(?i)\\bsteps\\s*\\.\\s*([A-Za-z0-9_-]+)\\s*\\.\\s*outputs\\b" in
let WHOLE_STEPS_RE = "(?i)\\bsteps\\b\\s*(\\[|[,)}]|$|\\.\\s*\\*|\\.\\s*[A-Za-z0-9_-]+\\s*(\\[|\\.\\s*\\*))" in
let uses_sandbox_outputs = fun publish_ids s =>
  std.is_string s
  && std.array.any
    (fun expr =>
      std.string.is_match WHOLE_STEPS_RE expr
      || std.array.any
        (fun m => !(std.array.elem (std.string.lowercase (std.array.first m.groups)) publish_ids))
        (std.string.find_all STEP_OUTPUTS_RE expr))
    (expressions s)
in
let step_strings = fun step =>
  (if std.record.has_field "run" step then [step.run] else [])
  @ (if std.record.has_field "working-directory" step then [step."working-directory"] else [])
  @ (if std.record.has_field "with" step then std.record.values step.with else [])
  @ (if std.record.has_field "env" step then std.record.values step.env else [])
in
let NoSandboxOutputs = fun publish_ids => validator
  (fun step => !(std.array.any (uses_sandbox_outputs publish_ids) (step_strings step)))
  (fun step => "a publish step can't use sandboxed steps' outputs in `run`, `working-directory`, `with` or `env`: they are strings the sandbox chose; stage a file instead, or test them in `if`")
in

let PublishStep = fun publish_ids => std.contract.Sequence [
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
  NoSandboxOutputs publish_ids,
  NoUntrustedTextInScript true,
] in

let Sandbox = {
  user | String | validator (fun s => std.string.is_match USER_RE s) (fun s => "invalid user name `%{s}`") | default = "runner-sandbox",
  # Take root away from the runner user too, once the sandbox is entered;
  # its only sudo rule left is the wrapper.
  lock_runner_sudo | Bool | default = true,
} in

# A relative path in the workspace, without `.` or `..` components.
let WorkspacePath = fun what => validator
  (fun s => std.string.is_match "^[^/]+(/[^/]+)*$" s && !(std.string.is_match "(^|/)\\.\\.?(/|$)" s) && !(std.string.contains "${{" s))
  (fun s => "%{what} `%{s}` must be relative to the workspace, without `.`, `..` or an expression (Actions would expand it into the enter step's script, which runs as root)")
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
  # SandboxStep, StageStep or UploadStep.
  steps | Array Dyn,
  # PublishStep: as runner, after the seal.
  publish_steps | Array Dyn | default = [],
} in

# publish_steps run as runner after untrusted code; only with runner's
# root taken away can they not undo the sandbox or read Runner.Worker's
# memory (#32).
let PublishNeedsLock = validator
  (fun job => job.publish_steps == [] || job.sandbox.lock_runner_sudo)
  (fun _job => "publish_steps need sandbox.lock_runner_sudo: they run as runner after the sandbox, which must not have root by then")
in

let Workflow = {
  name | String,
  "run-name" | String | optional,
  on | Dyn,
  permissions | { _ : String } | optional,
  concurrency | Dyn | optional,
  jobs | { _ : std.contract.Sequence [Job, PublishNeedsLock] },
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

# The sandboxed step that stages STEP's `stage` or `upload` record (FIELD).
let stage_step = fun field step =>
  let st = step."%{field}" in
  let id = if std.record.has_field "id" step then step.id else "stage-%{st.name}" in
  step
  |> std.record.remove field
  |> std.record.filter (fun name _v => name != "id" && name != "name")
  |> std.record.insert "id" id
  |> std.record.insert "name" (if std.record.has_field "name" step then step.name else "Stage %{st.path} as %{st.name} (generated)")
  |> std.record.insert "shell" "bash"
  |> std.record.insert "run" "%{EXEC} --stage %{st.name} %{st.path}"
in

# The publish step uploading what an `upload` step staged.
let upload_publish_step = fun step =>
  let up = step.upload in
  let id = if std.record.has_field "id" step then step.id else "stage-%{up.name}" in
  {
    name = "Upload %{up.name} (generated)",
    "if" = "!cancelled() && steps.%{id}.outcome == 'success' && steps.%{SEAL_ID}.outcome == 'success'",
    uses = UPLOAD_ARTIFACT,
    with = { name = up.name, path = "%{STAGED_DIR}/%{up.name}", if-no-files-found = "error" }
      & (if std.record.has_field "retention-days" up then { retention-days = up."retention-days" } else {}),
  }
in

# Runs as runner once the sandboxed steps are done, whether they
# succeeded or not: the wrapper's root side stops the sandbox's processes
# and makes its files unreadable to runner, so publish_steps (and the
# post-steps of runner_steps actions) can only read what was staged.
let seal_step = {
  name = "Seal the sandbox (generated)",
  id = SEAL_ID,
  "if" = "always()",
  shell = "bash",
  run = "%{EXEC} --seal",
} in

let COMPILER_FIELDS = ["sandbox", "handoff", "runner_steps", "steps", "publish_steps"] in

let compile_job = fun job =>
  let sandbox = job.sandbox in
  let steps =
    std.array.map
      (fun s =>
        if std.record.has_field "stage" s then
          stage_step "stage" (s | StageStep)
        else if std.record.has_field "upload" s then
          stage_step "upload" (s | UploadStep)
        else
          sandbox_step (s | SandboxStep))
      job.steps
  in
  let uploads = std.array.map upload_publish_step (std.array.filter (fun s => std.record.has_field "upload" s) job.steps) in
  let publish_ids =
    std.array.map (fun s => std.string.lowercase s.id) (std.array.filter (fun s => std.is_record s && std.record.has_field "id" s) job.publish_steps)
  in
  # Fail closed: a publish step runs only after a successful seal, on top
  # of its own condition (with the implicit success() if it has none).
  let after_seal = fun s =>
    let raw = if std.record.has_field "if" s then std.string.trim s."if" else "success()" in
    let cond =
      if std.string.is_match "^\\$\\{\\{.*\\}\\}$" raw then
        std.string.substring 3 (std.string.length raw - 2) raw
      else
        raw
    in
    # The condition is wrapped in parentheses, so they must balance in it
    # (outside string literals), or `always()) || (true` would escape; and
    # it must be one expression, not a template like `${{ 'a' }} ${{ 'b' }}`,
    # which is a string, and true.
    let depths =
      std.array.fold_left
        (fun acc c => if c == "(" then acc @ [std.array.last acc + 1] else if c == ")" then acc @ [std.array.last acc - 1] else acc)
        [0]
        (std.string.characters (std.string.replace_regex "'([^']|'')*'" "''" cond))
    in
    if std.array.any (fun d => d < 0) depths || std.array.last depths != 0
      || std.string.contains "${{" cond || std.string.contains "}}" cond then
      std.fail_with "a publish step's `if` must be one expression with balanced parentheses: %{cond}"
    else
      std.record.filter (fun n _v => n != "if") s
      |> std.record.insert "if" "(%{std.string.trim cond}) && steps.%{SEAL_ID}.outcome == 'success'"
  in
  let publish = std.array.map (fun s => after_seal (s | PublishStep publish_ids)) job.publish_steps in
  job
  |> std.record.filter (fun name _v => !(std.array.elem name COMPILER_FIELDS))
  |> std.record.insert "steps" (
    std.array.map runner_step job.runner_steps
    @ [secure_host_step, install_step sandbox job.handoff]
    @ steps
    @ [seal_step]
    @ uploads
    @ publish
  )
in

{
  share_dir = SHARE_DIR,
  # Where publish_steps find what a `stage` step named NAME staged.
  staged = fun name => "%{STAGED_DIR}/%{name}",
  compile = fun source =>
    let wf = source | Workflow in
    wf
    |> std.record.remove "jobs"
    |> std.record.insert "jobs" (std.record.map (fun _name job => compile_job job) wf.jobs),
}
