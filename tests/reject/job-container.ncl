# expect: extra field `container`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    container = { image = "fedora", options = "--user 1001" },
    steps = [{ run = "id" }],
  },
}
