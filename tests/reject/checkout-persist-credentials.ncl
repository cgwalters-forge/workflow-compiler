# expect: must set `with.persist-credentials = false`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    runner_steps = [{ uses = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" }],
    steps = [{ run = "id" }],
  },
}
