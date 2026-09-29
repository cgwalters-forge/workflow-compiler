# A composite action (tests/actions/composite-ok) used twice: once with an
# input that is one of the caller's expressions, which mentions the
# caller's own step, and once with a literal holding `$`. The expected
# output shows the rewriting: the action's step ids under the caller's,
# the caller's `steps.build` left alone, `$` kept, sandbox paths.
let gha = import "../../lib/gha.ncl" in
let composite = "wfc-test/composite-ok@0000000000000000000000000000000000000000" in
gha.compile {
  name = "t",
  on = { push = {} },
  jobs.t = {
    "runs-on" = "ubuntu-26.04",
    steps = [
      { id = "build", run = m%"echo "v=1" >>"$GITHUB_OUTPUT""% },
      { id = "greet", uses = composite, with.who = "${{ steps.build.outputs.v }}" },
      { id = "again", uses = composite, with.who = "world $1" },
      { env.M = "${{ steps.greet.outputs.message }}", run = m%"echo "$M""% },
    ],
  },
}
