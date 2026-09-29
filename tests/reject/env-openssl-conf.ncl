# expect: cannot be set in a sandboxed step
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "id", env = { OPENSSL_CONF = "/tmp/x.cnf" } }],
  },
}
