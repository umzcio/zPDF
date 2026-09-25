// End-to-end test: wrangler dev (local) + a mock GitHub API. No network, no real token.
import { spawn } from "node:child_process";
import http from "node:http";
import assert from "node:assert/strict";

const MOCK_PORT = 18788, WORKER_PORT = 18787;
const received = [];
let rejectLabelsOnce = false;
const mock = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const payload = JSON.parse(body || "{}");
    received.push({ url: req.url, auth: req.headers.authorization, payload });
    if (rejectLabelsOnce && payload.labels) { rejectLabelsOnce = false; res.writeHead(422); return res.end("{}"); }
    res.writeHead(201, { "content-type": "application/json" });
    res.end(JSON.stringify({ number: 100 + received.length, html_url: `https://github.com/umzcio/zPDF/issues/${100 + received.length}` }));
  });
}).listen(MOCK_PORT);

const worker = spawn("npx", ["wrangler", "dev", "--port", String(WORKER_PORT), "--var", `GITHUB_API:http://127.0.0.1:${MOCK_PORT}`],
  { cwd: new URL("..", import.meta.url).pathname, stdio: ["ignore", "pipe", "pipe"] });
let log = "";
worker.stdout.on("data", (d) => (log += d));
worker.stderr.on("data", (d) => (log += d));
const base = `http://127.0.0.1:${WORKER_PORT}`;
async function ready() {
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch {}
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("wrangler dev did not start:\n" + log);
}
const post = (body, ip = "203.0.113.1") => fetch(`${base}/v1/reports`, {
  method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": ip }, body: JSON.stringify(body),
});
// 1×1 PNG
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const good = {
  kind: "bug", title: "Signing fails on umzmac", description: "Sign & Save shows ENGINE_FAILED. cc @octocat",
  steps: "1. Open PDF\n2. Sign", expected: "A signed PDF", email: "tester@example.edu",
  diagnostics: { appVersion: "0.1.1", build: "2", macOS: "27.0 (26A428)", chip: "arm64", locale: "en_US",
                 lastError: "The PDF engine could not complete this operation. Details: AttributeError: 'int'…" },
  screenshot: { mime: "image/png", base64: png },
};
let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok  -", name); } catch (e) { failures++; console.log("FAIL -", name, "\n     ", e.message); }
}
try {
  await ready();
  await test("valid bug report files an issue without leaking the email", async () => {
    const r = await post(good, "203.0.113.10");
    assert.equal(r.status, 201, await r.clone().text());
    const out = await r.json();
    assert.equal(out.ok, true); assert.ok(out.issue.number > 100);
    const sent = received.at(-1);
    assert.equal(sent.url, "/repos/umzcio/zPDF/issues");
    assert.equal(sent.auth, "Bearer dev-only-not-a-real-token");
    assert.match(sent.payload.title, /^\[Bug\] Signing fails/);
    assert.deepEqual(sent.payload.labels, ["bug", "from-app"]);
    assert.ok(!sent.payload.body.includes("tester@example.edu"), "email must not be in the public issue");
    assert.ok(sent.payload.body.includes("@​octo"), "@mentions are neutralised");
    assert.ok(sent.payload.body.includes("27.0 (26A428)") && sent.payload.body.includes("AttributeError"));
    const link = sent.payload.body.match(/\((http[^)]+\/v1\/attachments\/[^)]+)\)/)[1];
    const img = await fetch(link.replace(/^https?:\/\/[^/]+/, base));
    assert.equal(img.status, 200); assert.equal(img.headers.get("content-type"), "image/png");
    const tampered = await fetch(link.replace(/^https?:\/\/[^/]+/, base).replace(/sig=../, "sig=00"));
    assert.equal(tampered.status, 404);
  });
  await test("missing title is rejected with a friendly message", async () => {
    const r = await post({ ...good, title: " ", screenshot: undefined }, "203.0.113.11");
    assert.equal(r.status, 400); assert.equal((await r.json()).error.code, "MISSING_FIELD");
  });
  await test("unknown kind is rejected", async () => {
    const r = await post({ ...good, kind: "spam", screenshot: undefined }, "203.0.113.12");
    assert.equal(r.status, 400);
  });
  await test("non-image attachment is rejected", async () => {
    const r = await post({ ...good, screenshot: { mime: "image/png", base64: btoa("not an image") } }, "203.0.113.13");
    assert.equal(r.status, 400); assert.equal((await r.json()).error.code, "INVALID_ATTACHMENT");
  });
  await test("oversized report is rejected", async () => {
    const r = await post({ ...good, description: "x".repeat(9 * 1024 * 1024) }, "203.0.113.14");
    assert.equal(r.status, 413);
  });
  await test("token without label permission still files the issue", async () => {
    rejectLabelsOnce = true;
    const r = await post({ ...good, kind: "suggestion", screenshot: undefined, email: undefined }, "203.0.113.15");
    assert.equal(r.status, 201);
    assert.equal(received.at(-1).payload.labels, undefined);
    assert.match(received.at(-1).payload.title, /^\[Suggestion\]/);
  });
  await test("burst rate limit per IP", async () => {
    const statuses = [];
    for (let i = 0; i < 5; i++) statuses.push((await post({ ...good, screenshot: undefined }, "203.0.113.99")).status);
    assert.ok(statuses.includes(429), "expected a 429 among " + statuses.join(","));
  });
} finally {
  worker.kill("SIGTERM"); mock.close();
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
