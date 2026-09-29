# expect: must be strings (quote numbers and booleans)
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "echo $RETRIES", env = { RETRIES = 1 } }],
  },
}
