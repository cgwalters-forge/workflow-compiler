# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { workflow_call = { inputs.ref = { type = "string" } } },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    runner_steps = [{ run = "git fetch origin ${{ inputs.ref }}" }],
    steps = [{ run = "id" }],
  },
}
