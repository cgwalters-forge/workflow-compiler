// The sandboxed step of an agent_run job (lib/agent-run.ncl): runs the
// agent through bot-harness, the Agent Client Protocol client from
// cgwalters-devspace-sandbox (harness/), and leaves what the task layer's
// contract wants in the workspace for the job's upload steps:
//
//   agent-run/         summary.json, summary.md, condensed.log, outcome.json
//   agent-transcript/  acp.jsonl, harness.json, agent-stderr.log
//
// The layout and summary.json (agent-run-summary/v1) are those of
// docs/devspace-agent-runs.md in cgwalters-bot/homegit, as agent/run.mjs
// there writes them. Unlike agent/run.mjs, which runs bot-harness as runner
// and the agent through sudo as runner-sandbox, this runs as the sandbox
// user already, harness and agent both: the harness holds nothing the
// agent may not see, so it needs no boundary of its own.
//
// Runs with node, as the sandbox user, from a share the privileged phase
// wrote. Environment: AGENT AGENTS PROMPT POLICY TIMEOUT_MINUTES BUDGET,
// the GITHUB_* context the wrapper passes, and HARNESS_SHARE, where
// bot-harness's redact.mjs was installed.
//
// All of this holds only for an agent that cooperates: it runs as the
// same user as bot-harness, so a hostile one can skip permission
// requests, kill or outlive the harness, and rewrite what it wrote. The
// summary and transcript are the agent's data (R7, R13 in
// docs/requirements.md); the step's timeout and the sandbox bound it.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const readline = require("node:readline");

const HARNESS = "bot-harness";
const RUN_DIR = "agent-run";
const TRANSCRIPT_DIR = "agent-transcript";
const HARNESS_FILES = ["acp.jsonl", "harness.json", "agent-stderr.log"];
const MAX_OUTCOME_BYTES = 65536;
// Seconds bot-harness gets past the agent's timeout to cancel it.
const HARNESS_GRACE_S = 90;
const EXIT_TIMEOUT = 124;
// No inference yet: only the scripted agent, whose cost is made up.
const AGENTS = ["fake"];
const AIC_PRICING = "mock";

const env = process.env;
const oneLine = (s) => s.replace(/[\x00-\x1f\x7f]/g, " ");

function fail(message) {
  console.error(`agent-run: ${message}`);
  process.exit(1);
}

// Runs bot-harness, passing its condensed transcript on to the log and
// CONDENSED; resolves to its exit status.
function runHarness({ out, prompt, condensed }) {
  const limit = Number(env.TIMEOUT_MINUTES) * 60 + HARNESS_GRACE_S;
  const child = spawn("timeout", ["--kill-after=30", `${limit}s`, HARNESS, "run",
    "--agent", env.AGENT, "--agents", env.AGENTS,
    "--cwd", process.cwd(), "--prompt", prompt, "--out", out,
    "--permissions", env.POLICY,
    "--timeout", `${env.TIMEOUT_MINUTES}m`, "--budget-aic", env.BUDGET], { stdio: ["ignore", "pipe", "inherit"] });
  const closed = new Promise((resolve) => child.on("close", (code) => resolve(code ?? 128)));
  const lines = [];
  const reader = readline.createInterface({ input: child.stdout });
  const read = new Promise((resolve) => reader.on("close", resolve));
  reader.on("line", (line) => {
    const clean = oneLine(line);
    console.log(clean);
    lines.push(clean);
  });
  return Promise.all([closed, read]).then(([status]) => {
    fs.writeFileSync(condensed, lines.map((l) => `${l}\n`).join(""));
    return status;
  });
}

// The agent's own outcome.json, if it left a JSON object of sane size.
function readOutcome() {
  const file = path.join(env.HOME, "out", "outcome.json");
  try {
    const text = fs.readFileSync(file, "utf8");
    if (text.length > MAX_OUTCOME_BYTES) return {};
    const parsed = JSON.parse(text);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

// The files the agent changed in the workspace, as git sees them.
function changedFiles() {
  const r = spawnSync("git", ["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "--no-renames",
    "--untracked-files=all"], { encoding: "utf8" });
  if (r.status !== 0) return [];
  return r.stdout.split("\0").filter((e) => e.length > 3).map((e) => e.slice(3))
    .filter((f) => !f.startsWith(`${RUN_DIR}/`) && !f.startsWith(`${TRANSCRIPT_DIR}/`)).sort();
}

async function main() {
  for (const name of ["AGENT", "AGENTS", "PROMPT", "POLICY", "TIMEOUT_MINUTES", "BUDGET", "HARNESS_SHARE", "GITHUB_RUN_ID", "GITHUB_SERVER_URL", "GITHUB_REPOSITORY"]) {
    if (!env[name]) fail(`${name} is not set`);
  }
  if (!AGENTS.includes(env.AGENT)) fail(`agent '${env.AGENT}' needs inference, which agent_run doesn't provide yet (only ${AGENTS.join(", ")})`);
  const scratch = path.join(env.RUNNER_TEMP, "agent");
  const harnessOut = path.join(scratch, "harness");
  // ~/out is where the agent leaves its outcome.json.
  for (const d of [harnessOut, RUN_DIR, TRANSCRIPT_DIR, path.join(env.HOME, "out")]) fs.mkdirSync(d, { recursive: true });

  const started = new Date();
  console.log("::group::agent (condensed)");
  const exitCode = await runHarness({ out: harnessOut, prompt: env.PROMPT, condensed: path.join(RUN_DIR, "condensed.log") });
  console.log("::endgroup::");
  const finished = new Date();
  if (exitCode !== 0 && !fs.existsSync(path.join(harnessOut, "harness.json"))) {
    const line = exitCode === EXIT_TIMEOUT ? `agent timed out after ${env.TIMEOUT_MINUTES}m` : `bot-harness exited ${exitCode}`;
    fs.appendFileSync(path.join(RUN_DIR, "condensed.log"), `${line}\n`);
  }

  for (const f of HARNESS_FILES) {
    if (fs.existsSync(path.join(harnessOut, f))) fs.copyFileSync(path.join(harnessOut, f), path.join(TRANSCRIPT_DIR, f));
  }
  fs.writeFileSync(path.join(RUN_DIR, "outcome.json"), `${JSON.stringify(readOutcome())}\n`);
  const files = changedFiles();

  // The same safety net as agent/run.mjs: token-shaped strings out of
  // everything uploaded. The sandbox has no token of the job's to leak.
  const { makeRedactor, redactTree } = await import(path.join(env.HARNESS_SHARE, "redact.mjs"));
  const redact = makeRedactor([]);
  redactTree(redact, [RUN_DIR, TRANSCRIPT_DIR]);

  const iso = (d) => d.toISOString().replace(/\.\d+Z$/, "Z");
  const meta = {
    run_id: Number(env.GITHUB_RUN_ID), run_attempt: Number(env.GITHUB_RUN_ATTEMPT ?? 1),
    run_url: `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}`,
    item: env.ITEM ?? null, repo: env.GITHUB_REPOSITORY, base: env.GITHUB_REF_NAME ?? null, workflow: "agent_run",
    agent: env.AGENT, model: null, cores: require("node:os").availableParallelism(),
    started_at: iso(started), finished_at: iso(finished), duration_s: Math.round((finished - started) / 1000),
    exit_code: exitCode, aic_budget: Number(env.BUDGET), aic_pricing: AIC_PRICING, files,
    egress_denied: [], redactions: redact.count,
  };
  fs.writeFileSync(path.join(scratch, "meta.json"), JSON.stringify(meta));
  const summary = spawnSync(HARNESS, ["summary", "--dir", TRANSCRIPT_DIR, "--meta", path.join(scratch, "meta.json"),
    "--outcome", path.join(RUN_DIR, "outcome.json"), "--markdown", path.join(RUN_DIR, "summary.md")], { encoding: "utf8" });
  if (summary.status !== 0) fail(`bot-harness summary failed: ${summary.stderr}`);
  fs.writeFileSync(path.join(RUN_DIR, "summary.json"), summary.stdout.endsWith("\n") ? summary.stdout : `${summary.stdout}\n`);
  if (env.GITHUB_STEP_SUMMARY) fs.appendFileSync(env.GITHUB_STEP_SUMMARY, fs.readFileSync(path.join(RUN_DIR, "summary.md")));
  console.log(`Agent ${env.AGENT} exited ${exitCode}: ${JSON.parse(summary.stdout).result}`);
  process.exitCode = exitCode;
}

main().catch((e) => fail(e.message));
