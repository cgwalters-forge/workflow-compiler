# expect: handoff.include path `../home` must be relative to the workspace
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    handoff.include = ["../home"],
    steps = [{ run = "id" }],
  },
}
