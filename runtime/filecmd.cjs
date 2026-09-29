// Parses and writes the runner's file commands (GITHUB_OUTPUT, GITHUB_ENV,
// GITHUB_STATE): `name=value` lines, and the heredoc form
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
"use strict";
const crypto = require("node:crypto");

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

module.exports = { parse, format, NAME_RE };
