# expect: a publish step can't use sandboxed steps' outputs
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ id = "out", run = "echo value=x >>\"$GITHUB_OUTPUT\"" }],
    publish_steps = [{ uses = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", with = { name = "${{ toJSON(steps) }}" } }],
  },
}
