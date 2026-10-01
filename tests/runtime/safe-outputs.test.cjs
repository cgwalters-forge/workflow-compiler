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
    noop: { max: 1 },
  },
};

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
    JSON.stringify({ type: "noop", message: "over its cap" }),
  ].join("\n");
  const { accepted, rejected } = lib.sortProposals(lib.parseLines(lines), CONFIG);
  assert.deepEqual(accepted.map((o) => o.type), ["add_comment", "noop"]);
  assert.equal(accepted[0].body, "hi `@bob`");
  assert.equal(accepted[0].item_number, 12);
  assert.deepEqual(rejected.map((r) => [r.line, r.reason]), [
    [2, "over the cap of 1 add_comment per run"],
    [3, "not valid JSON"],
    [5, "over the cap of 1 noop per run"],
  ]);
  // What the publish phase does with the sandbox's result: the same
  // checks, with nothing more refused or changed.
  const again = lib.sortProposals(accepted, CONFIG);
  assert.deepEqual(again, { accepted, rejected: [] });
});
