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
    shell = "sudo --preserve-env=RUNNER_SANDBOX_EXEC_JS,RUNNER_SANDBOX_RUN_JS,RUNNER_SANDBOX_HANDOFF_JS,RUNNER_SANDBOX_FILECMD_JS,RUNNER_SANDBOX_LAUNCH_JS node {0}",
    env = {
      RUNNER_SANDBOX_EXEC_JS = import "../runtime/exec.cjs" as 'Text,
      RUNNER_SANDBOX_RUN_JS = import "../runtime/run.cjs" as 'Text,
      RUNNER_SANDBOX_HANDOFF_JS = import "../runtime/handoff.cjs" as 'Text,
      RUNNER_SANDBOX_FILECMD_JS = import "../runtime/filecmd.cjs" as 'Text,
      RUNNER_SANDBOX_LAUNCH_JS = import "../runtime/launch.cjs" as 'Text,
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

# Actions in `steps` run in the sandbox: the shim. A generated step
# before the sandbox is entered fetches each one at its pinned commit into
# a root-owned directory (runtime/fetch-actions.cjs), and the step runs its
# entry point there as the sandbox user (runtime/launch.cjs), with
# its inputs as INPUT_* and sandbox-owned file-command files, which the
# wrapper validates on the way out. Their metadata comes from
# actions.lock.json, which compile.mjs fills: nickel can't fetch anything.
#
# Everything taken from an action's metadata is its author's text, not
# the workflow author's, and it ends up in the lock file, where Actions
# evaluates it with the job's contexts. So it is held to allowlists:
# names and paths to fixed patterns, and expressions to literals, a few
# functions and contexts that hold no credentials (ACTION_CONTEXTS), plus
# the action's own inputs and steps. Its env names never become the
# runner-side wrapper's own variables (see mapped_env).
let ACTIONS_LOCK = import "../actions.lock.json" in
let ACTIONS_DIR = "/opt/runner-sandbox/actions" in
# The sandbox's paths, as runtime/install.cjs creates them, for the
# contexts an action's defaults and composite steps name.
let SANDBOX_CONTEXTS = [
  { re = "(?i)\\bgithub\\s*\\.\\s*workspace\\b", path = "/var/lib/runner-sandbox/work" },
  { re = "(?i)\\brunner\\s*\\.\\s*temp\\b", path = "/var/lib/runner-sandbox/temp" },
  { re = "(?i)\\brunner\\s*\\.\\s*tool_cache\\b", path = "/var/lib/runner-sandbox/toolcache" },
] in
let IDENT_RE = "^[A-Za-z_][A-Za-z0-9_-]*$" in
let ENTRY_RE = "^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$" in
# What an action's expressions may use besides its own inputs and steps.
let ACTION_CONTEXTS = [
  "(?i)\\bgithub\\s*\\.\\s*(action_path|workspace|repository|repository_owner|repository_id|ref|ref_name|ref_type|sha|server_url|api_url|graphql_url|run_id|run_number|run_attempt|workflow|workflow_ref|job|action|action_ref|action_repository|event_name|actor|base_ref|retention_days)\\b",
  "(?i)\\brunner\\s*\\.\\s*(os|arch|name|temp|tool_cache|debug|environment)\\b",
  "(?i)\\bjob\\s*\\.\\s*status\\b",
  "(?i)\\b(true|false|null)\\b",
  "\\b0x[0-9a-fA-F]+\\b",
  "\\b[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?\\b",
] in
# Not hashFiles: the runner evaluates it over its own files, which would
# make it an oracle for them.
let ACTION_FUNCTIONS_RE = "(?i)\\b(contains|startsWith|endsWith|format|join|toJSON|fromJSON|success|failure|always|cancelled)\\s*\\(" in

let action_meta = fun uses =>
  if std.record.has_field uses ACTIONS_LOCK then
    ACTIONS_LOCK."%{uses}"
  else
    std.fail_with "action `%{uses}` is not in actions.lock.json; run node compile.mjs to lock its metadata"
in

# Whether E, the inside of a `${{ }}` in an action's text, uses nothing
# but literals, operators, the functions above, ACTION_CONTEXTS and what
# the regexes in ALLOWED match: once string literals and all of those are
# taken out, no name may be left.
let action_expression_ok = fun allowed e =>
  let rest =
    std.array.fold_left
      (fun acc re => std.string.replace_regex re "0" acc)
      (std.string.replace_regex ACTION_FUNCTIONS_RE "(" (std.string.replace_regex "'([^']|'')*'" "''" e))
      (ACTION_CONTEXTS @ allowed)
  in
  !(std.string.is_match "[A-Za-z_]" rest)
in
# The inside of each `${{ }}` in S, up to its `}}` (string literals taken
# out first, so a `}}` in one doesn't end it), rather than all the text
# after it as `expressions` gives.
let expression_bodies = fun s =>
  std.array.map
    (fun p =>
      let q = std.string.replace_regex "'([^']|'')*'" "''" p in
      if std.string.contains "}}" q then std.string.substring 0 (std.string.find "\\}\\}" q).index q else q)
    (expressions s)
in
let action_text_ok = fun allowed s => std.array.all (action_expression_ok allowed) (expression_bodies s) in

# Whether COND has balanced parentheses outside string literals, and no
# `${{ }}` inside, so it can be wrapped as `(COND) && ...`.
let one_expression = fun cond =>
  let depths =
    std.array.fold_left
      (fun acc c => if c == "(" then acc @ [std.array.last acc + 1] else if c == ")" then acc @ [std.array.last acc - 1] else acc)
      [0]
      (std.string.characters (std.string.replace_regex "'([^']|'')*'" "''" cond))
  in
  !(std.array.any (fun d => d < 0) depths) && std.array.last depths == 0
  && !(std.string.contains "${{" cond) && !(std.string.contains "}}" cond)
in

# F applied to the inside of every `${{ }}` in S. (Not with split on
# `}}`: std.string.split drops a trailing empty piece.)
let map_exprs = fun f s =>
  let parts = std.string.split "${{" s in
  if parts == [] then
    s
  else
    std.string.join "${{" (
      [std.array.first parts]
      @ std.array.map
        (fun p =>
          if std.string.contains "}}" p then
            let at = (std.string.find "\\}\\}" p).index in
            f (std.string.substring 0 at p) ++ std.string.substring at (std.string.length p) p
          else
            f p)
        (std.array.drop_first parts)
    )
in

# Contexts that name the runner's paths name the sandbox's instead. (The
# replacements are literal: std.string.replace_regex expands no groups.)
let sandbox_paths = map_exprs (fun e =>
  std.array.fold_left (fun acc c => std.string.replace_regex c.re "'%{c.path}'" acc) e SANDBOX_CONTEXTS)
in

# The directory the fetch step puts USES in.
let action_dir = fun uses =>
  let at = std.string.split "@" uses in
  let parts = std.string.split "/" (std.array.first at) in
  std.string.join "/" ([ACTIONS_DIR, std.array.at 0 parts, std.array.at 1 parts, std.array.at 1 at] @ std.array.drop_first (std.array.drop_first parts))
in

let input_env_name = fun name => "INPUT_%{std.string.uppercase (std.string.replace " " "_" name)}" in

# The inputs an action declares, their names checked.
let declared_inputs = fun ref meta =>
  let inputs = if std.record.has_field "inputs" meta && meta.inputs != null then meta.inputs else {} in
  let bad = std.array.filter (fun n => !(std.string.is_match IDENT_RE n)) (std.record.fields inputs) in
  if bad != [] then std.fail_with "`%{ref}` declares an input named `%{std.array.first bad}`, which isn't a plain name" else inputs
in

# The INPUT_* variables of an action: the step's `with`, else the input's
# default. A default naming the job's token or secrets is dropped (the
# sandbox has none); any other default must pass the allowlist.
let input_env = fun ref meta with =>
  let inputs = declared_inputs ref meta in
  let default_of = fun name =>
    let i = inputs."%{name}" in
    if !(std.is_record i) || !(std.record.has_field "default" i) || i.default == null then
      []
    else if std.is_number i.default || std.is_bool i.default then
      [std.to_string i.default]
    else if !(std.is_string i.default) || mentions_credentials i.default then
      []
    else if action_text_ok [] i.default then
      [
        map_exprs
          (fun e => std.string.replace_regex "(?i)\\bgithub\\s*\\.\\s*action_path\\b" "'%{action_dir ref}'" e)
          (sandbox_paths i.default)
      ]
    else
      std.fail_with "the default of input `%{name}` of `%{ref}` uses a context an action's text may not: %{i.default}"
  in
  let names = std.record.fields inputs @ std.array.filter (fun n => !(std.record.has_field n inputs)) (std.record.fields with) in
  std.array.fold_left
    (fun acc name =>
      let v = if std.record.has_field name with then [with."%{name}"] else default_of name in
      if v == [] then acc else std.record.insert (input_env_name name) (std.array.first v) acc)
    {}
    names
in

# `env` with RUNNER_SANDBOX_ENV listing its names, which exec.cjs forwards.
let with_env_list = fun env =>
  let names = std.record.fields env in
  if names == [] then env else std.record.insert "RUNNER_SANDBOX_ENV" (std.string.join "," names) env
in

# The env of a step generated from an action, whose names are the
# action's: they must not become the runner-side wrapper's own variables
# (NODE_OPTIONS there would run code as runner, GITHUB_OUTPUT redirect
# its writes), so each value goes under a fixed name, RUNNER_SANDBOX_VAR_<i>,
# and exec.cjs gives it its name in the request, which the root side
# checks again.
let mapped_env = fun ref env =>
  let names = std.record.fields env in
  let bad = std.array.filter (fun n => !(std.string.is_match IDENT_RE n) || std.string.is_match DENIED_ENV_RE n) names in
  if bad != [] then
    std.fail_with "`%{ref}` sets env `%{std.array.first bad}`, which a sandboxed step can't"
  else if names == [] then
    {}
  else
    std.array.fold_left
      (fun acc i => std.record.insert "RUNNER_SANDBOX_VAR_%{std.to_string i}" env."%{std.array.at i names}" acc)
      { RUNNER_SANDBOX_ENV_NAMES = std.string.join "," names }
      (std.array.generate (fun i => i) (std.array.length names))
in

let JS_RUNTIMES = ["node12", "node16", "node20", "node24"] in
# Actions known to need the job's runtime token, which the sandbox never
# has: they would fail there, so say where they go instead.
let CREDENTIALED_ACTIONS = [
  "actions/upload-artifact", "actions/download-artifact",
  "actions/cache", "actions/cache/save", "actions/cache/restore",
] in

# An entry point from action.yml, which goes into the step's spec.
let entry_point = fun ref p =>
  if std.is_string p && std.string.is_match ENTRY_RE p && !(std.string.is_match "(^|/)\\.\\.?(/|$)" p) then
    p
  else
    std.fail_with "`%{ref}` has an entry point `%{std.to_string p}` that isn't a plain path in the action"
in

# A step's condition as an expression, `success()` when it has none.
let condition = fun step =>
  if std.record.has_field "if" step then
    let raw = std.string.trim step."if" in
    if std.string.is_match "^\\$\\{\\{.*\\}\\}$" raw then std.string.trim (std.string.substring 3 (std.string.length raw - 2) raw) else raw
  else
    "success()"
in

# An input's value as an expression for a composite action's steps, in
# which `inputs.NAME` is replaced by it: a string literal, or the one
# expression the value is.
let input_expression = fun ref name value =>
  let trimmed = std.string.trim value in
  if !(std.string.contains "${{" value) then
    "'%{std.string.replace "'" "''" value}'"
  else if std.string.is_match "^\\$\\{\\{(?s:.)*\\}\\}$" trimmed
    && std.array.length (std.string.find_all "\\$\\{\\{" trimmed) == 1
    && std.array.length (std.string.find_all "\\}\\}" trimmed) == 1 then
    std.string.trim (std.string.substring 3 (std.string.length trimmed - 2) trimmed)
  else
    std.fail_with "input `%{name}` of `%{ref}` mixes text and expressions, which the compiler can't pass into a composite action's steps"
in

# F applied to S as an expression: to each `${{ }}` in it, or to all of it
# for an `if:` without them.
let map_condition = fun f s => if std.string.contains "${{" s then map_exprs f s else f s in

let rec action_steps = fun key step =>
  let ref = step.uses in
  let meta = (action_meta ref).metadata in
  let runs = meta.runs in
  let using = if std.record.has_field "using" runs then runs.using else "" in
  let with = if std.record.has_field "with" step then step.with else {} in
  let user_env = if std.record.has_field "env" step then step.env else {} in
  let step_env = mapped_env ref (std.array.fold_left (fun acc f => std.record.update f user_env."%{f}" acc) (input_env ref meta with) (std.record.fields user_env)) in
  let common = std.record.filter (fun n _v => std.array.elem n ["name", "if", "continue-on-error", "timeout-minutes"]) step in
  let spec = fun entry_path => std.serialize 'Json { uses = ref, entry = entry_point ref entry_path, stateKey = key } in
  let fetched = [{ uses = ref, file = (action_meta ref).file, sha256 = (action_meta ref).sha256 }] in
  if std.array.elem (std.array.first (std.string.split "@" ref)) CREDENTIALED_ACTIONS then
    std.fail_with "`%{ref}` needs the job's credentials, which the sandbox doesn't have: put it in `publish_steps` (reading what a `stage` step staged), or use an `upload` step"
  else if std.array.elem using JS_RUNTIMES then
    if std.record.has_field "pre" runs then
      std.fail_with "`%{ref}` has a `pre` entry point, which the sandbox shim doesn't run; use it in runner_steps if it needs no sandbox"
    else
      {
        main = [
          common
          & {
            name | default = "Run %{ref} (sandboxed)",
            id = key,
            shell = "%{EXEC} --action {0}",
            run = spec runs.main,
            env = step_env,
          }
        ],
        post =
          if std.record.has_field "post" runs then
            let post_if = if std.record.has_field "post-if" runs then std.string.trim runs."post-if" else "always()" in
            if !(std.is_string post_if) || !(one_expression post_if) || !(action_expression_ok [] post_if) then
              std.fail_with "`%{ref}` has a `post-if` the compiler can't use: %{std.to_string post_if}"
            else
              [
                {
                  name = "Post %{ref} (generated)",
                  "if" = "(%{post_if}) && steps.%{key}.outcome != 'skipped'",
                  shell = "%{EXEC} --action {0}",
                  run = spec runs.post,
                  env = step_env,
                }
              ]
          else
            [],
        fetch = fetched,
      }
  else if using == "composite" then
    # Expanded here, each of its steps a sandboxed step of this job: its
    # `run:` steps get GITHUB_ACTION_PATH from the wrapper, its `uses:`
    # steps go through the shim in turn. Its text must pass the allowlist,
    # with its own inputs and steps allowed too; then `inputs.X`,
    # `github.action_path` and step ids in its expressions are rewritten
    # for the caller's job.
    let inputs = declared_inputs ref meta in
    let inner_steps = if std.record.has_field "steps" runs && std.is_array runs.steps then runs.steps else [] in
    # Longest first, in the allowlist's alternations and in the rewriting,
    # so `inputs.ver` doesn't match the start of `inputs.ver-file`.
    let longest_first = std.array.sort (fun a b =>
      let la = std.string.length a in
      let lb = std.string.length b in
      if la > lb then 'Lesser else if la < lb then 'Greater else 'Equal)
    in
    let own_ids = std.array.flat_map (fun s => if std.is_record s && std.record.has_field "id" s then [s.id] else []) inner_steps in
    let bad_ids = std.array.filter (fun id => !(std.is_string id) || !(std.string.is_match IDENT_RE id)) own_ids in
    let outputs = if std.record.has_field "outputs" meta && meta.outputs != null then meta.outputs else {} in
    let output_names = std.record.fields outputs in
    let bad_outputs = std.array.filter (fun n => !(std.string.is_match IDENT_RE n) || !(std.is_record outputs."%{n}") || !(std.record.has_field "value" outputs."%{n}")) output_names in
    let allowed =
      (if inputs == {} then [] else ["(?i)\\binputs\\s*\\.\\s*(%{std.string.join "|" (longest_first (std.record.fields inputs))})\\b"])
      @ (if own_ids == [] then [] else ["(?i)\\bsteps\\s*\\.\\s*(%{std.string.join "|" (longest_first own_ids)})\\s*\\.\\s*(outputs\\s*\\.\\s*[A-Za-z0-9_-]+|outcome|conclusion)\\b"])
    in
    # Checks S, a piece of the action's text, and returns it.
    let checked = fun what s =>
      if !(std.is_string s) then
        std.fail_with "`%{ref}` has a %{what} that isn't a string"
      else if std.string.contains "@@wfc-" s then
        std.fail_with "the %{what} of a step of `%{ref}` holds `@@wfc-`, which the compiler uses for its own rewriting"
      else if action_text_ok allowed s then
        s
      else
        std.fail_with "the %{what} of a step of `%{ref}` uses a context an action's text may not (only its inputs, its own steps' outputs and a few non-secret contexts): %{s}"
    in
    # An input's default, which GitHub doesn't let name `steps` or
    # `inputs`: it goes in after the step ids are renamed, so the action's
    # own steps there would be the caller's.
    let checked_default = fun d =>
      if std.string.contains "@@wfc-" d then
        std.fail_with "the default of an input of `%{ref}` holds `@@wfc-`, which the compiler uses for its own rewriting"
      else if action_text_ok [] d then
        d
      else
        std.fail_with "the default of an input of `%{ref}` uses a context an input default may not (no steps or inputs, only a few non-secret contexts): %{d}"
    in
    let checked_condition = fun c =>
      if one_expression c && action_expression_ok allowed c then
        c
      else
        std.fail_with "a step of `%{ref}` has an `if` the compiler can't use: %{c}"
    in
    let value_of = fun name =>
      if std.record.has_field name with then
        with."%{name}"
      else
        let i = inputs."%{name}" in
        if std.is_record i && std.record.has_field "default" i && i.default != null then
          (
            if std.is_string i.default then
              # The action's own text: its runner paths and action path
              # are rewritten here, since it goes in after that pass.
              (
                if mentions_credentials i.default then
                  ""
                else
                  map_exprs
                    (fun e => std.string.replace_regex "(?i)\\bgithub\\s*\\.\\s*action_path\\b" "'%{action_dir ref}'" e)
                    (sandbox_paths (checked_default i.default))
              )
            else
              std.to_string i.default
          )
        else
          ""
    in
    # The rewriting goes through placeholders, so a replacement is never
    # rewritten again: an input's value may be the caller's expression,
    # with the caller's own `steps.x` or `inputs.y` in it. (Replacements
    # are literal: std.string.replace_regex expands no groups.)
    let input_names = longest_first (std.record.fields inputs) in
    # Placeholders are names, which the allowlist refuses in the text
    # itself, so the action can't write one.
    let placeholder = fun kind i => "@@wfc-%{kind}%{std.to_string i}@@" in
    let own_ids_ordered = longest_first own_ids in
    let rewrite_expr = fun e =>
      let own_steps =
        std.array.fold_left
          (fun acc i => std.string.replace_regex "(?i)\\bsteps\\s*\\.\\s*%{std.array.at i own_ids_ordered}\\b" (placeholder "s" i) acc)
          e
          (std.array.generate (fun i => i) (std.array.length own_ids_ordered))
      in
      let marked =
        std.array.fold_left
          (fun acc i => std.string.replace_regex "(?i)\\binputs\\s*\\.\\s*%{std.array.at i input_names}\\b" (placeholder "i" i) acc)
          own_steps
          (std.array.generate (fun i => i) (std.array.length input_names))
      in
      let paths =
        std.array.fold_left
          (fun acc c => std.string.replace_regex c.re "'%{c.path}'" acc)
          (std.string.replace_regex "(?i)\\bgithub\\s*\\.\\s*action_path\\b" "'%{action_dir ref}'" marked)
          SANDBOX_CONTEXTS
      in
      let with_steps =
        std.array.fold_left
          (fun acc i => std.string.replace (placeholder "s" i) "steps.%{key}__%{std.array.at i own_ids_ordered}" acc)
          paths
          (std.array.generate (fun i => i) (std.array.length own_ids_ordered))
      in
      std.array.fold_left
        (fun acc i =>
          let name = std.array.at i input_names in
          std.string.replace (placeholder "i" i) "(%{input_expression ref name (value_of name)})" acc)
        with_steps
        (std.array.generate (fun i => i) (std.array.length input_names))
    in
    # The rewritten text is sandboxed, and the caller's `with` values went
    # into it: like the source's own, it may not name the token or secrets.
    let rewrite = fun what s =>
      let out = map_exprs rewrite_expr (checked what s) in
      if mentions_credentials out then
        std.fail_with "a step of `%{ref}` references secrets or github.token, which the sandbox doesn't have"
      else
        out
    in
    let rewrite_record = fun what r => std.record.map (fun _k v => if std.is_string v then rewrite what v else checked what v) r in
    let outer_if = condition step in
    let inner_key_of = fun i =>
      let inner = std.array.at i inner_steps in
      "%{key}__%{if std.record.has_field "id" inner then inner.id else std.to_string i}"
    in
    let expanded =
      std.array.generate
        (fun i =>
          let inner = std.array.at i inner_steps in
          let inner_key = inner_key_of i in
          # A composite action stops at its first failing step.
          let earlier_ok = std.array.generate (fun j => " && steps.%{inner_key_of j}.outcome != 'failure'") i in
          let inner_if = map_condition rewrite_expr (checked_condition (condition inner)) in
          let cond = "(%{outer_if}) && (%{inner_if})%{std.string.join "" earlier_ok}" in
          let shared =
            { "if" = cond, id = inner_key }
            & (if std.record.has_field "name" inner then { name = rewrite "name" inner.name } else {})
            & std.record.filter (fun n _v => std.array.elem n ["continue-on-error", "timeout-minutes"]) step
          in
          if std.record.has_field "working-directory" inner then
            std.fail_with "a step of `%{ref}` sets `working-directory`, which sandboxed steps can't"
          else if std.record.has_field "uses" inner then
            action_steps inner_key (
              { uses = inner.uses | Pinned }
              & shared
              & (if std.record.has_field "with" inner then { with = rewrite_record "`with`" inner.with } else {})
              & (if std.record.has_field "env" inner || user_env != {} then { env = user_env & (if std.record.has_field "env" inner then rewrite_record "`env`" inner.env else {}) } else {})
            )
          else if !(std.record.has_field "shell" inner) || !(std.array.elem inner.shell ["bash", "sh"]) then
            std.fail_with "a step of `%{ref}` runs with shell `%{if std.record.has_field "shell" inner then std.to_string inner.shell else "(none)"}`; sandboxed composite steps run with bash"
          else
            {
              main = [
                shared
                & {
                  name | default = "Run %{ref} step %{std.to_string (i + 1)} (sandboxed)",
                  shell = "%{EXEC} --action-path %{ref} {0}",
                  run = rewrite "`run`" inner.run,
                  env = mapped_env ref (std.array.fold_left (fun acc f => std.record.update f user_env."%{f}" acc) (if std.record.has_field "env" inner then rewrite_record "`env`" inner.env else {}) (std.record.fields user_env)),
                }
              ],
              post = [],
              fetch = [],
            })
        (std.array.length inner_steps)
    in
    # The step that stands for the whole action, with its id: it fails if
    # one of the action's steps failed, and sets the action's outputs.
    let n_inner = std.array.length inner_steps in
    let outputs_step = [
      std.record.filter (fun n _v => std.array.elem n ["continue-on-error"]) step
      & {
        name = "Finish %{ref} (generated)",
        id = key,
        "if" = "!cancelled() && (%{outer_if})",
        shell = "%{EXEC} {0}",
        env =
          mapped_env ref (
            std.array.fold_left (fun acc i => std.record.insert "OUTCOME_%{std.to_string i}" "${{ steps.%{inner_key_of i}.outcome }}" acc) {} (std.array.generate (fun i => i) n_inner)
            & std.array.fold_left (fun acc i => std.record.insert "OUTPUT_%{std.to_string i}" (rewrite "output" outputs."%{std.array.at i output_names}".value) acc) {} (std.array.generate (fun i => i) (std.array.length output_names))
          ),
        run =
          std.string.join "\n" (
            std.array.generate (fun i => "test \"$OUTCOME_%{std.to_string i}\" != failure") n_inner
            @ ["delim=ghadelimiter_$(cat /proc/sys/kernel/random/uuid)"]
            @ std.array.generate
              (fun i => "printf '%s<<%s\\n%s\\n%s\\n' %{std.array.at i output_names} \"$delim\" \"$OUTPUT_%{std.to_string i}\" \"$delim\" >>\"$GITHUB_OUTPUT\"")
              (std.array.length output_names)
          ),
      }
    ] in
    if bad_ids != [] then
      std.fail_with "`%{ref}` has a step id `%{std.to_string (std.array.first bad_ids)}` that isn't a plain name"
    else if bad_outputs != [] then
      std.fail_with "`%{ref}` has an output `%{std.array.first bad_outputs}` that isn't a plain name with a value"
    else
      {
        main = std.array.flat_map (fun e => e.main) expanded @ outputs_step,
        post = std.array.flat_map (fun e => e.post) expanded,
        fetch = fetched @ std.array.flat_map (fun e => e.fetch) expanded,
      }
  else if using == "docker" then
    std.fail_with "`%{ref}` is a Docker action, which can't run in the sandbox (no container engine as root); run the tool in a `run:` step with rootless podman instead"
  else
    std.fail_with "`%{ref}` runs with `%{using}`, which the sandbox shim doesn't support"
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

# The generated step that fetches the sandbox's actions, one clone per
# repository and commit, or nothing when the job uses none.
let fetch_steps = fun fetch =>
  let by_commit =
    std.array.fold_left
      (fun acc f =>
        let at = std.string.split "@" f.uses in
        let parts = std.string.split "/" (std.array.first at) in
        let repository = "%{std.array.at 0 parts}/%{std.array.at 1 parts}" in
        let k = "%{repository}@%{std.array.at 1 at}" in
        let prev = if std.record.has_field k acc then acc."%{k}".files else {} in
        std.record.update k { repo = repository, sha = std.array.at 1 at, files = std.record.update f.file f.sha256 prev } acc)
      {}
      fetch
  in
  if fetch == [] then
    []
  else
    [
      {
        name = "Fetch the sandbox's actions (generated)",
        shell = "sudo --preserve-env=RUNNER_SANDBOX_ACTIONS node {0}",
        env.RUNNER_SANDBOX_ACTIONS = std.serialize 'Json (std.record.values by_commit),
        run = import "../runtime/fetch-actions.cjs" as 'Text,
      }
    ]
in

let compile_job = fun job =>
  let sandbox = job.sandbox in
  let compiled =
    std.array.generate
      (fun i =>
        let s = std.array.at i job.steps in
        if std.record.has_field "stage" s then
          { main = [stage_step "stage" (s | StageStep)], post = [], fetch = [] }
        else if std.record.has_field "upload" s then
          { main = [stage_step "upload" (s | UploadStep)], post = [], fetch = [] }
        else
          let s = s | SandboxStep in
          if std.record.has_field "uses" s then
            action_steps (if std.record.has_field "id" s then s.id else "action-%{std.to_string i}") s
          else
            { main = [sandbox_step s], post = [], fetch = [] })
      (std.array.length job.steps)
  in
  let steps = std.array.flat_map (fun c => c.main) compiled in
  let posts = std.array.reverse (std.array.flat_map (fun c => c.post) compiled) in
  let fetch = std.array.flat_map (fun c => c.fetch) compiled in
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
    @ fetch_steps fetch
    @ [secure_host_step, install_step sandbox job.handoff]
    @ steps
    @ posts
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
