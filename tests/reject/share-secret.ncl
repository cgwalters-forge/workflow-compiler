# expect: a share is readable by the sandbox
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    runner_steps = [{ share = { name = "token", content = "${{ secrets.API_KEY }}" } }],
    steps = [{ run = "id" }],
  },
}
