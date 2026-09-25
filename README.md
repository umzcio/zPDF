# zPDF

A native macOS PDF editor — read, comment, fill and sign, edit, redact,
organize, convert and protect PDFs. Built with Swift, SwiftUI and PDFKit, with
a bundled PDFium/QPDF engine so edits are written as real PDF content.

> **Status: early tester builds.** Please report anything that looks wrong or
> loses work (see [Reporting bugs](#reporting-bugs)).

## Download

Get the latest `zPDF-x.y.z.dmg` from
**[Releases](https://github.com/umzcio/zPDF/releases/latest)**, open it and drag
**zPDF** to **Applications**. Builds are signed with a Developer ID and
notarized by Apple, so they open normally.

- **Requires** macOS 15 or later on an Apple silicon Mac (M1 or newer).
- **Updates:** zPDF checks automatically; you can also choose
  **zPDF ▸ Check for Updates…**. Updates are verified with zPDF's signing key
  before they install.

## Features

**Edit & redact**
- Edit existing text in place (font, size, color, alignment, reflow), add
  text boxes, images and links; move, resize, rotate, crop and arrange objects
- Find and replace in page content; crop pages; headers & footers,
  watermarks, backgrounds and Bates numbering
- Redaction that removes the underlying text, image pixels and drawings;
  search & redact with patterns (SSN, phone, email, card numbers, dates);
  remove hidden information (metadata, attachments, scripts, hidden layers)

**Comment & review**
- Highlight, underline, strikethrough, replace/insert text, notes, text
  boxes, callouts, pen and eraser, shapes, clouds, stamps (standard, dynamic,
  custom), file attachments and sound comments
- Threaded replies, review status and checkmarks; import/export FDF and XFDF;
  comment summaries, comparison and flattening

**Forms & signatures**
- Fill forms, including calculated and formatted fields; Fill & Sign on any PDF
- Prepare Form: every field type, properties, validation, calculations, tab
  order, automatic field detection (including scans)
- Signatures and initials; digital signatures (PAdES) with validation,
  certification, timestamps and long-term validation
- Password protection (AES-256) and permissions; certificate encryption;
  convert hybrid XFA forms to standard forms

**Pages & documents**
- Insert, replace, duplicate, reorder, rotate, split, extract and combine
  pages; page labels and page boxes
- Create PDFs from images, documents, web pages, the clipboard or a scanner
- OCR (searchable text for scans), optimize and reduce file size, PDF/A, PDF/X
  and PDF/E, preflight, output preview, compare two versions

**Export**
- Word, Excel, PowerPoint, HTML, Markdown, RTF, XML, EPUB and images.
  Conversions are close, not identical; each export lists what changed.

**Reading & tools**
- Bookmarks, attachments, layers, destinations, advanced search across files,
  full screen, split view, rulers and guides, measure tools, read aloud,
  accessibility checker and tagging, document properties, Action Wizard and
  batch processing, custom print layouts (booklet, n-up, poster)

## Your files and privacy

- zPDF works on your Mac. Your file is only changed when you choose **Save**,
  and every edit can be undone until then.
- Network use is limited to what you ask for: web pages you convert,
  signature timestamp servers you enable, update checks, and bug reports you
  send.

## Reporting bugs

Choose **Help ▸ Report a Bug…** (or **Report…** on any error message) — no
GitHub account needed. The form shows exactly what is sent: your description
plus app version, macOS version and chip, and the last error message. An
email address is optional and never published. A screenshot of the zPDF
window is optional. Your PDFs, file names and document text are never sent.

Reports arrive as issues in this repository.

## Build from source

Requires an Apple silicon Mac, macOS 15 or later, Xcode and XcodeGen.

```sh
brew install xcodegen gitleaks
python3 scripts/install_git_hooks.py
xcodegen generate
xcodebuild -scheme zPDF -destination 'platform=macOS' test
```

`project.yml` is the source of truth; the Xcode project is generated and
ignored. The first build downloads checksum-pinned Python, PDFium and
dependencies; later builds reuse the cache. The app runs entirely on its
bundled runtime.

Engine tests run with a development Python that has the same pinned wheels
(see [EngineSupport/transforms/README.md](EngineSupport/transforms/README.md)):

```sh
python scripts/test_transforms.py   # and the other scripts/test_*.py suites
```

## How it's built

- **App** (`zPDF/`): SwiftUI + AppKit, with PDFKit as the on-screen copy.
- **Engine** (`EngineSupport/`): a sandboxed helper bundled in the app. The
  original save facade (PDFium + QPDF) handles form values, notes and page
  order; the transform layer (`EngineSupport/transforms/`, pikepdf + PDFium)
  handles everything else — each edit is validated, applied to a private
  working copy as one Undo step, and written to your file only on Save.
- **Export** (`EngineSupport/exporter/`): a pinned copy of
  [zPDF-exporter](https://github.com/umzcio/zPDF-exporter)
  ([integration notes](EngineSupport/EXPORTER.md)).
- **Feedback relay** (`services/feedback/`): a Cloudflare Worker that turns
  in-app reports into GitHub issues; its token never ships in the app.

## Releasing

`scripts/release/release.sh <version>` runs the tests, builds a Developer ID
app, notarizes and staples the app and disk image, and writes the signed
Sparkle update feed (`appcast.xml`). Publishing — tag, GitHub release, feed
commit — is a separate step the script prints. Notarization credentials stay
in a gitignored local file.

## Contributing

Read [PRIVACY.md](PRIVACY.md) before adding files: local documents, planning
notes, screenshots, test evidence, credentials and generated output are kept
out of the repository, and only public or synthetic fixture PDFs belong here.
The git hooks enforce this.

## License

zPDF is licensed under the [Apache License 2.0](LICENSE); see [NOTICE](NOTICE).
The vendored exporter (`EngineSupport/exporter/`) is MIT-licensed.

## Third-party software

zPDF bundles PDFium (BSD-3-Clause), QPDF (Apache-2.0), pikepdf (MPL-2.0),
fontTools (MIT), cryptography (Apache-2.0/BSD), Sparkle (MIT) and the Python
runtime (PSF); their license notices are included in the app bundle. See
[EngineSupport/README.md](EngineSupport/README.md) and
[EngineSupport/exporter/THIRD_PARTY_NOTICES.md](EngineSupport/exporter/THIRD_PARTY_NOTICES.md).
