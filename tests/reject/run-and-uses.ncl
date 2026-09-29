# expect: exactly one of `run` or `uses`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ name = "nothing" }],
  },
}
