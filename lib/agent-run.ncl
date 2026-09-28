# agent-run: a whole sandboxed agent job from little more than a prompt.
#
#   jobs.review = agent_run { prompt = "/etc/agent-share/agentskills/review.md" }
#
# expands into a job for gha.ncl whose privileged phase checks out the
# repository, shares its skills directory read-only at
# /etc/agent-share/<skills.name> and installs the agent, and whose
# sandboxed phase runs the agent on the prompt and uploads what it wrote.
# The prompt must be inside a share, so the agent reads instructions that
# nothing in the sandbox could have rewritten.
#
# It is a compiler macro rather than a composite action on purpose: a
# composite action runs as runner, with the job's tokens, takes whatever
# `with:` and `env:` its caller passes, and can't constrain the steps
# around it. Here the result goes through gha.compile like any other job,
# so the same contracts hold for it.
#
# Proof of concept: the agent is runtime/agent-stub.sh, which reads the
# prompt, tries a few escapes, and writes a stub review.
let gha = import "gha.ncl" in
let checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" in # v7.0.1
let AGENT = "/usr/local/bin/agent-stub" in

let InShare =
  std.contract.from_validator (fun p =>
    if std.string.is_match "^/etc/agent-share/[^/]+(/[^/]+)*$" p && !(std.string.is_match "(^|/)\\.\\.?(/|$)" p) then
      'Ok
    else
      'Error { message = "agent-run's prompt `%{p}` must be a file under %{gha.share_dir}/, where the privileged phase shares it" }
  )
in

let AgentRun = {
  # The prompt file, under a share.
  prompt | String | InShare,
  # The repository directory shared as the agent's skills.
  skills | { name | String, path | String } | default = { name = "agentskills", path = "agentskills" },
  "runs-on" | String | default = "ubuntu-26.04",
  "timeout-minutes" | Number | default = 30,
} in

fun args =>
  let a = args | AgentRun in
  {
    "runs-on" = a."runs-on",
    "timeout-minutes" = a."timeout-minutes",
    runner_steps = [
      { uses = checkout, with = { persist-credentials = false } },
      { share = { name = a.skills.name, path = a.skills.path } },
      {
        name = "Install the agent (stub)",
        shell = "bash",
        env = { AGENT_STUB = import "../runtime/agent-stub.sh" as 'Text },
        run = m%"
          printf '%s' "$AGENT_STUB" | sudo tee %{AGENT} >/dev/null
          sudo chmod 0755 %{AGENT}
        "%,
      },
    ],
    steps = [
      {
        name = "Run the agent",
        id = "agent",
        env = { PROMPT = a.prompt },
        run = m%"%{AGENT} "$PROMPT""%,
      },
      { "if" = "always()", upload = { name = "agent-output", path = "review.md" } },
    ],
  }
