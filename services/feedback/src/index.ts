/**
 * zPDF feedback relay: the app posts a bug report or suggestion; this Worker
 * validates it, rate-limits by IP and files a GitHub issue with a token that
 * never leaves Cloudflare. Reporter contact details are stored privately in
 * KV and never written to the (public) issue.
 */

const MAX_BODY_BYTES = 8 * 1024 * 1024; // screenshot (base64) + text
const MAX_ATTACHMENT_BYTES = 5 * 1024 * 1024;
const ATTACHMENT_TTL_SECONDS = 180 * 24 * 60 * 60;
const LIMITS = { title: 120, description: 8000, steps: 4000, expected: 2000, email: 254, field: 200, lastError: 600 };

type ReportKind = "bug" | "suggestion";

interface Diagnostics {
  appVersion: string;
  build: string;
  macOS: string;
  chip: string;
  locale?: string;
  lastError?: string;
}

interface Report {
  kind: ReportKind;
  title: string;
  description: string;
  steps?: string;
  expected?: string;
  email?: string;
  diagnostics?: Diagnostics;
  screenshot?: { mime: "image/png" | "image/jpeg"; base64: string };
}

class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && url.pathname === "/v1/reports") {
        return await submit(request, env, ctx);
      }
      if (request.method === "GET" && url.pathname.startsWith("/v1/attachments/")) {
        return await attachment(url, env);
      }
      if (request.method === "GET" && url.pathname === "/health") {
        return json({ ok: true });
      }
      return json({ ok: false, error: { code: "NOT_FOUND", message: "Not found." } }, 404);
    } catch (error) {
      if (error instanceof HttpError) {
        return json({ ok: false, error: { code: error.code, message: error.message } }, error.status);
      }
      console.error(JSON.stringify({ event: "unhandled", message: String(error) }));
      return json({ ok: false, error: { code: "RELAY_FAILED", message: "The report could not be sent. Please try again later." } }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function submit(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (!(request.headers.get("content-type") ?? "").startsWith("application/json")) {
    throw new HttpError(415, "UNSUPPORTED_MEDIA_TYPE", "Send the report as JSON.");
  }
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const { success } = await env.BURST_LIMITER.limit({ key: ip });
  if (!success) throw new HttpError(429, "RATE_LIMITED", "Too many reports in a short time. Please wait a minute.");
  await enforceDailyCap(env, ip);

  const report = validate(await readJson(request));
  const id = crypto.randomUUID();

  let screenshotLink: string | undefined;
  if (report.screenshot) {
    const bytes = decodeBase64(report.screenshot.base64);
    if (bytes.byteLength > MAX_ATTACHMENT_BYTES) throw new HttpError(413, "ATTACHMENT_TOO_LARGE", "The screenshot is larger than 5 MB.");
    if (!looksLikeImage(bytes, report.screenshot.mime)) throw new HttpError(400, "INVALID_ATTACHMENT", "The screenshot isn't a PNG or JPEG image.");
    await env.REPORTS.put(`attachment:${id}`, bytes, {
      expirationTtl: ATTACHMENT_TTL_SECONDS,
      metadata: { mime: report.screenshot.mime },
    });
    const origin = new URL(request.url).origin;
    screenshotLink = `${origin}/v1/attachments/${id}?sig=${await sign(env, id)}`;
  }
  if (report.email) {
    await env.REPORTS.put(`contact:${id}`, JSON.stringify({ email: report.email, at: new Date().toISOString() }));
  }

  const issue = await createIssue(env, report, id, screenshotLink);
  console.log(JSON.stringify({ event: "report_filed", id, issue: issue.number, kind: report.kind }));
  return json({ ok: true, id, issue: { number: issue.number, url: issue.html_url } }, 201);
}

async function readJson(request: Request): Promise<unknown> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, "TOO_LARGE", "The report is too large.");
  if (!request.body) throw new HttpError(400, "EMPTY", "The report is empty.");
  // Read with a hard cap rather than trusting Content-Length.
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new HttpError(413, "TOO_LARGE", "The report is too large.");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  try {
    return JSON.parse(new TextDecoder().decode(body));
  } catch {
    throw new HttpError(400, "INVALID_JSON", "The report isn't valid JSON.");
  }
}

function text(value: unknown, name: string, max: number, required = false): string | undefined {
  if (value === undefined || value === null || value === "") {
    if (required) throw new HttpError(400, "MISSING_FIELD", `Please fill in ${name}.`);
    return undefined;
  }
  if (typeof value !== "string") throw new HttpError(400, "INVALID_FIELD", `${name} must be text.`);
  const trimmed = value.trim();
  if (required && !trimmed) throw new HttpError(400, "MISSING_FIELD", `Please fill in ${name}.`);
  if (trimmed.length > max) throw new HttpError(400, "FIELD_TOO_LONG", `${name} is too long (limit ${max} characters).`);
  return trimmed || undefined;
}

function validate(input: unknown): Report {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new HttpError(400, "INVALID_REPORT", "The report is malformed.");
  }
  const raw = input as Record<string, unknown>;
  const kind = raw.kind;
  if (kind !== "bug" && kind !== "suggestion") throw new HttpError(400, "INVALID_KIND", "Choose Bug or Suggestion.");
  const email = text(raw.email, "Email", LIMITS.email);
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new HttpError(400, "INVALID_EMAIL", "That email address doesn't look right.");
  let diagnostics: Diagnostics | undefined;
  if (raw.diagnostics !== undefined) {
    if (typeof raw.diagnostics !== "object" || raw.diagnostics === null) throw new HttpError(400, "INVALID_DIAGNOSTICS", "Diagnostics are malformed.");
    const d = raw.diagnostics as Record<string, unknown>;
    diagnostics = {
      appVersion: text(d.appVersion, "appVersion", LIMITS.field, true)!,
      build: text(d.build, "build", LIMITS.field, true)!,
      macOS: text(d.macOS, "macOS", LIMITS.field, true)!,
      chip: text(d.chip, "chip", LIMITS.field, true)!,
      locale: text(d.locale, "locale", LIMITS.field),
      lastError: text(d.lastError, "lastError", LIMITS.lastError),
    };
  }
  let screenshot: Report["screenshot"];
  if (raw.screenshot !== undefined && raw.screenshot !== null) {
    const s = raw.screenshot as Record<string, unknown>;
    if ((s.mime !== "image/png" && s.mime !== "image/jpeg") || typeof s.base64 !== "string") {
      throw new HttpError(400, "INVALID_ATTACHMENT", "Attach a PNG or JPEG screenshot.");
    }
    screenshot = { mime: s.mime, base64: s.base64 };
  }
  return {
    kind,
    title: text(raw.title, "a title", LIMITS.title, true)!,
    description: text(raw.description, "what happened", LIMITS.description, true)!,
    steps: text(raw.steps, "Steps", LIMITS.steps),
    expected: text(raw.expected, "Expected", LIMITS.expected),
    email,
    diagnostics,
    screenshot,
  };
}

async function enforceDailyCap(env: Env, ip: string): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const key = `rate:${await sha256(ip)}:${day}`;
  const count = Number((await env.REPORTS.get(key)) ?? "0");
  if (count >= Number(env.DAILY_LIMIT_PER_IP)) {
    throw new HttpError(429, "DAILY_LIMIT", "You've sent the maximum number of reports for today. Thank you!");
  }
  // Approximate by design (KV is eventually consistent); the burst limiter is strict.
  await env.REPORTS.put(key, String(count + 1), { expirationTtl: 2 * 24 * 60 * 60 });
}

/** Neutralise @mentions and issue references so reports can't ping people or link-spam. */
function inert(value: string): string {
  return value.replace(/@/g, "@​").replace(/<!--/g, "&lt;!--");
}

function fenced(value: string): string {
  const fence = value.includes("```") ? "~~~~" : "```";
  return `${fence}\n${value}\n${fence}`;
}

async function createIssue(env: Env, report: Report, id: string, screenshot?: string): Promise<{ number: number; html_url: string }> {
  const d = report.diagnostics;
  const sections = [
    `### What happened\n\n${inert(report.description)}`,
    report.steps ? `### Steps to reproduce\n\n${inert(report.steps)}` : "",
    report.expected ? `### Expected\n\n${inert(report.expected)}` : "",
    screenshot ? `### Screenshot\n\n![Screenshot](${screenshot})` : "",
    d
      ? `### Diagnostics\n\n| | |\n|---|---|\n| zPDF | ${inert(d.appVersion)} (${inert(d.build)}) |\n| macOS | ${inert(d.macOS)} |\n| Chip | ${inert(d.chip)} |` +
        (d.locale ? `\n| Locale | ${inert(d.locale)} |` : "") +
        (d.lastError ? `\n\n**Last engine error**\n\n${fenced(d.lastError)}` : "")
      : "",
    `<sub>Sent from zPDF · report ${id}${report.email ? " · reporter left private contact details" : ""}</sub>`,
  ].filter(Boolean);
  const payload = {
    title: `${report.kind === "bug" ? "[Bug]" : "[Suggestion]"} ${report.title}`,
    body: sections.join("\n\n"),
    labels: [report.kind === "bug" ? "bug" : "enhancement", "from-app"],
  };
  const endpoint = `${env.GITHUB_API}/repos/${env.GITHUB_REPO}/issues`;
  const headers = {
    authorization: `Bearer ${env.GITHUB_TOKEN}`,
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "zpdf-feedback-relay",
    "content-type": "application/json",
  };
  let response = await fetch(endpoint, { method: "POST", headers, body: JSON.stringify(payload) });
  if (response.status === 422 || response.status === 403) {
    // A token without label permission: file the issue without labels.
    const { labels: _labels, ...plain } = payload;
    response = await fetch(endpoint, { method: "POST", headers, body: JSON.stringify(plain) });
  }
  if (!response.ok) {
    console.error(JSON.stringify({ event: "github_error", status: response.status, id }));
    throw new HttpError(502, "GITHUB_UNAVAILABLE", "The report couldn't be filed right now. Please try again later.");
  }
  return (await response.json()) as { number: number; html_url: string };
}

async function attachment(url: URL, env: Env): Promise<Response> {
  const id = url.pathname.slice("/v1/attachments/".length);
  const sig = url.searchParams.get("sig") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(id) || !(await verify(env, id, sig))) {
    return json({ ok: false, error: { code: "NOT_FOUND", message: "Not found." } }, 404);
  }
  const { value, metadata } = await env.REPORTS.getWithMetadata<{ mime: string }>(`attachment:${id}`, "arrayBuffer");
  if (!value) return json({ ok: false, error: { code: "NOT_FOUND", message: "Not found." } }, 404);
  return new Response(value, {
    headers: {
      "content-type": metadata?.mime === "image/jpeg" ? "image/jpeg" : "image/png",
      "cache-control": "private, max-age=3600",
      "content-security-policy": "default-src 'none'",
      "x-content-type-options": "nosniff",
    },
  });
}

async function hmac(env: Env, value: string): Promise<ArrayBuffer> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ATTACHMENT_KEY),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
}

async function sign(env: Env, id: string): Promise<string> {
  return hex(await hmac(env, id));
}

async function verify(env: Env, id: string, sig: string): Promise<boolean> {
  if (!/^[0-9a-f]{64}$/.test(sig)) return false;
  const expected = new Uint8Array(await hmac(env, id));
  const given = new Uint8Array(sig.match(/../g)!.map((h) => parseInt(h, 16)));
  return expected.byteLength === given.byteLength && crypto.subtle.timingSafeEqual(expected, given);
}

async function sha256(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).slice(0, 32);
}

function hex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function decodeBase64(value: string): Uint8Array {
  try {
    return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
  } catch {
    throw new HttpError(400, "INVALID_ATTACHMENT", "The screenshot couldn't be read.");
  }
}

function looksLikeImage(bytes: Uint8Array, mime: string): boolean {
  if (mime === "image/png") return bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
