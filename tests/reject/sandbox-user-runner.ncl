# expect: sandbox.user can't be `runner`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    sandbox.user = "runner",
    steps = [{ run = "id" }],
  },
}
