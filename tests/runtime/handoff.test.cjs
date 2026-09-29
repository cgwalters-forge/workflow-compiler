// Tests for runtime/handoff.cjs, run by ci with `node --test`.
// They copy to the current user rather than to a sandbox user, which is
// all the ownership part needs without root.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { handoff, checkCredentials } = require("../../runtime/handoff.cjs");

const owner = { uid: process.getuid(), gid: process.getgid() };

// A git workspace with tracked, untracked and generated files, and the
// destination to hand it to.
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "handoff-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const ws = path.join(dir, "ws");
  const files = {
    "README.md": "hello\n",
    "src/main.sh": "#!/bin/sh\necho hi\n",
    "src/deep/x.txt": "x\n",
  };
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(ws, rel)), { recursive: true });
    fs.writeFileSync(path.join(ws, rel), text);
  }
  fs.chmodSync(path.join(ws, "src/main.sh"), 0o755);
  fs.symlinkSync("/etc/passwd", path.join(ws, "passwd-link"));
  const git = (...args) => execFileSync("git", ["-C", ws, ...args], { encoding: "utf8" });
  git("init", "-q");
  git("add", ".");
  // Not tracked: left behind by setup steps.
  fs.writeFileSync(path.join(ws, "untracked.txt"), "u\n");
  fs.mkdirSync(path.join(ws, "gen"));
  fs.writeFileSync(path.join(ws, "gen/out.txt"), "generated\n");
  return {
    ws,
    dest: path.join(dir, "dest"),
    git,
    listTracked: () => git("ls-files", "-z", "-s"),
  };
}

const exists = (p) => fs.lstatSync(p, { throwIfNoEntry: false }) !== undefined;

test("tracked copies what git tracks and what is included", (t) => {
  const f = fixture(t);
  handoff({ workspace: f.ws, dest: f.dest, mode: "tracked", include: ["gen"], owner, listTracked: f.listTracked });
  for (const rel of ["README.md", "src/main.sh", "src/deep/x.txt", "gen/out.txt"]) {
    assert.equal(fs.readFileSync(path.join(f.dest, rel), "utf8"), fs.readFileSync(path.join(f.ws, rel), "utf8"), rel);
  }
  assert.equal(fs.readlinkSync(path.join(f.dest, "passwd-link")), "/etc/passwd");
  assert.equal(exists(path.join(f.dest, "untracked.txt")), false);
  assert.equal(exists(path.join(f.dest, ".git")), false);
  assert.equal(fs.statSync(path.join(f.dest, "src/main.sh")).mode & 0o777, 0o755);
});

test("all copies everything, none nothing", (t) => {
  const f = fixture(t);
  handoff({ workspace: f.ws, dest: f.dest, mode: "all", owner, listTracked: f.listTracked });
  for (const rel of ["untracked.txt", "gen/out.txt", ".git/HEAD"]) assert.ok(exists(path.join(f.dest, rel)), rel);
  const g = fixture(t);
  handoff({ workspace: g.ws, dest: g.dest, mode: "none", owner, listTracked: g.listTracked });
  assert.deepEqual(fs.readdirSync(g.dest), []);
});

test("refuses paths through symlinks, special files and bad include paths", (t) => {
  const cases = [
    { name: "include through a symlinked directory", mode: "tracked", include: ["linked/out.txt"], error: /goes through the symlink linked/ },
    { name: "a fifo", mode: "all", fifo: true, error: /not a regular file, directory or symlink/ },
    { name: "an absolute include", mode: "tracked", include: ["/etc"], error: /invalid workspace path/ },
    { name: "a .. include", mode: "tracked", include: ["../x"], error: /invalid workspace path/ },
    { name: "a missing include", mode: "tracked", include: ["nope"], error: /does not exist/ },
    { name: "an unknown mode", mode: "some", error: /invalid handoff mode/ },
  ];
  for (const c of cases) {
    const f = fixture(t);
    fs.symlinkSync(path.join(f.ws, "gen"), path.join(f.ws, "linked"));
    if (c.fifo) execFileSync("mkfifo", [path.join(f.ws, "fifo")]);
    assert.throws(
      () => handoff({ workspace: f.ws, dest: f.dest, mode: c.mode, include: c.include ?? [], owner, listTracked: f.listTracked }),
      c.error,
      c.name,
    );
  }
});

test("finds credentials a setup step left behind", () => {
  const token = `ghs_${"a".repeat(36)}`;
  const cases = [
    [".git/config", '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic xyz\n', true],
    [".git/config", '[remote "origin"]\n\turl = https://x-access-token:abc@github.com/o/r\n', true],
    [".git/config", '[remote "origin"]\n\turl = https://github.com/o/r\n', false],
    [".git/modules/sub/config", "[http]\n\textraheader = AUTHORIZATION: basic xyz\n", true],
    [".npmrc", "//registry.npmjs.org/:_authToken=npm_abc\n", true],
    [".npmrc", "//registry.npmjs.org/:_authToken=${NPM_TOKEN}\n", false],
    [".npmrc", "registry=https://registry.npmjs.org/\n", false],
    [".yarnrc.yml", 'npmAuthToken: "${NPM_TOKEN}"\n', false],
    [".yarnrc.yml", "npmAuthToken: npm_abc\n", true],
    [".pypirc", "[pypi]\nusername = __token__\npassword = pypi-abc\n", true],
    [".git-credentials", "https://u:p@github.com\n", true],
    [".git-credentials", "https://u:p@gitlab.com\r\n", true],
    [".git-credentials", "https://u:p@gitlab.com \n", true],
    [".npmrc", "//r/:_authToken=${NPM_TOKEN} npm_real\n", true],
    [".docker/config.json", '{"auths":{"x":{"identitytoken":"secret"}}}', true],
    [".docker/config.json", '{"auths":{"ghcr.io":{"auth":"dTpw"}}}', true],
    [".docker/config.json", '{"auths":{}}', false],
    [".config/gh/hosts.yml", "github.com:\n    oauth_token: gho_abc\n", true],
    [".cargo/credentials.toml", '[registry]\ntoken = "cio_abc"\n', true],
    ["gha-creds-1234.json", '{"type": "external_account"}', true],
    ["notes/anything.txt", `left behind: ${token}\n`, true],
    ["notes/anything.txt", "ghs_short is not a token\n", false],
    ["sub/config", "extraheader = x\n", false],
  ];
  for (const [rel, text, refused] of cases) {
    if (refused) assert.throws(() => checkCredentials(Buffer.from(text), rel), /holds (credentials|a GitHub token)/, rel);
    else assert.doesNotThrow(() => checkCredentials(Buffer.from(text), rel), rel);
  }
});

test("committed files are not scanned, changed ones are", (t) => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.ws, ".npmrc"), "//registry.npmjs.org/:_authToken=npm_committed\n");
  f.git("add", ".npmrc");
  handoff({ workspace: f.ws, dest: f.dest, mode: "tracked", owner, listTracked: f.listTracked });
  assert.ok(exists(path.join(f.dest, ".npmrc")));
  const g = fixture(t);
  fs.writeFileSync(path.join(g.ws, ".npmrc"), "registry=https://registry.npmjs.org/\n");
  g.git("add", ".npmrc");
  fs.writeFileSync(path.join(g.ws, ".npmrc"), "//registry.npmjs.org/:_authToken=npm_from_setup\n");
  assert.throws(
    () => handoff({ workspace: g.ws, dest: g.dest, mode: "tracked", owner, listTracked: g.listTracked }),
    /\.npmrc holds credentials/,
  );
});

test("all refuses a checkout that persisted its token", (t) => {
  const f = fixture(t);
  execFileSync("git", ["-C", f.ws, "config", "http.https://github.com/.extraheader", "AUTHORIZATION: basic abc"]);
  assert.throws(
    () => handoff({ workspace: f.ws, dest: f.dest, mode: "all", owner, listTracked: f.listTracked }),
    /\.git\/config holds credentials/,
  );
});
