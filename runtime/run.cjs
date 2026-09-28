// Root side of a sandboxed step: runner-sandbox-exec pipes a request
// ({id, script, env}) to this program through `sudo -n`, the one command the
// runner user may still run as root once the job has entered the sandbox.
// It runs the script as the sandbox user with run0, in a login session of
// its own and with a fixed environment, then hands back what the step wrote to its
// GITHUB_OUTPUT and GITHUB_STEP_SUMMARY. Nothing here trusts the request: its
// fields are validated, and the files the sandbox wrote are read without
// following symlinks.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const CONFIG = JSON.parse(fs.readFileSync("/etc/runner-sandbox/config.json", "utf8"));
const STEPS_DIR = "/run/runner-sandbox/steps";
const RESULTS_DIR = "/run/runner-sandbox/results";
const MAX_FILE = 1 << 20;
const SANDBOX_PATH = "/usr/local/bin:/usr/bin:/bin";
const SUDO_VARS = ["SUDO_USER", "SUDO_UID", "SUDO_GID", "SUDO_HOME"];
// Variables the request may not set: the runner's credentials and anything
// that changes how the sandbox's own programs start.
const DENIED_ENV = /^(ACTIONS_|GITHUB_TOKEN$|GITHUB_ENV$|GITHUB_PATH$|GITHUB_OUTPUT$|GITHUB_STATE$|GITHUB_STEP_SUMMARY$|RUNNER_|LD_|BASH_ENV$|ENV$|NODE_|PATH$|HOME$|USER$|LOGNAME$|SHELL$)/;

function fail(message) {
  console.error(`runner-sandbox-run: ${message}`);
  process.exit(125);
}

// Reads a file the sandbox user wrote, refusing symlinks and oversized files.
function readSandboxFile(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  } catch (e) {
    if (e.code === "ENOENT") return "";
    throw new Error(`${path.basename(file)}: ${e.code}`);
  }
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile()) throw new Error(`${path.basename(file)} is not a regular file`);
    if (st.size > MAX_FILE) throw new Error(`${path.basename(file)} is larger than ${MAX_FILE} bytes`);
    return fs.readFileSync(fd, "utf8");
  } finally {
    fs.closeSync(fd);
  }
}

let req;
try {
  req = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (e) {
  fail(`invalid request: ${e.message}`);
}
if (!/^[0-9a-f]{32}$/.test(req.id ?? "")) fail("invalid step id");
if (typeof req.script !== "string") fail("missing script");
const env = req.env ?? {};
for (const [k, v] of Object.entries(env)) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) fail(`invalid variable name ${JSON.stringify(k)}`);
  if (DENIED_ENV.test(k)) fail(`${k} cannot be passed into the sandbox`);
  if (typeof v !== "string" || /[\0\n\r]/.test(v)) fail(`${k}: values must be single-line strings`);
}

// pam_systemd moves each step into a session scope, which outlives the
// service when the step leaves a process behind, and the user's systemd
// manager can run more. Stopping the user's slice ends all of them, and
// systemctl waits until they are gone. It runs before each step too, for a
// step whose run.cjs was killed (a timeout, a cancel) before it got to
// stop its own; cron, at and lingering are denied to the sandbox user, so
// nothing can start its processes outside a step.
function stopSandboxProcesses() {
  const r = spawnSync("systemctl", ["stop", `user-${CONFIG.uid}.slice`], { stdio: ["ignore", "inherit", "inherit"] });
  return r.status === 0 ? null : `could not stop the sandbox user's processes (${r.error ?? `exit ${r.status}`})`;
}

const user = CONFIG.user;
const stopError = stopSandboxProcesses();
if (stopError) fail(stopError);
const stepDir = path.join(STEPS_DIR, req.id);
const outDir = path.join(stepDir, "out");
fs.mkdirSync(stepDir, { mode: 0o755 }); // fails if the id was used before
fs.writeFileSync(path.join(stepDir, "script.sh"), req.script, { mode: 0o644 });
fs.mkdirSync(outDir, { mode: 0o700 });
fs.chownSync(outDir, CONFIG.uid, CONFIG.gid);

const vars = {
  ...env,
  LANG: "C.UTF-8", PATH: SANDBOX_PATH,
  GITHUB_OUTPUT: path.join(outDir, "output"),
  GITHUB_STEP_SUMMARY: path.join(outDir, "summary"),
};
// run0 starts the script as a transient service through its own PAM stack
// (no pam_env), so pam_systemd gives it a logind session like an SSH login
// gets: XDG_RUNTIME_DIR and the user's systemd manager, which rootless
// podman needs. It sets HOME, USER, LOGNAME and SHELL for the sandbox user
// itself. It also sets SUDO_USER and friends as sudo would, which tools
// take to mean they run under sudo, and --setenv can't unset them, hence
// the env -u. Unlike systemd-run --collect, run0 would leave a failed unit
// behind for every step that fails, so collect those too.
const argv = [
  "--pipe", "--no-ask-password", "--shell-prompt-prefix=", `--user=${user}`, `--chdir=${CONFIG.workdir}`,
  "--property=CollectMode=inactive-or-failed",
  // The sandbox gets its own /tmp, so it can't leave files there for the
  // runner's later steps; the runner's home is hidden outright.
  "--property=PrivateTmp=yes", `--property=InaccessiblePaths=-${CONFIG.runnerHome}`,
  ...Object.entries(vars).map(([k, v]) => `--setenv=${k}=${v}`),
  "--", "env", ...SUDO_VARS.flatMap((v) => ["-u", v]), "--",
  "/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail", path.join(stepDir, "script.sh"),
];
// run0 hands stdio to PID 1 over D-Bus, which accepts pipes but not every
// file type, so give it an empty pipe rather than /dev/null.
const r = spawnSync("run0", argv, { stdio: ["pipe", "inherit", "inherit"], input: "" });
const status = r.status ?? 125;

// Every process of the step is gone after this, so none can touch the
// files read below.
const stopAfter = stopSandboxProcesses();
let result;
try {
  if (stopAfter) throw new Error(stopAfter);
  result = { status, output: readSandboxFile(path.join(outDir, "output")), summary: readSandboxFile(path.join(outDir, "summary")) };
} catch (e) {
  result = { status: 125, error: e.message };
}
fs.rmSync(stepDir, { recursive: true, force: true });
fs.writeFileSync(path.join(RESULTS_DIR, `${req.id}.json`), JSON.stringify(result), { mode: 0o644, flag: "wx" });
process.exit(status);
