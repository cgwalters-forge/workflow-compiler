# agent-run: Build bot-harness at a pinned commit
# shellcheck shell=bash
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
