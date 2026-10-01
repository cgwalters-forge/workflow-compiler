// The sandbox's egress proxy: an HTTP proxy that the enter step
// (install.cjs) starts as a systemd unit with a dynamic user, and the only
// way out of the host for the sandbox user, whose other traffic nftables
// rejects. It forwards plain HTTP requests and tunnels CONNECT only to the
// hosts `sandbox.network.allow` lists, on ports 80 and 443, resolving the
// names itself so that the sandbox's own DNS can stay closed.
//
//   node egress-proxy.cjs CONFIG.json   CONFIG: {listen: {host, port}, allow: [pattern]}
//
// A pattern is a host name (`crates.io`, that host only) or `*.` and a
// host name (`*.githubusercontent.com`, its subdomains only). IP literals
// are refused, and so are names that resolve to loopback, link-local
// (the cloud metadata service) or unspecified addresses.
"use strict";
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const dns = require("node:dns/promises");

// Lowercase DNS names of two or more labels whose last label starts with a
// letter, so no IPv4 literal; `*.` only as the first label. The compiler
// (lib/gha.ncl, src/shape.rs) holds the allowlist to the same pattern.
const PATTERN_RE = /^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/;
const PORTS = new Set([80, 443]);
const CONNECT_TIMEOUT_MS = 30_000;

// The host in a request, lowercased and without a trailing dot, or null
// if it isn't a DNS name (an IP literal, say).
function normalize(host) {
  const h = String(host).toLowerCase().replace(/\.$/, "");
  if (net.isIP(h) || h.startsWith("[")) return null;
  return PATTERN_RE.test(h) && !h.startsWith("*.") ? h : null;
}

function allowed(host, allow) {
  const h = normalize(host);
  if (!h) return false;
  return allow.some((p) => (p.startsWith("*.") ? h.endsWith(p.slice(1)) : h === p));
}

// Addresses no allowed name may lead to: the host itself and the link
// (where the cloud metadata service and Azure's wireserver live).
function forbiddenAddress(addr) {
  const v4 = addr.startsWith("::ffff:") && net.isIPv4(addr.slice(7)) ? addr.slice(7) : addr;
  if (net.isIPv4(v4)) {
    const [a, b] = v4.split(".").map(Number);
    return a === 0 || a === 127 || (a === 169 && b === 254) || v4 === "168.63.129.16";
  }
  const a = addr.toLowerCase();
  return a === "::" || a === "::1" || /^fe[89ab]/.test(a) || a.startsWith("fd00:ec2:");
}

async function resolve(host) {
  const addrs = (await dns.lookup(host, { all: true, verbatim: true })).map((r) => r.address);
  const ok = addrs.filter((a) => !forbiddenAddress(a));
  if (!ok.length) throw new Error(`${host} resolves only to forbidden addresses (${addrs.join(", ")})`);
  return ok[0];
}

// `host:port` from a CONNECT request target, or null.
function splitTarget(target) {
  const m = /^([^:[\]]+):([0-9]{1,5})$/.exec(target ?? "");
  return m ? { host: m[1], port: Number(m[2]) } : null;
}

function serve(config, { quiet = false } = {}) {
  const allow = config.allow;
  const say = quiet ? () => {} : console.log;
  const log = (verdict, host, port, why = "") => say(`${verdict} ${host}:${port}${why ? ` (${why})` : ""}`);
  const check = (host, port) => {
    if (!PORTS.has(port)) return `port ${port} is not 80 or 443`;
    if (!allowed(host, allow)) return "not in sandbox.network.allow";
    return null;
  };

  const server = http.createServer(async (req, res) => {
    let url;
    try {
      url = new URL(req.url);
    } catch {
      res.writeHead(400).end("egress proxy: only absolute http:// URLs\n");
      return;
    }
    const port = Number(url.port || 80);
    const denied = url.protocol !== "http:" ? "only http:// requests (https goes through CONNECT)" : check(url.hostname, port);
    if (denied) {
      log("DENY", url.hostname, port, denied);
      res.writeHead(403).end(`egress proxy: ${url.hostname}:${port}: ${denied}\n`);
      return;
    }
    let addr;
    try {
      addr = await resolve(url.hostname);
    } catch (e) {
      log("DENY", url.hostname, port, e.message);
      res.writeHead(502).end(`egress proxy: ${e.message}\n`);
      return;
    }
    log("ALLOW", url.hostname, port);
    const headers = { ...req.headers };
    delete headers["proxy-connection"];
    delete headers["proxy-authorization"];
    const up = http.request({ host: addr, port, method: req.method, path: url.pathname + url.search, headers });
    up.on("response", (r) => {
      res.writeHead(r.statusCode ?? 502, r.headers);
      r.pipe(res);
    });
    up.on("error", (e) => res.headersSent ? res.destroy() : res.writeHead(502).end(`egress proxy: ${e.message}\n`));
    req.pipe(up);
  });

  server.on("connect", async (req, client, head) => {
    const t = splitTarget(req.url);
    const host = t?.host ?? String(req.url);
    const port = t?.port ?? 0;
    const denied = t ? check(t.host, t.port) : "not host:port";
    const refuse = (status, why) => {
      log("DENY", host, port, why);
      client.end(`HTTP/1.1 ${status}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\negress proxy: ${host}:${port}: ${why}\n`);
    };
    if (denied) return refuse("403 Forbidden", denied);
    let addr;
    try {
      addr = await resolve(t.host);
    } catch (e) {
      return refuse("502 Bad Gateway", e.message);
    }
    const up = net.connect({ host: addr, port: t.port, timeout: CONNECT_TIMEOUT_MS });
    let established = false;
    up.once("connect", () => {
      established = true;
      up.setTimeout(0);
      log("ALLOW", host, port);
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head?.length) up.write(head);
      up.pipe(client);
      client.pipe(up);
    });
    up.once("timeout", () => up.destroy(new Error("connect timed out")));
    up.on("error", (e) => (established ? client.destroy() : refuse("502 Bad Gateway", e.message)));
    client.on("error", () => up.destroy());
  });
  server.on("clientError", (_e, socket) => socket.destroy());
  server.listen(config.listen.port, config.listen.host, () =>
    say(`egress proxy on ${config.listen.host}:${server.address().port}, allowing ${allow.length ? allow.join(", ") : "nothing"}`));
  return server;
}

module.exports = { PATTERN_RE, allowed, forbiddenAddress, splitTarget, serve };

if (require.main === module) {
  const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  for (const p of config.allow) {
    if (!PATTERN_RE.test(p)) throw new Error(`invalid sandbox.network.allow entry ${JSON.stringify(p)}`);
  }
  serve(config);
}
