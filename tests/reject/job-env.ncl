# expect: extra field `env`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    env.LD_PRELOAD = "/tmp/x.so",
    steps = [{ run = "id" }],
  },
}
