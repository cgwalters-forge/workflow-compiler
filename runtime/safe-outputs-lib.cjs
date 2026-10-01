// Safe outputs: the checks an agent's proposed outputs must pass, for
// lib/safe-outputs.ncl's apply job. Shared there as
// /etc/agent-share/safe-outputs-lib.cjs and required by both
// safe-outputs-validate.cjs, in the sandbox, and safe-outputs-apply.cjs,
// in the publish phase, which runs every check again on what the sandbox
// accepted before it writes anything.
//
// The format follows gh-aw's safe outputs: one JSON object per line, with
// a `type` and that type's fields. The CONFIG is the source's, as
// lib/safe-outputs.ncl serializes it: { repo, max_total, types: { TYPE:
// { max, ... } } }.
"use strict";

const MAX_LINES = 100;
const MAX_LINE_BYTES = 256 * 1024;
const MAX_REASON = 200;

// Token shapes that must never leave the job, from bot-harness's
// redaction list and gh-aw's secret redaction.
const SECRET_PATTERNS = [
  [/\bgh[pousr]_[A-Za-z0-9]{20,}/, "GitHub token"],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/, "GitHub fine-grained token"],
  [/\bpraxis-run-[A-Za-z0-9_-]{8,}/, "praxis run token"],
  [/\bAKIA[0-9A-Z]{16}\b/, "AWS access key"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private key"],
  [/\bsk-ant-[A-Za-z0-9_-]{10,}/, "Anthropic key"],
];

// The fields of each type besides `type`: a proposal with any other
// field is refused rather than trimmed.
const FIELDS = {
  add_comment: { required: ["body"], optional: ["item_number", "repo"] },
  noop: { required: ["message"], optional: [] },
};

// gh-aw's sanitize_content, the parts that matter for text posted to
// GitHub: no @mentions that would notify anyone, no hidden HTML comments
// (instructions for the next agent that reads them), no control
// characters, and no line a workflow log would read as a command.
function sanitize(text) {
  return text
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "")
    .replace(/<!--[\s\S]*?(-->|$)/g, "")
    .replace(/(^|[^\w`])@([A-Za-z0-9][A-Za-z0-9-]{0,38}(?:\/[A-Za-z0-9._-]+)?)/g, "$1`@$2`")
    .replace(/^(\s*)::/gm, "$1: :");
}

// Why proposal P is refused under CONFIG, or null. Doesn't count caps.
function checkProposal(p, config) {
  if (p === null || typeof p !== "object" || Array.isArray(p)) return "not a JSON object";
  const fields = FIELDS[p.type];
  const cfg = config.types[p.type];
  if (!fields || !cfg) return `type ${JSON.stringify(String(p.type))} is not enabled`;
  for (const k of Object.keys(p)) {
    if (k !== "type" && !fields.required.includes(k) && !fields.optional.includes(k)) return `unknown field ${JSON.stringify(k)}`;
  }
  for (const k of fields.required) if (typeof p[k] !== "string" || p[k].trim() === "") return `${k} must be a non-empty string`;
  for (const [re, what] of SECRET_PATTERNS) {
    if (Object.values(p).some((v) => typeof v === "string" && re.test(v))) return `threat detection: looks like a ${what}`;
  }
  if (p.repo !== undefined && p.repo !== config.repo) return `repo ${JSON.stringify(String(p.repo))} is not ${config.repo}`;
  if (p.type === "add_comment") {
    const target = p.item_number ?? cfg.targets[0];
    if (!Number.isInteger(target) || !cfg.targets.includes(target)) {
      return `target ${JSON.stringify(target)} is not in the allowed targets [${cfg.targets.join(", ")}]`;
    }
    if (Buffer.byteLength(p.body) > cfg.max_body_bytes) return `body is over ${cfg.max_body_bytes} bytes`;
  } else if (Buffer.byteLength(p.message) > 1000) {
    return "message is over 1000 bytes";
  }
  return null;
}

// The output to apply for an accepted proposal: only the fields the
// apply step uses, with text sanitized.
function normalize(p, config) {
  switch (p.type) {
    case "add_comment":
      return { type: p.type, item_number: p.item_number ?? config.types.add_comment.targets[0], body: sanitize(p.body) };
    default:
      return { type: p.type, message: sanitize(p.message) };
  }
}

// Sorts PROPOSALS (parsed JSON values, or {error} for lines that weren't)
// into accepted outputs and rejections, with the caps applied in order.
function sortProposals(proposals, config) {
  const accepted = [];
  const rejected = [];
  const counts = {};
  proposals.forEach((p, i) => {
    const reject = (reason) =>
      rejected.push({ line: i + 1, type: String(p?.type ?? "?").slice(0, 40), reason: reason.slice(0, MAX_REASON) });
    if (i >= MAX_LINES) return reject(`over the cap of ${MAX_LINES} proposals`);
    if (p?.error !== undefined && Object.keys(p).length === 1) return reject(p.error);
    const why = checkProposal(p, config);
    if (why) return reject(why);
    const max = config.types[p.type].max;
    if ((counts[p.type] ?? 0) >= max) return reject(`over the cap of ${max} ${p.type} per run`);
    if (accepted.length >= config.max_total) return reject(`over the cap of ${config.max_total} outputs per run`);
    counts[p.type] = (counts[p.type] ?? 0) + 1;
    accepted.push(normalize(p, config));
  });
  return { accepted, rejected };
}

// Parses JSONL TEXT into proposals for sortProposals.
function parseLines(text) {
  return text
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => {
      if (Buffer.byteLength(l) > MAX_LINE_BYTES) return { error: `line is over ${MAX_LINE_BYTES} bytes` };
      try {
        return JSON.parse(l);
      } catch {
        return { error: "not valid JSON" };
      }
    });
}

module.exports = { sanitize, checkProposal, sortProposals, parseLines, normalize };
