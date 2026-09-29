# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    needs = "build",
    steps = [{ run = "id" }],
    publish_steps = [{ run = "echo ${{ needs.build.outputs.version }}" }],
  },
}
