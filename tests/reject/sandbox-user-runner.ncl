# expect: sandbox.user can't be `runner`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    sandbox.user = "runner",
    steps = [{ run = "id" }],
  },
}
