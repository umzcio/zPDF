# Windows parity checklist

The Windows app reaches feature parity with the Mac app phase by phase. Each
item is built on the shared engine (`EngineSupport/`) or PDFium, tested
headlessly over SSH, and UI-tested on Windows. `[x]` done and tested, `[~]`
partial (note says what's missing), `[ ]` to do, `[!]` needs the owner.

## A. Viewing
- [x] Open (picker, command line, drag-and-drop), continuous scroll, thumbnails
- [x] Zoom (in/out, fit width, actual size), anchored on the reading position
- [ ] Find (Ctrl+F): matches highlighted, next/previous, match count, case option
- [ ] Select and copy text (drag across text, Ctrl+A on a page, Ctrl+C)
- [ ] Links: internal jumps and web links (with confirmation)
- [ ] Bookmarks panel (outline), click to jump
- [ ] Keyboard: Page Up/Down, Home/End, Ctrl+Home/End, arrow scrolling
- [ ] Go to page (Ctrl+G), page labels shown
- [ ] Document properties (title, author, producer, pages, size, PDF version, security)
- [ ] Recent files (jump list and in-app list)
- [ ] Full screen / reading mode (F11), dark app chrome
- [ ] Print (Windows print dialog; page range, scale to fit, annotations)
- [ ] Passwords: open encrypted PDFs (prompt)

## B. Comments
- [ ] Highlight / underline / strikethrough on selected text
- [ ] Sticky notes; text boxes; freehand ink; rectangle, ellipse, line, arrow
- [ ] Stamps (standard and custom image)
- [ ] Comments panel: list, jump, edit text, delete, reply, status
- [ ] Select / move / resize / recolor existing annotations
- [ ] Import/export comments (FDF, XFDF); flatten

## C. Forms
- [ ] Fill text, checkbox, radio, combo, list fields; calculated fields
- [ ] Reset, flatten; Tab order navigation
- [ ] Prepare form: add/edit/delete fields, properties, auto-detect fields

## D. Pages and documents
- [x] Rotate, delete, move, drag-to-reorder
- [ ] Insert blank page; insert from file; replace; duplicate
- [ ] Extract pages to a new PDF; split; combine files
- [ ] Crop pages; resize; page labels
- [ ] Header & footer, Bates numbering, watermark options, background
- [ ] Create PDF from images / other files

## E. Protect and redact
- [ ] Password protection and permissions; remove security
- [ ] Redaction: mark text/areas, search & redact patterns, apply
- [ ] Sanitize / remove hidden information

## F. Sign
- [ ] Fill & Sign: typed/drawn/image signature and initials, place on page
- [ ] Digital IDs: create, import .pfx/.p12; sign (visible/invisible); certify
- [ ] Signatures panel: validate, timestamp and LTV status

## G. Tools
- [ ] OCR (Windows.Media.Ocr → engine text layer)
- [ ] Reduce file size (optimize presets)
- [ ] PDF/A, PDF/X, PDF/E conversion and validation
- [ ] Export to Word, Excel, PowerPoint, images, HTML, text, etc. (exporter)
- [ ] Compare two PDFs
- [ ] Accessibility: check, autotag, reading order, alt text
- [ ] Measure (distance, perimeter, area)
- [ ] Print production: preflight, output preview, printer marks
- [ ] Action Wizard / batch processing

## H. Edit content
- [ ] Edit text blocks in place; add text; find & replace in content
- [ ] Images: add, replace, crop; objects: move, resize, arrange, align, delete
- [ ] Links: add/edit/remove; attachments; layers

## I. App
- [ ] Tabs (several documents), window restore
- [ ] Undo/redo history (Redo), unsaved-change handling on exit
- [ ] Preferences
- [ ] Report a Bug (feedback relay), About, licenses
- [!] Installer and updates (needs a Windows code-signing certificate decision)
- [ ] File association ("Open with zPDF"), default-app prompt
- [ ] Accessibility of the UI itself (screen reader names, keyboard-only use, high contrast)
