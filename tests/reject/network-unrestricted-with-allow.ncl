# expect: sandbox.network: `allow` and `unrestricted = true` together
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    sandbox.network = { allow = ["crates.io"], unrestricted = true },
    steps = [{ run = "id" }],
  },
}
