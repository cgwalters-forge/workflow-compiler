# expect: extra field `env`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  env.BASH_ENV = "/tmp/x.sh",
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ run = "id" }],
  },
}
