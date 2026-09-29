# expect: must be strings (quote numbers and booleans)
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ run = "echo $RETRIES", env = { RETRIES = 1 } }],
  },
}
