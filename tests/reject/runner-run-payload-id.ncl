# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { repository_dispatch = {} },
  jobs.t = {
    runner_steps = [{ run = "echo ${{ github.event.client_payload.id }}" }],
    steps = [{ run = "id" }],
  },
}
