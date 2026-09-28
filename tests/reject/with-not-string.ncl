# expect: must be strings (quote numbers and booleans)
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    sandbox.allowed_actions = ["actions/upload-artifact"],
    steps = [{ uses = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", with = { name = "x", path = "x", retention-days = 1 } }],
  },
}
