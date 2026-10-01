# expect: sandbox.network.allow entry `*.com` must be a lowercase host name
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    sandbox.network.allow = ["*.com"],
    steps = [{ run = "id" }],
  },
}
