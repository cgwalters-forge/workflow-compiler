# expect: sandbox.user can't be `root`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    sandbox.user = "root",
    steps = [{ run = "id" }],
  },
}
