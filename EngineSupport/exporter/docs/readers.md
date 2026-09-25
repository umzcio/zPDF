# Reader compatibility

## EPUB 3: epubcheck (verified); Apple Books (checked, partly)

- **epubcheck 4.2.6:** 0 fatals, 0 errors, 0 warnings, 0 infos on 12 books
  (2026-09-24). It is the last release that runs on this Mac's Java 8 and
  checks the EPUB 3.2 rules; it is a verification tool only.
  - Downloaded to `results/tools/`.
  - SHA-256 of `epubcheck-4.2.6.zip`:
    `3f73c1265cc92e3b53ffda6cd5bbeb58505b2b0c43411c26e74d8df1b193b2c0`.
- **Apple Books** (the user approved importing the test books). The W-9
  instructions, the USGS fact sheet and EIA table 1 were opened, and only
  Books' own window was captured.
  - W-9 instructions: Books showed the bookmarks as the table of contents,
    nested as in the PDF, and the IRS logo picture. It offers "Print Edition
    Page Numbers", so the page list was read; whether it shows the source
    page numbers was not confirmed.
  - USGS fact sheet: headings, bold, bullets and the pictures rendered.
  - EIA table 1: the table has its spans ("Week Ago", "Year Ago"). Wider
    than the column, it scrolls sideways.
  - Found and fixed: the USGS book was titled "FactSheet_3col v 4.1", its PDF
    metadata. Titles that read as file or template names now give way to the
    first page's largest text, then the first heading.
  - Shared reading-order defects seen in Books (backlog): a paragraph that
    continues into the next column stays split, and line-break hyphens stay
    as "under- standing".
  - **Not re-checked in Books:** paging and closing the book were done with
    scripted keystrokes, which went to the user's frontmost window and closed
    their windows. Keyboard automation is removed from every check. The three
    test books were left in the Books library for the user to delete. Any
    further Books check needs the user's go-ahead and hands off the machine.

## XML: the shipped XSD (lxml) and xmllint (verified); checked against PDFium

`scripts/xml_check.py`, 11 documents (2026-09-24). Each file is validated
with xmllint (libxml 2.9.13, independent of the worker's own lxml check)
and read with Python's standard-library parser. The source's displayed
words are compared with the `<word>` elements, and each word's box is read
back from the PDF with PDFium. Order numbers, ids, image data and widget
references are also checked.

| Document | xmllint | Words | Word coverage | Boxes hold their word | Widgets referenced once | Size |
|---|---|---|---|---|---|---|
| FOMC | valid | 776 | 100 % | 100 % | — | 0.2 MB |
| Federal Register | valid | 3,581 | 99.95 % | 100 % | 1 / 1 | 0.7 MB |
| USGS FS 2019-3026 | valid | 1,933 | 100 % | 100 % | — | 12.7 MB |
| EIC pp. 49–50 | valid | 2,862 | 100 % | 100 % | — | 0.9 MB |
| I-9 | valid | 2,968 | 99.96 % | 100 % | 91 / 91 | 0.6 MB |
| EIA table 1 | valid | 1,343 | 99.66 % | 100 % | — | 0.3 MB |
| Census A-4b | valid | 1,010 | 100 % | 100 % | — | 0.3 MB |
| NWS Owlie | valid | 832 | 100 % | 100 % | — | 4.5 MB |
| WH-380-E | valid | 2,329 | 100 % | 100 % | 77 / 77 | 0.4 MB |
| FRB Bulletin 1920 scan | valid | 1,288 | 100 % | 99.5 %¹ | — | 2.1 MB |
| FAA PHAK ch. 3 | valid | 1,740 | 99.88 % | 100 % | — | 6.1 MB |

¹ The scan's OCR layer brings its own glyph boxes.

**Remaining missing words**, each explained:
- **I-9 "tates" and FR "RULESER02JA24", "telephone":**
  - "tates" is PDFium's own text split, "S tates".
  - "RULESER02JA24" is PDFium joining a stamp kept in a picture with the
    next text.
  - "telephone" is set as two touching pieces in separate blocks.
- **EIA "00" ×4:** PDFium's text order runs a "0" cell into the next "0.0"
  cell ("00.0"). The XML keeps them apart.
- **FAA "Struts"** (backlog) and **"CLLift":** PDFium joins two diagram
  labels that are kept in a picture.

**Found and fixed while checking:**
- A picture's base64 exceeded libxml2's 10 MB text-node limit, so FAA's
  file did not parse. Pictures are now capped at 200 dpi, recompressed as
  JPEG if still too big, or described without pixels.
- Words were missing where text came without a glyph list, which cost
  WH-380 29 %:
  - check-box sentences;
  - recovered table bodies, and a wrapped row label whose box and glyphs
    covered only its last line (fixed in `stream_tables.py`);
  - header cells widened to their rule;
  - field labels, now `<field><line>`.
- Table cells had no word breaks at tight spaces ("(ifapplicable)").
- A drop cap was a separate word.
- A joined paragraph's box covered only its first line.

## RTF: Microsoft Word for Mac and TextEdit (verified)

`scripts/rtf_batch.sh`, 11 documents (2026-09-24). Each RTF went through
Word for Mac 16.113.2 (`word_reader_check.py`: open, PDF export, edit, save,
reopen) and TextEdit (`textedit_reader_check.py`: open, text, window
capture, edit, save, reopen).

| Document | Tables written / Word | Pictures written / Word | Links written / working in Word's PDF | Word coverage | TextEdit coverage |
|---|---|---|---|---|---|
| FOMC | 0 / 0 | 1 / 1 | 3 / 3 | 100 % | 100 % |
| Federal Register | 1 / 1 | 7 / 7 | 26 / 26 | 96.5 %¹ | 99.97 % |
| USGS FS 2019-3026 | 0 / 0 | 19 / 19 | 2 / 2 | 100 % | 100 % |
| EIC pp. 49–50 | 5 / 5 | 0 / 0 | 0 / 0 | 100 % | 100 % |
| I-9 | 6 / 6 | 4 / 4 | 4 / 4 | 99.96 % | 99.96 % |
| EIA table 1 | 2 / 2 | 0 / 0 | 0 / 0 | 97.9 %² | 97.9 %² |
| Census A-4b | 1 / 1 | 0 / 0 | 1 / 1 | 98.7 %² | 98.7 %² |
| NWS Owlie | 2 / 2 | 11 / 11 | 3 / 3 | 100 % | 100 % |
| WH-380-E | 0 / 0 | 1 / 1 | 2 / 2 | 100 % | 100 % |
| FRB Bulletin 1920 scan | 0 / 0 | 3 / 3 | 0 / 0 | 3 %¹ | 100 %³ |
| FAA PHAK ch. 3 | 5 / 5 | 27 / 27 | 0 / 0 | 99.9 % | 99.9 % |

Every file opened in both readers, and every edit survived save and reopen.

¹ The invisible text layer is hidden text, hidden in Word as intended.
² Footnote marks are written as superscript characters ("Gasoline³"); this
count does not normalise them.
³ TextEdit ignores RTF hidden text, so the OCR layer shows as ordinary text.

- **TextEdit shows no pictures from any `.rtf`.** Word's own RTF of the
  same document, with 38 `\pict` groups, also shows none. TextEdit reads
  pictures only from RTFD. Its saved copy therefore drops them (18 MB → 18
  KB).
- **Found and fixed:** on I-9's turned page, table columns were measured
  along the displayed x axis and collapsed to slivers. Columns now follow
  the axis along which cells start in column order.
- **Visual review of Word's PDF export:**
  - EIC's tables and I-9's lists table (three lists side by side) read as
    the source.
  - USGS's fact sheet reads in column order with its pictures.
  - The EIC example box's narrow columns wrap some numbers.
- **Not checked:** Pages, LibreOffice, WordPad and Windows Word (NOT RUN).

## PPTX: Microsoft PowerPoint for Mac (verified); Keynote 14.2 and Keynote Creator Studio 15.1.1 (checked separately)

`scripts/pptx_batch.sh` converts 15 decks and runs
`scripts/powerpoint_reader_check.py` on each (2026-09-24). The decks are 11
documents in `editable` mode, plus USGS, Owlie, FAA and EIC in
`page_image`. PowerPoint 16.113.2 opens each deck and reports its slide
count. It exports a PDF, inserts a marker into the first text box, saves a
copy, reopens it and finds the marker. The PDF is measured against the
source with `layout_compare`.

| Document | Slides | Median displacement per page (pt) | Lines within 12 pt | Ink-missing cells |
|---|---|---|---|---|
| FOMC statement | 4 | 0.5, 0.5, 0.7, 0.6 | 100 % | 0 |
| Federal Register | 4 | 0.9, 0.8, 1.0, 0.9 | 100 % | 0 |
| USGS FS 2019-3026 | 4 | 0.9, 0.8, 1.0, 0.8 | 100 % | 0 |
| EIC pp. 49–50 | 2 | 1.0, 1.2 | 99.5–100 % | 0 |
| I-9 (6 pp.) | 6 | —¹, 0.6, 0.7, 0.5, 0.5, 0.5 | 100 % (pp. 2–6) | 32¹, 3, 0, 0, 0, 0 |
| EIA table 1 | 1 | 0.7 | 100 % | 0 |
| Census A-4b | 1 | 1.2 | 100 % | 0 |
| NWS Owlie | 3 | 1.9, 1.1, 0.7 | 100 %, 67.6 %², 100 % | 0 |
| WH-380-E | 4 | 1.0, 1.0, 0.9, 1.1 | 100 % | 0 |
| FRB Bulletin 1920 scan | 3 | 0.9, 0.5, 0.4 | 100 % | 0 |
| FAA PHAK ch. 3 | 4 | 1.1, 0.9, 0.7, 0.7 | 100 % | 0 |
| `page_image`: USGS, Owlie, FAA, EIC | 13 | the same as editable | the same | 0–1 |

¹ I-9 p. 1 is a landscape page, displayed rotated, scaled into the portrait
slide (`PPTX_PAGE_SCALED`). Positions cannot be compared, so the page was
reviewed visually: it is turned and scaled as a whole. ² The stand-in font's
bullet width, as in DOCX and HTML.

- **Every deck** opened with the right slide count. The edit survived save
  and reopen, and I-9's three comments survived as speaker notes.
- **Visual review** (contact sheets): FOMC, USGS, EIC, FAA and Owlie read as
  their sources. FAA's light display title is set in Arial, so it is wider
  and heavier than the source's.
- **Found and fixed during the check:**
  - list markers were placed a line below their text (now one paragraph
    with tab stops);
  - a double-spaced paragraph was one box per line (reading-order joins);
  - near-equal page sizes were scaled (now padded).

**Keynote** (`scripts/keynote_reader_check.py`, a second reader). Two
Keynotes are installed, and both answer to the AppleScript name "Keynote",
so the check addresses one by bundle ID throughout. Otherwise the file opens
in the other app.
- **Keynote Creator Studio 15.1.1** (`com.apple.Keynote`) and **Keynote 14.2**
  (`com.apple.iWork.Keynote`) gave identical results. All 15 decks opened.
  The edit was exported back to PPTX and found on reopening, and the notes
  survived.
- **Measurements:** medians 0.6–1.7 pt per page, every unscaled page 99.8–100 %
  within 12 pt, except Owlie p. 2 as above.
- **Found and fixed:**
  - Keynote refused any deck with speaker notes, because python-pptx does not
    list the notes master in `presentation.xml`. It was isolated with a
    one-slide deck, and the writer now adds the list.
  - Keynote truncates exact line spacing and space-before to whole points
    (13.8 becomes 13, 0.95 becomes 0; measured). The writer now uses whole
    points with carried rounding, which improved PowerPoint too.

**Not checked:** PowerPoint for Windows, PowerPoint for the web, Google
Slides and LibreOffice Impress (NOT RUN).

## XLSX: Microsoft Excel for Mac (verified); others not checked

`scripts/excel_reader_check.py` on the EIC, EIA and Census workbooks
(2026-09-22): every displayed cell matched the intended text (2,483, 694 and
919 cells), before and after Excel's save. Merges, numeric cells and text
cells were unchanged after Excel saved the file, there were no formulas, and
an edit plus a marker row persisted. The first Census run found 336 cells
shown as `####` (columns too narrow); fixed before these results. Numbers,
Google Sheets, LibreOffice and Windows Excel are **not checked**.

## HTML: Google Chrome for Mac (verified); Safari NOT RUN

Chrome 153, 2026-09-23. Preserve layout was printed by headless Chrome and
measured against the source. Eight documents (26 pages) matched page count
and page size, with medians of 0.6–1.9 pt. That includes the rotated I-9
page after the `contain: strict` fix, and no ink is missing. Responsive
reading at 390 px had no horizontal page overflow, wide tables scrolled
inside their box, no image was broken, and no page contains a script.
**Safari: NOT RUN.** safaridriver needs Remote Automation enabled, which
requires an administrator password. Firefox is not installed and not
checked.

## Markdown: pandoc, GitHub's engine and VS Code (verified); Typora partial; Obsidian NOT RUN

- **pandoc 3 GFM parser** (`scripts/markdown_check.py`): ten documents
  parsed with exactly the structure the writer reported.
- **Word coverage** (`scripts/coverage_audit.py`, also run by
  `markdown_check.py`): every source word occurrence that the Markdown
  lacks is located on its page and classified as *picture*, *sideways* or
  *unexplained*. Both sides are NFKC-normalized, so "Gasoline³" counts as
  PDFium's "Gasoline3". The earlier 97.6–100% figure came from comparing
  PDFium's text order with the output: footnote marks, words split where
  PDFium interleaves table cells, and escaped Markdown. It also hid four
  real defects, which are now fixed (increment 14). A missing word is also
  checked against the pictures' alt text (`in_alt_text`). Result after
  increment 15:

  | Document | Source words | In the Markdown | Missing, and why |
  |---|---|---|---|
  | FOMC statement | 735 | 735 | none |
  | Federal Register (4 pp.) | 3,706 | 3,680 | 26 words of the sideways print stamp "khammond on DSKJM1Z7X2PROD with RULES" (4 pages), all in the stamp pictures' alt text |
  | USGS FS 2019-3026 | 1,927 | 1,884 | 43 labels of the page-1 and page-3 maps and the caldera diagram, all in their pictures' alt text |
  | EIC pp. 49–50 | 2,893 | 2,893 | none |
  | I-9 (6 pp.) | 2,830 | 2,830 | none |
  | EIA table 1 | 1,183 | 1,183 | none |
  | Census A-4b | 1,208 | 1,208 | none |
  | NWS Owlie | 816 | 816 | none |
  | WH-380-E | 1,996 | 1,996 | none |
  | FRB Bulletin 1920 scan | 1,287 | 1,287 | none |
  | FAA PHAK ch. 3 (4 pp.; added in increment 15) | 1,720 | 1,710 | 9 diagram labels, in alt text; **"Struts" (p. 4) unexplained** |

  In the ten reference documents no occurrence is unexplained, and every
  missing word is in the alt text of the picture that keeps it.
  - **Correction to increment 14:** Federal Register was not 100%. The
    audit then broke the turned stamp into single letters, which it
    ignores, so the stamp's 26 words were never counted. It now follows
    turned glyphs by adjacency.
  - **FAA "Struts"** is a label over a drawing placed as a backdrop. It is
    live text, yet absent from the output, and Word shows it broken ("St t
    / ru s"). The committed build before increment 15 does the same. It is
    on the backlog.
- **GitHub's rendering engine, cmark-gfm** (`scripts/markdown_reader_check.py`,
  run locally with GitHub's extensions and raw HTML allowed; the page is
  never uploaded to github.com). Seven files were checked, covering
  picture folders, embedded pictures, tables, task items and a scan with
  its invisible text.
  - Every picture link resolved to a readable image file.
  - Tables, task-list items and `<details>` sections came out as elements.
  - No raw HTML was omitted.
  - Chrome renders were reviewed.
  - github.com's sanitizer is known to remove `data:` pictures, which is
    why folder mode is the default.
- **Visual Studio Code, built-in Markdown preview** (restricted mode, by
  AppleScript; captures in `results/md-readers/*.vscode.png`). The USGS
  fact sheet showed its photographs and logo from the image folder, with
  bold text, the list and headings. EIA's two tables were complete, with
  labels and superscript marks. The 1920 scan showed its page picture.
  The page markers were hidden. (Checked once, in increment 13; the
  automation sent a keystroke to the frontmost app and has been removed.
  The check is NOT RUN from now on.)
- **Typora:** partial. The document rendered with its pictures from the
  folder behind Typora's licence-expiry dialog; the trial had expired and
  was not bypassed. Typora shows the `<!-- page N -->` markers as visible
  grey text.
- **Obsidian:** NOT RUN. It opens a file only inside a registered vault,
  and registering one changes the user's Obsidian settings.
- **Seen in the review, fixed in increment 14:** one EIA header column
  read "Percent Change" without its "Year Ago" group. A group header now
  takes the extent of the rule that underlines it, so "Year Ago" spans
  its date, difference and percent change in Markdown, HTML and XLSX. In
  Excel's saved copy "Year Ago" is merged over F1:H1, beside "Week Ago"
  over C1:E1.

## DOCX

The layout-preserving DOCX is verified in **Microsoft Word for Mac** (open →
PDF export → edit → save → reopen, `scripts/word_reader_check.py`). Claims
about Word are measured claims and are kept separate from every other reader.
**Windows Word is unverified.** LibreOffice is not installed on the
verification machine and has not been checked.

## Apple Pages — what breaks, measured

Method: `scripts/reader_isolates.py` writes one small DOCX per construct the
writer relies on, with the geometry each should produce; `scripts/pages_export.py`
opens each in Pages (AppleScript), exports a PDF and measures it with PDFium
(`results/pages-isolates/pages-isolates.json`, 2026-09-21, Pages on macOS 15).

| Construct | Word for Mac | Apple Pages | Measured |
|---|---|---|---|
| Exact line pitch (`lineRule=exact`, 14 pt for 10 pt text) | honoured | **honoured** | line tops 76, 90, 104 … (14.0 pt pitch) |
| Exact pitch tighter than the font (8 pt for 10 pt text) | honoured | **honoured** | 8.0 pt pitch |
| Exact table rows (30 / 50 / 120 pt, zero cell margins) | honoured | **honoured** | row text at 78.3, 108.3, 158.3 |
| Cell shading and single cell borders | honoured | **honoured** | shaded cell and 0.5 pt rule present |
| Anchored picture at a page position (`behindDoc`) | honoured | **honoured** | picture at (300, 400) 100×60 |
| Tab stops, right stop, dotted leader | honoured | **honoured** | "Mid" at 272.7 (stop 272), right stop ends 538.9 (540) |
| Hidden text (`w:vanish`) | honoured | **honoured** | hidden word absent from the export |
| Run shading (`w:shd`), strike-through | honoured | **honoured** | yellow behind the run, line through the words |
| **Per-section page size / orientation** | honoured | **ignored** | both pages exported 612×792; the landscape section was laid on the portrait sheet |
| **Nested table with exact rows** (a side-by-side band) | honoured | **ignored** | inner rows collapsed to content height: 12 pt apart instead of 40 |
| **Character scale `w:w`** (condensed lines) | honoured | **ignored** | condensed line as wide as the natural one (343.2 pt both) |

Consequences for exporter output opened in Pages:

- A **rotated page** (`LAYOUT_PAGE_ROTATED`: the sheet is swapped and the
  page rebuilt transposed) is laid on the first section's sheet, so its
  content runs off the page or wraps. The I-9 (one rotated page) exports as
  11 pages in Pages against 6 in Word.
- **Side-by-side content** (two tables or two text columns sharing one exact
  row, written as a one-row table whose cells hold nested tables) loses the
  nested rows' exact heights; the columns' rows shrink to their text and the
  page's vertical positions below them drift upward.
- **Condensed lines** (a line Word's font would set wider than the source,
  written with a character scale) are set at natural width in Pages and may
  wrap, pushing the lines under them down by one line each.
- Everything else measured — exact pitch, top-level exact rows, shading,
  anchored pictures, tab stops and leaders, hidden text, run shading and
  strike-through — behaves as in Word.

What a Pages-compatible variant would need: one sheet size per document (or
a separate document per sheet size), no nested tables (side-by-side bands as
one grid whose columns are the bands' columns), and line breaks that do not
rely on character scaling (measure with a wider margin and break lines
explicitly). None of this is attempted; Word remains the target.
