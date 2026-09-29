# expect: a publish step can't use sandboxed steps' outputs
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ id = "out", run = "echo dir=/etc >>\"$GITHUB_OUTPUT\"" }],
    publish_steps = [{ run = "ls", "working-directory" = "${{ steps.out.outputs.dir }}" }],
  },
}
