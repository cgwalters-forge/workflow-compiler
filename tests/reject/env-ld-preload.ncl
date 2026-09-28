# expect: cannot be set in a sandboxed step
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ env = { LD_PRELOAD = "./evil.so" }, run = "id" }],
  },
}
