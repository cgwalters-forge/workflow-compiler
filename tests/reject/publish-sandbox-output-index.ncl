# expect: a publish step can't use sandboxed steps' outputs
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ id = "out", run = "echo value=x >>\"$GITHUB_OUTPUT\"" }],
    publish_steps = [{ run = "echo ${{ steps['out'].outputs.value }}" }],
  },
}
