# expect: cannot be set in a sandboxed step
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ env = { NODE_OPTIONS = "--require ./evil.js" }, run = "id" }],
  },
}
