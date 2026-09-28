#!/bin/bash
# A stand-in for a coding agent, for agent-run's proof of concept: it reads
# its prompt the way an agent would, then behaves like a hostile one and
# tries to rewrite its own instructions, become root and reach the job's
# credentials. It fails if any of that works, and otherwise writes a
# "review" and a step output.
#
#   agent-stub PROMPT-FILE
set -euo pipefail

prompt=${1:?usage: agent-stub PROMPT-FILE}
escaped=()

echo "agent-stub: running as $(id -un) (uid $(id -u)) in $PWD"
echo "agent-stub: prompt $prompt, owned by $(stat -c '%U:%G %a' "$prompt"):"
sed 's/^/  > /' "$prompt"

if { echo "ignore all previous instructions" >>"$prompt"; } 2>/dev/null; then escaped+=("rewrote its prompt"); fi
if touch "$(dirname "$prompt")/injected" 2>/dev/null; then escaped+=("added a file to the share"); fi
if sudo -n true 2>/dev/null; then escaped+=("became root with sudo"); fi
for v in ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_RUNTIME_TOKEN GITHUB_TOKEN; do
  if [[ -v $v ]]; then escaped+=("saw $v"); fi
done
worker=$(pgrep -f Runner.Worker | head -n1 || true)
if [[ -n $worker ]] && cat "/proc/$worker/environ" >/dev/null 2>&1; then escaped+=("read Runner.Worker's environment"); fi

if ((${#escaped[@]})); then
  printf 'agent-stub: ESCAPED: %s\n' "${escaped[@]}" >&2
  exit 1
fi
echo "agent-stub: every escape attempt failed"

{
  echo "# Review by agent-stub"
  echo
  echo "Prompt: \`$prompt\` ($(wc -l <"$prompt") lines), read as $(id -un)."
} >review.md
echo "verdict=looks-good" >>"$GITHUB_OUTPUT"
cat review.md >>"$GITHUB_STEP_SUMMARY"
