# Worker integration handoff (exporter → zPDF app)

Status: **handoff notes for the app team; nothing in the app has been changed.**
The exporter is a local, offline Python helper spoken to over JSON lines.
Everything below is what the helper does today (`local-reconstructor/0.1.0`),
measured, not planned. The authoritative contract is the tech spec
(`zPDF-Exporter-Adapter-Tech-Spec.md` §5–§6); this note is the operational
summary an integrator needs, with real outputs.

## 1. What the app can ask for

| Request | Implemented | Notes |
|---|---|---|
| `capabilities` | yes | returns versions, formats, allowed option values, unsupported options with reasons |
| `convert` → `format: "docx"` | yes | `layout_mode: "preserve"` (default) or `"reflow"`; page selection; the option flags below |
| `convert` → `format: "xlsx"` | yes (increment 10) | tables to worksheets; see §3a for options, result and fidelity limits |
| `convert` → `format: "html"` | yes (increment 11) | two modes; see §3b |
| `convert` → `format: "md"` | yes (increment 12) | GitHub Flavored Markdown; see §3c |
| `cancel` | yes | polled between pages and stages (see §4) |
| OCR, locale rules, running-header removal | **no** | `UNSUPPORTED_OPTION` with a reason; `ocr` accepts only `"off"` |

Options accepted on `convert` (all optional): `include_images`,
`include_hyperlinks`, `include_form_values`, `include_comments` (booleans,
default true); `layout_mode` (`preserve` \| `reflow`); `allow_partial`
(default false; see image-only pages in §5); `running_headers: "preserve"`;
`ocr: "off"`; `locale: null`. Unknown fields anywhere in the request are
rejected (`INVALID_REQUEST / unknown_request_field`, `UNSUPPORTED_OPTION /
unknown_option`).

Request shape (one JSON object per line on the worker's stdin):

```json
{"protocol_version": 1, "operation": "convert", "job_id": "opaque-uuid",
 "snapshot": {"path": "/private/job/snapshot.pdf", "sha256": "<hex of the snapshot bytes>"},
 "staging_directory": "/chosen-parent/.zpdf-export-uuid",
 "format": "docx", "pages": [1, 2], "options": {"layout_mode": "preserve"}}
```

Rules the worker enforces: `protocol_version` must be 1; `snapshot.sha256`
must match the file (`SOURCE_CHANGED / snapshot_hash_mismatch` otherwise —
the app owns the snapshot and its hash); `staging_directory` must exist, be a
real directory (not a symlink) and be **empty**; `pages` are 1-based, in
range (`INVALID_REQUEST / page_out_of_range` with the offending page). The
worker never receives a final destination and never writes outside the
staging directory. The CLI (`zpdf-export convert`) is the reference
coordinator: unique staging directory beside the destination, validation,
same-filesystem replace, refusal to overwrite without `--force`, Ctrl-C leaves
no output.

## 2. Progress

Events on stdout, one JSON object per line, in order:

```json
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "extract", "pages_done": 0, "pages_total": 2}
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "extract", "pages_done": 1, "pages_total": 2}
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "extract", "pages_done": 2, "pages_total": 2}
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "write",    "pages_done": 0, "pages_total": 1}
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "write",    "pages_done": 1, "pages_total": 1}
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "validate", "pages_done": 0, "pages_total": 1}
{"protocol_version": 1, "event": "progress", "job_id": "demo-1", "stage": "validate", "pages_done": 1, "pages_total": 1}
```

Stages are `extract` (per selected page; the same page may be reported twice
as it starts and ends), `write` and `validate` (each 0→1). Extraction is most
of the elapsed time on picture-heavy pages; the writer and validator are
quick. There is no overall percentage: show the stage and the page count.
Measured wall time on the trial corpus: 2–15 s per page for typeset pages,
up to ~40 s for a page with hundreds of vector paths (a 16 000-path map).

## 3. Terminal result (exactly one per job)

```json
{"protocol_version": 1, "event": "result", "job_id": "demo-1", "status": "ok",
 "backend": "local-reconstructor/0.1.0",
 "snapshot_sha256": "e5a3eb8c…", "layout_mode": "preserve",
 "artifact": {"relative_path": "document.docx", "sha256": "4f143a51…", "bytes": 106717},
 "warnings": [],
 "stats": {"pages_requested": 2, "pages_processed": 2, "paragraphs": 32, "tables": 0, "images": 1,
           "form_values": 0, "comments": 0, "warnings": 0,
           "writer": {"pages": 2, "tables": 1, "paragraphs": 32, "images": 1,
                      "fonts": {"TimesNewRomanPSMT": "Times New Roman"}, "links": 1,
                      "links_dropped_unsafe_scheme": 0, "comments": 0, "comments_unanchored": 0,
                      "layout_mode": "preserve"}},
 "report": {"versions": {"helper": "local-reconstructor/0.1.0", "python": "3.13.14", "pypdfium2": "5.13.0",
                         "pdfium": "153.0.7999.0", "python_docx": "1.2.0", "lxml": "6.1.3"},
            "pages": [1, 2], "format": "docx", "options": {"layout_mode": "preserve"},
            "font_substitution": "mapped from PDF font names (see fonts)",
            "font_mapping": {"TimesNewRomanPSMT": "Times New Roman"}}}
```

`status` is `ok`, `ok_with_warnings`, `error` or `cancelled`. The artifact is
`<staging_directory>/document.docx`, already validated (the package opens and
its parts parse); the app publishes it. `report` is safe to store: versions,
pages, options, counts and font mapping — **no document text, no paths**.

## 3a. XLSX

Request: `"format": "xlsx"`. Accepted options: `include_images`,
`include_hyperlinks`, `include_form_values`, `include_comments`,
`running_headers: "preserve"`, `ocr: "off"`, `locale: null`, `allow_partial`.
`layout_mode` is **refused** for XLSX
(`UNSUPPORTED_OPTION / option_not_applicable_to_format {option, format}`).
The result's `layout_mode` is `null`. The artifact is
`<staging_directory>/document.xlsx`, validated by reopening it and rejecting
any formula cell. `capabilities` lists the same options and the fidelity
limits under `formats.xlsx`.

Sample result (EIA Weekly Petroleum Status Report table 1, page 1):

```json
{"status": "ok_with_warnings", "layout_mode": null,
 "artifact": {"relative_path": "document.xlsx", "sha256": "d1a96676…", "bytes": 13082},
 "warnings": [
   {"code": "TABLE_BODY_RECOVERED", "page": 1, "object_id": "p1-table-1", "rows": 19, "cols": 8,
    "detail": "an unruled body under a ruled header was read by its column alignment"},
   {"code": "TABLE_BODY_RECOVERED", "page": 1, "object_id": "p1-table-2", "rows": 41, "cols": 12, "detail": "…"}],
 "stats": {"writer": {"tables": 2, "rows": 66, "cells_number": 525, "cells_text": 103,
                      "merged_cells": 27, "text_rows": 21, "links": 0}}}
```

XLSX warnings: `TABLE_JOINED` (continuations are one sheet),
`TABLE_BODY_RECOVERED`, `XLSX_CELL_OVERLAP`, `XLSX_NO_TABLES`,
`XLSX_PICTURE_OMITTED`, `XLSX_LINKS_REDUCED`.

Fidelity limits, which the app should show or link to:

- One sheet per table, and a Text sheet for everything else in reading order.
  Pictures are not carried; a placeholder row marks each, followed by the
  labels the picture keeps.
- A cell is a number only when it displays exactly as printed. Identifiers
  with leading zeros, dates, line numbers such as "(1)", and footnote-marked
  values stay text. No formulas are ever written, so printed totals are
  values.
- Unruled bodies are recovered only under a ruled header. A table with no
  ruled header at all is not detected; its text goes to the Text sheet.
- Fonts, colours, borders and shading are not reproduced. Header rows are
  bold and frozen.

Verification (Excel for Mac, `scripts/excel_reader_check.py`): IRS EIC table
(pp. 49–50), EIA table 1, Census P60 Table A-4b. Every displayed cell matched
the intended text, before and after Excel's save. Merges and numeric types
survived Excel's save, no text cell changed, there were no formulas, and the
edit persisted. Windows Excel is unverified.

## 3b. HTML

Request: `"format": "html"`, with `layout_mode`:

| `layout_mode` | UI name | What the user gets |
|---|---|---|
| `preserve` (default) | Preserve layout | fixed pages at the source size, everything at its measured position; prints one sheet per page |
| `reflow` | Responsive reading | the document in reading order as semantic HTML that reflows on any screen |

The other options are the same as for DOCX. The artifact is
`<staging_directory>/document.html`: one UTF-8 file with images inline, no
scripts and no external resources. Validation rejects a `<script>` or an
external `src`/`url()`. The result echoes `layout_mode`. `capabilities` lists
both modes, each with its fidelity limits, under `formats.html.modes`.

Sample result (Federal Register notice, page 1, Responsive reading):

```json
{"status": "ok_with_warnings", "layout_mode": "reflow",
 "artifact": {"relative_path": "document.html", "sha256": "…", "bytes": 9659},
 "warnings": [{"code": "GLYPH_INFERRED", "page": 1}, {"code": "TEXT_SIDEWAYS_RENDERED", "page": 1},
              {"code": "FORM_VALUE_UNPAIRED", "page": 1},
              {"code": "IMAGE_DOWNSAMPLED", "page": 1, "count": 1, "max_dpi": 200}],
 "stats": {"writer": {"paragraphs": 33, "headings": 8, "list_items": 2, "tables": 0, "images": 1,
                      "links": 8, "form_values": 1, "mode": "reflow"}}}
```

Fidelity limits the app should show with each mode:

- **Preserve layout**
  - Text is set in a stand-in font (Arial, Times New Roman or Courier New),
    scaled to each line's measured width.
  - Tables are drawn, not marked up. Artwork and gradients are pictures.
  - The page has a fixed width, so it scrolls or zooms on a phone.
  - A scan's OCR text is transparent and selectable over the scan.
  - Comments show on hover or focus.
- **Responsive reading**
  - Page geometry, fonts, colours, rules and shading are not reproduced.
  - Bullets are the browser's own. Numbered lists keep their start number.
  - A scan's OCR text (and any invisible text layer) is in a collapsed
    section after its page; it may contain recognition errors.
- **Both modes**
  - Pictures are downsampled to 200 dpi (`IMAGE_DOWNSAMPLED`).
  - No language is declared (`lang="und"`).
  - Internal links (to other pages) are not anchors yet.

Verification (Google Chrome for Mac 153): Preserve layout for eight
documents (26 pages) was printed and measured against the source. Page
count and size matched, and medians were 0.6–1.9 pt. Responsive reading at
390 px had no page overflow and no broken images. **Safari and Firefox:
NOT RUN.**

## 3c. Markdown

Request: `"format": "md"`. The options are as for XLSX: `layout_mode` is
refused as not applicable, and `include_images=false` omits pictures. There
are two Markdown options:

| Option | Values | Meaning |
|---|---|---|
| `markdown_images` | `"folder"` (default), `"embed"` | pictures as files beside the document, or as data URIs inside it |
| `markdown_asset_folder` | a plain folder name (letters, digits, space, `. _ ( ) -`; no path; default `document_images`) | the folder's name, which is also the link prefix |

The primary artifact is `<staging_directory>/document.md`. In folder mode
the pictures are in `<staging_directory>/<markdown_asset_folder>/`, and the
result lists them all:

```json
"artifact": {"relative_path": "document.md", "sha256": "1eed6983…", "bytes": 3614,
             "files": [{"relative_path": "Fact Sheet_images/page-001-01.png", "sha256": "4f5c9a81…", "bytes": 747}, …]}
```

(USGS fact sheet, page 1: 8 pictures listed.)

**The app must publish the folder with the document.** Pass the destination
name's stem as `markdown_asset_folder` (the CLI uses `<stem>_images`), so
the links match. Verify each listed file's hash, then move the folder next
to the saved `.md` before the `.md` itself, under the same replace rule as
the document. Never publish the `.md` without its folder: its picture links
would break. Use `embed` if the save flow can only write one file. The
worker validates UTF-8, no `<script>`, and that the picture links equal the
listed files. `capabilities.formats.md` gives `dialect: "gfm"`, both option
sets and the fidelity limits.

Every Markdown result carries `MD_FORMATTING_NOT_KEPT`, the kinds of
formatting Markdown never keeps. It also carries whichever structural losses
apply: `MD_TABLE_HEADER_FLATTENED`, `MD_TABLE_SPANS_NOT_KEPT`,
`MD_TABLE_NO_HEADER`, `MD_LIST_MARKERS_AS_DIGITS`, `MD_PICTURES_AS_DATA_URI`
and `MD_COMMENTS_AS_QUOTES`. Show them; they are the fidelity statement for
the file.

Sample result (EIC table, page 49):

```json
{"status": "ok_with_warnings", "layout_mode": null,
 "artifact": {"relative_path": "document.md", "sha256": "9fa49b90…", "bytes": 11406},
 "warnings": [{"code": "MD_FORMATTING_NOT_KEPT", "kinds": ["page_layout", "fonts_and_sizes", "colours", "underline_and_highlight", "alignment", "rules_and_shading"]},
              {"code": "MD_TABLE_HEADER_FLATTENED", "count": 3},
              {"code": "MD_TABLE_SPANS_NOT_KEPT", "count": 6}],
 "stats": {"writer": {"headings": 3, "paragraphs": 4, "list_items": 2, "tables": 3, "dialect": "gfm"}}}
```

Verification (details in `docs/readers.md`):
- **pandoc's GFM parser:** ten documents matched the written structure.
- **Word coverage audit** (`scripts/coverage_audit.py`): every missing
  source word located, classified and checked against the pictures' alt
  text. In the ten reference documents every missing word is a label or
  stamp that its picture keeps and describes in alt text; none is
  unexplained (`docs/readers.md`). FAA PHAK ch. 3, added in increment 15,
  has one unexplained word, "Struts" on p. 4 (backlog).
- **GitHub's engine (cmark-gfm), run locally:** every picture link resolved
  to a readable file, and tables, task items and `<details>` came out as
  elements. github.com itself was not used, because that would upload the
  document.
- **VS Code's Markdown preview:** the USGS fact sheet (pictures from the
  folder), EIA's tables and the 1920 scan rendered correctly.
- **Typora:** it rendered the fact sheet's pictures behind its
  licence-expiry dialog. Its trial had expired, so it was not usable
  further, and it shows the `<!-- page N -->` markers as visible text.
- **Obsidian:** NOT RUN. It opens files only inside a registered vault, and
  registering one changes the user's Obsidian settings.

## 4. Cancellation

Send `{"protocol_version": 1, "operation": "cancel", "job_id": "…"}` on the
same stdin at any time. The worker polls between pages during `extract` and
between stages; the result is `{"event": "result", "status": "cancelled"}`
and the staging directory is left empty (the `.part` file is removed). A
cancel for a job that is not running is answered with
`{"event": "cancel_ack", "job_id": "…", "active": false}`. **Closing the
worker's stdin also cancels** the running job. Cancellation latency is
bounded by one page's extraction (seconds on heavy pages); it is not 250 ms
and the app should not promise that.

## 5. Warnings the app will see (and what to say)

Every non-obvious decision is a warning with a stable `code`, a `page` and
often a count or `detail`; nothing is substituted silently. The full catalogue
is in the spec (§6.1). The ones users will meet:

| Code | Meaning for the user |
|---|---|
| `LAYOUT_PAGE_ROTATED` | a landscape/rotated page was rebuilt turned; fine in Word, breaks in Pages (see `docs/readers.md`) |
| `LAYOUT_RULES_DROPPED`, `LAYOUT_FILLS_AS_BACKDROP` | decorative lines/colour handled as pictures or dropped; text is complete |
| `VECTOR_ARTWORK_RENDERED`, `VECTOR_ARTWORK_BACKDROP` | drawings/diagrams/gradients are pictures, not editable shapes |
| `VECTOR_ARTWORK_OVERLAPS_TEXT` | a drawing over body text was **not** reproduced; the text is |
| `TEXT_INVISIBLE_KEPT_HIDDEN` | a scan's OCR layer is hidden text (searchable, not shown) |
| `IMAGE_ONLY_PAGE` | a page with no text at all is placed as its picture |
| `IMAGE_DOWNSAMPLED` | pictures on this page were embedded below their source resolution (`max_dpi`, `count`); a quality loss the user should know about |
| `TEXT_SIDEWAYS_RENDERED` | sideways margin text (print stamps) is a picture |
| `PICTURE_LABELS_KEPT` | a map's or diagram picture's labels stay in the picture; they are its alt text (`absorbed_text`), not editable text |
| `GLYPH_INFERRED`, `GLYPH_RECOVERED`, `MISSING_UNICODE_MAP` | characters the PDF did not name; the last keeps a visible U+FFFD |
| `TABLE_SPAN_IRREGULAR`, `FORM_VALUE_UNPAIRED` | a table cell layout or a form value could not be placed with certainty |
| `LINK_DROPPED_UNSAFE_SCHEME` | a non-http/mailto link target stays plain text |

## 6. Failures (`status: "error"`, `error.code`)

Measured from the worker on the trial fixtures:

| Situation | Result |
|---|---|
| snapshot hash mismatch | `SOURCE_CHANGED / snapshot_hash_mismatch` |
| `format: "html"` or `"md"` | `UNSUPPORTED_FORMAT / not_implemented {format}` |
| `layout_mode` with `format: "xlsx"` | `UNSUPPORTED_OPTION / option_not_applicable_to_format {option, format}` |
| page out of range | `INVALID_REQUEST / page_out_of_range {page}` |
| `ocr: "on"` | `UNSUPPORTED_OPTION / ocr_unavailable {option, value}` |
| hybrid XFA form (IRS 1040, W-4, VA 21-526EZ) | `POLICY_BLOCKED / xfa_export_blocked {reason}` — **kept blocked by decision (2026-09-21)** |
| every selected page image-only (scan without OCR) | `OCR_REQUIRED / image_only_page {page}`; with `allow_partial: true` → `ok_with_warnings`, pages placed as pictures |
| encrypted source | `POLICY_BLOCKED` (engine policy; no password parameter exists) |
| `protocol_version: 2` | `PROTOCOL_MISMATCH / unsupported_protocol_version {supported: 1}` |
| staging directory not empty / missing | `INVALID_REQUEST / staging_directory_not_empty` (or `_invalid`) |
| unexpected exception | `WORKER_FAILED / unexpected_exception {exception}`; the type name only, logged to stderr as `WORKER_FAILED <Type>` |

Error objects carry `code`, `message_key`, optional `args` and `page`; the
app localises copy from `message_key`. Routine stderr is empty; the worker
never prints document text or paths.

### Quality the app must not overstate

- Pictures are downsampled to at most 200 dpi for their placed size
  (`IMAGE_DOWNSAMPLED` per page). High-resolution scans lose detail. The
  threshold follows one observed Word for Mac export failure on a 61 MB
  document; it is not a documented Word limit and no size limit was measured.
- Labels drawn over a map or diagram (`PICTURE_LABELS_KEPT`, and
  `VECTOR_ARTWORK_RENDERED` with `absorbed_text`) are part of the picture,
  not editable text. Every format carries them as the picture's
  description (Word alt text, HTML/Markdown `alt`, the XLSX placeholder
  row), so they stay searchable by assistive technology but cannot be
  edited in place.
- Output is a layout-preserving reconstruction verified in Word for Mac, not a
  1:1 conversion. Known visual defects stay on the backlog (PROGRESS.md,
  increment 9 "Remaining degradation").

## 7. Dependencies and packaging

- Python 3.13 (developed on 3.13.14), `pypdfium2 5.13.0` (PDFium
  153.0.7999.0), `python-docx 1.2.0`, `lxml 6.1.3`, `openpyxl 3.1.5` (MIT;
  depends on `et-xmlfile 2.0.0`, MIT) for XLSX, Pillow 12.3.0 (text width
  measurement and rendering). All permissive licences; no network, no cloud,
  no AGPL.
- Fonts: the writer names Word's stand-in families (Arial, Times New Roman,
  Courier New) and measures line widths with the TrueType files installed on
  the machine (`/Applications/Microsoft Word.app/Contents/Resources/DFonts`,
  then the system fonts). Without them widths fall back to an average-width
  estimate and lines may wrap in Word.
- The worker is a plain module (`python -m zpdf_export.worker`); the app
  would bundle the interpreter and packages. Resource limits (input bytes,
  pages, pixels, time) are **not** enforced by the helper; the coordinator
  must set them (spec §6.1).
- Windows: unverified. Word for Windows has not been used to open any output.

## 8. Sample outputs

- Word-verified DOCX and their measurements: `results/trial-summary.md`
  (18-document trial, increment 8) and `results/trial-fresh.md` (11 new
  documents, increment 9), with per-document `results/docx/*.report.json`
  (no text) and `results/word/*.check.json` (Word open/edit/save/reopen).
- Excel-verified XLSX: `results/xlsx/{eic,eia,census}.xlsx` with
  `results/excel/*.excel-check.json` (displayed-text comparison, merges,
  types, edit/save/reopen) and Excel's own PDF export `results/excel/*.excel.pdf`.
  (`results/` is local evidence, not committed; regenerate with the commands in PROGRESS.md.)
- Chrome-verified HTML: `results/html/*.{preserve,reflow}.html`, Chrome's prints
  and comparisons `results/browser/*.chrome.pdf`, `*.chrome-compare.json`, and
  screenshots at 390 and 1280 px.
- Reader compatibility: `docs/readers.md` (Word vs Apple Pages, measured).
- Reproduce a session: `printf … | python -m zpdf_export.worker` with stdin
  kept open until the result (closing it cancels), or use the CLI:
  `zpdf-export convert in.pdf out.docx --pages 1-3 --report r.json --json`.

## 9. What the app should not do yet

- Do not claim Safari support for HTML: only Chrome was verified.
- Do not infer support from the helper's presence; read `capabilities`.
- Do not present the output as reader-neutral: it is verified in Word for Mac
  only (`docs/readers.md` lists what Pages breaks).
- Do not unlock encrypted or XFA sources through the converter.
