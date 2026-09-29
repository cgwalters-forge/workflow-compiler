# expect: that isn't a plain name with a value
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ uses = "wfc-test/composite-output-name@0000000000000000000000000000000000000000" }],
  },
}
