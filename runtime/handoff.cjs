// The workspace hand-off: what the enter step copies from the runner's
// workspace into the sandbox's. install.cjs loads it (the compiler passes
// it as RUNNER_SANDBOX_HANDOFF_JS) and runs it as root; tests/runtime/
// requires it directly.
//
// The job's `handoff.workspace` picks what is copied:
//
//   tracked  the files git tracks (`git ls-files`), plus handoff.include
//   all      the whole workspace
//   none     nothing: the sandbox starts in an empty directory
//
// Nothing here follows a symlink: a path that goes through one is refused,
// and a symlink inside the copied tree is copied as a symlink, which the
// sandbox then resolves as its own user. Special files are refused. The
// copy is refused too if it holds credentials a setup step left behind,
// such as checkout's token with persist-credentials, or an .npmrc token.
// Files exactly as git tracks them aren't scanned: whatever they hold was
// committed, not left behind by the runner.
"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const HANDOFF_MODES = ["tracked", "all", "none"];

// Files that hold credentials: which paths, and patterns whose first group
// is the credential. A value that only refers to an environment variable
// (an .npmrc's `_authToken=${NPM_TOKEN}`) is not one.
const CREDENTIAL_FILES = [
  // checkout's persist-credentials (older versions write it here), or a
  // token in a remote URL, for the repository and its submodules.
  { path: /(^|\/)\.git\/(modules\/.+\/)?config$/, re: [/^\s*extraheader\s*=\s*(.+)$/gim, /:\/\/[^/\s:@]+:([^/\s@]+)@/g] },
  { path: /(^|\/)\.git-credentials$/, re: [/^\s*(\S.*?)\s*$/gm] },
  { path: /(^|\/)\.netrc$/, re: [/\bpassword\s+(\S+)/g] },
  { path: /(^|\/)\.npmrc$/, re: [/(?:_authToken|_auth|_password)\s*=\s*(.+)$/gm] },
  { path: /(^|\/)\.yarnrc\.yml$/, re: [/(?:npmAuthToken|npmAuthIdent)\s*:\s*(.+)$/gm] },
  { path: /(^|\/)\.pypirc$/, re: [/^\s*password\s*[=:]\s*(.+)$/gm] },
  { path: /(^|\/)\.docker\/config\.json$/, re: [/"(?:auth|identitytoken|registrytoken)"\s*:\s*"([^"]+)"/g] },
  { path: /(^|\/)\.aws\/credentials$/, re: [/aws_secret_access_key\s*=\s*(.+)$/gm] },
  // gh's login, cargo's registry token.
  { path: /(^|\/)gh\/hosts\.yml$/, re: [/oauth_token\s*:\s*(.+)$/gm] },
  { path: /(^|\/)\.cargo\/credentials(\.toml)?$/, re: [/^\s*token\s*=\s*(.+)$/gm] },
  // google-github-actions/auth writes these into the workspace.
  { path: /(^|\/)gha-creds-[^/]*\.json$/, re: [/^([\s\S]+)$/g] },
];
// Tokens GitHub issues, in any file.
const GITHUB_TOKEN_RE = /\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b/;
const ENV_REFERENCE_RE = /^\s*["']?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?["']?\s*$/;

// Throws if DATA, the content of the workspace file REL, holds credentials.
function checkCredentials(data, rel) {
  const text = data.toString("utf8");
  const refuse = (what) => {
    throw new Error(`${rel} holds ${what}; refusing to hand it to the sandbox (for checkout, set persist-credentials: false)`);
  };
  if (GITHUB_TOKEN_RE.test(text)) refuse("a GitHub token");
  for (const c of CREDENTIAL_FILES) {
    if (!c.path.test(rel)) continue;
    for (const re of c.re) {
      for (const m of text.matchAll(re)) {
        if (!ENV_REFERENCE_RE.test(m[1])) refuse("credentials");
      }
    }
  }
}

// The git object id of DATA as a blob, in the hash of OID (SHA-1 or SHA-256).
function blobId(data, oid) {
  const hash = crypto.createHash(oid.length === 64 ? "sha256" : "sha1");
  return hash.update(`blob ${data.length}\0`).update(data).digest("hex");
}

// {path: oid} from the NUL-separated output of `git ls-files -z -s`.
function parseIndex(text) {
  const index = new Map();
  for (const entry of text.split("\0").filter(Boolean)) {
    const m = /^\d+ ([0-9a-f]{40}|[0-9a-f]{64}) \d+\t(.+)$/s.exec(entry);
    if (!m) throw new Error(`unexpected git ls-files entry ${JSON.stringify(entry.slice(0, 80))}`);
    index.set(m[2], m[1]);
  }
  return index;
}

// A relative path within the workspace: no leading /, no . or .. component.
function checkRelative(rel) {
  if (typeof rel !== "string" || rel === "" || path.isAbsolute(rel) || rel.split("/").some((c) => c === "" || c === "." || c === "..")) {
    throw new Error(`invalid workspace path ${JSON.stringify(rel)}`);
  }
}

// Whether ROOT/REL exists; throws if it goes through a symlink before its
// last component.
function existsNoSymlinkAbove(root, rel) {
  let p = root;
  for (const part of rel.split("/")) {
    p = path.join(p, part);
    const st = fs.lstatSync(p, { throwIfNoEntry: false });
    if (!st) return false;
    if (p === path.join(root, rel)) return true;
    if (st.isSymbolicLink()) throw new Error(`${rel} goes through the symlink ${path.relative(root, p)}`);
    if (!st.isDirectory()) throw new Error(`${rel}: ${path.relative(root, p)} is not a directory`);
  }
  return true;
}

// Copies SRC (REL in the workspace) to DEST, owned by OWNER {uid, gid},
// keeping modes and times, copying symlinks as symlinks, refusing special
// files and credentials in files that differ from INDEX.
function copyEntry(src, dest, rel, owner, index) {
  const st = fs.lstatSync(src);
  if (st.isSymbolicLink()) {
    fs.symlinkSync(fs.readlinkSync(src), dest);
    fs.lchownSync(dest, owner.uid, owner.gid);
    return;
  }
  if (st.isDirectory()) {
    fs.mkdirSync(dest, { mode: 0o700 });
    for (const entry of fs.readdirSync(src).sort()) {
      copyEntry(path.join(src, entry), path.join(dest, entry), path.join(rel, entry), owner, index);
    }
  } else if (st.isFile()) {
    const data = fs.readFileSync(src);
    const oid = index.get(rel);
    if (!oid || blobId(data, oid) !== oid) checkCredentials(data, rel);
    fs.writeFileSync(dest, data, { mode: 0o600, flag: "wx" });
  } else {
    throw new Error(`${rel} is not a regular file, directory or symlink; refusing to hand it to the sandbox`);
  }
  fs.chownSync(dest, owner.uid, owner.gid);
  fs.chmodSync(dest, st.mode & 0o7777 & ~0o6000);
  fs.utimesSync(dest, st.atime, st.mtime);
}

// Creates the parent directories of DEST_ROOT/REL that don't exist yet,
// like their counterparts in SRC_ROOT.
function makeParents(srcRoot, destRoot, rel, owner) {
  const parts = rel.split("/").slice(0, -1);
  for (let i = 1; i <= parts.length; i++) {
    const sub = parts.slice(0, i).join("/");
    const dest = path.join(destRoot, sub);
    if (fs.existsSync(dest)) continue;
    const st = fs.lstatSync(path.join(srcRoot, sub));
    fs.mkdirSync(dest, { mode: st.mode & 0o777 });
    fs.chownSync(dest, owner.uid, owner.gid);
  }
}

// The workspace paths to copy for MODE, relative to the workspace, or null
// for all of it, given the INDEX of what git tracks.
function handoffPaths(mode, include, index) {
  if (!HANDOFF_MODES.includes(mode)) throw new Error(`invalid handoff mode ${JSON.stringify(mode)}`);
  if (mode === "none") return [];
  if (mode === "all") return null;
  const all = new Set([...index.keys(), ...include]);
  // A path below another one in the list is copied with it (an included
  // directory, or a submodule, which git lists as one entry).
  const below = (p) => {
    const parts = p.split("/");
    return parts.slice(1).some((_, i) => all.has(parts.slice(0, i + 1).join("/")));
  };
  return [...all].filter((p) => !below(p)).sort();
}

// Hands WORKSPACE over to DEST, owned by OWNER. LIST_TRACKED returns the
// output of `git ls-files -z -s` (install.cjs runs it as the runner user,
// not root), and throws if the workspace isn't a git checkout, which only
// 'tracked needs. Returns the number of top-level entries copied.
function handoff({ workspace, dest, mode, include = [], owner, listTracked }) {
  for (const rel of include) checkRelative(rel);
  let index = new Map();
  if (mode !== "none") {
    try {
      index = parseIndex(listTracked());
    } catch (e) {
      if (mode === "tracked") throw e;
    }
  }
  const paths = handoffPaths(mode, include, index);
  fs.mkdirSync(dest, { recursive: true, mode: 0o755 });
  fs.chownSync(dest, owner.uid, owner.gid);
  const rels = paths ?? fs.readdirSync(workspace).sort();
  for (const rel of rels) {
    checkRelative(rel);
    const src = path.join(workspace, rel);
    if (!existsNoSymlinkAbove(workspace, rel)) {
      // A tracked file the setup steps deleted is simply not there.
      if (include.includes(rel)) throw new Error(`handoff.include path ${rel} does not exist in the workspace`);
      continue;
    }
    makeParents(workspace, dest, rel, owner);
    copyEntry(src, path.join(dest, rel), rel, owner, index);
  }
  return rels.length;
}

module.exports = { handoff, handoffPaths, checkCredentials, HANDOFF_MODES };
