# expect: uses a context an action's text may not
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ uses = "wfc-test/composite-env-context@0000000000000000000000000000000000000000" }],
  },
}
