# expect: must be a file under /etc/agent-share/
let gha = import "../../lib/gha.ncl" in
let agent_run = import "../../lib/agent-run.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  # The workspace is the sandbox's own, so an earlier step could rewrite it.
  jobs.t = agent_run { prompt = "/var/lib/runner-sandbox/work/agentskills/review.md" },
}
