# Repository publication policy

Treat every Git commit as potentially public, even while GitHub visibility is private.

## Local only

Keep personal/customer PDFs, completed forms, exports, screenshots, session logs,
credentials, signing keys, test output and internal planning notes out of Git.
Use an ignored `private/` directory for local material. New top-level paths are
ignored by default. `PROGRESS.md`, `IMPLEMENTATION.md`, `SPEC.md`, `plans/`,
`animation-plans/`, `docs/`, old icon artwork, and `build/` remain local.
Never force-add these files. `.gitignore` does not protect already tracked files.

The original development history is retained only on the local
`local/pre-publication` branch. The published `main` begins with a clean snapshot.
Never push the local branch, use `git push --all`, or mirror this repository.

## Reviewed assets

Only the five named public/synthetic test PDFs are excepted from the PDF ignore
rule. Their provenance and exact SHA-256 hashes, shipping icons, and required
native helper binaries are recorded in `scripts/public-assets.json`. A changed
fixture must be reviewed again; never update a hash merely to silence a check.
Do not replace a blank government fixture with a filled personal document.
Third-party source and license notices retain their original attribution.

## Before committing or pushing

Install `gitleaks`, then run `python3 scripts/install_git_hooks.py` in every clone.
Use your GitHub noreply email as this clone's Git author/committer address.

The pre-commit hook scans the complete staged snapshot with Gitleaks and checks
allowed paths, file types, binary hashes and personal filesystem paths. The
pre-push hook checks every reachable commit, including deleted files and commit
email addresses, and blocks the local history branch. Gitleaks is required;
checks fail closed if it is unavailable. Reports redact matched secrets.

Hooks are local and must be installed in each clone; they can be bypassed.
Automated scanning cannot identify every private fact inside ordinary source or
text. Review `git diff --cached` before committing. If sensitive data is found
in Git, untracking it is insufficient: remove it from every outgoing commit;
if it was uploaded, rotate credentials and clean remote history as appropriate.

Before making GitHub public, repeat the history/asset review and check releases,
issues, pull requests and Actions artifacts separately. These are not covered by
`.gitignore`. This setup creates no release or uploaded build artifact.
