# sandbox-test: Read the shares, and fail to change them
# shellcheck shell=bash
cd "$SHARE_DIR" || exit
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
