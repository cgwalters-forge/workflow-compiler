# Provision the machine as `runner`, then run as the sandbox user and check
# that the sandbox holds nothing of the job's credentials and that escape
# attempts fail. ci.yml runs it; compiled to
# .github/workflows/sandbox-test.lock.yml.
let gha = import "../lib/gha.ncl" in
let checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" in # v7.0.1
let upload_artifact = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in # v7.0.1

gha.compile {
  name = "Sandbox test",
  on = { workflow_call = {}, workflow_dispatch = {} },
  permissions = { contents = "read" },
  jobs.sandbox = {
    "runs-on" = "ubuntu-24.04",
    "timeout-minutes" = 15,
    sandbox = {
      user = "runner-sandbox",
      allowed_actions = ["actions/upload-artifact"],
    },
    runner_steps = [
      { uses = checkout, with = { persist-credentials = false } },
      {
        name = "Install a tool system-wide",
        shell = "bash",
        run = m%"
          sudo tee /usr/local/bin/hello-tool >/dev/null <<'EOF'
          #!/bin/sh
          echo "installed by runner_steps, run by $(id -un)"
          EOF
          sudo chmod 0755 /usr/local/bin/hello-tool
        "%,
      },
    ],
    steps = [
      {
        name = "Runs as the sandbox user",
        run = m%"
          id
          test "$(id -un)" = runner-sandbox
          test "$PWD" = /var/lib/runner-sandbox/work
          test -f LICENSE
        "%,
      },
      { name = "sudo is refused", id = "sudo", "continue-on-error" = true, run = "sudo -n true" },
      {
        name = "The sudo step failed",
        env = { OUTCOME = "${{ steps.sudo.outcome }}" },
        run = m%"test "$OUTCOME" = failure"%,
      },
      {
        name = "The job's credentials are out of reach",
        run = m%"
          for v in ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_TOKEN GITHUB_ENV GITHUB_PATH; do
            if [[ -v $v ]]; then echo "$v is set"; exit 1; fi
          done
          worker=$(pgrep -f Runner.Worker | head -n1)
          test -n "$worker"
          if cat "/proc/$worker/environ" >/dev/null; then echo "read Runner.Worker's environment"; exit 1; fi
          if ls /home/runner >/dev/null; then echo "listed the runner's home"; exit 1; fi
          if docker ps >/dev/null 2>&1; then echo "reached a docker daemon"; exit 1; fi
          echo "no credentials reachable"
        "%,
      },
      { name = "Use what runner_steps installed", run = "hello-tool | tee hello.log" },
      {
        name = "Write a step output",
        id = "out",
        run = m%"
          echo "answer=42" >>"$GITHUB_OUTPUT"
          echo "Written from the sandbox by $(id -un)" >>"$GITHUB_STEP_SUMMARY"
        "%,
      },
      {
        name = "Read it back",
        env = { ANSWER = "${{ steps.out.outputs.answer }}" },
        run = m%"test "$ANSWER" = 42"%,
      },
      # Escape attempts: each must fail, or leave nothing behind.
      {
        name = "Point GITHUB_OUTPUT at a root-only file",
        id = "symlink",
        "continue-on-error" = true,
        run = m%"ln -sf /etc/shadow "$GITHUB_OUTPUT""%,
      },
      {
        name = "Smuggle a multi-line output",
        id = "heredoc",
        "continue-on-error" = true,
        run = m%"printf 'x<<EOF\nsomething\nEOF\n' >>"$GITHUB_OUTPUT""%,
      },
      {
        name = "Leave a process behind",
        run = m%"setsid sleep 600 </dev/null >/dev/null 2>&1 & echo "started $!""%,
      },
      {
        name = "The escapes failed",
        env = {
          SYMLINK = "${{ steps.symlink.outcome }}",
          HEREDOC = "${{ steps.heredoc.outcome }}",
        },
        run = m%"
          test "$SYMLINK" = failure
          test "$HEREDOC" = failure
          if pgrep -u runner-sandbox -x sleep; then echo "a process survived its step"; exit 1; fi
          echo "all escapes failed"
        "%,
      },
      {
        name = "Upload what the sandbox wrote",
        "if" = "always()",
        uses = upload_artifact,
        with = { name = "sandbox-test", path = "/var/lib/runner-sandbox/work/hello.log" },
      },
    ],
  },
}
