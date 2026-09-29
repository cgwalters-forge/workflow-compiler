# expect: extra field `services`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    services.db = { image = "postgres" },
    steps = [{ run = "id" }],
  },
}
