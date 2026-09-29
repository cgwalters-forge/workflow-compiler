# expect: uses a context an action's text may not
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ uses = "wfc-test/composite-steps-context@0000000000000000000000000000000000000000" }],
  },
}
