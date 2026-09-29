// Checks the shape of a compiled workflow, independently of its source:
// that each job has the generated steps, byte for byte what this
// repository's runtime scripts make them, and that everything between
// entering the sandbox and sealing it runs through the step wrapper. The
// stale-lock check proves a lock file matches its source; this proves the
// source went through gha.compile, rather than building a record of its
// own that merely looks like a workflow (#13).
//
// checkWorkflow(workflow, runtime) returns a list of problems (strings).
// WORKFLOW is the parsed lock file; RUNTIME has the texts of the runtime
// scripts the generated steps embed, keyed by file name. checkTree(root)
// checks every workflow of a checkout at ROOT, and so does this file as a
// command, which the trusted check runs on a pull request's tree as data:
//
//   node lib/check-lock.mjs TREE [--uncompiled FILE]
//
// It uses `nickel` (or $NICKEL) only to parse YAML.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXEC = "/usr/local/bin/runner-sandbox-exec";
const SEAL_ID = "runner-sandbox-seal";
const SEAL_CONDITION = `steps.${SEAL_ID}.outcome == 'success'`;
// The wrapper forms a sandboxed step's shell may take.
const SANDBOX_SHELLS = [
  new RegExp(`^${EXEC} \\{0\\}$`),
  new RegExp(`^${EXEC} --action \\{0\\}$`),
  new RegExp(`^${EXEC} --action-path [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} \\{0\\}$`),
];
const STAGE_RUN = new RegExp(`^${EXEC} --stage [A-Za-z0-9_-]+ [A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`);
// As DENIED_ENV_RE in lib/gha.ncl: names that would change how the
// runner side of the wrapper starts. The wrapper's own are allowed.
const DENIED_ENV = /^(ACTIONS_|RUNNER_|GITHUB_(TOKEN|ENV|PATH|OUTPUT|STATE|STEP_SUMMARY)$|LD_|NODE_|(BASH_ENV|ENV|PATH|HOME|USER|LOGNAME|SHELL)$)/;
const WRAPPER_ENV = /^RUNNER_SANDBOX_(ENV|ENV_NAMES|VAR_[0-9]+)$/;
// The enter step's embedded scripts, by variable.
const ENTER_ENV = {
  RUNNER_SANDBOX_EXEC_JS: "exec.cjs",
  RUNNER_SANDBOX_RUN_JS: "run.cjs",
  RUNNER_SANDBOX_HANDOFF_JS: "handoff.cjs",
  RUNNER_SANDBOX_FILECMD_JS: "filecmd.cjs",
  RUNNER_SANDBOX_LAUNCH_JS: "launch.cjs",
};
const ENTER_SHELL = `sudo --preserve-env=${Object.keys(ENTER_ENV).join(",")} node {0}`;
// Keys a compiled job or workflow never has: each would reach every step.
const JOB_FORBIDDEN = ["container", "services", "defaults", "env", "uses"];
const WORKFLOW_FORBIDDEN = ["env", "defaults"];

// Whether RUN is `const CONFIG = <JSON>;\n` followed by install.cjs.
function isInstall(runtime, run) {
  const install = runtime["install.cjs"];
  if (typeof run !== "string" || !run.endsWith(install)) return false;
  const m = /^const CONFIG = ([\s\S]*);\n$/.exec(run.slice(0, run.length - install.length));
  if (!m) return false;
  try {
    const config = JSON.parse(m[1]);
    return config !== null && typeof config === "object" && !Array.isArray(config);
  } catch {
    return false;
  }
}

const isEnter = (runtime, s) =>
  s.shell === ENTER_SHELL &&
  isInstall(runtime, s.run) &&
  Object.entries(ENTER_ENV).every(([k, f]) => s.env?.[k] === runtime[f]) &&
  Object.keys(s.env ?? {}).length === Object.keys(ENTER_ENV).length;

const isSecureHost = (runtime, s) => s.shell === "sudo node {0}" && s.run === runtime["secure-host.cjs"] && !s.env;

const isSeal = (s) => s.id === SEAL_ID && s.if === "always()" && s.shell === "bash" && s.run === `${EXEC} --seal` && !s.env;

// Whether COND has balanced parentheses outside string literals.
function balanced(cond) {
  let depth = 0;
  for (const c of cond.replace(/'([^']|'')*'/g, "''")) {
    depth += c === "(" ? 1 : c === ")" ? -1 : 0;
    if (depth < 0) return false;
  }
  return depth === 0;
}

// Whether a publish step's condition requires the seal to have succeeded.
function afterSeal(cond) {
  if (typeof cond !== "string" || cond.includes("${{") || cond.includes("}}")) return false;
  const wrapped = new RegExp(`^\\((.*)\\) && ${SEAL_CONDITION.replace(/[.()]/g, "\\$&")}$`, "s").exec(cond);
  if (wrapped) return balanced(wrapped[1]);
  return new RegExp(`^!cancelled\\(\\) && steps\\.[A-Za-z0-9_-]+\\.outcome == 'success' && ${SEAL_CONDITION.replace(/[.()]/g, "\\$&")}$`).test(cond);
}

// Problems with STEP, a step between entering the sandbox and the seal.
function sandboxStepProblems(step) {
  const problems = [];
  if (step.uses) problems.push(`uses ${step.uses} between entering the sandbox and the seal, where it would run as runner`);
  if (step["working-directory"]) problems.push("sets working-directory in the sandbox phase");
  if (step.id === SEAL_ID) problems.push(`has the seal's id ${SEAL_ID}`);
  const stage = step.shell === "bash" && STAGE_RUN.test(step.run ?? "");
  if (!stage && !SANDBOX_SHELLS.some((re) => re.test(step.shell ?? ""))) {
    problems.push(`runs with shell ${JSON.stringify(step.shell ?? null)}, not the sandbox wrapper`);
  }
  for (const name of Object.keys(step.env ?? {})) {
    if (!WRAPPER_ENV.test(name) && DENIED_ENV.test(name)) problems.push(`sets ${name} for the wrapper's runner side`);
  }
  return problems;
}

export function checkWorkflow(workflow, runtime) {
  const problems = [];
  for (const k of WORKFLOW_FORBIDDEN) if (k in workflow) problems.push(`the workflow sets ${k}`);
  for (const [name, job] of Object.entries(workflow.jobs ?? {})) {
    const at = (i, s) => `job ${name}, step ${i + 1}${s?.name ? ` (${s.name})` : ""}`;
    for (const k of JOB_FORBIDDEN) if (k in job) problems.push(`job ${name} sets ${k}`);
    const steps = Array.isArray(job.steps) ? job.steps : [];
    const enters = steps.flatMap((s, i) => (isEnter(runtime, s) ? [i] : []));
    const seals = steps.flatMap((s, i) => (s.id === SEAL_ID ? [i] : []));
    if (enters.length !== 1) {
      problems.push(`job ${name} has ${enters.length} generated steps entering the sandbox, not 1 (or it differs from runtime/install.cjs)`);
      continue;
    }
    const enter = enters[0];
    if (enter === 0 || !isSecureHost(runtime, steps[enter - 1])) {
      problems.push(`job ${name}: the step before entering the sandbox isn't the generated secure-host step`);
    }
    if (seals.length !== 1 || seals[0] < enter || !isSeal(steps[seals[0]])) {
      problems.push(`job ${name} doesn't have exactly one generated seal step after entering the sandbox`);
      continue;
    }
    const seal = seals[0];
    for (let i = enter + 1; i < seal; i++) {
      for (const p of sandboxStepProblems(steps[i])) problems.push(`${at(i, steps[i])} ${p}`);
    }
    for (let i = seal + 1; i < steps.length; i++) {
      if (!afterSeal(steps[i].if)) problems.push(`${at(i, steps[i])} runs as runner after the sandbox without requiring the seal to have succeeded`);
    }
  }
  return problems;
}

const SOURCES = "workflows";
const OUT = ".github/workflows";
const RUNTIME = "runtime";

// Every workflow in ROOT's OUT is a lock file with a source in SOURCES and
// the compiled shape, or listed in UNCOMPILED (one name per line, with a
// reason after `#`: each runs with none of the compiler's guarantees, so
// each is a reviewed exception). Returns the problems.
export function checkTree(root, { uncompiled = path.join(root, ".github/uncompiled-workflows"), nickel = "nickel" } = {}) {
  const found = [];
  const listed = existsSync(uncompiled)
    ? readFileSync(uncompiled, "utf8").split("\n").map((l) => l.replace(/#.*/, "").trim()).filter(Boolean)
    : [];
  const runtime = Object.fromEntries(
    readdirSync(path.join(root, RUNTIME)).map((f) => [f, readFileSync(path.join(root, RUNTIME, f), "utf8")]),
  );
  for (const file of readdirSync(path.join(root, OUT)).sort()) {
    const rel = path.join(OUT, file);
    if (!/\.ya?ml$/.test(file)) continue;
    if (!file.endsWith(".lock.yml")) {
      if (!listed.includes(file)) found.push(`${rel} isn't compiled; compile it from ${SOURCES}/, or list it in ${path.basename(uncompiled)} with the reason`);
      continue;
    }
    if (!existsSync(path.join(root, SOURCES, file.replace(/\.lock\.yml$/, ".ncl")))) {
      found.push(`${rel} has no source in ${SOURCES}/`);
      continue;
    }
    // YAML only: nickel parses it as data, with no imports to follow.
    const r = spawnSync(nickel, ["export", "--format", "json", path.join(root, rel)], { encoding: "utf8" });
    if (r.error || r.status !== 0) {
      found.push(`${rel} can't be parsed: ${r.error?.message ?? r.stderr}`);
      continue;
    }
    for (const p of checkWorkflow(JSON.parse(r.stdout), runtime)) found.push(`${rel}: ${p}`);
  }
  for (const name of listed) if (!existsSync(path.join(root, OUT, name))) found.push(`${path.basename(uncompiled)} lists ${name}, which doesn't exist`);
  return found;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const args = process.argv.slice(2);
  const i = args.indexOf("--uncompiled");
  const uncompiled = i >= 0 ? args.splice(i, 2)[1] : undefined;
  if (args.length !== 1 || (i >= 0 && !uncompiled)) {
    console.error("usage: node lib/check-lock.mjs TREE [--uncompiled FILE]");
    process.exit(2);
  }
  const problems = checkTree(args[0], { ...(uncompiled ? { uncompiled } : {}), nickel: process.env.NICKEL ?? "nickel" });
  for (const p of problems) console.error(`error: ${p}`);
  if (!problems.length) console.log(`ok: every workflow in ${path.join(args[0], OUT)} is compiled`);
  process.exit(problems.length ? 1 : 0);
}
