// The compiler-generated "fetch the sandbox's actions" step, run as root
// (`sudo node`) before the sandbox is entered: fetches every action the
// job's sandboxed steps use, at its pinned commit, into a root-owned
// directory under ACTIONS_DIR, where the sandbox can read and run it but
// not change it.
//
// RUNNER_SANDBOX_ACTIONS is the JSON list the compiler wrote from
// actions.lock.json: [{repo, sha, files: {path: sha256}}], `files` being
// each action's action.yml by its path in the repository. git checks that
// the tree is the pinned commit's; the sha256 checks that the metadata the
// compiler used is the metadata of that commit, so an edited lock file
// fails here rather than running a different entry point.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

const ACTIONS_DIR = "/opt/runner-sandbox/actions";
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const SHA_RE = /^[0-9a-f]{40}$/;

function git(dir, args) {
  const r = spawnSync("git", ["-C", dir, "-c", "advice.detachedHead=false", ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed (${r.error ?? `exit ${r.status}`})`);
  return r.stdout.trim();
}

// root:root, directories 0755 and files keeping only their exec bit.
function makeRootOwned(p) {
  const st = fs.lstatSync(p);
  fs.lchownSync(p, 0, 0);
  if (st.isSymbolicLink()) return;
  fs.chmodSync(p, st.isDirectory() || st.mode & 0o100 ? 0o755 : 0o644);
  if (st.isDirectory()) for (const e of fs.readdirSync(p)) makeRootOwned(path.join(p, e));
}

if (process.getuid() !== 0) throw new Error("must run as root");
const actions = JSON.parse(process.env.RUNNER_SANDBOX_ACTIONS ?? "[]");
fs.mkdirSync(ACTIONS_DIR, { recursive: true, mode: 0o755 });
for (const { repo, sha, files } of actions) {
  if (!REPO_RE.test(repo) || !SHA_RE.test(sha)) throw new Error(`invalid action ${repo}@${sha}`);
  const dest = path.join(ACTIONS_DIR, repo, sha);
  const tmp = `${dest}.tmp`;
  fs.rmSync(tmp, { recursive: true, force: true });
  fs.mkdirSync(tmp, { recursive: true, mode: 0o755 });
  git(tmp, ["init", "-q"]);
  git(tmp, ["fetch", "-q", "--depth=1", "--no-tags", `https://github.com/${repo}`, sha]);
  git(tmp, ["checkout", "-q", "FETCH_HEAD"]);
  const head = git(tmp, ["rev-parse", "HEAD"]);
  if (head !== sha) throw new Error(`${repo}: fetched ${head}, not ${sha}`);
  fs.rmSync(path.join(tmp, ".git"), { recursive: true, force: true });
  for (const [file, sum] of Object.entries(files)) {
    const got = crypto.createHash("sha256").update(fs.readFileSync(path.join(tmp, file))).digest("hex");
    if (got !== sum) throw new Error(`${repo}@${sha}: ${file} has sha256 ${got}, but actions.lock.json says ${sum}`);
  }
  makeRootOwned(tmp);
  fs.rmSync(dest, { recursive: true, force: true });
  fs.renameSync(tmp, dest);
  console.log(`Fetched ${repo}@${sha} into ${dest}`);
}
