# agent-run: a whole sandboxed agent job from little more than a prompt.
#
#   jobs.review = agent_run { prompt = "/etc/agent-share/agentskills/review.md" }
#
# expands into a job for gha.ncl whose privileged phase checks out the
# repository, shares its skills directory read-only at
# /etc/agent-share/<skills.name>, and builds and installs bot-harness, the
# Agent Client Protocol client from cgwalters-devspace-sandbox (harness/),
# at a pinned commit; and whose sandboxed phase runs the agent through it
# on the prompt (runtime/agent-run.cjs) and uploads the run summary and
# the transcript, staged, from the publish phase. The prompt must be
# inside a share, so the agent reads instructions that nothing in the
# sandbox could have rewritten.
#
# It is a compiler macro rather than a composite action on purpose: a
# composite action runs as runner, with the job's tokens, takes whatever
# `with:` and `env:` its caller passes, and can't constrain the steps
# around it. Here the result goes through gha.compile like any other job,
# so the same contracts hold for it.
#
# There is no inference yet, so the only agent is `fake`, bot-harness's
# scripted ACP agent, which exercises the tools, the sandbox and the
# permission policy without a model (#7).
let gha = import "gha.ncl" in
let checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" in # v7.0.1
# bot-harness is built from this commit of cgwalters-devspace-sandbox, as a
# setup step: the head of cgwalters-forge/cgwalters-devspace-sandbox#3
# until that lands, then a release with a sha256, which saves the build.
let harness_repo = "cgwalters-forge/cgwalters-devspace-sandbox" in
let harness_sha = "13308dc5480bc9f89dbf4b9abfabc7972222db8e" in
# Where the build installs its configuration and redact.mjs, root-owned.
let harness_share = "/usr/local/share/bot-harness" in
let AGENT_RUN = "agent-run.cjs" in
let AGENT_POLICY = "agent-policy.toml" in
let AGENT_REGISTRY = "agent-agents.toml" in
let AGENT_SESSION = "agent-session.json" in
# Seconds bot-harness gets past the agent's timeout (runtime/agent-run.cjs),
# plus its kill grace, rounded up to minutes for the step's own timeout.
let HARNESS_GRACE_MINUTES = 3 in

# What the scripted agent does: bot-harness's demo (the tools, the
# permission policy, the redaction canary, a file and an outcome), then
# escape attempts, each printing `contained-<name>` if it failed and
# `ESCAPED-<name>` if it didn't, which ci reads from the transcript (the
# quotes keep the markers out of the command's own text there). They
# are the checks the old stub agent made, run by the agent itself.
let session = fun prompt =>
  let attempt = fun name cmd => { execute = { title = "Bash", command = "(%{cmd}) >/dev/null 2>&1 && echo ESC''APED-%{name} || echo contain''ed-%{name}" } } in
  [
    { say = "Fake run: the tools, the sandbox, the permission policy, the redaction pass, and escape attempts." },
    { execute = { title = "Bash", command = "git log --oneline -1 && id -un" } },
    { read = { title = "Read", path = "{cwd}/README.md", lines = 5 } },
    { execute = { title = "Bash", command = "printf 'fake secret: gh%s_%s\\n' p FAKEREDACTIONCANARY0123456789abcdef" } },
    { execute = { title = "Bash", command = "git push origin HEAD" } },
    attempt "rewrite-prompt" "echo pwned >>'%{prompt}'",
    attempt "add-to-share" "touch %{gha.share_dir}/new",
    attempt "sudo" "sudo -n true",
    attempt "worker-environ" "cat /proc/$(pgrep -f Runner.Worker | head -n1)/environ",
    attempt "runner-home" "ls /home/runner",
    attempt "job-token" "env | grep -E '^(ACTIONS_(RUNTIME|ID_TOKEN_REQUEST)_|GITHUB_TOKEN=)'",
    { write = { title = "Write", path = "{cwd}/FAKE.md", content = "Written by a fake agent run.\n" } },
    { write = { title = "Write", path = "{home}/out/outcome.json", content = "{\"tests\": [{\"command\": \"git log --oneline -1\", \"exit_code\": 0, \"duration_s\": 0}]}\n" } },
    { cost = { usd = 0.01 } },
    { say = "Done: the fake run finished." },
  ]
in

let InShare =
  std.contract.from_validator (fun p =>
    if std.string.is_match "^/etc/agent-share/[^/]+(/[^/]+)*$" p && !(std.string.is_match "(^|/)\\.\\.?(/|$)" p) then
      'Ok
    else
      'Error { message = "agent-run's prompt `%{p}` must be a file under %{gha.share_dir}/, where the privileged phase shares it" }
  )
in

let AgentRun = {
  # The prompt file, under a share.
  prompt | String | InShare,
  # The repository directory shared as the agent's skills.
  skills | { name | String, path | String } | default = { name = "agentskills", path = "agentskills" },
  # An entry in bot-harness's agents.toml; only the scripted one until
  # there is inference.
  agent | [| 'fake |] | default = 'fake,
  # Minutes the agent may run, and its spend cap in AIC (1 AIC = $0.01).
  agent_timeout_minutes | Number | default = 10,
  budget_aic | Number | default = 500,
  "runs-on" | String | default = "ubuntu-26.04",
  "timeout-minutes" | Number | default = 45,
} in

fun args =>
  let a = args | AgentRun in
  {
    "runs-on" = a."runs-on",
    "timeout-minutes" = a."timeout-minutes",
    # Agents work with git: the checkout's history comes along (checkout
    # persists no credentials, and the hand-off checks .git/config).
    handoff.include = [".git"],
    runner_steps = [
      { uses = checkout, with = { persist-credentials = false } },
      { share = { name = a.skills.name, path = a.skills.path } },
      { share = { name = AGENT_RUN, content = import "../runtime/agent-run.cjs" as 'Text } },
      { share = { name = AGENT_POLICY, content = import "../runtime/agent-policy.toml" as 'Text } },
      { share = { name = AGENT_SESSION, content = std.serialize 'Json (session a.prompt) } },
      {
        share = {
          name = AGENT_REGISTRY,
          # bot-harness's agents.toml, with only the scripted agent until
          # there is inference (#36), playing the session above.
          content = m%"
            [fake]
            command = ["fake-acp-agent", "script", "%{gha.share_dir}/%{AGENT_SESSION}"]
          "%,
        },
      },
      {
        name = "Build bot-harness at a pinned commit",
        shell = "bash",
        env = { HARNESS_REPO = harness_repo, HARNESS_SHA = harness_sha, HARNESS_SHARE = harness_share },
        run = m%"
          set -euo pipefail
          src="$RUNNER_TEMP/bot-harness"
          git init -q "$src"
          git -C "$src" fetch -q --depth 1 "https://github.com/$HARNESS_REPO" "$HARNESS_SHA"
          git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
          test "$(git -C "$src" rev-parse HEAD)" = "$HARNESS_SHA"
          cargo build --manifest-path "$src/Cargo.toml" --release --locked -p bot-harness
          sudo install -m 0755 "$src/target/release/bot-harness" "$src/target/release/fake-acp-agent" /usr/local/bin/
          sudo install -d -m 0755 "$HARNESS_SHARE"
          sudo install -m 0644 "$src/agent/redact.mjs" "$HARNESS_SHARE/"
        "%,
      },
    ],
    steps = [
      {
        name = "Run the agent",
        id = "agent",
        # The wrapper stops the step, and every process in it, at this
        # point, whatever the agent does to bot-harness.
        "timeout-minutes" = a.agent_timeout_minutes + HARNESS_GRACE_MINUTES,
        env = {
          AGENT = std.string.from_enum a.agent,
          PROMPT = a.prompt,
          AGENTS = "%{gha.share_dir}/%{AGENT_REGISTRY}",
          POLICY = "%{gha.share_dir}/%{AGENT_POLICY}",
          TIMEOUT_MINUTES = std.to_string a.agent_timeout_minutes,
          BUDGET = std.to_string a.budget_aic,
          HARNESS_SHARE = harness_share,
        },
        run = "node %{gha.share_dir}/%{AGENT_RUN}",
      },
      { "if" = "always()", upload = { name = "agent-run", path = "agent-run" } },
      { "if" = "always()", upload = { name = "agent-transcript", path = "agent-transcript" } },
    ],
  }
