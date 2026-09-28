# expect: must be a single path component
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    runner_steps = [{ share = { name = "../sudoers.d/x", content = "runner ALL=(ALL) ALL" } }],
    steps = [{ run = "id" }],
  },
}
