# expect: has a `post-if` the compiler can't use
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    steps = [{ uses = "wfc-test/js-post-if@0000000000000000000000000000000000000000" }],
  },
}
