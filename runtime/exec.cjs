// Runner side of a sandboxed step, used as its shell
// (`shell: /usr/local/bin/runner-sandbox-exec {0}`). It runs as the runner
// user, which holds the job's credentials, so it passes along only the step
// script, the variables the compiler listed in RUNNER_SANDBOX_ENV and a
// fixed set of non-secret context variables, and asks runner-sandbox-run
// (through sudo) to run the script as the sandbox user. Afterwards it copies
// the step's outputs and summary into the runner's own files, checking the
// output names.
//
// `runner-sandbox-exec --action SPEC` runs a JavaScript action in the
// sandbox instead: SPEC is the file the runner wrote from the step's
// `run:`, the JSON {uses, entry, stateKey} the compiler generated, and
// the action's inputs are in the step's env. `runner-sandbox-exec
// --action-path USES SCRIPT` runs a `run:` step of the composite action
// USES. `runner-sandbox-exec --stage NAME PATH` has the root side copy
// PATH out of the sandbox for a generated stage step, and
// `runner-sandbox-exec --seal` has it seal the sandbox after the last
// sandboxed step.
//
// Outputs come back as name=value lines or in the heredoc form, and are
// written to the runner's GITHUB_OUTPUT re-encoded with a delimiter of
// this side's choosing (filecmd.cjs).
"use strict";
const fs = require("node:fs");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { parse, format } = require("/usr/local/libexec/runner-sandbox-filecmd.cjs");

const RUN = "/usr/local/libexec/runner-sandbox-run";
const SUDO = "/usr/bin/sudo";
const RESULTS_DIR = "/run/runner-sandbox/results";
const CONTEXT_ENV = [
  "CI", "GITHUB_ACTIONS", "GITHUB_ACTOR", "GITHUB_EVENT_NAME", "GITHUB_JOB", "GITHUB_REF", "GITHUB_REF_NAME",
  "GITHUB_REPOSITORY", "GITHUB_RUN_ATTEMPT", "GITHUB_RUN_ID", "GITHUB_SERVER_URL", "GITHUB_SHA", "GITHUB_WORKFLOW",
];
const USAGE = "usage: runner-sandbox-exec SCRIPT | --action SPEC | --action-path USES SCRIPT | --stage NAME PATH | --seal";

function fail(message) {
  console.error(`runner-sandbox-exec: ${message}`);
  process.exit(125);
}

const args = process.argv.slice(2);
const ARGC = { "--action": 2, "--action-path": 3, "--stage": 3, "--seal": 1 };
if (args.length === 0 || args.length !== (ARGC[args[0]] ?? (args[0].startsWith("--") ? -1 : 1))) fail(USAGE);
const names = (process.env.RUNNER_SANDBOX_ENV ?? "").split(",").filter(Boolean);
const env = {};
for (const name of [...CONTEXT_ENV, ...names]) {
  if (process.env[name] !== undefined) env[name] = process.env[name];
}
// A step generated from an action has its env under fixed names, so the
// action's own names never apply to this process; they come back here.
const mapped = (process.env.RUNNER_SANDBOX_ENV_NAMES ?? "").split(",").filter(Boolean);
mapped.forEach((name, i) => {
  const value = process.env[`RUNNER_SANDBOX_VAR_${i}`];
  if (value !== undefined) env[name] = value;
});
const id = crypto.randomBytes(16).toString("hex");
let request;
switch (args[0]) {
  case "--stage":
    request = { id, stage: { name: args[1], path: args[2] } };
    break;
  case "--seal":
    request = { id, seal: true };
    break;
  case "--action": {
    let spec;
    try {
      spec = JSON.parse(fs.readFileSync(args[1], "utf8"));
    } catch (e) {
      fail(`invalid action spec: ${e.message}`);
    }
    request = { id, action: { uses: spec.uses, entry: spec.entry, stateKey: spec.stateKey }, env };
    break;
  }
  case "--action-path":
    request = { id, script: fs.readFileSync(args[2], "utf8"), env, actionPath: args[1] };
    break;
  default:
    request = { id, script: fs.readFileSync(args[0], "utf8"), env };
}
// By absolute path: the step's own env: applies to this process.
const r = spawnSync(SUDO, ["-n", RUN], { input: JSON.stringify(request), stdio: ["pipe", "inherit", "inherit"] });
if (r.error) fail(`running ${RUN}: ${r.error.message}`);

let result;
try {
  result = JSON.parse(fs.readFileSync(`${RESULTS_DIR}/${id}.json`, "utf8"));
} catch (e) {
  fail(`no result from the sandbox (exit ${r.status}): ${e.message}`);
}
if (result.error) fail(result.error);
let outputs;
try {
  outputs = parse(result.output, "GITHUB_OUTPUT");
} catch (e) {
  fail(e.message);
}
if (outputs.length) fs.appendFileSync(process.env.GITHUB_OUTPUT, outputs.map(([k, v]) => format(k, v)).join(""));
if (result.summary) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, result.summary);
process.exit(result.status);
