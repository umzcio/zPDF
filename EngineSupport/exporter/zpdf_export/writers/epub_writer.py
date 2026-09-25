"""EPUB 3 writer: a reflowable book built from the Responsive reading HTML.

The Responsive reading document (headings, paragraphs, lists, tables,
figures, links, form values, comments, invisible text layers in collapsed
sections) is split into one XHTML chapter per source page, each opening with
an EPUB page break named after its source page. Pictures become files in the
package (no data URIs). Navigation:

* the table of contents is the PDF's bookmarks that point into the selected
  pages, in outline order and nesting, linking to each page's start; without
  bookmarks it is the headings, nested by level, linking to each heading;
  with neither, one entry per page;
* a page list maps every source page to its chapter;
* landmarks point to the first chapter.

The package follows the EPUB 3.3 container rules: ``mimetype`` first,
stored, no extra field; ``META-INF/container.xml``; a package document with
a UUID identifier derived from the source and the selected pages, title
(the PDF's, unless it reads as a file or template name; then the first heading), language ``und`` (no language is
known) and ``dcterms:modified``. No scripts, no remote resources.
"""
from __future__ import annotations

import base64
import datetime as _dt
import re
import uuid
import zipfile
from html import escape
from pathlib import Path

import lxml.html
from lxml import etree

from .. import BACKEND_ID
from .html_writer import render_html_reflow

XHTML = "http://www.w3.org/1999/xhtml"
_DATA_URI = re.compile(r"^data:(image/(?:png|jpeg));base64,(.*)$", re.S)

_CSS = """body{margin:0 1em;line-height:1.5;overflow-wrap:break-word}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.4em 0 .5em;page-break-after:avoid}
p{margin:.6em 0}
img{max-width:100%;height:auto}
figure{margin:1em 0;text-align:center}
.table{max-width:100%;overflow-x:auto;margin:1em 0}
table{border-collapse:collapse;font-size:.9em}
th,td{border:1px solid #999;padding:.25em .45em;vertical-align:top;text-align:left}
td.num{text-align:right;white-space:nowrap}
.comment{margin:.8em 0;padding:.4em .7em;border-left:3px solid #c8a200;font-size:.95em}
.fields dt{font-weight:bold}.fields dd{margin:0 0 .4em 1.5em}
.unsupported{font-style:italic}
details.ocr{margin:1em 0;font-size:.9em}
"""


_JUNK_TITLE = re.compile(r"(?i)(\.(docx?|pdf|indd|qxp|qxd|pub|rtf|odt|ai|eps)$)|^microsoft (word|powerpoint) - |"
                         r"^untitled|_|\bv ?\d+(\.\d+)+\b")


def book_title(pdf_title: str | None, headings: list[str], largest: str | None = None) -> tuple[str, str]:
    """The book's title and where it came from: the PDF's title, unless it reads
    as a file or template name ('FactSheet_3col v 4.1', 'Microsoft Word -
    memo.docx'); then the largest text on the first page (how a title is set);
    then the first heading; then a generic name."""
    t = (pdf_title or "").strip()
    if t and not _JUNK_TITLE.search(t):
        return t, "pdf_metadata"
    for text, source in ((largest, "largest_text"), (next((h for h in headings if h.strip()), None), "first_heading")):
        text = " ".join((text or "").split())
        if text:
            return (text[:117] + "…") if len(text) > 120 else text, source
    return "Converted document", "generic"


def _largest_text(doc) -> str | None:
    """The first page's text in the largest size (at least two words)."""
    from ..ir import TextNode
    pages = [p.source_index for p in getattr(doc, "pages", [])]
    if not pages:
        return None
    best = None
    for nid in doc.flow:
        n = doc.nodes[nid]
        if not isinstance(n, TextNode) or n.kind == "invisible" or not n.size or len(n.text.split()) < 2:
            continue
        if re.search(r"(?i)https?://|www\.", n.text):
            continue                                   # a digitization footer or a web address is not a title
        if not n.source_regions or n.source_regions[0]["page"] != pages[0]:
            continue
        if best is None or n.size > best.size + 0.5:
            best = n
    return best.text if best is not None else None


def _xhtml(title: str, body: str, css_href: str | None = "css/style.css") -> str:
    css = f'<link rel="stylesheet" type="text/css" href="{css_href}"/>' if css_href else ""
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n'
            f'<html xmlns="{XHTML}" xmlns:epub="http://www.idpf.org/2007/ops" lang="und" xml:lang="und">'
            f"<head><meta charset=\"utf-8\"/><title>{escape(title)}</title>{css}</head>\n"
            f"<body>\n{body}\n</body></html>\n")


def _nested(entries: list[tuple[int, str, str]]) -> str:
    """entries: (level, title, href) → nested <ol> as EPUB navigation needs it
    (each deeper level inside the previous item; no level skipped)."""
    if not entries:
        return "<ol><li><span>(no entries)</span></li></ol>"
    base = min(lvl for lvl, _t, _h in entries)
    out: list[str] = ["<ol>"]
    depth = 0
    open_li = [False]
    for lvl, title, href in entries:
        lvl = lvl - base
        lvl = min(lvl, depth + 1) if open_li[-1] else min(lvl, depth)
        while depth < lvl:
            out.append("<ol>"); depth += 1; open_li.append(False)
        while depth > lvl:
            out.append("</li></ol>"); depth -= 1; open_li.pop()
        if open_li[-1]:
            out.append("</li>")
        out.append(f'<li><a href="{escape(href)}">{escape(title)}</a>')
        open_li[-1] = True
    while depth > 0:
        out.append("</li></ol>"); depth -= 1; open_li.pop()
    out.append("</li></ol>")
    return "".join(out)


class _Writer:
    def __init__(self, doc):
        self.doc = doc
        self.images: list[tuple[str, str, bytes]] = []    # (href, media type, bytes)
        self.stats: dict = {}

    def write(self, path: Path) -> dict:
        html, stats = render_html_reflow(self.doc)
        self.stats = {k: v for k, v in stats.items()}
        root = lxml.html.document_fromstring(html)
        main = root.find(".//main")
        chapters: list[tuple[int, list]] = []
        pages = [p.source_index for p in getattr(self.doc, "pages", [])]
        for el in list(main):
            if el.tag == "div" and "page-marker" in (el.get("class") or ""):
                num = int(re.sub(r"\D", "", el.get("id", "")) or 0)
                chapters.append((num, []))
                continue
            if not chapters:
                chapters.append((pages[0] if pages else 1, []))
            chapters[-1][1].append(el)
        have = {n for n, _e in chapters}
        for p in pages:                                   # a page with no content still has its chapter
            if p not in have:
                chapters.append((p, []))
        chapters.sort(key=lambda c: pages.index(c[0]) if c[0] in pages else 10 ** 6)

        headings: list[tuple[int, str, str]] = []
        files: list[tuple[str, str]] = []                 # (href, content)
        hid = 0
        for num, elements in chapters:
            href = f"page-{num:04d}.xhtml"
            parts = [f'<span epub:type="pagebreak" role="doc-pagebreak" id="page-{num}" title="{num}"></span>']
            for el in elements:
                for img in el.iter("img"):
                    self._package(img)
                for h in el.iter("h1", "h2", "h3", "h4", "h5", "h6"):
                    hid += 1
                    h.set("id", f"h-{hid}")
                    headings.append((int(h.tag[1]), " ".join(h.itertext()).strip() or f"Heading {hid}",
                                     f"{href}#h-{hid}"))
                parts.append(etree.tostring(el, method="xml", encoding="unicode", with_tail=False))
            body = "\n".join(parts)
            content = _xhtml(f"Page {num}", body, "css/style.css")
            etree.fromstring(content.encode("utf-8"))    # well-formed, or fail here
            files.append((href, content))

        outline = [b for b in (getattr(self.doc, "outline", None) or []) if b["page"] in set(pages)]
        if outline:
            toc = [(b["level"], b["title"], f"page-{b['page']:04d}.xhtml#page-{b['page']}") for b in outline]
            source = "bookmarks"
        elif headings:
            toc, source = headings, "headings"
        else:
            toc = [(0, f"Page {n}", f"page-{n:04d}.xhtml#page-{n}") for n, _e in chapters]
            source = "pages"
        page_list = "".join(f'<li><a href="page-{n:04d}.xhtml#page-{n}">{n}</a></li>' for n, _e in chapters)
        title, title_source = book_title(getattr(self.doc, "title", None), [h[1] for h in headings],
                                         _largest_text(self.doc))
        nav = _xhtml(title, (
            f'<nav epub:type="toc" id="toc"><h1>{escape(title)}</h1>{_nested(toc)}</nav>\n'
            f'<nav epub:type="page-list" hidden=""><h2>Pages</h2><ol>{page_list}</ol></nav>\n'
            f'<nav epub:type="landmarks" hidden=""><h2>Landmarks</h2><ol>'
            f'<li><a epub:type="bodymatter" href="{files[0][0]}">Start</a></li></ol></nav>'), None)
        etree.fromstring(nav.encode("utf-8"))

        ident = uuid.uuid5(uuid.NAMESPACE_URL, f"zpdf-export:{self.doc.source_sha256}:{','.join(map(str, pages))}")
        modified = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
        author = getattr(self.doc, "author", None)
        manifest = ['<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
                    '<item id="css" href="css/style.css" media-type="text/css"/>']
        spine = []
        for k, (href, _c) in enumerate(files, start=1):
            manifest.append(f'<item id="c{k}" href="{href}" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="c{k}"/>')
        for k, (href, mt, _b) in enumerate(self.images, start=1):
            manifest.append(f'<item id="img{k}" href="{href}" media-type="{mt}"/>')
        opf = ('<?xml version="1.0" encoding="UTF-8"?>\n'
               '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="und">'
               '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
               f'<dc:identifier id="bookid">urn:uuid:{ident}</dc:identifier>'
               f"<dc:title>{escape(title)}</dc:title><dc:language>und</dc:language>"
               + (f"<dc:creator>{escape(author)}</dc:creator>" if author else "")
               + f'<meta property="dcterms:modified">{modified}</meta>'
               f'<meta property="schema:accessMode">textual</meta>'
               + ('<meta property="schema:accessMode">visual</meta>' if self.images else "")
               + '<meta property="schema:accessibilityFeature">tableOfContents</meta>'
               '<meta property="schema:accessibilityFeature">pageNavigation</meta>'
               '<meta property="schema:accessibilityHazard">none</meta>'
               '<meta property="schema:accessibilitySummary">A reflowable conversion of a PDF in reading order; '
               'pictures carry descriptions where the source labels them.</meta>'
               "</metadata>"
               f"<manifest>{''.join(manifest)}</manifest><spine>{''.join(spine)}</spine></package>\n")
        etree.fromstring(opf.encode("utf-8"))
        container = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                     '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                     '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
                     "</rootfiles></container>\n")
        with zipfile.ZipFile(path, "w") as z:
            info = zipfile.ZipInfo("mimetype", date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            z.writestr(info, b"application/epub+zip")
            z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr("OEBPS/css/style.css", _CSS, compress_type=zipfile.ZIP_DEFLATED)
            for href, content in files:
                z.writestr(f"OEBPS/{href}", content, compress_type=zipfile.ZIP_DEFLATED)
            for href, _mt, data in self.images:
                z.writestr(f"OEBPS/{href}", data, compress_type=zipfile.ZIP_STORED)
        self.stats.update(chapters=len(files), toc_entries=len(toc), toc_source=source, images=len(self.images),
                          title_source=title_source, generator=BACKEND_ID)
        self.stats.setdefault("warnings", [])
        self.stats["warnings"] = list(self.stats["warnings"]) + [
            {"code": "EPUB_LAYOUT_NOT_KEPT", "kinds": ["page_layout", "fonts", "colours", "rules_and_shading"],
             "detail": "the book reflows in reading order; each source page is a chapter"}]
        return self.stats

    def _package(self, img) -> None:
        m = _DATA_URI.match(img.get("src") or "")
        if not m:
            return
        mt, b64 = m.group(1), m.group(2)
        data = base64.b64decode(b64)
        k = len(self.images) + 1
        href = f"images/img-{k:04d}.{'jpg' if mt == 'image/jpeg' else 'png'}"
        self.images.append((href, mt, data))
        img.set("src", href)


def write_epub(doc, path: Path) -> dict:
    return _Writer(doc).write(Path(path))
