# expect: extra field `env`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  env.BASH_ENV = "/tmp/x.sh",
  jobs.t = {
    steps = [{ run = "id" }],
  },
}
