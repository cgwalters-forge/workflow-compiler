# expect: extra field `env`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    env.LD_PRELOAD = "/tmp/x.so",
    steps = [{ run = "id" }],
  },
}
