# expect: extra field `share`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ share = { name = "prompt", content = "hi" } }],
  },
}
