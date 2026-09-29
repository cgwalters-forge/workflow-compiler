# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { issues = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    runner_steps = [{ env = { TITLE = "${{ github.event.issue.title }}" }, run = "echo \"${{ env.TITLE }}\"" }],
    steps = [{ run = "id" }],
  },
}
