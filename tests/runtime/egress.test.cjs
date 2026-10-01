// Tests for runtime/egress-proxy.cjs, run by ci with `node --test`.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const net = require("node:net");
const { PATTERN_RE, allowed, forbiddenAddress, splitTarget, serve } = require("../../runtime/egress-proxy.cjs");

const ALLOW = ["api.github.com", "*.githubusercontent.com"];

test("matches hosts against the allowlist", () => {
  const cases = [
    ["api.github.com", true],
    ["API.GitHub.com", true],
    ["api.github.com.", true],
    ["github.com", false],
    ["evil-api.github.com", false],
    ["api.github.com.evil.example", false],
    ["objects.githubusercontent.com", true],
    ["a.b.githubusercontent.com", true],
    // `*.` is subdomains only.
    ["githubusercontent.com", false],
    ["evilgithubusercontent.com", false],
    ["140.82.112.6", false],
    ["::1", false],
    ["[::1]", false],
    ["localhost", false],
    ["", false],
  ];
  for (const [host, want] of cases) assert.equal(allowed(host, ALLOW), want, host);
});

test("allowlist patterns are host names, or *. and one", () => {
  const cases = [
    ["crates.io", true],
    ["*.crates.io", true],
    ["xn--bcher-kva.example", true],
    ["*", false],
    ["*.io", false],
    ["a.*.io", false],
    ["1.2.3.4", false],
    ["Crates.io", false],
    ["crates.io:443", false],
    ["https://crates.io", false],
    ["-a.io", false],
    ["localhost", false],
  ];
  for (const [p, want] of cases) assert.equal(PATTERN_RE.test(p), want, p);
});

test("refuses addresses on this host and its link", () => {
  const cases = [
    ["127.0.0.1", true],
    ["127.1.2.3", true],
    ["0.0.0.0", true],
    ["169.254.169.254", true],
    ["168.63.129.16", true],
    ["::1", true],
    ["::", true],
    ["fe80::1", true],
    ["::ffff:127.0.0.1", true],
    ["::ffff:169.254.169.254", true],
    ["fd00:ec2::254", true],
    ["140.82.112.6", false],
    ["10.0.0.1", false],
    ["2606:50c0:8000::154", false],
  ];
  for (const [addr, want] of cases) assert.equal(forbiddenAddress(addr), want, addr);
});

test("parses CONNECT targets", () => {
  assert.deepEqual(splitTarget("api.github.com:443"), { host: "api.github.com", port: 443 });
  for (const t of ["api.github.com", "[::1]:443", "a:b:443", ":443", undefined]) assert.equal(splitTarget(t), null, String(t));
});

// Sends `request` to the proxy and returns its first response line.
function ask(port, request) {
  return new Promise((resolve, reject) => {
    const s = net.connect(port, "127.0.0.1", () => s.write(request));
    let data = "";
    s.on("data", (d) => {
      data += d;
      if (data.includes("\r\n")) {
        s.destroy();
        resolve(data.split("\r\n")[0]);
      }
    });
    s.on("error", reject);
  });
}

test("the proxy refuses what isn't allowed, without going out", async () => {
  const server = serve({ listen: { host: "127.0.0.1", port: 0 }, allow: ALLOW }, { quiet: true });
  await new Promise((r) => server.once("listening", r));
  const { port } = server.address();
  try {
    const cases = [
      "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
      "CONNECT api.github.com:22 HTTP/1.1\r\nHost: api.github.com:22\r\n\r\n",
      "CONNECT 140.82.112.6:443 HTTP/1.1\r\nHost: 140.82.112.6:443\r\n\r\n",
      "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::1]:443\r\n\r\n",
      "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
      "GET http://api.github.com:8080/ HTTP/1.1\r\nHost: api.github.com:8080\r\n\r\n",
    ];
    for (const req of cases) assert.match(await ask(port, req), /^HTTP\/1\.1 403 /, req);
    assert.match(await ask(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n"), /^HTTP\/1\.1 400 /);
  } finally {
    server.close();
  }
});
