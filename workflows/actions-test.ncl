# Real actions from the marketplace, run in the sandbox through the shim:
# a linter, a setup action that installs into the tool cache and adds to
# PATH, and a composite action (a spell checker that downloads its binary
# into RUNNER_TEMP and runs a script from its own directory). Also checks that what a step writes to GITHUB_ENV and
# GITHUB_PATH reaches later sandboxed steps and never the runner, and
# that outputs in the heredoc form come through without a way to smuggle
# another name. ci.yml runs it; compiled to
# .github/workflows/actions-test.lock.yml.
let gha = import "../lib/gha.ncl" in
let checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" in # v7.0.1
let markdownlint = "DavidAnson/markdownlint-cli2-action@21c1be1b93ad9ed58fa840aacc3f279cde2a72ff" in # v24.2.0
let setup_node = "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020" in # v7.0.0
let typos = "crate-ci/typos@00f422f3b19c57bc6338715ebfe3316d38768461" in # v1.50.3, a composite action

gha.compile {
  name = "Actions test",
  on = { workflow_call = {}, workflow_dispatch = {} },
  permissions = { contents = "read" },
  jobs.actions = {
    "runs-on" = "ubuntu-26.04",
    "timeout-minutes" = 15,
    runner_steps = [
      { uses = checkout, with = { persist-credentials = false } },
    ],
    steps = [
      {
        name = "Lint the Markdown, in the sandbox",
        uses = markdownlint,
        # A multi-line input.
        with.globs = m%"
          README.md
          docs/*.md
        "%,
      },
      {
        name = "Install Node 22 into the sandbox's tool cache",
        id = "node",
        uses = setup_node,
        with = { node-version = "22", package-manager-cache = "false" },
      },
      {
        name = "Spell-check a clean file with a composite action",
        uses = typos,
        with.files = "LICENSE-MIT",
      },
      {
        name = "Write a misspelled file",
        run = m%"echo "This is teh wrong spelling." >misspelled.txt"%,
      },
      {
        name = "The composite action finds it",
        id = "typo",
        "continue-on-error" = true,
        uses = typos,
        with.files = "misspelled.txt",
      },
      {
        name = "setup-node's PATH and outputs reach later sandboxed steps",
        env = { VERSION = "${{ steps.node.outputs.node-version }}" },
        run = m%"
          echo "node $(node --version) at $(command -v node), output $VERSION"
          case "$(node --version)" in v22.*) ;; *) echo "not Node 22"; exit 1 ;; esac
          case "$VERSION" in v22.*) ;; *) echo "no node-version output"; exit 1 ;; esac
          case "$(command -v node)" in /var/lib/runner-sandbox/toolcache/*) ;; *) echo "node is not from the tool cache"; exit 1 ;; esac
          test "$(stat -c %U "$(command -v node)")" = runner-sandbox
        "%,
      },
      {
        name = "Set environment for later sandboxed steps",
        id = "env",
        run = m%"
          echo "SANDBOX_GREETING=hello" >>"$GITHUB_ENV"
          mkdir -p ~/bin && printf '#!/bin/sh\necho sandbox-tool\n' >~/bin/sandbox-tool && chmod +x ~/bin/sandbox-tool
          echo ~/bin >>"$GITHUB_PATH"
          delim=EOF_$RANDOM
          printf 'multi<<%s\nline one\ninjected=1\n%s\n' "$delim" "$delim" >>"$GITHUB_OUTPUT"
        "%,
      },
      {
        name = "Read it back",
        env = {
          MULTI = "${{ steps.env.outputs.multi }}",
          INJECTED = "${{ steps.env.outputs.injected }}",
        },
        run = m%"
          test "$SANDBOX_GREETING" = hello
          test "$(sandbox-tool)" = sandbox-tool
          test "$MULTI" = "$(printf 'line one\ninjected=1')"
          test -z "$INJECTED"
        "%,
      },
      {
        name = "The sandbox can't set what the wrapper sets",
        id = "denied-env",
        "continue-on-error" = true,
        run = m%"echo "LD_PRELOAD=/tmp/x.so" >>"$GITHUB_ENV""%,
      },
      {
        name = "An unterminated heredoc output fails the step",
        id = "bad-heredoc",
        "continue-on-error" = true,
        run = m%"printf 'x<<EOF\nno end\n' >>"$GITHUB_OUTPUT""%,
      },
      {
        name = "Both failed",
        env = {
          DENIED = "${{ steps.denied-env.outcome }}",
          HEREDOC = "${{ steps.bad-heredoc.outcome }}",
          TYPO = "${{ steps.typo.outcome }}",
        },
        run = m%"test "$DENIED $HEREDOC $TYPO" = "failure failure failure""%,
      },
    ],
    publish_steps = [
      {
        name = "Nothing the sandbox set reached the runner",
        run = m%"
          if test -n "${SANDBOX_GREETING:-}"; then echo "GITHUB_ENV reached the runner"; exit 1; fi
          if command -v sandbox-tool; then echo "GITHUB_PATH reached the runner"; exit 1; fi
          echo "the runner's environment is its own"
        "%,
      },
    ],
  },
}
