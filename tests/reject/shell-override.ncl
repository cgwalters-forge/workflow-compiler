# expect: extra field `shell`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "id", shell = "bash {0}" }],
  },
}
