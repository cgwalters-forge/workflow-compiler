# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { issues = {} },
  jobs.t = {
    runner_steps = [{ run = "echo \"${{ github.event.issue.title }}\"" }],
    steps = [{ run = "id" }],
  },
}
