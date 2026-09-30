# sandbox-test: The job's credentials are out of reach
# shellcheck shell=bash
for v in ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_TOKEN; do
  if [[ -v $v ]]; then echo "$v is set"; exit 1; fi
done
# The file commands are the sandbox's own.
for v in GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT GITHUB_STATE GITHUB_STEP_SUMMARY; do
  test "$(stat -c %U "$(dirname "${!v}")")" = runner-sandbox
done
worker=$(pgrep -f Runner.Worker | head -n1)
test -n "$worker"
if cat "/proc/$worker/environ" >/dev/null; then echo "read Runner.Worker's environment"; exit 1; fi
if ls /home/runner >/dev/null; then echo "listed the runner's home"; exit 1; fi
if docker ps >/dev/null 2>&1; then echo "reached a docker daemon"; exit 1; fi
echo "no credentials reachable"
