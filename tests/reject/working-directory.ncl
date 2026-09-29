# expect: extra field `working-directory`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "id", "working-directory" = "/" }],
  },
}
