# expect: sandbox.network.allow entry `crates.io:443` must be a lowercase host name
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    sandbox.network.allow = ["crates.io:443"],
    steps = [{ run = "id" }],
  },
}
