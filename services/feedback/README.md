# zPDF feedback relay

Cloudflare Worker behind **Help ▸ Report a Bug…**. The app posts a report;
the Worker validates it, rate-limits by IP, stores optional screenshots and
private contact emails in KV, and files a GitHub issue on `umzcio/zPDF`. The
GitHub token exists only as a Worker secret — never in the app.

## Develop

Create `.dev.vars` (ignored by git) for local runs:

```
GITHUB_TOKEN=dev-only-not-a-real-token
ATTACHMENT_KEY=dev-only-attachment-key
```

```sh
npm install
npm run types      # generates worker-configuration.d.ts (not committed)
npm run check      # TypeScript
npm test           # wrangler dev + mock GitHub API; no network, no real token
```

## Deploy (one-time setup)

1. Create a KV namespace and put its id in `wrangler.jsonc`:
   `npx wrangler kv namespace create REPORTS`
2. Secrets:
   - `npx wrangler secret put GITHUB_TOKEN` — a fine-grained token limited to
     `umzcio/zPDF` with **Issues: Read and write** (nothing else).
   - `npx wrangler secret put ATTACHMENT_KEY` — any long random string.
3. `npx wrangler deploy`, then set `ZPDFFeedbackURL` in `zPDF/Info.plist` to
   the deployed URL.

Privacy: reports never include PDFs, file names or document text. Emails are
kept in KV, not in the issue. Screenshots are opt-in and publicly viewable via
the issue's signed link; the form warns about this.
