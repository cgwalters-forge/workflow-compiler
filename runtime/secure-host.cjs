// The compiler-generated "secure the host" step, run as root (`sudo node`)
// before the job enters the sandbox. It closes what runner images leave
// open to every local user, which stops mattering only once some steps
// run as a user other than runner. These are the image fixes from
// cgwalters-devspace-sandbox's setup-runner-sandbox.mjs, for images like
// the RHEL runners that are built with umask 000.
//
// TODO: replace this step with cgwalters-forge/actions/secure-host-setup,
// pinned by commit, once it exists.
"use strict";
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

// The runner's .credentials and the hosted compute agent's token
// (/opt/hca/.settings, RHEL runners only) are world-readable there.
const PRIVATE_DIRS = ["/home/runner", "/opt/hca"];
// Sticky world-writable directories, meant to stay that way.
const SHARED_TMP = ["/tmp", "/var/tmp"];
// Some images set XDG_RUNTIME_DIR to runner's here, and PAM hands it to
// every session, which breaks other users' session bus and rootless podman.
// https://github.com/actions/runner-images/issues/14649
const ENVIRONMENT = "/etc/environment";
const IMAGE_ENV_VARS = ["XDG_RUNTIME_DIR"];

function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} failed (${r.error ?? `exit ${r.status}`})`);
  return r.stdout.trim();
}

if (process.getuid() !== 0) throw new Error("must run as root");

for (const dir of PRIVATE_DIRS.filter((d) => fs.existsSync(d))) {
  fs.chmodSync(dir, 0o700);
}

// World-writable system files include ones root loads code from (a polkit
// rule, a unit): any user could make itself root through them.
const prune = SHARED_TMP.flatMap((d) => ["-path", d, "-o"]);
const fixed = run("find", ["/", "-xdev", "(", ...prune, "-false", ")", "-prune", "-o",
  "(", "-type", "f", "-o", "-type", "d", ")", "-perm", "-0002", "!", "-perm", "-1000",
  "-print", "-exec", "chmod", "o-w", "{}", "+"]);
const paths = fixed ? fixed.split("\n") : [];
console.log(`Removed world write access from ${paths.length} paths${paths.length ? `, such as:\n  ${paths.slice(0, 10).join("\n  ")}` : ""}`);

if (fs.existsSync(ENVIRONMENT)) {
  const lines = fs.readFileSync(ENVIRONMENT, "utf8").split("\n");
  const kept = lines.filter((l) => !IMAGE_ENV_VARS.some((v) => l.trim().startsWith(`${v}=`)));
  if (kept.length !== lines.length) {
    const tmp = `${ENVIRONMENT}.secure-host`;
    fs.writeFileSync(tmp, kept.join("\n"), { mode: fs.statSync(ENVIRONMENT).mode & 0o7777 });
    fs.renameSync(tmp, ENVIRONMENT);
    // SELinux (RHEL): give the new file the label of the one it replaced.
    if (spawnSync("sh", ["-c", "command -v restorecon"], { stdio: "ignore" }).status === 0) run("restorecon", [ENVIRONMENT]);
    console.log(`Dropped ${IMAGE_ENV_VARS.join(", ")} from ${ENVIRONMENT}`);
  }
}

// Hardening only (the uid split is the boundary): some images let any
// process attach to any other of its uid.
fs.writeFileSync("/proc/sys/kernel/yama/ptrace_scope", "1\n");
