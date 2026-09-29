# expect: a publish step's `if` must have balanced parentheses
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ run = "id" }],
    publish_steps = [{ "if" = "always()) || (true", run = "id" }],
  },
}
