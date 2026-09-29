# expect: sandboxed steps cannot reference secrets or github.token
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ run = "echo \"${{ join(github.*, ',') }}\"" }],
  },
}
