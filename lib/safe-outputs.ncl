# safe-outputs: the job that applies what an agent job proposed, the way
# gh-aw's safe outputs work. The agent, in its sandbox with no token,
# writes proposals (one JSON object per line, gh-aw's `type` and fields)
# to safe-outputs/outputs.jsonl, and `upload` hands them out:
#
#   jobs.agent = agent_run { ... } |> with steps @ [safe_outputs.upload],
#   jobs.apply = safe_outputs.apply {
#     needs = "agent",
#     repo = "owner/name",
#     types.add_comment = { targets = [12] },
#   },
#
# The apply job's token has only the permissions its enabled types need.
# The proposals, the config and the scripts come into its sandbox as
# shares, the scripts from the lock file rather than any checkout, and
# runtime/safe-outputs-validate.cjs sorts them there, with no token, into
# accepted outputs and rejections. Its publish phase then checks every
# accepted output again, with the same code and the same caps, sanitizes
# its text again (mentions, HTML comments, workflow commands), and only
# then writes (runtime/safe-outputs-apply.cjs).
#
# Types: add_comment on listed issues, noop, and
# create_pull_request (a `git diff` the job applies to a fresh fetch of
# `base`, pushes as a new branch and opens as a pull request).
let gha = import "gha.ncl" in
let download = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c" in # v8.0.1
let ARTIFACT = "safe-outputs" in
let DIR = "safe-outputs" in
let SHARE = gha.share_dir in
let LIB = "safe-outputs-lib.cjs" in
let VALIDATE = "safe-outputs-validate.cjs" in
let APPLY = "safe-outputs-apply.cjs" in
let CONFIG = "safe-outputs-config.json" in
let PROPOSALS = "safe-outputs-proposals" in
let VALIDATED = "safe-outputs-validated" in

let Positive = std.contract.from_predicate (fun n => std.is_number n && n >= 1 && std.number.is_integer n) in
let Repo = std.contract.from_predicate (fun s => std.is_string s && std.string.is_match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$" s) in
# A branch name, or with a trailing / a prefix of one.
let branch = fun prefix => std.contract.from_predicate (fun s =>
  std.is_string s
  && std.string.is_match "^[A-Za-z0-9][A-Za-z0-9._/-]*$" s
  && !(std.string.is_match "\\.\\.|//|\\.lock(/|$)" s)
  && (prefix || !(std.string.is_match "/$" s)))
in

let SafeOutputs = {
  # The agent job, whose `upload` step handed out the proposals.
  needs | String,
  # The repository the outputs go to: the workflow's own, since the job's
  # token can't write anywhere else.
  repo | Repo,
  # Outputs applied per run, whatever their types.
  max_total | Positive | default = 3,
  types | {
    add_comment | {
      max | Positive | default = 1,
      # The issues a comment may go on; the first is where one without
      # an item_number goes.
      targets | Array Positive,
      max_body_bytes | Positive | default = 16384,
    } | optional,
    create_pull_request | {
      max | Positive | default = 1,
      # The branch the patch applies to and the pull request targets.
      base | branch false,
      # Globs (`*` within a directory, `**` across) of the paths a patch
      # may change. `.github/`, `.git` and `.gitmodules` never.
      allowed_paths | Array String,
      max_patch_bytes | Positive | default = 65536,
      max_files | Positive | default = 20,
      max_body_bytes | Positive | default = 16384,
      branch_prefix | branch true | default = "safe-outputs/",
      draft | Bool | default = true,
    } | optional,
    noop | { max | Positive | default = 1 } | optional,
  },
  "runs-on" | String | default = gha.default_runner,
  "timeout-minutes" | Number | default = 10,
} in

# The job token's permissions: only what the enabled types write with.
let permissions_for = fun types =>
  (if std.record.has_field "add_comment" types then { issues = "write" } else {})
  & (if std.record.has_field "create_pull_request" types then { contents = "write", "pull-requests" = "write" } else {})
in

{
  # Where the agent writes its proposals, relative to its workspace.
  dir = DIR,
  # The agent job's step that hands out the proposals.
  upload = { "if" = "always()", upload = { name = ARTIFACT, path = DIR } },
  apply = fun args =>
    let a = args | SafeOutputs in
    let config = { repo = a.repo, max_total = a.max_total, types = a.types } in
    {
      needs = a.needs,
      "runs-on" = a."runs-on",
      "timeout-minutes" = a."timeout-minutes",
      permissions = permissions_for a.types,
      # Nothing from the repository: the scripts come from the lock file.
      handoff.workspace = 'none,
      runner_steps = [
        { uses = download, with = { name = ARTIFACT, path = PROPOSALS } },
        { share = { name = PROPOSALS, path = PROPOSALS } },
        { share = { name = CONFIG, content = std.serialize 'Json config } },
        { share = { name = LIB, content = import "../runtime/safe-outputs-lib.cjs" as 'Text } },
        { share = { name = VALIDATE, content = import "../runtime/safe-outputs-validate.cjs" as 'Text } },
        { share = { name = APPLY, content = import "../runtime/safe-outputs-apply.cjs" as 'Text } },
      ],
      steps = [
        {
          name = "Check the proposals",
          run = "node %{SHARE}/%{VALIDATE} %{SHARE}/%{LIB} %{SHARE}/%{CONFIG} %{SHARE}/%{PROPOSALS} validated",
        },
        { upload = { name = VALIDATED, path = "validated" } },
      ],
      publish_steps = [
        {
          name = "Check and apply the outputs",
          run = "node %{SHARE}/%{APPLY} %{SHARE}/%{LIB} %{SHARE}/%{CONFIG} %{gha.staged VALIDATED}/validated/validated.json",
          env = { GITHUB_TOKEN = "${{ github.token }}" },
        },
      ],
    },
}
