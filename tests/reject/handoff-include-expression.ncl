# expect: without `.`, `..` or an expression
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { issues = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    handoff.include = ["${{ github.event.issue.title }}"],
    steps = [{ run = "id" }],
  },
}
