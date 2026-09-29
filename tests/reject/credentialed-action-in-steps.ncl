# expect: needs the job's credentials, which the sandbox doesn't have
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [{ uses = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", with = { path = "x" } }],
  },
}
