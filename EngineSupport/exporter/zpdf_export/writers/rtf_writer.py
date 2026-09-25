"""RTF writer: the document in reading order as Rich Text Format 1.9.

Built on the same ordered IR as the reflow DOCX and Markdown writers:
headings (outline levels 1–9 with heading styles), paragraphs in their
dominant font and size with bold, italic and links (HYPERLINK fields to
http/https/mailto only), lists as RTF lists that keep the source's numbering
style and start (decimal, letters, roman, bullets), tables with header rows
repeated, column widths from the source and cells that span columns, pictures
embedded as PNG or JPEG with the labels they keep as their description, form
values, and comments in a labelled section per page. A page's invisible text
layer is hidden text.

The file is 7-bit: every character outside ASCII is a \\uN escape (UTF-16 code
units, so characters outside the BMP are two), and \\, { and } are escaped.
No field other than HYPERLINK and no embedded object is ever written, so
opening the file cannot fetch or run anything.

Not kept (RTF_LAYOUT_NOT_KEPT, on every result): page layout and positions,
columns, rules and shading, text colour; fonts are the installed stand-ins
(Arial, Times New Roman, Courier New) named from the PDF fonts.
"""
from __future__ import annotations

import io
import re
from pathlib import Path
from urllib.parse import urlsplit

from ..fonts import map_font
from ..ir import CommentNode, FigureNode, FormValueNode, TableNode, TextNode
from .docx_layout_writer import MAX_PICTURE_DPI, _fit_picture

TWIPS = 20                   # per point
_TEXT_WIDTH_PT = 468         # 6.5 in: US Letter with 1 in margins
_ALLOWED_SCHEMES = {"http", "https", "mailto"}
_FAMILY_CLASS = {"Times New Roman": "froman", "Courier New": "fmodern"}
_HEADING_SIZE = {1: 16, 2: 14, 3: 13, 4: 12, 5: 11, 6: 11}
_NFC = {"decimal": 0, "upper-roman": 1, "lower-roman": 2, "upper-letter": 3, "lower-letter": 4, "bullet": 23}


def _esc(text: str) -> str:
    """RTF-escape text: \\ { } escaped, ASCII control characters dropped (tabs
    and newlines are the caller's), everything else outside ASCII as \\uN?."""
    out = []
    for ch in text or "":
        o = ord(ch)
        if ch in "\\{}":
            out.append("\\" + ch)
        elif 32 <= o < 127:
            out.append(ch)
        elif ch == "\t":
            out.append("\\tab ")
        elif ch == "\n":
            out.append("\\line ")
        elif o < 32 or o == 127:
            continue
        else:
            data = ch.encode("utf-16-le")
            for k in range(0, len(data), 2):
                unit = int.from_bytes(data[k:k + 2], "little")
                out.append(f"\\u{unit - 65536 if unit > 32767 else unit}?")
    return "".join(out)


def _twips(pt: float) -> int:
    return int(round(pt * TWIPS))


def _marker_style(marker: str | None) -> tuple[str, int, str, str]:
    """(numbering format, start value, text before, text after) of a list marker."""
    m = (marker or "").strip()
    g = re.match(r"^(\(?)(\d+)([.)])$", m)
    if g:
        return "decimal", int(g.group(2)), g.group(1), g.group(3)
    g = re.match(r"^(\(?)([ivxlcdm]+|[IVXLCDM]+)([.)])$", m)
    if g and (len(g.group(2)) > 1 or g.group(2) in "iIvVxX"):
        roman = g.group(2)
        # a single 'i', 'v' or 'x' starts a roman list only when it is 'i'; otherwise it is a letter
        if len(roman) > 1 or roman in "iI":
            return ("lower-roman" if roman.islower() else "upper-roman"), _roman_value(roman), g.group(1), g.group(3)
    g = re.match(r"^(\(?)([a-zA-Z])([.)])$", m)
    if g:
        c = g.group(2)
        return ("lower-letter" if c.islower() else "upper-letter"), ord(c.lower()) - 96, g.group(1), g.group(3)
    return "bullet", 1, "", ""


def _column_axis(cells: list[dict]):
    """The coordinate (in displayed space) along which the table's columns run:
    the one in which each column's cells start in column order. Upright pages:
    x; pages displayed turned: y, one way or the other."""
    span = max((c["bbox"][2] for c in cells), default=0) + max((c["bbox"][3] for c in cells), default=0)
    options = [lambda b: (b[0], b[2]), lambda b: (b[1], b[3]),
               lambda b: (span - b[2], span - b[0]), lambda b: (span - b[3], span - b[1])]

    def score(f) -> int:
        starts: dict[int, list[float]] = {}
        for c in cells:
            starts.setdefault(c["col"], []).append(f(c["bbox"])[0])
        order = [sum(v) / len(v) for _k, v in sorted(starts.items())]
        return sum(1 for a, b in zip(order, order[1:]) if b > a)
    return max(options, key=score)


def _roman_value(s: str) -> int:
    vals = {"i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000}
    total, prev = 0, 0
    for ch in reversed(s.lower()):
        v = vals[ch]
        total += -v if v < prev else v
        prev = max(prev, v)
    return total


class _Writer:
    def __init__(self, doc):
        self.doc = doc
        self.fonts: list[str] = ["Arial"]              # \f0 is the default
        self.lists: list[tuple[str, int, str, str]] = []
        self.body: list[str] = []
        self.stats = {"paragraphs": 0, "headings": 0, "list_items": 0, "tables": 0, "images": 0, "links": 0,
                      "form_values": 0, "comments": 0, "hidden_paragraphs": 0, "links_dropped_unsafe_scheme": 0,
                      "fonts": {}, "pages": 0}
        self._list_open: tuple | None = None           # (format, list index) of the list being written

    # -- helpers -----------------------------------------------------------
    def font(self, pdf_font: str | None) -> tuple[int, bool, bool]:
        fam, bold, italic = map_font(pdf_font or "")
        fam = fam if fam in ("Arial", "Times New Roman", "Courier New") else "Arial"
        if pdf_font:
            self.stats["fonts"][pdf_font] = fam
        if fam not in self.fonts:
            self.fonts.append(fam)
        return self.fonts.index(fam), bold, italic

    def runs(self, node: TextNode, base_bold: bool = False, base_italic: bool = False) -> str:
        parts = []
        for r in node.runs or [{"text": node.text, "bold": False, "italic": False}]:
            text = r.get("text", "")
            if not text:
                continue
            fmt = ("\\b " if r.get("bold") or base_bold else "") + ("\\i " if r.get("italic") or base_italic else "")
            uri = r.get("uri")
            if uri and urlsplit(uri).scheme.lower() in _ALLOWED_SCHEMES:
                target = uri.replace("\\", "%5C").replace('"', "%22")
                parts.append('{\\field{\\*\\fldinst{HYPERLINK "' + _esc(target) + '"}}{\\fldrslt{\\ul\\cf1 '
                             + fmt + _esc(text) + "}}}")
                self.stats["links"] += 1
            else:
                if uri:
                    self.stats["links_dropped_unsafe_scheme"] += 1
                parts.append("{" + fmt + _esc(text) + "}" if fmt else _esc(text))
        return "".join(parts)

    def para(self, content: str, pard: str = "") -> None:
        self.body.append("\\pard\\plain\\sa120" + pard + " " + content + "\\par\n")

    # -- nodes -----------------------------------------------------------------
    def text(self, node: TextNode) -> None:
        f, fb, fi = self.font(node.font)
        size = node.size or 11.0
        if node.kind == "invisible":
            self.para("{\\v " + _esc(node.text.replace("\n", " ")) + "}", f"\\f{f}\\fs{int(round(size * 2))}")
            self.stats["hidden_paragraphs"] += 1
            return
        if node.kind == "list_item":
            fmt, start, pre, post = _marker_style(node.marker)
            restart = (self._list_open is None or self._list_open[0] != fmt
                       or (fmt != "bullet" and start == 1))
            if restart:
                self.lists.append((fmt, start, pre, post))
                self._list_open = (fmt, len(self.lists))
            ls = self._list_open[1]
            marker = node.marker.strip() if node.marker else "\u2022"
            if fmt == "bullet":
                marker = "\u2022"
            lead = "{\\listtext\\pard\\plain\\f" + str(f) + " " + _esc(marker) + "\\tab}"
            self.para(lead + self.runs(node, fb, fi),
                      f"\\ls{ls}\\ilvl0\\fi-360\\li720\\f{f}\\fs{int(round(size * 2))}")
            self.stats["list_items"] += 1
            return
        self._list_open = None
        if node.kind == "heading":
            level = min(max(node.level or 1, 1), 9)
            hs = node.size or _HEADING_SIZE.get(level, 11)
            self.para(self.runs(node, True, fi),
                      f"\\s{level}\\outlinelevel{level - 1}\\keepn\\sb120\\f{f}\\fs{int(round(hs * 2))}")
            self.stats["headings"] += 1
            return
        if node.kind == "unsupported":
            self.para("{\\i " + _esc(node.text) + "}")
            return
        self.para(self.runs(node, fb, fi), f"\\f{f}\\fs{int(round(size * 2))}")
        self.stats["paragraphs"] += 1

    def table(self, node: TableNode) -> None:
        self._list_open = None
        cells = node.cells
        if not cells:
            return
        # column right edges from the source: the right edge of cells ending in each column,
        # along the page's upright x axis (cell boxes are in displayed space: on a page
        # displayed turned, the columns run along its y axis)
        ncols = node.n_cols
        axis = _column_axis(cells)
        rights = [0.0] * ncols
        lefts = [None] * ncols
        for c in cells:
            a0, a1 = axis(c["bbox"])
            end = c["col"] + c.get("colspan", 1) - 1
            if c.get("colspan", 1) == 1:
                rights[end] = max(rights[end], a1)
                lefts[c["col"]] = a0 if lefts[c["col"]] is None else min(lefts[c["col"]], a0)
        x0 = min((v for v in lefts if v is not None), default=0.0)
        for k in range(ncols):                         # a column that never stands alone: share its neighbours'
            if rights[k] <= 0:
                rights[k] = rights[k - 1] + 36 if k else x0 + 36
        for k in range(1, ncols):
            rights[k] = max(rights[k], rights[k - 1] + 12)
        width = rights[-1] - x0
        scale = min(1.0, _TEXT_WIDTH_PT / width) if width > 0 else 1.0
        edge = [_twips((r - x0) * scale) for r in rights]
        header = set(node.header_rows)
        grid: dict[tuple[int, int], dict] = {(c["row"], c["col"]): c for c in cells}
        covered: dict[tuple[int, int], str] = {}
        for c in cells:
            for rr in range(c["row"], c["row"] + c.get("rowspan", 1)):
                for cc in range(c["col"], c["col"] + c.get("colspan", 1)):
                    if (rr, cc) != (c["row"], c["col"]):
                        covered[(rr, cc)] = "v" if rr != c["row"] and cc == c["col"] else "h"
        for r in range(node.n_rows):
            row = ["\\trowd\\trgaph72\\trleft0" + ("\\trhdr" if r in header else "")]
            content = []
            col = 0
            while col < ncols:
                c = grid.get((r, col))
                if c is None and covered.get((r, col)) == "h":
                    col += 1
                    continue                           # inside a wider cell of this row
                span = c.get("colspan", 1) if c else 1
                borders = "\\clbrdrt\\brdrs\\brdrw10\\clbrdrl\\brdrs\\brdrw10\\clbrdrb\\brdrs\\brdrw10\\clbrdrr\\brdrs\\brdrw10"
                vm = ""
                if c is not None and c.get("rowspan", 1) > 1:
                    vm = "\\clvmgf"
                elif covered.get((r, col)) == "v":
                    vm = "\\clvmrg"
                    owner = next(x for x in cells if x["col"] == col and x["row"] < r < x["row"] + x.get("rowspan", 1)
                                 or (x["col"] == col and x["row"] < r and r < x["row"] + x.get("rowspan", 1)))
                    span = owner.get("colspan", 1)
                row.append(f"{vm}{borders}\\cellx{edge[min(col + span, ncols) - 1]}")
                text = _esc(c["raw_text"]).replace("\n", "\\line ") if c else ""
                if c is not None and (c.get("bold") or r in header):
                    text = "{\\b " + text + "}" if text else ""
                content.append("\\pard\\plain\\intbl\\f0\\fs16 " + text + "\\cell")
                col += span
            self.body.append("".join(row) + "\n" + "\n".join(content) + "\n\\row\n")
        self.body.append("\\pard\\plain\\sa120\\par\n")
        self.stats["tables"] += 1

    def figure(self, node: FigureNode) -> None:
        self._list_open = None
        asset = self.doc.assets.get(node.asset_id)
        if asset is None or not getattr(asset, "data", b""):
            return
        bbox = node.source_regions[0]["bbox"] if node.source_regions else [0, 0, 144, 144]
        w_pt = max(min(bbox[2] - bbox[0], _TEXT_WIDTH_PT), 8.0)
        h_pt = max((bbox[3] - bbox[1]) * w_pt / max(bbox[2] - bbox[0], 1e-6), 4.0)
        data = _fit_picture(asset.data, w_pt, h_pt, self.stats)
        from PIL import Image
        im = Image.open(io.BytesIO(data))
        blip = "\\jpegblip" if data[:3] == b"\xff\xd8\xff" else "\\pngblip"
        if blip == "\\pngblip" and data[:8] != b"\x89PNG\r\n\x1a\n":
            buf = io.BytesIO(); im.save(buf, format="PNG"); data = buf.getvalue()
        hexed = data.hex()
        lines = "\n".join(hexed[k:k + 128] for k in range(0, len(hexed), 128))
        descr = ""
        if node.absorbed_text:
            descr = "{\\*\\picprop{\\sp{\\sn wzDescription}{\\sv " + _esc(node.absorbed_text) + "}}}"
        pict = (f"{{\\pict{descr}{blip}\\picw{im.width}\\pich{im.height}"
                f"\\picwgoal{_twips(w_pt)}\\pichgoal{_twips(h_pt)}\n{lines}}}")
        self.para(pict)
        self.stats["images"] += 1

    def form_value(self, v: FormValueNode) -> None:
        self._list_open = None
        if v.field_type in ("checkbox", "radio"):
            glyph = "\u2612" if v.checked else "\u2610"
            label = v.label or v.field_name
            ev = (v.export_value or "").strip()
            extra = f" ({ev})" if v.checked and ev and ev.lower() not in ("on", "yes", "true", "1") \
                and ev.lower() not in label.lower() else ""
            self.para(_esc(f"{glyph} {label}{extra}"))
        else:
            label = (v.label or v.field_name or "").rstrip(":")
            value = _esc(v.raw_value) if v.raw_value.strip() else "{\\i (blank)}"
            self.para("{\\b " + _esc(label + ": ") + "}" + value)
        self.stats["form_values"] += 1

    def comment(self, node: CommentNode, page: int | None, heading_for: dict) -> None:
        self._list_open = None
        if heading_for.get("page") != page:
            heading_for["page"] = page
            self.para("{\\b " + _esc(f"Comments (page {page})") + "}", "\\s3\\outlinelevel2\\keepn\\fs26")
        who = f" by {node.author}" if node.author else ""
        when = f" ({node.modified})" if node.modified else ""
        self.para("{\\b " + _esc(node.comment_kind.capitalize()) + "}" + _esc(f"{who}{when}: {node.text}"))
        self.stats["comments"] += 1

    # -- document ------------------------------------------------------------------
    def write(self, path: Path) -> dict:
        heading_for: dict = {}
        unpaired: list[FormValueNode] = []
        for nid in self.doc.flow:
            node = self.doc.nodes[nid]
            page = node.source_regions[0]["page"] if node.source_regions else None
            if isinstance(node, TextNode):
                self.text(node)
            elif isinstance(node, TableNode):
                self.table(node)
            elif isinstance(node, FigureNode):
                self.figure(node)
            elif isinstance(node, FormValueNode):
                if node.placement in ("table_cell", "inline_sentence"):
                    self.stats["form_values"] += 1     # already inside its cell or sentence
                elif node.placement == "inline" and node.paired:
                    self.form_value(node)
                else:
                    unpaired.append(node)
            elif isinstance(node, CommentNode):
                self.comment(node, page, heading_for)
        if unpaired:
            self.para("{\\b " + _esc("Unpaired form values") + "}", "\\s3\\outlinelevel2\\keepn\\fs26")
            for v in unpaired:
                self.form_value(v)
        pages = getattr(self.doc, "pages", [])
        self.stats["pages"] = len(pages)
        pw, ph = (pages[0].width, pages[0].height) if pages else (612.0, 792.0)
        if pages and pages[0].rotation in (90, 270):
            pw, ph = ph, pw
        header = ["{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0\n{\\fonttbl"]
        for k, fam in enumerate(self.fonts):
            header.append(f"{{\\f{k}\\{_FAMILY_CLASS.get(fam, 'fswiss')}\\fcharset0 {fam};}}")
        header.append("}\n{\\colortbl;\\red5\\green99\\blue193;}\n")
        header.append("{\\stylesheet{\\s0 Normal;}" + "".join(
            f"{{\\s{k}\\outlinelevel{k - 1}\\keepn\\b heading {k};}}" for k in range(1, 10)) + "}\n")
        if self.lists:
            header.append("{\\*\\listtable\n")
            for k, (fmt, start, pre, post) in enumerate(self.lists, start=1):
                if fmt == "bullet":
                    text = "{\\leveltext\\'01\\u8226 ?;}{\\levelnumbers;}"
                else:
                    tmpl = _esc(pre) + "\\'00" + _esc(post)
                    n = len(pre) + 1 + len(post)
                    pos = len(pre) + 1
                    text = f"{{\\leveltext\\'{n:02x}{tmpl};}}{{\\levelnumbers\\'{pos:02x};}}"
                header.append(f"{{\\list\\listtemplateid{k}\\listsimple{{\\listlevel\\levelnfc{_NFC[fmt]}\\levelnfcn{_NFC[fmt]}"
                              f"\\leveljc0\\levelstartat{start}\\levelfollow0{text}\\fi-360\\li720}}\\listid{k}}}\n")
            header.append("}\n{\\*\\listoverridetable")
            for k in range(1, len(self.lists) + 1):
                header.append(f"{{\\listoverride\\listid{k}\\listoverridecount0\\ls{k}}}")
            header.append("}\n")
        header.append("{\\info{\\author zPDF Export}}\n")
        header.append(f"\\paperw{_twips(pw)}\\paperh{_twips(ph)}\\margl1440\\margr1440\\margt1440\\margb1440\n")
        out = "".join(header) + "".join(self.body) + "}\n"
        Path(path).write_text(out, encoding="ascii")
        warnings = [{"code": "RTF_LAYOUT_NOT_KEPT",
                     "kinds": ["page_layout", "columns", "positions", "rules_and_shading", "text_colour"],
                     "detail": "RTF is written in reading order; the page layout is not reproduced"}]
        if self.stats["comments"]:
            warnings.append({"code": "RTF_COMMENTS_AS_TEXT", "count": self.stats["comments"],
                             "detail": "comments are paragraphs in a 'Comments (page N)' section, not annotations"})
        stats = dict(self.stats)
        stats["max_picture_dpi"] = MAX_PICTURE_DPI
        stats["warnings"] = warnings
        stats["font_substitution"] = "mapped from PDF font names to Arial, Times New Roman or Courier New"
        return stats


def write_rtf(doc, path: Path) -> dict:
    return _Writer(doc).write(Path(path))
