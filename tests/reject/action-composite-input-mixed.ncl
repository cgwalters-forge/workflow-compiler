# expect: mixes text and expressions
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [
      { id = "build", run = "true" },
      { uses = "wfc-test/composite-ok@0000000000000000000000000000000000000000", with.who = "dear ${{ steps.build.outputs.v }}" },
    ],
  },
}
