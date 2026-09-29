# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { pull_request_target = {} },
  jobs.t = {
    runner_steps = [{ run = "echo '${{ join(github.*, ',') }}'" }],
    steps = [{ run = "id" }],
  },
}
