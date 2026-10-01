// Safe outputs, step 2 of 2 (lib/safe-outputs.ncl): apply what
// safe-outputs-validate.cjs accepted. Runs in the apply job's publish
// phase, as runner with the job's token, which has only the permissions
// the enabled output types need. Its input was written in the sandbox,
// so it is checked again here, every proposal with the same checks and
// the same caps, and its text sanitized again, before anything is
// written; one that fails refuses the whole run.
//
// Usage: node safe-outputs-apply.cjs LIB CONFIG VALIDATED_JSON
"use strict";
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const env = process.env;
const API = env.GITHUB_API_URL ?? "https://api.github.com";
const BOT = { name: "github-actions[bot]", email: "41898282+github-actions[bot]@users.noreply.github.com" };
// Git as the publish phase runs it on a patch from the sandbox: a fresh
// repository with no hooks, no fsmonitor and no local transports.
const GIT_CONFIG = ["core.hooksPath=/dev/null", "core.fsmonitor=false", "protocol.file.allow=never", "commit.gpgSign=false"];
const ALLOWED_MODES = new Set(["000000", "100644", "100755"]);

// What this step prints can quote the sandbox's text (git's errors quote
// the patch), and runs with the job's token: no workflow commands in it.
const unc = (s) => String(s).replace(/^(\s*)::/gm, "$1: :").replaceAll("##[", "## [");

function fail(message) {
  console.error(unc(`safe-outputs-apply: ${message}`));
  process.exit(1);
}

// Text from the sandbox, shown in Markdown as code on one line.
const code = (s) => `\`${String(s).replace(/[`\r\n]/g, " ").slice(0, 200)}\``;

function footer(repo) {
  const run = `${env.GITHUB_SERVER_URL}/${repo}/actions/runs/${env.GITHUB_RUN_ID}`;
  return `\n\n---\nProposed by an agent in [run ${env.GITHUB_RUN_ID}](${run}); checked and applied by its safe-outputs job.`;
}

async function api(method, url, body) {
  const res = await fetch(`${API}${url}`, {
    method,
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${url}: ${res.status} ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

// The accepted outputs, checked again from scratch.
function recheck(lib, config, validated) {
  if (!Array.isArray(validated?.accepted)) fail("validated.json has no accepted list");
  const { accepted, rejected } = lib.sortProposals(validated.accepted, config);
  if (rejected.length) fail(`the sandbox accepted outputs that fail the checks: ${rejected.map((r) => r.reason).join("; ")}`);
  // Sanitizing twice changes nothing, so this only differs if the sandbox
  // passed on text it didn't sanitize.
  return accepted;
}

function git(cwd, args, extra = {}) {
  const r = spawnSync("git", [...GIT_CONFIG.flatMap((c) => ["-c", c]), ...args], {
    cwd, encoding: "utf8", input: extra.input, env: { ...extra.env, PATH: env.PATH, HOME: extra.home },
  });
  if (r.status !== 0) throw new Error(`git ${args[0]}: ${(r.stderr || r.stdout).trim().slice(0, 500)}`);
  return r.stdout;
}

async function createPullRequest(lib, config, o, n) {
  const cfg = config.types.create_pull_request;
  const work = fs.mkdtempSync(path.join(env.RUNNER_TEMP ?? os.tmpdir(), "safe-outputs-pr-"));
  const home = path.join(work, "home");
  const dir = path.join(work, "repo");
  fs.mkdirSync(home);
  // The token goes to git in its environment, never on a command line or
  // in a file.
  const auth = Buffer.from(`x-access-token:${env.GITHUB_TOKEN}`).toString("base64");
  const gitEnv = {
    GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: `http.${env.GITHUB_SERVER_URL}/.extraheader`, GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${auth}`,
    GIT_AUTHOR_NAME: BOT.name, GIT_AUTHOR_EMAIL: BOT.email, GIT_COMMITTER_NAME: BOT.name, GIT_COMMITTER_EMAIL: BOT.email,
  };
  const run = (args, input) => git(dir, args, { env: gitEnv, home, input });
  const url = `${env.GITHUB_SERVER_URL}/${config.repo}`;
  const branch = `${cfg.branch_prefix}${env.GITHUB_RUN_ID}-${env.GITHUB_RUN_ATTEMPT ?? 1}-${n}`;
  git(work, ["init", "-q", dir], { env: gitEnv, home });
  run(["fetch", "-q", "--depth=1", "--no-tags", url, `refs/heads/${cfg.base}`]);
  run(["checkout", "-q", "-b", branch, "FETCH_HEAD"]);
  // A diff taken through a shell's $(...) loses its last newline, which
  // git apply needs.
  run(["apply", "--index", "--whitespace=nowarn", "-"], o.patch.endsWith("\n") ? o.patch : `${o.patch}\n`);
  // What git changed, as git sees it, against the same rules as the
  // patch's own headers.
  const raw = run(["diff", "--cached", "--raw", "--no-renames", "-z"]).split("\0").filter(Boolean);
  if (raw.length === 0) throw new Error("the patch changes nothing");
  for (let i = 0; i < raw.length; i += 2) {
    const [oldMode, newMode] = raw[i].slice(1).split(" ");
    const file = raw[i + 1];
    if (!ALLOWED_MODES.has(oldMode) || !ALLOWED_MODES.has(newMode)) throw new Error(`${file}: mode ${newMode} isn't allowed`);
    const why = lib.pathProblem(file, cfg.allowed_paths);
    if (why) throw new Error(why);
  }
  if (raw.length / 2 > cfg.max_files) throw new Error(`the patch changes more than ${cfg.max_files} files`);
  run(["commit", "-q", "-F", "-"], `${o.title}\n\n${o.body}${footer(config.repo)}\n`);
  run(["push", "-q", url, `HEAD:refs/heads/${branch}`]);
  try {
    const pr = await api("POST", `/repos/${config.repo}/pulls`, {
      title: o.title, head: branch, base: cfg.base, body: o.body + footer(config.repo), draft: cfg.draft,
    });
    return pr.html_url;
  } catch (e) {
    throw new Error(`pushed ${branch}, but opening the pull request failed (${e.message}); open it from ${url}/compare/${cfg.base}...${branch}`);
  }
}

async function main() {
  const [libPath, configPath, validatedPath] = process.argv.slice(2);
  if (!validatedPath) fail("usage: safe-outputs-apply.cjs LIB CONFIG VALIDATED_JSON");
  for (const name of ["GITHUB_TOKEN", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_SERVER_URL"]) {
    if (!env[name]) fail(`${name} is not set`);
  }
  const lib = require(libPath);
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (config.repo !== env.GITHUB_REPOSITORY) fail(`the config is for ${config.repo}, not ${env.GITHUB_REPOSITORY}`);
  const validated = JSON.parse(fs.readFileSync(validatedPath, "utf8"));
  const accepted = recheck(lib, config, validated);

  const summary = ["## Safe outputs", ""];
  const errors = [];
  let n = 0;
  for (const o of accepted) {
    try {
      if (o.type === "add_comment") {
        const c = await api("POST", `/repos/${config.repo}/issues/${o.item_number}/comments`, { body: o.body + footer(config.repo) });
        summary.push(`- applied \`add_comment\` on #${o.item_number}: ${c.html_url}`);
      } else if (o.type === "create_pull_request") {
        summary.push(`- applied \`create_pull_request\`: ${await createPullRequest(lib, config, o, ++n)}`);
      } else {
        summary.push(`- \`noop\`: ${code(o.message)}`);
      }
      console.log(unc(summary.at(-1).slice(2)));
    } catch (e) {
      errors.push(`${o.type}: ${e.message}`);
      summary.push(`- **failed** \`${o.type}\`: ${code(e.message)}`);
    }
  }
  const rejected = Array.isArray(validated.rejected) ? validated.rejected : [];
  for (const r of rejected) summary.push(`- **rejected** line ${code(r?.line)} ${code(r?.type)}: ${code(r?.reason)}`);
  if (env.GITHUB_STEP_SUMMARY) fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `${summary.join("\n")}\n`);
  console.log(`${accepted.length - errors.length} applied, ${errors.length} failed, ${rejected.length} rejected`);
  if (errors.length) fail(errors.join("\n"));
}

main().catch((e) => fail(e.message));
