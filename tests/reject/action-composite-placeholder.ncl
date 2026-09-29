# expect: which the compiler uses for its own rewriting
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ uses = "wfc-test/composite-placeholder@0000000000000000000000000000000000000000" }],
  },
}
