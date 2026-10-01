# expect: sandbox.network.allow entry `140.82.112.6` must be a lowercase host name
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    sandbox.network.allow = ["140.82.112.6"],
    steps = [{ run = "id" }],
  },
}
