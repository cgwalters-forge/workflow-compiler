# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { pull_request_target = {} },
  jobs.t = {
    steps = [{ run = "id" }],
    publish_steps = [{ run = "echo ${{ GITHUB.HEAD_REF }}" }],
  },
}
