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

const env = process.env;
const API = env.GITHUB_API_URL ?? "https://api.github.com";
// What this step prints can quote the sandbox's text, and it runs with
// the job's token: no workflow commands in it.
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
  for (const o of accepted) {
    try {
      if (o.type === "add_comment") {
        const c = await api("POST", `/repos/${config.repo}/issues/${o.item_number}/comments`, { body: o.body + footer(config.repo) });
        summary.push(`- applied \`add_comment\` on #${o.item_number}: ${c.html_url}`);
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
