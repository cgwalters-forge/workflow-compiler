#!/usr/bin/env node
// Compiles workflows/*.ncl into .github/workflows/*.lock.yml.
//
//   node compile.mjs          write the lock files, fetching the metadata
//                             of new actions in `steps` into
//                             actions.lock.json
//   node compile.mjs --check  fail if a lock file is stale or hand-edited,
//                             if actions.lock.json doesn't match the
//                             action.yml files it holds, or if a source in
//                             tests/reject/ compiles
//
// Uses `nickel` from PATH, or $NICKEL.
//
// actions.lock.json holds, for every action that runs in the sandbox
// (owner/repo[/path]@sha), its action.yml as fetched at that commit, the
// file's sha256 (which the generated fetch step checks at run time) and
// the metadata parsed from it, which lib/gha.ncl imports: nickel can't
// fetch anything itself. --check reparses each action.yml and compares.
// Actions of the owner TEST_OWNER are fixtures for reject tests, read from
// tests/actions/<repo>/ instead of fetched; no workflow can run them.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const ROOT = import.meta.dirname;
const SOURCES = "workflows";
const REJECT = "tests/reject";
const OUT = ".github/workflows";
const ACTIONS_LOCK = "actions.lock.json";
const NICKEL = process.env.NICKEL ?? "nickel";
const TEST_OWNER = "wfc-test";
const TEST_ACTIONS = "tests/actions";
// gha.ncl's error for an action missing from ACTIONS_LOCK.
const MISSING_ACTION_RE = /action `([^`]+)` is not in actions\.lock\.json/;
const USES_RE = /^([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)((?:\/[A-Za-z0-9_.-]+)*)@([0-9a-f]{40})$/;
// At most this many actions are added in one compile of a source, one
// nickel run each; a composite action can pull in more.
const MAX_NEW_ACTIONS = 50;

function nickelExport(file, format = "yaml") {
  const r = spawnSync(NICKEL, ["export", "--format", format, file], { cwd: ROOT, encoding: "utf8" });
  if (r.error) throw new Error(`running ${NICKEL}: ${r.error.message}`);
  return { ok: r.status === 0, stdout: r.stdout, stderr: r.stderr };
}

function nclFiles(dir) {
  return readdirSync(path.join(ROOT, dir)).filter((f) => f.endsWith(".ncl")).sort().map((f) => path.join(dir, f));
}

// JSON with sorted keys, so the lock file's diffs are stable.
function stableJSON(value) {
  const sort = (v) => Array.isArray(v) ? v.map(sort)
    : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sort(v[k])]))
    : v;
  return `${JSON.stringify(sort(value), null, 2)}\n`;
}

// action.yml's text parsed with nickel, which reads YAML.
function parseActionYaml(text) {
  const dir = mkdtempSync(path.join(tmpdir(), "wfc-action-"));
  try {
    writeFileSync(path.join(dir, "action.yaml"), text);
    const r = nickelExport(path.join(dir, "action.yaml"), "json");
    if (!r.ok) throw new Error(`cannot parse action.yml:\n${r.stderr}`);
    const { name, inputs, outputs, runs } = JSON.parse(r.stdout);
    return { name, inputs: inputs ?? {}, outputs: outputs ?? {}, runs };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const sha256 = (text) => createHash("sha256").update(text).digest("hex");

// The lock entry of USES, fetched from GitHub at its pinned commit.
async function fetchAction(uses) {
  const m = USES_RE.exec(uses);
  if (!m) throw new Error(`cannot fetch ${uses}: not owner/repo[/path]@<sha>`);
  const [, repo, sub, sha] = m;
  const [owner, name] = repo.split("/");
  if (owner === TEST_OWNER) {
    const file = path.posix.join(sub.replace(/^\//, ""), "action.yml");
    const yaml = readFileSync(path.join(ROOT, TEST_ACTIONS, name, file), "utf8");
    console.log(`locked ${uses} (fixture ${TEST_ACTIONS}/${name}/${file})`);
    return { file, sha256: sha256(yaml), yaml, metadata: parseActionYaml(yaml) };
  }
  for (const name of ["action.yml", "action.yaml"]) {
    const file = path.posix.join(sub.replace(/^\//, ""), name);
    const res = await fetch(`https://raw.githubusercontent.com/${repo}/${sha}/${file}`);
    if (res.status === 404) continue;
    if (!res.ok) throw new Error(`fetching ${file} of ${repo}@${sha}: HTTP ${res.status}`);
    const yaml = await res.text();
    console.log(`locked ${uses} (${file})`);
    return { file, sha256: sha256(yaml), yaml, metadata: parseActionYaml(yaml) };
  }
  throw new Error(`${repo}@${sha} has no action.yml or action.yaml in ${sub || "its root"}`);
}

function readLock() {
  const file = path.join(ROOT, ACTIONS_LOCK);
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
}

// Checks that every entry's sha256 and metadata come from its action.yml.
function checkLock(lock) {
  const problems = [];
  for (const [uses, entry] of Object.entries(lock)) {
    if (sha256(entry.yaml) !== entry.sha256) problems.push(`${ACTIONS_LOCK}: ${uses}: sha256 doesn't match its action.yml`);
    else if (stableJSON(parseActionYaml(entry.yaml)) !== stableJSON(entry.metadata)) {
      problems.push(`${ACTIONS_LOCK}: ${uses}: metadata doesn't match its action.yml; run node compile.mjs`);
    }
  }
  return problems;
}

const check = process.argv.includes("--check");
const problems = [];
const lock = readLock();

// Compiles SRC, adding the actions it needs to the lock unless checking.
async function compile(src) {
  for (let added = 0; ; added++) {
    const r = nickelExport(src);
    const missing = MISSING_ACTION_RE.exec(r.stderr)?.[1];
    if (r.ok || check || !missing || added === MAX_NEW_ACTIONS) return r;
    lock[missing] = await fetchAction(missing);
    writeFileSync(path.join(ROOT, ACTIONS_LOCK), stableJSON(lock));
  }
}

if (check) problems.push(...checkLock(lock));

for (const src of nclFiles(SOURCES)) {
  const lockFile = path.join(OUT, `${path.basename(src, ".ncl")}.lock.yml`);
  const r = await compile(src);
  if (!r.ok) {
    problems.push(`${src} does not compile:\n${r.stderr}`);
    continue;
  }
  const text = `# Generated by workflow-compiler from ${src}; do not edit.\n# Regenerate with: node compile.mjs\n${r.stdout}`;
  if (!check) {
    writeFileSync(path.join(ROOT, lockFile), text);
    console.log(`wrote ${lockFile}`);
  } else if (!existsSync(path.join(ROOT, lockFile)) || readFileSync(path.join(ROOT, lockFile), "utf8") !== text) {
    problems.push(`${lockFile} does not match ${src}; run node compile.mjs and commit the result`);
  }
}

if (!check) {
  // Only to lock the actions they use; they must still fail to compile.
  for (const src of nclFiles(REJECT)) await compile(src);
} else {
  for (const src of nclFiles(REJECT)) {
    const expect = /^# expect: (.*)$/m.exec(readFileSync(path.join(ROOT, src), "utf8"))?.[1];
    const r = nickelExport(src);
    if (!expect) problems.push(`${src} has no "# expect:" line`);
    else if (r.ok) problems.push(`${src} compiled, but should fail with "${expect}"`);
    else if (!r.stderr.includes(expect)) problems.push(`${src} failed without "${expect}":\n${r.stderr}`);
    else console.log(`ok: ${src} rejected (${expect})`);
  }
}

for (const p of problems) console.error(`error: ${p}`);
process.exit(problems.length ? 1 : 0);
