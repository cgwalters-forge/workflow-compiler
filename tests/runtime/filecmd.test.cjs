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

test("neutralizes workflow commands but annotations", () => {
  const { neutralize } = require("../../runtime/filecmd.cjs");
  const cases = [
    ["plain output", "plain output"],
    ["::warning file=a.md,line=1::bad", "::warning file=a.md,line=1::bad"],
    ["::ERROR::bad", "::ERROR::bad"],
    ["::notice::fyi", "::notice::fyi"],
    ["::debug::details", "::debug::details"],
    ["::set-output name=x::1", "[sandbox] ::set-output name=x::1"],
    ["  ::add-mask::secret", "  [sandbox] ::add-mask::secret"],
    ["\t::stop-commands::tok", "\t[sandbox] ::stop-commands::tok"],
    ["::save-state name=s::1", "[sandbox] ::save-state name=s::1"],
    ["::set-env name=X::1", "[sandbox] ::set-env name=X::1"],
    ["::add-path::/tmp", "[sandbox] ::add-path::/tmp"],
    ["::add-matcher::m.json", "[sandbox] ::add-matcher::m.json"],
    ["::group::title", "::group::title"],
    ["::endgroup::", "::endgroup::"],
    ["\u0085::add-mask::x", "\u0085[sandbox] ::add-mask::x"],
    ["::echo::on", "[sandbox] ::echo::on"],
    ["::::", "[sandbox] ::::"],
    ["text ##[set-output name=x;]1", "text ## [set-output name=x;]1"],
    ["::warning::then ##[add-mask]x", "::warning::then ## [add-mask]x"],
  ];
  for (const [line, want] of cases) assert.equal(neutralize(line), want, line);
});

test("the filter follows the runner's line breaks across chunks", () => {
  const { CommandFilter } = require("../../runtime/filecmd.cjs");
  const run = (chunks) => {
    const f = new CommandFilter();
    return chunks.map((c) => f.push(Buffer.isBuffer(c) ? c : Buffer.from(c))).join("") + f.end();
  };
  const cases = [
    [["a\n::set-output name=x::1\n"], "a\n[sandbox] ::set-output name=x::1\n"],
    [["a\r::add-mask::y\r\n"], "a\r[sandbox] ::add-mask::y\r\n"],
    [["::add-", "mask::y\n"], "[sandbox] ::add-mask::y\n"],
    [["a\r", "\n::echo::on"], "a\r\n[sandbox] ::echo::on"],
    [["x #", "#[set-env]y\n"], "x ## [set-env]y\n"],
    // A character split between chunks.
    [[Buffer.from([0xc3]), Buffer.from([0xa9, 0x0a])], "é\n"],
  ];
  for (const [chunks, want] of cases) assert.equal(run(chunks), want, JSON.stringify(chunks));
  // A line longer than what the filter holds is passed on in pieces, and
  // a command can't hide in its tail.
  const long = "x".repeat(70 * 1024);
  const out = run([long, "##[set-output name=x;]1\n"]);
  assert.equal(out, `${long}## [set-output name=x;]1\n`);
});
