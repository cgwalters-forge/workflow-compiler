# expect: sets env `NODE_OPTIONS`, which a sandboxed step can't
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ uses = "wfc-test/composite-env@0000000000000000000000000000000000000000" }],
  },
}
