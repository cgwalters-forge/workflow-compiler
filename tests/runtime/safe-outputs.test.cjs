"use strict";
// Unit tests of runtime/safe-outputs-lib.cjs, the checks lib/safe-outputs.ncl's
// apply job runs on an agent's proposals, in its sandbox and again in its
// publish phase.
const test = require("node:test");
const assert = require("node:assert/strict");
const lib = require("../../runtime/safe-outputs-lib.cjs");

const CONFIG = {
  repo: "o/r",
  max_total: 3,
  types: {
    add_comment: { max: 1, targets: [12, 13], max_body_bytes: 100 },
    create_pull_request: {
      max: 1, base: "main", allowed_paths: ["docs/**", "*.md"], max_patch_bytes: 2000, max_files: 2,
      max_body_bytes: 100, branch_prefix: "safe-outputs/", draft: true,
    },
    noop: { max: 1 },
  },
};

const diff = (file, extra = "") =>
  `diff --git a/${file} b/${file}\n${extra}new file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/${file}\n@@ -0,0 +1 @@\n+hello\n`;
const pr = (patch) => ({ type: "create_pull_request", title: "t", body: "b", patch });

test("sanitize neutralizes mentions, HTML comments and workflow commands", () => {
  const cases = [
    ["hi @alice", "hi `@alice`"],
    ["@org/team ping", "`@org/team` ping"],
    ["mail a@b.c", "mail a@b.c"],
    ["already `@x`", "already `@x`"],
    ["a<!-- hidden -->b", "ab"],
    ["a<!-- unterminated", "a"],
    ["::add-mask::x\n  ::warning::y", ": :add-mask::x\n  : :warning::y"],
    ["bell\x07", "bell"],
  ];
  for (const [input, want] of cases) {
    assert.equal(lib.sanitize(input), want, input);
    assert.equal(lib.sanitize(want), want, `sanitizing again: ${want}`);
  }
});

test("globs", () => {
  const cases = [
    ["docs/**", "docs/a/b.md", true],
    ["docs/**", "docs.md", false],
    ["*.md", "README.md", true],
    ["*.md", "docs/README.md", false],
    ["**/*.md", "README.md", true],
    ["**/*.md", "a/b/c.md", true],
    ["src/?.rs", "src/a.rs", true],
  ];
  for (const [glob, path, want] of cases) assert.equal(lib.globRegex(glob).test(path), want, `${glob} ${path}`);
});

test("proposals are checked against the config", () => {
  const cases = [
    [{ type: "add_comment", body: "hi" }, null],
    [{ type: "add_comment", item_number: 13, body: "hi" }, null],
    [{ type: "add_comment", item_number: 1, body: "hi" }, /not in the allowed targets/],
    [{ type: "add_comment", item_number: "12", body: "hi" }, /not in the allowed targets/],
    [{ type: "add_comment", repo: "o/other", body: "hi" }, /is not o\/r/],
    [{ type: "add_comment", body: "x".repeat(101) }, /over 100 bytes/],
    [{ type: "add_comment", body: `ghp_${"a".repeat(36)}` }, /threat detection/],
    [{ type: "add_comment", body: "x", labels: [] }, /unknown field/],
    [{ type: "add_comment", body: "" }, /non-empty/],
    [{ type: "create_issue", title: "x" }, /not enabled/],
    [{ type: "noop", message: "nothing" }, null],
    [[], /not a JSON object/],
    [pr(diff("docs/a.md")), null],
    [pr(diff("README.md")), null],
    [pr(diff(".github/workflows/x.yml")), /may never be changed/],
    [pr(diff("docs/.git/config")), /may never be changed/],
    [pr(diff("Cargo.toml")), /outside the allowed paths/],
    [pr(diff("docs/../Cargo.toml")), /not a plain relative path/],
    [pr(diff("docs/a.md").replace("new file mode 100644", "new file mode 120000")), /mode 120000/],
    [pr(diff("docs/a.md") + diff("docs/b.md") + diff("docs/c.md")), /3 files, over 2/],
    [pr(`${diff("docs/a.md")}GIT binary patch\n`), /binary/],
    [pr("--- a/docs/a.md\n+++ b/docs/a.md\n"), /not a git diff/],
    [pr(diff("docs/a.md") + "+x".repeat(1000)), /over 2000 bytes/],
    [pr(`diff --git a/docs/a.md b/docs/a.md\nrename from docs/a.md\nrename to src/a.rs\n`), /outside the allowed paths/],
    [pr(`diff --git "a/docs/\\303.md" "b/docs/\\303.md"\n`), /not a git diff|quoted/],
  ];
  for (const [p, want] of cases) {
    const got = lib.checkProposal(p, CONFIG);
    if (want === null) assert.equal(got, null, JSON.stringify(p));
    else assert.match(got ?? "accepted", want, JSON.stringify(p));
  }
});

test("caps apply in order, and accepted text is sanitized", () => {
  const lines = [
    JSON.stringify({ type: "add_comment", body: "hi @bob" }),
    JSON.stringify({ type: "add_comment", body: "second" }),
    "{not json",
    JSON.stringify({ type: "noop", message: "n" }),
    JSON.stringify(pr(diff("docs/a.md"))),
    JSON.stringify({ type: "noop", message: "over the total" }),
  ].join("\n");
  const { accepted, rejected } = lib.sortProposals(lib.parseLines(lines), CONFIG);
  assert.deepEqual(accepted.map((o) => o.type), ["add_comment", "noop", "create_pull_request"]);
  assert.equal(accepted[0].body, "hi `@bob`");
  assert.equal(accepted[0].item_number, 12);
  assert.deepEqual(rejected.map((r) => [r.line, r.reason]), [
    [2, "over the cap of 1 add_comment per run"],
    [3, "not valid JSON"],
    [6, "over the cap of 1 noop per run"],
  ]);
  // What the publish phase does with the sandbox's result: the same
  // checks, with nothing more refused or changed.
  const again = lib.sortProposals(accepted, CONFIG);
  assert.deepEqual(again, { accepted, rejected: [] });
});
