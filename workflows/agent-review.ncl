# The whole source of an agent job: run the agent on a prompt from the
# repository's agentskills/ directory. lib/agent-run.ncl expands it into
# the privileged setup, the share and the sandboxed agent step; ci.yml
# runs it. Compiled to .github/workflows/agent-review.lock.yml.
let gha = import "../lib/gha.ncl" in
let agent_run = import "../lib/agent-run.ncl" in

gha.compile {
  name = "Agent review",
  on = { workflow_call = {}, workflow_dispatch = {} },
  permissions = { contents = "read" },
  jobs.review = agent_run { prompt = "/etc/agent-share/agentskills/review.md" },
}
