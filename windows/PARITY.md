# Windows parity checklist

The Windows app reaches feature parity with the Mac app phase by phase. Each
item is built on the shared engine (`EngineSupport/`) or PDFium, tested
headlessly over SSH, and UI-tested on Windows. `[x]` done and tested, `[~]`
partial (note says what's missing), `[ ]` to do, `[!]` needs the owner.

## A. Viewing
- [x] Open (picker, command line, drag-and-drop), continuous scroll, thumbnails
- [x] Zoom (in/out, fit width, actual size), anchored on the reading position
- [x] Find (Ctrl+F): matches highlighted, next/previous, match count, case option
- [x] Select and copy text (drag across text, Ctrl+A on a page, Ctrl+C)
- [x] Links: internal jumps and web links (with confirmation)
- [x] Bookmarks panel (outline), click to jump
- [x] Keyboard: Page Up/Down, Ctrl+Home/End, arrow scrolling
- [x] Go to page (Ctrl+G), page labels shown
- [x] Document properties (title, author, producer, pages, size, PDF version, security)
- [x] Recent files — in-app list and menu; Windows recent documents (taskbar jump list)
- [x] Full screen / reading mode (F11); chrome follows the system theme
- [x] Print (Windows print dialog; page range, scale to fit, annotations; forms flattened for the printer)
- [x] Passwords: open encrypted PDFs (prompt)

## B. Comments
- [x] Highlight / underline / strikethrough on selected text
- [x] Sticky notes; text boxes; freehand ink; rectangle, ellipse, line, arrow
- [x] Stamps — 14 standard, dynamic (name & date), custom text, image stamps
- [x] Comments panel: list, jump, edit text, delete, reply, status
- [x] Select / move / resize (corner handles) / recolor existing annotations
- [x] Import/export comments (FDF, XFDF); flatten

## C. Forms
- [x] Fill text, checkbox, radio, combo, list fields; calculated fields
- [x] Reset, flatten; Tab order navigation
- [x] Prepare form: add/move/edit/delete fields, properties, detect fields

## D. Pages and documents
- [x] Rotate, delete, move, drag-to-reorder
- [x] Insert blank page; insert from file; replace; duplicate
- [x] Extract pages to a new PDF; split; combine files
- [x] Crop pages; resize; page labels
- [x] Header & footer, Bates numbering, watermark options, background
- [x] Insert images into a document; Create PDF from images or blank pages

## E. Protect and redact
- [x] Password protection and permissions; remove security
- [x] Redaction: mark text/areas, search & redact patterns, apply
- [x] Sanitize / remove hidden information

## F. Sign
- [x] Fill & Sign: typed/drawn/image signature and initials, place on page
- [x] Digital IDs: create, import .pfx/.p12; sign (visible/invisible); certify
- [x] Signatures panel: validate, timestamp and LTV status

## G. Tools
- [x] OCR (Windows.Media.Ocr → engine text layer)
- [x] Reduce file size (optimize presets)
- [x] PDF/A, PDF/X-4, PDF/E conversion (PDF/A validated)
- [x] Export to Word, Excel, PowerPoint, images, HTML, text, etc. (exporter)
- [x] Compare two PDFs
- [x] Accessibility: check with fixes, autotag, alternate text, reading order (per page)
- [x] Measure (distance, perimeter, area)
- [x] Print production: preflight (4 profiles, fixes), output preview (inks, spot → process), printer marks
- [x] Batch processing (13 steps, output folder, never overwrites) and saved actions

## H. Edit content
- [x] Edit text blocks in place; add text; find & replace in content
- [x] Images: add, replace, crop; objects: move, resize (corner handles), align on the page, arrange, delete
- [x] Links: add/edit/remove; attachments; layers

## J. Found by comparing engine use with the Mac app
- [x] Bookmarks editing (add/rename/delete/move/nest), bookmarks from headings, named destinations
- [x] Document properties editor (description, custom fields, XMP, initial view, fonts, security)
- [x] Page boxes (crop/trim/bleed/art/media), scale page content, page transitions
- [x] Print layouts: booklet, n-up, poster tiling (saved as a new PDF, then opened or printed)
- [x] Split by file size, portfolios, extract images and attachments, space usage
- [x] OCR: straighten and clean scans; text-layer status; remove recognized text
- [x] Measurement snapping to vector art; measurement list and CSV export; compare comments
- [ ] Signatures: add LTV, clear signature field, view signed version, finalize (in progress)
- [ ] Forms: calculation order, tab order, duplicate field across pages, recalculate, XFA → AcroForm, barcodes (in progress)
- [ ] Document JavaScript list/remove; tags editor; mark PDF/UA (in progress)
- [ ] Articles and 3D content lists; print a selected area (low priority)

## I. App
- [x] Several documents: tabs (Ctrl+T, Ctrl+W, Ctrl+Tab; reorder) and separate windows (Ctrl+N; preference)
- [x] Undo/redo history (Redo), unsaved-change handling on exit
- [x] Preferences
- [x] Report a Bug (feedback relay), About, licenses
- [~] Installer and updates — Velopack Setup.exe and GitHub-Releases updates build; unsigned until there's a code-signing certificate [!]
- [x] File association ("Open with zPDF"), default-app prompt
- [~] Accessibility of the UI itself — named controls, pages exposed as documents with their text; keyboard shortcuts; needs a Narrator/high-contrast pass
