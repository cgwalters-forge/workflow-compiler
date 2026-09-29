# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { issue_comment = {} },
  jobs.t = {
    runner_steps = [{ run = "echo '${{ toJSON(github) }}' | jq ." }],
    steps = [{ run = "id" }],
  },
}
