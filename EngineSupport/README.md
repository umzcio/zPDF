# Save helper build inputs

`engine/` is the unchanged spike facade (source hashes in `facade-provenance.json`),
including the macOS arm64 QPDF bundle and dependency notices. `serve.py` exposes
open, inspect_policy, fill, annotate, organize_pages, save and the app-only
edit_comments, detect_fields, and add_fields adapters over a private JSON-line pipe. EOF disposes the
per-operation session. The frozen public v0 API is unchanged.

Run `xcodegen`, then `xcodebuild -scheme zPDF -destination 'platform=macOS' test`.
The build phase prepares a pinned, checksum-verified standalone Python/PDFium
runtime under ignored `build/EngineRuntime` and bundles it into the app. The first
build downloads those two archives; later builds use the verified cache. The
running app requires neither Homebrew nor the spike checkout. Helper executables
inherit the app sandbox. Save may request access to the containing folder because
the facade stages replacement there; file-only access does not grant that right.

This packaging is macOS arm64 only. **Windows remains UNVERIFIED.** PDFium is
permissively licensed with required notices; QPDF is Apache-2.0. Notices ship in
the runtime. Preview is only an independent test reader, never an engine tool.

File → Save accepts form values, newly authored text fields/checkboxes, notes/highlights/underlines (including existing
comment text edits/deletion) and page rotation/reorder/deletion. Unsupported
mutations fail before replacing the original. Page composition runs after
form/comment edits against a serialized candidate, using IDs from its revision.
Each successful Save reloads PDFKit from the native output and starts a fresh
Undo history; failed saves preserve edits/history.

`app_engine.py` extends the app transport without changing `engine/`:

- Field detection reads vector boxes/lines on one page and excludes occupied text and existing widgets. Suggestions are reviewed before adding. Manual placement covers missed fields and scans; detection does not run OCR.
- Field creation patches a private QPDF candidate, creates editable AcroForm widgets and appearances, preserves the prior semantic inventory, and validates strict QPDF output before publication. Flate streams are recompressed to normalize malformed trailing bytes found in the IRS fixture. New values are filled before page organization.
- Combine prepares each input, then imports its pinned pages. Private source
  snapshots namespace top-level field names (`zpdf1_`, `zpdf2_`, …) so two copies
  of the same form remain independently editable. Shared widgets within each
  source retain linking; unsupported nested field-tree repair fails closed.
- Split and Extract publish native outputs with current edits. Split publishes
  a new folder only after every part passes; existing folders are rejected.
- Compress requests QPDF's lossless mode and reports actual byte differences.
  It does not downsample images or promise a smaller file.
- Existing note/highlight/underline contents and deletion use PDFium on a
  candidate. Deletion of threaded comments is unsupported. Candidate validation
  precedes publication. Annotation rectangles with reversed corners compare by
  their equivalent geometric box.

Encrypted PDFs accept a password for opening, passed over stdin without logging
or retaining it. They remain read-only; encrypted writes are not implemented.
XFA/hybrid-XFA remains blocked from editing and Save. Reading/search/navigation
remain available. Print uses the current PDFKit display copy through the macOS
print system; that output does not replace the document of record.

Current verification and remaining interactive checks are in `PROGRESS.md`.
Retained local evidence is under `build/v1-validation/`; tests generate copies
under the app container's temporary `zpdf-v1-evidence/` directory.
`scripts/test_app_engine.py` adds a cross-page comment-thread regression; run it
with a development Python containing the pinned pypdfium2 dependency. It uses
the bundled QPDF and never changes the source fixture.

The separate pinned export worker is bundled alongside Save; see EXPORTER.md
for its provenance, dependencies, format options, publication and resource limits.
It does not change the frozen editing facade API.
