# expect: uses a context an input default may not
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ uses = "wfc-test/composite-default-steps@0000000000000000000000000000000000000000" }],
  },
}
