# expect: sandboxed steps cannot reference secrets
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ env = { KEY = "${{ format('{0}', secrets.API_KEY) }}" }, run = "env" }],
  },
}
