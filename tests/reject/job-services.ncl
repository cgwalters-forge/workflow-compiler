# expect: extra field `services`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    services.db = { image = "postgres" },
    steps = [{ run = "id" }],
  },
}
