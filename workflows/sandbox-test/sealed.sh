# sandbox-test: The sandbox is sealed
# shellcheck shell=bash
test "$LINES" = 1
for p in /var/lib/runner-sandbox/work/report.txt /home/runner-sandbox/private/notes; do
  if cat "$p" 2>/dev/null; then echo "read $p after the seal"; exit 1; fi
done
for f in /dev/shm/sandbox-leftover /dev/shm/subuid-leftover; do
  if test -e "$f"; then echo "the sandbox's $f survived the seal"; exit 1; fi
done
if pgrep -u runner-sandbox; then echo "a sandbox process survived the seal"; exit 1; fi
if /usr/local/bin/runner-sandbox-exec --stage late report.txt; then echo "staged after the seal"; exit 1; fi
if sudo -n true 2>/dev/null; then echo "runner has sudo in the publish phase"; exit 1; fi
# Same uid as Runner.Worker, but Yama keeps it from its memory.
worker=$(pgrep -f Runner.Worker | head -n1)
test -n "$worker"
if (exec 3<"/proc/$worker/mem") 2>/dev/null; then echo "opened Runner.Worker's memory"; exit 1; fi
echo "only staged outputs are left"
