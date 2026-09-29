# expect: that isn't a plain path in the action
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ uses = "wfc-test/js-main-expression@0000000000000000000000000000000000000000" }],
  },
}
