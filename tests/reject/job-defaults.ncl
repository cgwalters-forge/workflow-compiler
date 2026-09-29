# expect: extra field `defaults`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    defaults = { run = { shell = "bash {0}" } },
    steps = [{ run = "id" }],
  },
}
