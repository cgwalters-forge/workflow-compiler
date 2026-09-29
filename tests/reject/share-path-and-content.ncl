# expect: needs exactly one of `path` or `content`
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    runner_steps = [{ share = { name = "prompt", path = "prompt.md", content = "hi" } }],
    steps = [{ run = "id" }],
  },
}
