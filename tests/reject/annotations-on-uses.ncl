# expect: `annotations` applies to `run` steps only
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ uses = "wfc-test/composite-ok@0000000000000000000000000000000000000000", annotations = false }],
  },
}
