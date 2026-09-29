// Tests for lib/check-lock.mjs, run by ci with `node --test`: a job of
// the compiled shape passes, and each way of leaving the sandbox that a
// hand-built "compiled" workflow could take is found.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const RUNTIME_DIR = path.join(__dirname, "../../runtime");
const runtime = Object.fromEntries(fs.readdirSync(RUNTIME_DIR).map((f) => [f, fs.readFileSync(path.join(RUNTIME_DIR, f), "utf8")]));
const EXEC = "/usr/local/bin/runner-sandbox-exec";
const SEAL = "steps.runner-sandbox-seal.outcome == 'success'";
const ENTER_ENV = {
  RUNNER_SANDBOX_EXEC_JS: runtime["exec.cjs"],
  RUNNER_SANDBOX_RUN_JS: runtime["run.cjs"],
  RUNNER_SANDBOX_HANDOFF_JS: runtime["handoff.cjs"],
  RUNNER_SANDBOX_FILECMD_JS: runtime["filecmd.cjs"],
  RUNNER_SANDBOX_LAUNCH_JS: runtime["launch.cjs"],
};

// A workflow of the compiled shape, with steps between enter and seal
// (SANDBOXED) and after the seal (PUBLISH).
function workflow({ sandboxed = [{ shell: `${EXEC} {0}`, run: "id" }], publish = [], job = {}, top = {} } = {}) {
  return {
    name: "t",
    ...top,
    jobs: {
      t: {
        "runs-on": "ubuntu-26.04",
        ...job,
        steps: [
          { uses: "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", with: { "persist-credentials": false } },
          { name: "Secure the host (generated)", shell: "sudo node {0}", run: runtime["secure-host.cjs"] },
          {
            name: "Enter the sandbox (generated)",
            shell: `sudo --preserve-env=${Object.keys(ENTER_ENV).join(",")} node {0}`,
            env: ENTER_ENV,
            run: `const CONFIG = {"user":"runner-sandbox"};\n${runtime["install.cjs"]}`,
          },
          ...sandboxed,
          { name: "Seal the sandbox (generated)", id: "runner-sandbox-seal", if: "always()", shell: "bash", run: `${EXEC} --seal` },
          ...publish,
        ],
      },
    },
  };
}

test("the compiled shape passes", async () => {
  const { checkWorkflow } = await import("../../lib/check-lock.mjs");
  const ok = workflow({
    sandboxed: [
      { shell: `${EXEC} {0}`, run: "make", env: { CC: "gcc", RUNNER_SANDBOX_ENV: "CC" } },
      { shell: `${EXEC} --action {0}`, run: "{}", env: { RUNNER_SANDBOX_ENV_NAMES: "INPUT_X", RUNNER_SANDBOX_VAR_0: "1" } },
      { shell: `${EXEC} --action-path o/r@${"a".repeat(40)} {0}`, run: "true" },
      { id: "stage-log", shell: "bash", run: `${EXEC} --stage log out/test.log` },
    ],
    publish: [
      { if: `!cancelled() && steps.stage-log.outcome == 'success' && ${SEAL}`, uses: "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" },
      { if: `(always()) && ${SEAL}`, run: "gh pr comment" },
    ],
  });
  assert.deepEqual(checkWorkflow(ok, runtime), []);
});

test("finds each way out of the sandbox", async () => {
  const { checkWorkflow } = await import("../../lib/check-lock.mjs");
  const cases = [
    ["an action mid-sandbox", workflow({ sandboxed: [{ uses: "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" }] }), /uses .* between entering the sandbox and the seal/],
    ["a plain shell", workflow({ sandboxed: [{ shell: "bash", run: "id" }] }), /not the sandbox wrapper/],
    ["a default shell", workflow({ sandboxed: [{ run: "id" }] }), /not the sandbox wrapper/],
    ["a stage that runs more", workflow({ sandboxed: [{ shell: "bash", run: `${EXEC} --stage x y; curl evil` }] }), /not the sandbox wrapper/],
    ["NODE_OPTIONS for the wrapper", workflow({ sandboxed: [{ shell: `${EXEC} {0}`, run: "id", env: { NODE_OPTIONS: "--require /tmp/x" } }] }), /sets NODE_OPTIONS/],
    ["a second seal id", workflow({ sandboxed: [{ id: "runner-sandbox-seal", shell: `${EXEC} {0}`, run: "true" }] }), /exactly one generated seal step/],
    ["publish without the seal", workflow({ publish: [{ run: "id" }] }), /without requiring the seal/],
    ["publish escaping the seal", workflow({ publish: [{ if: `(always()) || (true) && ${SEAL}`, run: "id" }] }), /without requiring the seal/],
    ["publish as a template", workflow({ publish: [{ if: `\${{ 'a' }} && ${SEAL}`, run: "id" }] }), /without requiring the seal/],
    ["a job env", workflow({ job: { env: { LD_PRELOAD: "/tmp/x.so" } } }), /sets env/],
    ["a job container", workflow({ job: { container: "alpine" } }), /sets container/],
    ["a workflow env", workflow({ top: { env: { BASH_ENV: "/tmp/x" } } }), /the workflow sets env/],
  ];
  for (const [name, wf, want] of cases) {
    const problems = checkWorkflow(wf, runtime);
    assert.ok(problems.some((p) => want.test(p)), `${name}: ${JSON.stringify(problems)}`);
  }
  // An enter step that isn't the compiler's, and none at all.
  const fake = workflow();
  fake.jobs.t.steps[2].run += "\nrequire('child_process').execSync('echo pwned');";
  assert.match(checkWorkflow(fake, runtime).join("\n"), /0 generated steps entering the sandbox/);
  const none = workflow();
  none.jobs.t.steps.splice(2, 1);
  assert.match(checkWorkflow(none, runtime).join("\n"), /0 generated steps entering the sandbox/);
});
