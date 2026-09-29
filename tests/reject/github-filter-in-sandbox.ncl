# expect: sandboxed steps cannot reference secrets or github.token
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "echo \"${{ join(github.*, ',') }}\"" }],
  },
}
