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
    "runs-on" = "ubuntu-26.04",
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
          ln -s /etc/shadow shadow-link
          ln -s /etc shadow-dir
        "%,
      },
      # Shares, read-only to the sandbox: content, a file, a directory.
      { share = { name = "greeting", content = "hello from ${{ github.job }}" } },
      { share = { name = "LICENSE", path = "LICENSE" } },
      { share = { name = "reject-tests", path = "tests/reject" } },
      # A symlink in the checkout must not publish its target.
      { id = "share-symlink", "continue-on-error" = true, share = { name = "shadow", path = "shadow-link" } },
      { id = "share-symlink-dir", "continue-on-error" = true, share = { name = "shadow2", path = "shadow-dir/shadow" } },
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
      {
        name = "Runs in a login session of its own, not as if under sudo",
        run = m%"
          test "$XDG_RUNTIME_DIR" = "/run/user/$(id -u)"
          loginctl show-session "$XDG_SESSION_ID" -p Name -p Class
          test "$(loginctl show-session "$XDG_SESSION_ID" -p Name --value)" = runner-sandbox
          if env | grep ^SUDO_; then echo "SUDO_* leaked into the sandbox"; exit 1; fi
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
      {
        name = "Read the shares, and fail to change them",
        env = {
          SYMLINK_SHARE = "${{ steps.share-symlink.outcome }}",
          SYMLINK_DIR_SHARE = "${{ steps.share-symlink-dir.outcome }}",
        },
        run = m%"
          cd %{gha.share_dir}
          ls -lR
          test "$(cat greeting)" = "hello from $GITHUB_JOB"
          cmp LICENSE /var/lib/runner-sandbox/work/LICENSE
          test -f reject-tests/shell-override.ncl
          test "$(stat -c '%U:%G %a' . greeting LICENSE reject-tests reject-tests/shell-override.ncl)" = "$(printf 'root:root %s\n' 755 644 644 755 644)"
          test "$SYMLINK_SHARE" = failure && test ! -e shadow
          test "$SYMLINK_DIR_SHARE" = failure && test ! -e shadow2
          for f in greeting LICENSE reject-tests/shell-override.ncl; do
            if { echo pwned >>"$f"; } 2>/dev/null; then echo "wrote $f"; exit 1; fi
          done
          if touch new reject-tests/new 2>/dev/null; then echo "created a file in a share"; exit 1; fi
          if rm -f greeting 2>/dev/null && test ! -e greeting; then echo "removed a share"; exit 1; fi
          echo "shares are readable and read-only"
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
        name = "Leave a process behind and time out",
        id = "timeout",
        "timeout-minutes" = 1,
        "continue-on-error" = true,
        run = m%"
          setsid sleep 600 </dev/null >/dev/null 2>&1 &
          systemd-run --user --quiet sleep 601
          sleep 300
        "%,
      },
      {
        name = "Cron, at and lingering are denied",
        run = m%"
          if echo "* * * * * sleep 602" | crontab - 2>/dev/null; then echo "installed a crontab"; exit 1; fi
          if command -v at >/dev/null && echo "sleep 603" | at now 2>/dev/null; then echo "queued an at job"; exit 1; fi
          if loginctl enable-linger 2>/dev/null; then echo "enabled lingering"; exit 1; fi
        "%,
      },
      {
        name = "The escapes failed",
        env = {
          SYMLINK = "${{ steps.symlink.outcome }}",
          HEREDOC = "${{ steps.heredoc.outcome }}",
          TIMEOUT = "${{ steps.timeout.outcome }}",
        },
        run = m%"
          test "$SYMLINK" = failure
          test "$HEREDOC" = failure
          test "$TIMEOUT" = failure
          if pgrep -u runner-sandbox -a sleep; then echo "a process survived its step"; exit 1; fi
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
