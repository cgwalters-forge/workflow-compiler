# expect: sandboxed steps cannot reference secrets
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ run = "make", env = { TOKEN = "${{ secrets.GITHUB_TOKEN }}" } }],
  },
}
