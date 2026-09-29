# expect: a publish step's `if` must be one expression with balanced parentheses
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "id" }],
    publish_steps = [{ "if" = "always()) || (true", run = "id" }],
  },
}
