# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { workflow_call = { inputs.ref = { type = "string" } } },
  jobs.t = {
    runner_steps = [{ run = "git fetch origin ${{ inputs.ref }}" }],
    steps = [{ run = "id" }],
  },
}
