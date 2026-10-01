// Safe outputs, step 1 of 2 (lib/safe-outputs.ncl): sort an agent's
// proposals into accepted outputs and rejections, in the apply job's
// sandbox, which has no token. The proposals are the agent's data,
// downloaded from its job and shared read-only; the config and this
// script came from the lock file. The result is staged for
// safe-outputs-apply.cjs, which checks it all again.
//
// Usage: node safe-outputs-validate.cjs LIB CONFIG PROPOSALS_DIR OUT_DIR
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const PROPOSALS_FILE = "outputs.jsonl";
const MAX_FILE_BYTES = 4 * 1024 * 1024;

// The proposals file, wherever the artifact and the share nested it, a
// few directories down at most, and never through a symlink.
function findProposals(dir, depth = 3) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const file = entries.find((e) => e.isFile() && e.name === PROPOSALS_FILE);
  if (file) return path.join(dir, file.name);
  if (depth === 0) return null;
  for (const e of entries) {
    const found = e.isDirectory() ? findProposals(path.join(dir, e.name), depth - 1) : null;
    if (found) return found;
  }
  return null;
}

function main() {
  const [libPath, configPath, dir, outDir] = process.argv.slice(2);
  if (!outDir) throw new Error("usage: safe-outputs-validate.cjs LIB CONFIG PROPOSALS_DIR OUT_DIR");
  const lib = require(libPath);
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const file = findProposals(dir);
  let result;
  if (!file) {
    result = { accepted: [], rejected: [{ line: 0, type: "?", reason: `the agent left no ${PROPOSALS_FILE}` }] };
  } else if (fs.statSync(file).size > MAX_FILE_BYTES) {
    result = { accepted: [], rejected: [{ line: 0, type: "?", reason: `${PROPOSALS_FILE} is over ${MAX_FILE_BYTES} bytes` }] };
  } else {
    result = lib.sortProposals(lib.parseLines(fs.readFileSync(file, "utf8")), config);
  }
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "validated.json"), `${JSON.stringify(result, null, 2)}\n`);
  console.log(`${result.accepted.length} accepted, ${result.rejected.length} rejected`);
  for (const r of result.rejected) console.log(`rejected line ${r.line} (${r.type}): ${r.reason}`);
}

try {
  main();
} catch (e) {
  console.error(`safe-outputs-validate: ${e.message}`);
  process.exit(1);
}
