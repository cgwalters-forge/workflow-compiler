# expect: a privileged step's script can't expand text others control
let gha = import "../../lib/gha.ncl" in
gha.compile {
  name = "t",
  on = { issue_comment = {} },
  jobs.t = {
    steps = [{ run = "id" }],
    publish_steps = [{
      uses = "actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3", # v9.0.0
      with.script = "core.info('${{ github.event.comment.body }}')",
    }],
  },
}
