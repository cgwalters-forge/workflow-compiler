// The compiler-generated "enter the sandbox" step, run as root (`sudo node`)
// right after the job's runner_steps. The compiler prepends
// `const CONFIG = {...};` to this file and passes the two halves of the step
// wrapper as RUNNER_SANDBOX_EXEC_JS and RUNNER_SANDBOX_RUN_JS, the
// workspace hand-off (handoff.cjs) as RUNNER_SANDBOX_HANDOFF_JS, and the
// file command parser and step launcher they use as
// RUNNER_SANDBOX_FILECMD_JS and RUNNER_SANDBOX_LAUNCH_JS, and the egress
// proxy as RUNNER_SANDBOX_EGRESS_JS.
//
// It creates the sandbox user, hands it the workspace, installs
// the two halves of the step wrapper, and (with CONFIG.lockRunnerSudo) takes
// root away from the runner user, whose only remaining sudo rule is the
// wrapper. From here on, the job's run steps execute as the sandbox user.
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const CONFIG_DIR = "/etc/runner-sandbox";
const EXEC = "/usr/local/bin/runner-sandbox-exec";
const RUN = "/usr/local/libexec/runner-sandbox-run";
const SUDOERS = "/etc/sudoers.d/zz-runner-sandbox";
const WORKDIR = "/var/lib/runner-sandbox/work";
// The sandbox's RUNNER_TEMP and RUNNER_TOOL_CACHE, for the actions it runs.
const TEMPDIR = "/var/lib/runner-sandbox/temp";
const TOOLCACHE = "/var/lib/runner-sandbox/toolcache";
const FILECMD = "/usr/local/libexec/runner-sandbox-filecmd.cjs";
const LAUNCHER = "/usr/local/libexec/runner-sandbox-launch";
const DOCKER_UNITS = ["docker.socket", "docker.service", "containerd.service"];
// The egress proxy (egress-proxy.cjs), the sandbox's only way out unless
// sandbox.network.unrestricted.
const EGRESS_PROXY = "/usr/local/libexec/runner-sandbox-egress-proxy.cjs";
const EGRESS_CONFIG = `${CONFIG_DIR}/egress.json`;
const EGRESS_UNIT = "runner-sandbox-egress";
const EGRESS_HOST = "127.0.0.1";
const EGRESS_PORT = 3128;
const NFT_TABLE = "runner_sandbox_egress";
// systemd-resolved answers any local user over D-Bus and varlink, which no
// packet filter sees: a way to send names (data) to any DNS server.
const RESOLVED_BUS_NAME = "org.freedesktop.resolve1";
const RESOLVED_VARLINK = "/run/systemd/resolve/io.systemd.Resolve";
const DBUS_POLICY = "/etc/dbus-1/system.d/zz-runner-sandbox.conf";

function run(cmd, args, { check = true } = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
  if (check && r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} failed (${r.error ?? `exit ${r.status}`})`);
  return { status: r.status, stdout: (r.stdout ?? "").trim() };
}

function passwd(name) {
  const [, , uid, gid, , home] = run("getent", ["passwd", name]).stdout.split(":");
  return { uid: Number(uid), gid: Number(gid), home };
}

if (process.getuid() !== 0) throw new Error("must run as root");
// Sandboxed steps run through run0 (systemd 256 or later): ubuntu-26.04 and
// RHEL 10 have it, ubuntu-24.04 (systemd 255) does not.
if (run("sh", ["-c", "command -v run0"], { check: false }).status !== 0) {
  throw new Error("run0 not found: sandboxed steps need systemd 256 or later (e.g. runs-on: ubuntu-26.04)");
}
const runner = process.env.SUDO_USER;
if (!runner || runner === "root") throw new Error("must be started with sudo by the runner user");
const user = CONFIG.user;
if (user === runner || user === "root") throw new Error(`the sandbox user can't be ${user}: it must be another user than the runner and root`);

// A runner that ran a job before would hand this one the previous job's
// sandbox and workspace: refuse it. (The user itself may come with the
// image, as on the devspace runners.)
if (fs.existsSync(path.dirname(WORKDIR))) {
  throw new Error(`${path.dirname(WORKDIR)} already exists: the sandbox needs a fresh, ephemeral runner`);
}
if (run("getent", ["passwd", user], { check: false }).status !== 0) {
  run("useradd", ["--create-home", "--user-group", "--shell", "/bin/bash", user]);
}
const sandbox = passwd(user);
const runnerHome = passwd(runner).home;
// Also by uid: another name for root or the runner is still them.
if (sandbox.uid === 0 || sandbox.uid === passwd(runner).uid) {
  throw new Error(`the sandbox user ${user} has uid ${sandbox.uid}, root's or the runner's`);
}

fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o755 });
// The sandbox works on its own copy of what the job hands it (the files git
// tracks, by default); the runner's home, which holds the runner's
// credentials and the job's temp files, is closed.
const HANDOFF = `${CONFIG_DIR}/handoff.cjs`;
fs.writeFileSync(HANDOFF, process.env.RUNNER_SANDBOX_HANDOFF_JS ?? "", { mode: 0o644 });
const { handoff } = require(HANDOFF);
const copied = handoff({
  workspace: CONFIG.workspace,
  dest: WORKDIR,
  mode: CONFIG.handoff.workspace,
  include: CONFIG.handoff.include,
  owner: sandbox,
  // As runner, whose checkout it is: git as root would read the runner's
  // repository configuration.
  listTracked: () => {
    const r = spawnSync("runuser", ["-u", runner, "--", "git", "-C", CONFIG.workspace, "ls-files", "-z", "-s"], { encoding: "utf8", maxBuffer: 1 << 30 });
    if (r.status !== 0) throw new Error(`handoff.workspace = 'tracked needs a git checkout in ${CONFIG.workspace} (use 'all or 'none otherwise): ${(r.stderr ?? "").trim()}`);
    return r.stdout;
  },
});
console.log(`Handed ${copied} workspace entries (${CONFIG.handoff.workspace}) to ${user} in ${WORKDIR}`);
fs.chmodSync(runnerHome, 0o700);
for (const d of [TEMPDIR, TOOLCACHE]) {
  fs.mkdirSync(d, { mode: 0o755 });
  fs.chownSync(d, sandbox.uid, sandbox.gid);
}

// The sandbox's uid and its subordinate uids (rootless containers), as
// nftables ranges.
function sandboxUids() {
  const ranges = [`${sandbox.uid}`];
  const subuid = fs.existsSync("/etc/subuid") ? fs.readFileSync("/etc/subuid", "utf8") : "";
  for (const line of subuid.split("\n")) {
    const [owner, start, count] = line.trim().split(":");
    if ((owner === user || owner === `${sandbox.uid}`) && Number(count) > 0) {
      ranges.push(`${Number(start)}-${Number(start) + Number(count) - 1}`);
    }
  }
  return ranges;
}

// Whether `user` (root if null) can open a TCP connection to host:port.
function canConnect(host, port, asUser = null) {
  const probe = ["bash", "-c", 'exec 3<>"/dev/tcp/$0/$1"', host, `${port}`];
  const cmd = asUser ? ["runuser", "-u", asUser, "--", "timeout", "10", ...probe] : ["timeout", "10", ...probe];
  return spawnSync(cmd[0], cmd.slice(1), { stdio: "ignore" }).status === 0;
}

// Default deny for the sandbox user: its packets may go to this host
// (where the proxy listens), never to DNS, and nowhere else; the proxy,
// another user, goes out for it to the allowed hosts only. The runner and
// root keep their network as it was.
function restrictEgress(allow) {
  for (const tool of ["nft", "systemd-run"]) {
    if (run("sh", ["-c", `command -v ${tool}`], { check: false }).status !== 0) {
      throw new Error(`${tool} not found: sandbox.network needs it (or set sandbox.network.unrestricted = true)`);
    }
  }
  if (canConnect(EGRESS_HOST, EGRESS_PORT)) throw new Error(`${EGRESS_HOST}:${EGRESS_PORT}, the egress proxy's port, is already taken`);
  fs.writeFileSync(EGRESS_PROXY, process.env.RUNNER_SANDBOX_EGRESS_JS ?? "", { mode: 0o644 });
  fs.writeFileSync(EGRESS_CONFIG, JSON.stringify({ listen: { host: EGRESS_HOST, port: EGRESS_PORT }, allow }), { mode: 0o644 });
  run("systemd-run", [`--unit=${EGRESS_UNIT}`, "--property=DynamicUser=yes", "--property=ProtectSystem=strict",
    "--property=ProtectHome=yes", "--property=PrivateTmp=yes", "--property=NoNewPrivileges=yes",
    fs.realpathSync(process.execPath), EGRESS_PROXY, EGRESS_CONFIG]);
  for (let i = 0; !canConnect(EGRESS_HOST, EGRESS_PORT); i++) {
    if (i >= 50) throw new Error(`the egress proxy didn't start listening; see journalctl -u ${EGRESS_UNIT}`);
    spawnSync("sleep", ["0.2"]);
  }
  const ruleset = `table inet ${NFT_TABLE} {
  chain output {
    type filter hook output priority filter; policy accept;
    meta skuid { ${sandboxUids().join(", ")} } jump sandbox
  }
  chain sandbox {
    meta l4proto { tcp, udp } th dport 53 counter reject
    oif "lo" accept
    meta l4proto tcp counter reject with tcp reset
    counter reject with icmpx admin-prohibited
  }
}
`;
  const nft = spawnSync("nft", ["-f", "-"], { input: ruleset, encoding: "utf8", stdio: ["pipe", "inherit", "inherit"] });
  if (nft.status !== 0) throw new Error(`nft -f failed (exit ${nft.status}) on:\n${ruleset}`);
  if (fs.existsSync(path.dirname(DBUS_POLICY))) {
    fs.writeFileSync(DBUS_POLICY, `<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="${user}">
    <deny send_destination="${RESOLVED_BUS_NAME}"/>
  </policy>
</busconfig>
`, { mode: 0o644 });
    run("busctl", ["call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReloadConfig"]);
  }
  if (fs.existsSync(RESOLVED_VARLINK)) run("setfacl", ["-m", `u:${user}:---`, RESOLVED_VARLINK]);
  // Fail closed: the sandbox must not get out on its own.
  for (const [host, port] of [["1.1.1.1", 443], ["8.8.8.8", 53]]) {
    if (canConnect(host, port, user)) throw new Error(`${user} still reaches ${host}:${port} directly after the egress rules`);
  }
  console.log(`Restricted ${user}'s egress to the proxy at ${EGRESS_HOST}:${EGRESS_PORT}, allowing ${allow.length ? allow.join(", ") : "nothing"}`);
  return `http://${EGRESS_HOST}:${EGRESS_PORT}`;
}
const proxy = CONFIG.network.unrestricted ? null : restrictEgress(CONFIG.network.allow);
if (!proxy) console.log(`sandbox.network.unrestricted: ${user}'s egress is open`);

fs.writeFileSync(`${CONFIG_DIR}/config.json`, JSON.stringify({ user, ...sandbox, workdir: WORKDIR, tempdir: TEMPDIR, toolcache: TOOLCACHE, runnerHome, proxy }), { mode: 0o644 });
// runner-sandbox-run runs as root under this node, through the one sudo
// rule runner keeps, so the binary and every directory above it must be
// root's alone: a runner-owned node, as in a tool cache, would give runner
// root.
const node = fs.realpathSync(process.execPath);
for (let p = node; ; p = path.dirname(p)) {
  const st = fs.statSync(p);
  if (st.uid !== 0 || st.mode & 0o002 || (st.mode & 0o020 && st.gid !== 0)) {
    throw new Error(`${p} must be owned by root and writable only by root: the step wrapper runs as root under ${node}`);
  }
  if (p === "/") break;
}
fs.mkdirSync("/usr/local/libexec", { recursive: true });
for (const [dest, text, shebang] of [
  [EXEC, process.env.RUNNER_SANDBOX_EXEC_JS, true],
  [RUN, process.env.RUNNER_SANDBOX_RUN_JS, true],
  [LAUNCHER, process.env.RUNNER_SANDBOX_LAUNCH_JS, true],
  [FILECMD, process.env.RUNNER_SANDBOX_FILECMD_JS, false],
]) {
  if (!text) throw new Error(`nothing to install at ${dest}`);
  fs.writeFileSync(dest, shebang ? `#!${node}\n${text}` : text, { mode: 0o755 });
  fs.chmodSync(dest, shebang ? 0o755 : 0o644);
}
for (const d of ["/run/runner-sandbox/steps", "/run/runner-sandbox/results", "/run/runner-sandbox/staged"]) {
  fs.mkdirSync(d, { recursive: true, mode: 0o755 });
}

// Nothing may start the sandbox user's processes outside a step, where the
// wrapper can't stop them: no cron, no at, no lingering user manager (whose
// polkit action, like every other, is denied to it below).
for (const deny of ["/etc/cron.deny", "/etc/at.deny"]) {
  const lines = fs.existsSync(deny) ? fs.readFileSync(deny, "utf8").split("\n") : [];
  if (!lines.includes(user)) fs.appendFileSync(deny, `${user}\n`, { mode: 0o600 });
}
run("loginctl", ["disable-linger", user]);
if (fs.existsSync("/etc/polkit-1")) {
  fs.mkdirSync("/etc/polkit-1/rules.d", { recursive: true, mode: 0o755 });
  fs.writeFileSync("/etc/polkit-1/rules.d/00-runner-sandbox.rules", `polkit.addRule(function(action, subject) {
  if (subject.user == ${JSON.stringify(user)}) return polkit.Result.NO;
});
`, { mode: 0o644 });
}

// The last matching sudoers rule wins, and this file is read last.
let sudoers = `${user} ALL=(ALL:ALL) !ALL\n`;
if (CONFIG.lockRunnerSudo) {
  sudoers += `${runner} ALL=(ALL:ALL) !ALL\n${runner} ALL=(root) NOPASSWD: ${RUN} ""\n`;
}
fs.writeFileSync(`${SUDOERS}.tmp`, sudoers, { mode: 0o440 });
run("visudo", ["-cq", "-f", `${SUDOERS}.tmp`]);
fs.renameSync(`${SUDOERS}.tmp`, SUDOERS);

if (CONFIG.lockRunnerSudo) {
  // The runner user is in the docker group, and processes the runner
  // already started keep that group; a daemon that isn't running can't
  // be asked for a root container.
  const present = DOCKER_UNITS.filter((u) => run("systemctl", ["cat", u], { check: false }).status === 0);
  if (present.length) run("systemctl", ["stop", ...present]);
  // Fail closed: the runner must have lost root, and kept only the wrapper.
  if (run("runuser", ["-u", runner, "--", "sudo", "-n", "true"], { check: false }).status === 0) {
    throw new Error(`${runner} still has sudo after the lock`);
  }
  run("runuser", ["-u", runner, "--", "sudo", "-n", "-l", RUN]);
}
console.log(`Entered the sandbox: later run steps execute as ${user} (uid ${sandbox.uid}) in ${WORKDIR}`);
console.log(run("sudo", ["-l", "-U", runner]).stdout);
