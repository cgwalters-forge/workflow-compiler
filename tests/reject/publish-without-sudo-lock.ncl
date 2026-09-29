# expect: publish_steps need sandbox.lock_runner_sudo
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    sandbox.lock_runner_sudo = false,
    steps = [{ run = "id" }],
    publish_steps = [{ run = "id" }],
  },
}
