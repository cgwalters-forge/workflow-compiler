// Tests for runtime/filecmd.cjs, run by ci with `node --test`.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { parse, format } = require("../../runtime/filecmd.cjs");

test("parses name=value lines and heredocs", () => {
  const cases = [
    ["a=1\nb=two words\n", [["a", "1"], ["b", "two words"]]],
    ["a=\n", [["a", ""]]],
    ["a=x=y\n", [["a", "x=y"]]],
    ["\n\na=1\r\n", [["a", "1"]]],
    ["m<<EOF\nline 1\nline 2\nEOF\n", [["m", "line 1\nline 2"]]],
    ["m<<ghadelimiter_1\n\nghadelimiter_1\nn=2\n", [["m", ""], ["n", "2"]]],
    // What @actions/core writes: a heredoc even for one line.
    ["node-version<<ghadelimiter_abc\nv22.1.0\nghadelimiter_abc\n", [["node-version", "v22.1.0"]]],
    ["", []],
  ];
  for (const [text, want] of cases) assert.deepEqual(parse(text, "T"), want, JSON.stringify(text));
});

test("refuses what isn't a file command", () => {
  const cases = [
    ["just text\n", /neither name=value nor name<<DELIMITER/],
    ["m<<EOF\nno end\n", /no closing/],
    ["bad name=1\n", /invalid name/],
    ["1abc=1\n", /invalid name/],
    ["a=b\0c\n", /NUL/],
  ];
  for (const [text, error] of cases) assert.throws(() => parse(text, "T"), error, JSON.stringify(text));
});

test("format round-trips any value, and a value can't start another name", () => {
  const values = ["", "plain", "two\nlines", "EOF\ninjected=1", "ghadelimiter_x\nz=1\nghadelimiter_x", "trailing\n"];
  for (const v of values) {
    const text = format("out", v) + format("next", "ok");
    assert.deepEqual(parse(text, "T"), [["out", v.replace(/\r/g, "")], ["next", "ok"]], JSON.stringify(v));
  }
  assert.throws(() => format("bad name", "x"), /invalid name/);
});
