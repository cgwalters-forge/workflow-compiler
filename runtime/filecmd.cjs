// The runner's commands, as far as the sandbox may use them.
//
// File commands (GITHUB_OUTPUT, GITHUB_ENV, GITHUB_STATE) are parsed and
// written back here: `name=value` lines, and the heredoc form
//
//   name<<DELIMITER
//   value, possibly
//   several lines
//   DELIMITER
//
// that @actions/core writes for every value. What the sandbox wrote is
// untrusted: names are checked, and values are written back to the
// runner's own files with a delimiter of the writer's choosing that the
// value can't contain, so a value can never end early and start another
// name. Installed as /usr/local/libexec/runner-sandbox-filecmd.cjs, where
// exec.cjs and run.cjs require it; tests/runtime/ requires it directly.
//
// Workflow commands are lines of a step's output that the runner acts on:
// `::name args::data` (after leading whitespace), and the legacy
// `##[name args]data` anywhere in a line. A sandboxed step's output is
// the sandbox's, so CommandFilter neutralizes every command in it except
// the annotations linters report with (`warning`, `error`, `notice`),
// `debug`, and `group`/`endgroup`, which fold the log: they only show
// text. The others would set outputs or state
// behind the file commands' checks (`set-output`, `save-state`), change
// the runner's environment, PATH or problem matchers, mask text in later
// steps' logs, or stop command processing for the steps after it.
// Neutralized lines stay in the log, marked.
"use strict";
const crypto = require("node:crypto");
const { StringDecoder } = require("node:string_decoder");

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_-]*$/;
const HEREDOC_RE = /^([^=<\r\n]+)<<([^\r\n]+)$/;

// Returns [[name, value], ...] from the text of a file command; throws on
// anything else. WHAT names the file in messages.
function parse(text, what) {
  const lines = text.split("\n");
  if (lines.at(-1) === "") lines.pop();
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "");
    if (line === "") continue;
    const heredoc = HEREDOC_RE.exec(line);
    let name;
    let value;
    if (heredoc) {
      name = heredoc[1];
      const delimiter = heredoc[2];
      const end = lines.findIndex((l, j) => j > i && l.replace(/\r$/, "") === delimiter);
      if (end < 0) throw new Error(`${what}: no closing ${JSON.stringify(delimiter.slice(0, 40))} for ${JSON.stringify(name.slice(0, 40))}`);
      value = lines.slice(i + 1, end).map((l) => l.replace(/\r$/, "")).join("\n");
      i = end;
    } else {
      const eq = line.indexOf("=");
      if (eq < 0) throw new Error(`${what}: refusing line ${JSON.stringify(line.slice(0, 80))}: neither name=value nor name<<DELIMITER`);
      name = line.slice(0, eq);
      value = line.slice(eq + 1);
    }
    if (!NAME_RE.test(name)) throw new Error(`${what}: invalid name ${JSON.stringify(name.slice(0, 80))}`);
    if (value.includes("\0")) throw new Error(`${what}: ${name} has a NUL byte`);
    out.push([name, value]);
  }
  return out;
}

// The text that sets NAME to VALUE in a file command, safe for any value.
function format(name, value) {
  if (!NAME_RE.test(name)) throw new Error(`invalid name ${JSON.stringify(name)}`);
  if (!value.includes("\n") && !value.includes("\r")) return `${name}=${value}\n`;
  let delimiter;
  do delimiter = `ghadelimiter_${crypto.randomUUID()}`; while (value.includes(delimiter));
  return `${name}<<${delimiter}\n${value}\n${delimiter}\n`;
}

const ALLOWED_COMMANDS = new Set(["warning", "error", "notice", "debug", "group", "endgroup"]);
const LEGACY_PREFIX = "##[";
const NEUTRALIZED_LEGACY = "## [";
const MARK = "[sandbox] ";
// Longest stretch of one line held before it is passed on in pieces.
const MAX_HELD = 64 * 1024;

// LINE, one line of a sandboxed step's output, with its commands
// neutralized. AT_START is false for the rest of a line whose start was
// already passed on.
function neutralize(line, atStart = true) {
  const out = line.replaceAll(LEGACY_PREFIX, NEUTRALIZED_LEGACY);
  if (!atStart) return out;
  // The runner trims what .NET calls whitespace, which includes U+0085.
  const m = /^([\s\u0085]*)::([^\s\u0085:]*)/.exec(out);
  if (!m || ALLOWED_COMMANDS.has(m[2].toLowerCase())) return out;
  return `${m[1]}${MARK}${out.slice(m[1].length)}`;
}

// Filters a stream of a sandboxed step's output: push() chunks as they
// come, and end() at the end; both return what to pass on. Lines end
// where the runner's reader ends them, at \n, \r or \r\n.
class CommandFilter {
  constructor() {
    this.decoder = new StringDecoder("utf8");
    this.held = "";
    this.atStart = true;
  }

  push(chunk) {
    this.held += typeof chunk === "string" ? chunk : this.decoder.write(chunk);
    let out = "";
    for (;;) {
      const m = /\r\n|\r|\n/.exec(this.held);
      // A \r at the end may be the start of \r\n.
      if (!m || (m[0] === "\r" && m.index === this.held.length - 1)) break;
      out += neutralize(this.held.slice(0, m.index), this.atStart) + m[0];
      this.held = this.held.slice(m.index + m[0].length);
      this.atStart = true;
    }
    if (this.held.length > MAX_HELD) {
      // Keep the last two characters: they may begin a "##[".
      const keep = this.held.slice(-2);
      out += neutralize(this.held.slice(0, -2), this.atStart);
      this.held = keep;
      this.atStart = false;
    }
    return out;
  }

  end() {
    const rest = this.held + this.decoder.end();
    this.held = "";
    return rest === "" ? "" : neutralize(rest, this.atStart);
  }
}

module.exports = { parse, format, NAME_RE, neutralize, CommandFilter };
