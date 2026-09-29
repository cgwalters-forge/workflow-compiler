// Starts a sandboxed step's program as the sandbox user, with the
// environment runner-sandbox-run wrote to a file: values can span several
// lines and input names have dashes (INPUT_NODE-VERSION), which run0's
// --setenv can't carry. Installed by the enter step as
// /usr/local/libexec/runner-sandbox-launch; for an action, PROGRAM is this
// same (root-owned) node and ARGS the action's entry point, which is how
// the runner starts it (`node <entry>`).
//
//   runner-sandbox-launch ENV_JSON PROGRAM [ARGS...]
"use strict";
const fs = require("node:fs");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

const [envFile, program, ...args] = process.argv.slice(2);
if (!envFile || !program) {
  console.error("usage: runner-sandbox-launch ENV_JSON PROGRAM [ARGS...]");
  process.exit(125);
}
const env = { ...process.env, ...JSON.parse(fs.readFileSync(envFile, "utf8")) };
const r = spawnSync(program === "node" ? process.execPath : program, args, { env, stdio: "inherit" });
if (r.error) {
  console.error(`runner-sandbox-launch: ${r.error.message}`);
  process.exit(125);
}
process.exit(r.status ?? 128 + (os.constants.signals[r.signal] ?? 0));
