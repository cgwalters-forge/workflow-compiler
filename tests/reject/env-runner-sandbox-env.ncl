# expect: cannot be set in a sandboxed step
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ env = { RUNNER_SANDBOX_ENV = "GITHUB_TOKEN" }, run = "id" }],
  },
}
