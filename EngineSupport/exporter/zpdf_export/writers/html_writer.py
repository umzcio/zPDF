"""HTML writer: one self-contained file, no scripts, no external resources.

Two modes, both built on the shared extraction and layout analysis:

* **Preserve layout** (``layout_mode="preserve"``, default): every page is a
  fixed-size box. Filled rectangles, rules and pictures are drawn at their
  measured positions in the source's paint order, and every text line is an
  absolutely positioned line at its measured position, scaled to its measured
  width in the stand-in font. A displayed rotation is a CSS rotation of the
  upright page. The OCR layer of a scan is transparent, selectable text over
  the scan picture. Tables are drawn, not marked up: their rules, shading and
  cell text are placed like everything else (the Responsive mode carries
  table structure).
* **Responsive reading** (``layout_mode="reflow"``): the document in reading
  order as semantic HTML: headings, paragraphs, ordered/unordered lists,
  tables with header rows and spans (unruled bodies recovered as for XLSX),
  figures, links, form values and comments, in a column that reflows from
  phone to desktop width.
"""
from __future__ import annotations

import base64
import html
import re
from pathlib import Path

from ..fonts import installed_family, map_font, text_width
from ..ir import CommentNode, FigureNode, FormValueNode, TableNode, TextNode
from ..layout_preserve import TextLine, lines_from_chars
from .docx_layout_writer import MAX_PICTURE_DPI, _fit_picture, _item_lines

TEXT_Z = 1000          # the text layer sits above every drawing
# how far a glyph reaches below the baseline, in em (Arial / Times): the line's
# measured bottom minus the deepest of these is its baseline
_DESCENT = {**{c: 0.21 for c in "gjpqy()[]{}|"}, ",": 0.11, ";": 0.11, "Q": 0.06, "$": 0.07, "@": 0.2,
            "/": 0.02, "_": 0.13, "\u201a": 0.11, "\u201e": 0.11}


def _esc(text: str) -> str:
    return html.escape(text or "", quote=True)


def _mime(data: bytes) -> str:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"\x89PNG":
        return "image/png"
    return "application/octet-stream"


def _data_uri(data: bytes) -> str:
    return f"data:{_mime(data)};base64,{base64.b64encode(data).decode('ascii')}"


def _pt(v: float) -> str:
    return f"{v:.2f}".rstrip("0").rstrip(".") + "pt"


# -- fonts ----------------------------------------------------------------------

_GENERIC = {"Times New Roman": "serif", "Courier New": "monospace"}
_METRICS: dict[tuple, tuple[float, float]] = {}


def _family(pdf_font: str) -> tuple[str, bool, bool]:
    fam, bold, italic = map_font(pdf_font or "")
    return installed_family(fam) or "Arial", bold, italic


def _css_family(fam: str) -> str:
    return f"'{fam}', {_GENERIC.get(fam, 'sans-serif')}"


def _metrics(fam: str, bold: bool, italic: bool) -> tuple[float, float]:
    """(ascent, descent) in em of the installed stand-in font."""
    key = (fam, bold, italic)
    if key not in _METRICS:
        asc, desc = 0.905, 0.212                      # Arial's
        try:
            from PIL import ImageFont
            from ..fonts import _font_file
            path, _exact = _font_file(fam, bold, italic)
            if path is not None:
                f = ImageFont.truetype(str(path), 1000)
                a, d = f.getmetrics()
                asc, desc = a / 1000, d / 1000
        except Exception:  # noqa: BLE001
            pass
        _METRICS[key] = (asc, desc)
    return _METRICS[key]


# -- preserve layout -------------------------------------------------------------

def _run_style(r: dict, base_fam: str, base_size: float) -> str:
    fam, fb, fi = _family(r.get("font", ""))
    parts = []
    if fam != base_fam:
        parts.append(f"font-family:{_css_family(fam)}")
    size = r.get("size") or base_size
    if abs(size - base_size) > 0.05:
        parts.append(f"font-size:{_pt(size)}")
    if r.get("bold") or fb:
        parts.append("font-weight:700")
    if r.get("italic") or fi:
        parts.append("font-style:italic")
    color = r.get("color")
    if color and sum(color) > 30:
        parts.append("color:#%02x%02x%02x" % tuple(int(v) for v in color))
    deco = [d for d, on in (("underline", r.get("underline")), ("line-through", r.get("strike"))) if on]
    if deco:
        parts.append("text-decoration:" + " ".join(deco))
    hl = r.get("highlight")
    if hl:
        parts.append("background:#%02x%02x%02x" % tuple(int(v) for v in hl))
    return ";".join(parts)


def _spans(runs: list[dict], base_fam: str, base_size: float) -> str:
    out = []
    uri_open = None
    for r in runs:
        if not r.get("text"):
            continue
        uri = r.get("uri")
        if uri != uri_open:
            if uri_open is not None:
                out.append("</a>")
            if uri:
                out.append(f'<a href="{_esc(uri)}">')
            uri_open = uri
        style = _run_style(r, base_fam, base_size)
        text = _esc(r["text"])
        out.append(f'<span style="{style}">{text}</span>' if style else text)
    if uri_open is not None:
        out.append("</a>")
    return "".join(out)


def _width(runs: list[dict]) -> float:
    w = 0.0
    for r in runs:
        fam, fb, fi = _family(r.get("font", ""))
        w += text_width(r.get("text", ""), fam, r.get("size") or 8.0, bool(r.get("bold") or fb), bool(r.get("italic") or fi))
    return w


def _line_html(ln: TextLine, cls: str = "l") -> tuple[str, int]:
    """Absolutely positioned segments for one measured line. Returns (html, links)."""
    runs = [r for r in ln.runs if r.get("text") is not None]
    if not runs or not "".join(r["text"] for r in runs).strip():
        return "", 0
    size = max((r.get("size") or 0) for r in runs) or ln.lbox.height or 8.0
    base_fam, bb, bi = _family(next((r.get("font", "") for r in runs if r.get("text", "").strip()), ""))
    asc, desc = _metrics(base_fam, bb, bi)
    text = "".join(r["text"] for r in runs if "tab_to" not in r)
    baseline = ln.lbox.y1 - max((_DESCENT.get(ch, 0.0) for ch in text), default=0.0) * size
    # a line box of line-height 1: the baseline sits (1 - (asc + desc)) / 2 + asc below its top
    top = baseline - ((1 - (asc + desc)) / 2 + asc) * size
    segs: list[tuple[float, list[dict], dict | None]] = [(ln.lbox.x0, [], None)]
    for r in runs:
        if r.get("tab_to") is not None:
            segs.append((r["tab_to"], [], r))
        else:
            segs[-1][1].append(r)
    parts = []
    links = 0
    for i, (x, seg_runs, tab) in enumerate(segs):
        if not seg_runs or not "".join(r["text"] for r in seg_runs).strip():
            continue
        if i == 0 and seg_runs:
            seg_runs = [dict(seg_runs[0], text=seg_runs[0]["text"].lstrip())] + seg_runs[1:]
        est = _width(seg_runs)
        last = all(not s[1] for s in segs[i + 1:])
        glyphs = len("".join(r["text"] for r in seg_runs).strip())
        if glyphs <= 2:
            scale = 1.0                               # a bullet or a mark: its shape, not a width to fit
        elif last:
            target = ln.lbox.x1 - x                   # the measured end of the line
            scale = target / est if est > 0 and target > 0 else 1.0
            scale = min(max(scale, 0.5), 1.6)
        else:
            avail = segs[i + 1][0] - x - 1.0
            scale = min(1.0, avail / est) if est > 0 and avail > 0 else 1.0
            scale = max(scale, 0.5)
        style = f"left:{_pt(x)};top:{_pt(top)};font-family:{_css_family(base_fam)};font-size:{_pt(size)}"
        if abs(scale - 1.0) > 0.01:
            style += f";transform:scaleX({scale:.3f})"
        body = _spans(seg_runs, base_fam, size)
        links += body.count("<a href")
        parts.append(f'<div class="{cls}" style="{style}">{body}</div>')
    # an underscore leader is the source's own rule, drawn with the page's rules
    return "".join(parts), links


def _join_touching(lines: list[TextLine]) -> list[TextLine]:
    """Pieces of one row that touch (a word split between two blocks: 'tele'
    + 'phone', 0.6 pt apart) become one line, so the text copies and searches
    as printed. Pieces with a real gap stay separate positioned lines."""
    out: list[TextLine] = []
    for ln in sorted(lines, key=lambda l: (round(l.lbox.y0, 1), l.lbox.x0)):
        prev = out[-1] if out else None
        if prev is not None and not any("tab_to" in r for r in prev.runs + ln.runs):
            size = max([r.get("size") or 0 for r in prev.runs + ln.runs] + [1.0])
            ov = min(prev.lbox.y1, ln.lbox.y1) - max(prev.lbox.y0, ln.lbox.y0)
            gap = ln.lbox.x0 - prev.lbox.x1
            if ov > 0.5 * min(prev.lbox.height, ln.lbox.height) and -0.5 <= gap <= 0.15 * size:
                out[-1] = TextLine(prev.runs + ln.runs, prev.lbox.union(ln.lbox), prev.align)
                continue
        out.append(ln)
    return out


def _box(b, extra: str = "") -> str:
    return f"left:{_pt(b.x0)};top:{_pt(b.y0)};width:{_pt(max(b.x1 - b.x0, 0.1))};height:{_pt(max(b.y1 - b.y0, 0.1))}{extra}"


def _page_html(layout, stats: dict, page_no: int) -> str:
    rot = layout.rotation % 360
    turned = rot in (90, 270)
    disp_w, disp_h = (layout.height, layout.width) if turned else (layout.width, layout.height)
    size_name = f"s{round(disp_w)}x{round(disp_h)}"
    stats["_sizes"].add((size_name, disp_w, disp_h))
    drawn: list[tuple[int, str]] = []
    for f in getattr(layout, "page_fills", []):
        if f.lbox.width < 0.1 or f.lbox.height < 0.1:
            continue
        png = getattr(f, "png", None)
        z = getattr(f, "z", 0)
        if png is not None:
            data = _fit_picture(png, f.lbox.width, f.lbox.height, stats)
            drawn.append((z, f'<img class="pic" alt="" data-z="{z}" src="{_data_uri(data)}" style="{_box(f.lbox)}">'))
        else:
            color = "#%02x%02x%02x" % tuple(int(v) for v in f.rgb)
            op = "" if getattr(f, "alpha", 255) >= 250 else f";opacity:{f.alpha / 255:.2f}"
            drawn.append((z, f'<div class="fill" data-z="{z}" style="{_box(f.lbox, f";background:{color}{op}")}"></div>'))
        stats["fills"] += 1
    for r in getattr(layout, "page_rules", []):
        z = getattr(r, "z", 0)
        color = "#%02x%02x%02x" % tuple(int(v) for v in getattr(r, "rgb", (0, 0, 0)))
        drawn.append((z, f'<div class="rule" data-z="{z}" style="{_box(r.lbox, f";background:{color}")}"></div>'))
        stats["rules"] += 1
    seen = set()
    figures = list(layout.figures)
    for band in layout.bands:
        figures += [it for it in band.items if it.kind == "figure"]
    for it in figures:
        im = it.payload
        if id(im) in seen:
            continue
        seen.add(id(im))
        if getattr(im, "behind", False):
            z = -10                                   # a drawing rendered from under the text: first of all
        elif getattr(im, "origin", "image") == "vector":
            z = 10 ** 9                               # rendered drawings carry no text: over fills and photos
        else:
            z = getattr(im, "z", 0)
        data = _fit_picture(im.png_bytes, it.lbox.width, it.lbox.height, stats)
        alt = _esc(getattr(im, "absorbed_text", "") or "")      # the labels the picture keeps
        drawn.append((z, f'<img class="pic" alt="{alt}" data-z="{z}" src="{_data_uri(data)}" style="{_box(it.lbox)}">'))
        stats["images"] += 1
    drawn.sort(key=lambda d: d[0])
    text: list[str] = []
    lines: list[TextLine] = []
    for band in layout.bands:
        for it in band.items:
            if it.kind == "figure":
                continue
            if it.kind == "table":
                for c in it.payload.cells:
                    lines += lines_from_chars(c.chars)
                    for v in getattr(c, "values", []) or []:
                        lines.append(TextLine([{"text": v["text"], "font": v.get("font", ""), "size": v.get("size", 8.0),
                                                "bold": v.get("bold", False), "italic": False}], v["lbox"]))
            else:
                lines += _item_lines(it)
    for ln in _join_touching(lines):
        h, n = _line_html(ln)
        if h:
            text.append(h); stats["lines"] += 1; stats["links"] += n
    for ln in getattr(layout, "hidden", []):
        h, _n = _line_html(ln, "l ocr")
        if h:
            text.append(h); stats["ocr_lines"] += 1
    notes = []
    for c in getattr(layout, "comments", []):
        who = f"{c.author}: " if getattr(c, "author", None) else ""
        body = _esc(f"{who}{c.text}")
        notes.append(f'<aside class="note" style="{_box(c.lbox)}"><span class="body">{body}</span></aside>')
        stats["comments"] += 1
    if turned:
        # the upright page turned to its displayed orientation: /Rotate 90 turns it a
        # quarter clockwise (the upright top edge becomes the right edge)
        tf = f"translate({_pt(layout.height)},0) rotate(90deg)" if rot == 90 else f"translate(0,{_pt(layout.width)}) rotate(270deg)"
        inner_style = f"width:{_pt(layout.width)};height:{_pt(layout.height)};transform:{tf}"
    else:
        inner_style = f"width:{_pt(layout.width)};height:{_pt(layout.height)}"
    return (f'<section class="page" id="page-{page_no}" aria-label="Page {page_no}" '
            f'style="page:{size_name};width:{_pt(disp_w)};height:{_pt(disp_h)}">'
            f'<div class="up" style="{inner_style}"><div class="art">' + "".join(h for _z, h in drawn) + "</div>"
            + '<div class="txt">' + "".join(text) + "</div>" + "".join(notes) + "</div></section>")


_PRESERVE_CSS = """
*{box-sizing:border-box}
html{background:#e8e8ea}
body{margin:0;padding:16px 0}
.page{position:relative;overflow:hidden;contain:strict;background:#fff;margin:0 auto 16px;box-shadow:0 1px 4px rgba(0,0,0,.25)}
.up{position:absolute;left:0;top:0;transform-origin:0 0}
.art,.txt{position:absolute;left:0;top:0;width:100%;height:100%}
.art{z-index:0}.txt{z-index:1}
.l{position:absolute;white-space:pre;line-height:1;transform-origin:0 0;color:#000}
.l.ocr{color:transparent}
.fill,.rule,.pic{position:absolute;display:block}
a{color:inherit;text-decoration:inherit}
.note{position:absolute;z-index:2;outline:1px dashed rgba(200,140,0,.8);background:rgba(255,220,80,.15)}
.note .body{display:none;position:absolute;top:100%;left:0;min-width:180pt;max-width:320pt;padding:4pt 6pt;background:#fff8d6;
 border:1px solid #c8a200;font:9pt/1.3 -apple-system,'Helvetica Neue',Arial,sans-serif;color:#222;white-space:normal}
.note:hover .body,.note:focus-within .body{display:block}
@media print{html{background:none}body{padding:0}.page{margin:0;box-shadow:none;break-after:page}.note{outline:none;background:none}}
"""


def write_html_preserve(doc, path: Path) -> dict:
    # stats["pages"] is the current page's 1-based index while writing: the
    # downsampling disclosure records pictures by it (as in the DOCX writer)
    stats = {"pages": 0, "lines": 0, "ocr_lines": 0, "images": 0, "fills": 0, "rules": 0, "links": 0,
             "comments": 0, "_sizes": set()}
    body = []
    selected = [p.source_index for p in getattr(doc, "pages", [])] or list(range(1, len(doc.layouts) + 1))
    for k, layout in enumerate(getattr(doc, "layouts", None) or []):
        stats["pages"] = k + 1
        body.append(_page_html(layout, stats, selected[k] if k < len(selected) else k + 1))
    sizes = "".join(f"@page {n}{{size:{_pt(w)} {_pt(h)};margin:0}}" for n, w, h in sorted(stats.pop("_sizes")))
    out = ("<!doctype html>\n<html lang=\"und\"><head><meta charset=\"utf-8\">"
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
           "<meta name=\"generator\" content=\"zPDF Export (preserve layout)\">"
           "<title>Converted document</title><style>" + _PRESERVE_CSS + sizes + "</style></head><body>\n"
           + "\n".join(body) + "\n</body></html>\n")
    Path(path).write_text(out, encoding="utf-8")
    stats["mode"] = "preserve"
    return _disclose(stats)


# -- responsive reading ----------------------------------------------------------

def _inline(runs: list[dict], fallback: str) -> str:
    if not runs:
        return _esc(fallback)
    out = []
    for r in runs:
        t = _esc(r.get("text", ""))
        if not t:
            continue
        if r.get("bold"):
            t = f"<strong>{t}</strong>"
        if r.get("italic"):
            t = f"<em>{t}</em>"
        if r.get("uri"):
            t = f'<a href="{_esc(r["uri"])}">{t}</a>'
        out.append(t)
    return "".join(out) or _esc(fallback)


def _cell_html(text: str) -> str:
    return "<br>".join(_esc(p) for p in (text or "").split("\n"))


def _table_html(node: TableNode, stats: dict) -> str:
    from .xlsx_writer import cell_value
    owner: dict[tuple[int, int], dict] = {}
    anchors: dict[tuple[int, int], dict] = {}
    for c in sorted(node.cells, key=lambda c: (c["row"], c["col"])):
        span = [(r, k) for r in range(c["row"], c["row"] + c["rowspan"]) for k in range(c["col"], c["col"] + c["colspan"])]
        taken = [owner[p] for p in span if p in owner]
        if taken:
            if c["raw_text"].strip():
                taken[0]["raw_text"] = (taken[0]["raw_text"] + "\n" + c["raw_text"]).strip("\n")
            stats["cell_overlaps"] += 1
            continue
        cc = dict(c)
        for p in span:
            owner[p] = cc
        anchors[(c["row"], c["col"])] = cc
    head = set(node.header_rows)
    rows_html = {"thead": [], "tbody": []}
    for r in range(node.n_rows):
        cells = []
        for k in range(node.n_cols):
            c = anchors.get((r, k))
            if c is None:
                if (r, k) not in owner:
                    cells.append("<td></td>")        # a gap in the grid keeps the columns aligned
                continue
            attrs = ""
            if c["colspan"] > 1:
                attrs += f' colspan="{c["colspan"]}"'
            if c["rowspan"] > 1:
                attrs += f' rowspan="{c["rowspan"]}"'
            tag = "th" if r in head else "td"
            if tag == "td" and cell_value(c["raw_text"])[2] == "number":
                attrs += ' class="num"'
            if tag == "th":
                attrs += ' scope="col"' if c["colspan"] >= 1 else ""
            cells.append(f"<{tag}{attrs}>{_cell_html(c['raw_text'])}</{tag}>")
        (rows_html["thead"] if r in head else rows_html["tbody"]).append("<tr>" + "".join(cells) + "</tr>")
    stats["tables"] += 1
    parts = ['<div class="table"><table>']
    if rows_html["thead"]:
        parts.append("<thead>" + "".join(rows_html["thead"]) + "</thead>")
    parts.append("<tbody>" + "".join(rows_html["tbody"]) + "</tbody></table></div>")
    return "".join(parts)


_ORDERED = re.compile(r"^\(?(\d+|[a-zA-Z]|[ivxlcdmIVXLCDM]+)[.)]$")


def _list_open(node: TextNode) -> tuple[str, str]:
    m = _ORDERED.match((node.marker or "").strip())
    if not m:
        return "ul", "<ul>"
    tok = m.group(1)
    if tok.isdigit():
        return "ol", "<ol>" if tok == "1" else f'<ol start="{int(tok)}">'
    if tok.isalpha() and len(tok) == 1:
        start = ord(tok.lower()) - ord("a") + 1
        kind = "a" if tok.islower() else "A"
        return "ol", f'<ol type="{kind}">' if start == 1 else f'<ol type="{kind}" start="{start}">'
    return "ol", '<ol type="i">'


_REFLOW_CSS = """
:root{--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--rule:#d2d2d7;--note:#fff8d6;--noteb:#c8a200}
@media (prefers-color-scheme:dark){:root{--fg:#f2f2f2;--muted:#a1a1a6;--bg:#161617;--rule:#3a3a3c;--note:#3a3320;--noteb:#8a7300}}
*{box-sizing:border-box}
html{background:var(--bg);color:var(--fg)}
body{margin:0 auto;max-width:44rem;padding:1.25rem 1rem 3rem;font:1.0625rem/1.55 -apple-system,'Segoe UI','Helvetica Neue',Arial,sans-serif;overflow-wrap:break-word}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .5em}
p{margin:.7em 0}
img{max-width:100%;height:auto}
figure{margin:1.2em 0}
.table{max-width:100%;overflow-x:auto;margin:1em 0}
table{border-collapse:collapse;font-size:.9rem}
th,td{border:1px solid var(--rule);padding:.3em .5em;vertical-align:top;text-align:left}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
thead th{background:rgba(127,127,127,.12)}
.page-marker{margin:2.2em 0 .6em;color:var(--muted);font-size:.8rem;letter-spacing:.04em;border-top:1px solid var(--rule);padding-top:.4em}
.comment{margin:.8em 0;padding:.5em .75em;background:var(--note);border-left:3px solid var(--noteb);font-size:.95rem}
.fields{display:grid;grid-template-columns:minmax(8rem,max-content) 1fr;gap:.25em 1em;margin:.8em 0}
.fields dt{color:var(--muted)}.fields dd{margin:0}
.unsupported{color:var(--muted);font-style:italic}
details.ocr{margin:1em 0;color:var(--muted);font-size:.9rem}details.ocr summary{cursor:pointer}
"""


def write_html_reflow(doc, path: Path) -> dict:
    stats = {"pages": 0, "paragraphs": 0, "headings": 0, "list_items": 0, "tables": 0, "images": 0,
             "links": 0, "comments": 0, "form_values": 0, "cell_overlaps": 0}
    parts: list[str] = []
    open_list: str | None = None
    current_page = None
    fields: list[FormValueNode] = []

    def close_list():
        nonlocal open_list
        if open_list:
            parts.append(f"</{open_list}>")
            open_list = None

    def flush_fields():
        if fields:
            parts.append('<dl class="fields">' + "".join(
                f"<dt>{_esc(v.label or v.field_name)}</dt><dd>{_esc(_shown(v))}</dd>" for v in fields) + "</dl>")
            stats["form_values"] += len(fields)
            fields.clear()

    for nid in doc.flow:
        node = doc.nodes[nid]
        page = node.source_regions[0]["page"] if node.source_regions else None
        if page is not None and page != current_page:
            close_list(); flush_fields()
            stats["pages"] += 1                  # the section index the downsampling disclosure uses
            parts.append(f'<div class="page-marker" id="page-{page}">Page {page}</div>')
            current_page = page
        if isinstance(node, FormValueNode):
            if node.placement in ("table_cell", "inline_sentence"):
                continue
            close_list()
            fields.append(node)
            continue
        flush_fields()
        if isinstance(node, TextNode):
            links = sum(1 for r in node.runs if r.get("uri"))
            stats["links"] += links
            if node.kind == "list_item":
                kind, tag = _list_open(node)
                if open_list != kind:
                    close_list(); parts.append(tag); open_list = kind
                parts.append(f"<li>{_inline(node.runs, node.text)}</li>")
                stats["list_items"] += 1
                continue
            close_list()
            if node.kind == "invisible":
                body = "<br>".join(_esc(t) for t in node.text.split("\n"))
                parts.append(f'<details class="ocr"><summary>Invisible text layer, page {page}</summary>'
                             f"<p>{body}</p></details>")
                stats["invisible_layers"] = stats.get("invisible_layers", 0) + 1
                continue
            if node.kind == "heading":
                lvl = min(max(node.level or 1, 1), 6)
                parts.append(f"<h{lvl}>{_esc(node.text)}</h{lvl}>")
                stats["headings"] += 1
            elif node.kind == "unsupported":
                parts.append(f'<p class="unsupported">{_esc(node.text)}</p>')
            else:
                parts.append(f"<p>{_inline(node.runs, node.text)}</p>")
                stats["paragraphs"] += 1
            continue
        close_list()
        if isinstance(node, TableNode):
            parts.append(_table_html(node, stats))
        elif isinstance(node, FigureNode):
            asset = doc.assets.get(node.asset_id)
            if asset is not None and asset.data:
                b = node.source_regions[0]["bbox"] if node.source_regions else [0, 0, 400, 300]
                data = _fit_picture(asset.data, b[2] - b[0], b[3] - b[1], stats)
                alt = node.absorbed_text or f"Picture from page {page}"
                parts.append(f'<figure><img src="{_data_uri(data)}" alt="{_esc(alt)}" '
                             f'width="{round((b[2] - b[0]) * 4 / 3)}" height="{round((b[3] - b[1]) * 4 / 3)}"></figure>')
                stats["images"] += 1
        elif isinstance(node, CommentNode):
            who = f" by {_esc(node.author)}" if node.author else ""
            when = f" ({_esc(node.modified)})" if node.modified else ""
            parts.append(f'<aside class="comment"><strong>{_esc(node.comment_kind.capitalize())}</strong>{who}{when}: '
                         f"{_esc(node.text)}</aside>")
            stats["comments"] += 1
    close_list(); flush_fields()
    out = ("<!doctype html>\n<html lang=\"und\"><head><meta charset=\"utf-8\">"
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
           "<meta name=\"generator\" content=\"zPDF Export (responsive reading)\">"
           "<meta name=\"color-scheme\" content=\"light dark\">"
           "<title>Converted document</title><style>" + _REFLOW_CSS + "</style></head><body><main>\n"
           + "\n".join(parts) + "\n</main></body></html>\n")
    Path(path).write_text(out, encoding="utf-8")
    stats["mode"] = "reflow"
    return _disclose(stats)


def _shown(v: FormValueNode) -> str:
    if v.checked is not None:
        return "checked" if v.checked else "unchecked"
    return v.raw_value


def _disclose(stats: dict) -> dict:
    stats.setdefault("images_downsampled", 0)
    stats.setdefault("images_downsampled_pages", [])
    stats["max_picture_dpi"] = MAX_PICTURE_DPI
    return stats


def write_html(doc, path: Path, mode: str = "preserve") -> dict:
    if mode == "reflow":
        return write_html_reflow(doc, path)
    return write_html_preserve(doc, path)
