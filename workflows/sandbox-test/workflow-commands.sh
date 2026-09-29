# sandbox-test: Issue workflow commands
# shellcheck shell=bash
c=::
echo "${c}set-output name=smuggled::1"
echo "  ${c}save-state name=smuggled::1"
echo "${c}add-mask::runner-sandbox"
echo "${c}add-path::/tmp/sandbox-bin"
echo "${c}set-env name=SMUGGLED::1"
echo "${c}stop-commands::sandbox-token" >&2
printf 'text\r%sset-output name=cr::1\n' "$c"
echo "legacy ##[set-output name=legacy;]1"
echo "${c}warning::an annotation from the sandbox, which is allowed"
