"""PowerPoint writer: one slide per page, built on the layout-preserving page
decomposition shared with layout DOCX and Preserve-layout HTML.

* **editable** (default): filled rectangles and rules are rectangle shapes,
  pictures are pictures (with the labels they keep as their description), all
  in the source's paint order; above them every paragraph block is one text
  box whose paragraphs are the source's lines, never re-wrapped, each at its
  measured position. Table cells are text boxes over the drawn rules and
  shading. A scan's OCR layer is transparent, selectable text.
* **page_image**: the page's drawing without its text and pictures is one
  background picture; pictures and editable text are placed over it as in
  editable mode. Complex vector drawing survives exactly; only text and
  pictures are separate objects.

A presentation has one slide size: the largest of the pages within 10 % of
the most common displayed size. Those pages are placed unscaled at the top
left (PPTX_PAGE_PADDED when smaller); a page further off is scaled uniformly
to fit and centred (PPTX_PAGE_SCALED). A page
displayed rotated is one group turned by the display rotation. Comments go to
the slide's speaker notes (PPTX_COMMENTS_AS_NOTES).

Vertical placement follows PowerPoint for Mac's measured behaviour with exact
line spacing S (results/pptx-cal, PROGRESS.md increment 16): the first
baseline lies 0.721·S + 0.060·size below the text box top, and each further
line S (plus its space-before) below the previous one. Keynote truncates both
to whole points, so both are written in whole points with each line's
rounding carried to the next.
"""
from __future__ import annotations

import io
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_AUTO_SIZE
from pptx.oxml.ns import qn
from pptx.util import Emu, Pt

from ..geometry import BBox
from ..layout_preserve import TextLine, lines_from_chars
from .docx_layout_writer import MAX_PICTURE_DPI, _crop_png, _fit_picture, _item_lines, _row_box, _tab
from .html_writer import _DESCENT, _family, _width

EMU_PER_PT = 12700
_BASELINE_S = 0.721        # first baseline below the box top, per point of line spacing
_BASELINE_SIZE = 0.060     # … plus this per point of font size
_SPC_LIMIT = (-1.5, 3.0)   # character spacing (pt) used to fit a line to its measured width


def _emu(v: float) -> Emu:
    return Emu(int(round(v * EMU_PER_PT)))


class _Place:
    """Page (upright layout) points → slide EMU: a uniform scale and an offset."""

    def __init__(self, scale: float = 1.0, ox: float = 0.0, oy: float = 0.0):
        self.s, self.ox, self.oy = scale, ox, oy

    def x(self, v: float) -> Emu:
        return _emu(self.ox + v * self.s)

    def y(self, v: float) -> Emu:
        return _emu(self.oy + v * self.s)

    def d(self, v: float) -> Emu:
        return _emu(max(v, 0.0) * self.s)


def _baseline(ln: TextLine, size: float) -> float:
    text = "".join(r.get("text", "") for r in ln.runs)
    return ln.lbox.y1 - max((_DESCENT.get(ch, 0.0) for ch in text), default=0.0) * size


def _line_size(ln: TextLine) -> float:
    return max((r.get("size") or 0) for r in ln.runs) or ln.lbox.height or 8.0


def _segments(ln: TextLine) -> list[tuple[float, list[dict]]]:
    """A line's pieces: runs up to a tab stop, then each tab-positioned piece."""
    segs: list[tuple[float, list[dict]]] = [(ln.lbox.x0, [])]
    for r in ln.runs:
        if r.get("tab_to") is not None:
            segs.append((r["tab_to"], []))
        elif r.get("text"):
            segs[-1][1].append(r)
    return [(x, runs) for x, runs in segs if "".join(r["text"] for r in runs).strip()]


def _merge_rows(lines: list[TextLine]) -> list[TextLine]:
    """Lines sharing a text row become one line; pieces in x order join with no
    space when they touch, a space when the gap is a word space, and a tab stop
    at the measured position otherwise (a list marker and its text). Tighter
    than the layout DOCX rule: a PowerPoint line has no hanging indent to
    absorb a marker's gap."""
    rows: list[list[TextLine]] = []
    for ln in sorted(lines, key=lambda l: (l.lbox.y0, l.lbox.x0)):
        if rows:
            ref = rows[-1][0]
            ov = min(ref.lbox.y1, ln.lbox.y1) - max(ref.lbox.y0, ln.lbox.y0)
            if ov > 0.5 * min(ref.lbox.height, ln.lbox.height):
                rows[-1].append(ln)
                continue
        rows.append([ln])
    out: list[TextLine] = []
    for row in rows:
        merged: list[TextLine] = []
        for ln in sorted(row, key=lambda l: l.lbox.x0):
            if merged and ln.lbox.x0 >= merged[-1].lbox.x1 - 2:
                prev = merged[-1]
                gap = ln.lbox.x0 - prev.lbox.x1
                size = max((r.get("size") or 8.0 for r in ln.runs), default=8.0)
                if gap < 0.12 * size:
                    joint: list[dict] = []
                elif gap < 0.6 * size:
                    joint = [{"text": " ", "font": "", "size": size, "bold": False, "italic": False}]
                else:
                    joint = [_tab(ln.lbox.x0)]
                merged[-1] = TextLine(prev.runs + joint + ln.runs, _row_box(prev, ln), prev.align,
                                      prev.anchor or ln.anchor)
            else:
                merged.append(TextLine(list(ln.runs), ln.lbox, ln.align, ln.anchor))
        out.extend(merged)
    return out


class _Slide:
    def __init__(self, writer: "_Writer", slide, place: _Place, container):
        self.w, self.slide, self.p, self.shapes = writer, slide, place, container

    # -- drawing -------------------------------------------------------------
    def rect(self, box: BBox, rgb, alpha: int = 255) -> None:
        if box.width < 0.05 or box.height < 0.05:
            return
        sh = self.shapes.add_shape(MSO_SHAPE.RECTANGLE, self.p.x(box.x0), self.p.y(box.y0),
                                   max(self.p.d(box.width), Emu(1)), max(self.p.d(box.height), Emu(1)))
        style = sh._element.find(qn("p:style"))
        if style is not None:
            sh._element.remove(style)                 # no theme line, shadow or text colour
        sh.fill.solid()
        sh.fill.fore_color.rgb = RGBColor(*(int(v) for v in rgb))
        if alpha < 250:
            clr = sh.fill._xPr.find(qn("a:solidFill"))[0]
            a = clr.makeelement(qn("a:alpha"), {"val": str(int(alpha / 255 * 100000))})
            clr.append(a)
        sh.line.fill.background()

    def picture(self, png: bytes, box: BBox, descr: str = "", page_box: BBox | None = None) -> None:
        if box.width < 0.1 or box.height < 0.1:
            return
        if page_box is not None:
            keep = BBox(max(box.x0, page_box.x0), max(box.y0, page_box.y0),
                        min(box.x1, page_box.x1), min(box.y1, page_box.y1))
            if keep.width < 0.5 or keep.height < 0.5:
                return
            if (keep.x0, keep.y0, keep.x1, keep.y1) != (box.x0, box.y0, box.x1, box.y1):
                png = _crop_png(png, box, keep)
                box = keep
        data = _fit_picture(png, box.width * self.p.s, box.height * self.p.s, self.w.stats)
        pic = self.shapes.add_picture(io.BytesIO(data), self.p.x(box.x0), self.p.y(box.y0),
                                      self.p.d(box.width), self.p.d(box.height))
        if descr:
            pic._element.nvPicPr.cNvPr.set("descr", descr)
        self.w.stats["images"] += 1

    # -- text ----------------------------------------------------------------
    def text_box(self, lines: list[TextLine], transparent: bool = False) -> None:
        # pieces sharing a row (a list marker and its text) become one line with tab stops
        rows = [(ln, _segments(ln)) for ln in _merge_rows([ln for ln in lines if ln.runs])]
        rows = [(ln, segs) for ln, segs in rows if segs]
        if not rows:
            return
        rows.sort(key=lambda r: r[0].lbox.y0)
        sizes = [_line_size(ln) for ln, _ in rows]
        bases = [_baseline(ln, s) for (ln, _), s in zip(rows, sizes)]
        pitches = [b - a for a, b in zip(bases, bases[1:])]
        s = self.p.s
        # whole-point spacing on the slide: Keynote truncates exact line spacing and
        # space-before to whole points (PowerPoint keeps fractions), so both are whole
        # points and each line's rounding error is carried to the next (±0.5 pt in both)
        spacing_pt = max(1, int(max(min(pitches), 0.9 * max(sizes)) * s)) if pitches else max(1, int(1.2 * sizes[0] * s))
        spacing = spacing_pt / s
        before: list[int] = [0]
        pos = bases[0] * s
        for b in bases[1:]:
            extra = max(0, round(b * s - (pos + spacing_pt)))
            before.append(extra)
            pos += spacing_pt + extra
        left = min(segs[0][0] for _, segs in rows)
        right = max(ln.lbox.x1 for ln, _ in rows)
        top = bases[0] - (_BASELINE_S * spacing + _BASELINE_SIZE * sizes[0])
        bottom = bases[-1] + 0.3 * sizes[-1]
        tb = self.shapes.add_textbox(self.p.x(left), self.p.y(top),
                                     self.p.d(right - left + 2.0), self.p.d(bottom - top))
        tf = tb.text_frame
        tf.word_wrap = False
        tf.auto_size = MSO_AUTO_SIZE.NONE
        tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
        for k, ((ln, segs), size) in enumerate(zip(rows, sizes)):
            para = tf.paragraphs[0] if k == 0 else tf.add_paragraph()
            para.line_spacing = Pt(spacing_pt)
            para.space_after = Pt(0)
            para.space_before = Pt(before[k])
            indent = segs[0][0] - left
            ppr = para._p.get_or_add_pPr()
            if indent > 0.05:
                ppr.set("marL", str(int(round(indent * s * EMU_PER_PT))))
            if len(segs) > 1:
                # a marker and its text, a label and its value: one line with tab stops
                # at the measured positions (PowerPoint measures them from the box's left edge)
                tabs = ppr.makeelement(qn("a:tabLst"), {})
                for x, _runs in segs[1:]:
                    tabs.append(tabs.makeelement(qn("a:tab"), {"pos": str(int(round((x - left) * s * EMU_PER_PT))),
                                                               "algn": "l"}))
                ppr.append(tabs)
            for i, (x, seg_runs) in enumerate(segs):
                end = segs[i + 1][0] - 1.0 if i + 1 < len(segs) else ln.lbox.x1
                self._runs(para, seg_runs, end - x, last=i + 1 == len(segs), tab=i > 0, transparent=transparent)
        self.w.stats["text_boxes"] += 1
        self.w.stats["lines"] += len(rows)

    def _runs(self, para, runs: list[dict], target: float, last: bool, tab: bool, transparent: bool) -> None:
        runs = [r for r in runs if r.get("text")]
        if runs:
            runs = [dict(runs[0], text=runs[0]["text"].lstrip())] + runs[1:]
        glyphs = len("".join(r["text"] for r in runs).strip())
        spc = 0.0
        if glyphs > 2:                                 # an OCR layer too: selection follows the scan's words
            est = _width(runs)
            if est > 0 and target > 0:
                spc = (target - est) / max(glyphs - 1, 1)
                if not last:
                    spc = min(spc, 0.0)                # only squeeze a piece that must end before the next stop
                spc = min(max(spc, _SPC_LIMIT[0]), _SPC_LIMIT[1])
        for j, r in enumerate(runs):
            fam, fb, fi = _family(r.get("font", ""))
            run = para.add_run()
            run.text = ("\t" if tab and j == 0 else "") + r["text"]
            f = run.font
            f.name = fam
            f.size = Pt(max((r.get("size") or 8.0) * self.p.s, 1.0))
            f.bold = bool(r.get("bold") or fb)
            f.italic = bool(r.get("italic") or fi)
            rpr = run._r.get_or_add_rPr()
            if abs(spc) > 0.01:
                rpr.set("spc", str(int(round(spc * self.p.s * 100))))
            if r.get("strike"):
                rpr.set("strike", "sngStrike")
            if r.get("underline"):
                f.underline = True
            color = r.get("color")
            if transparent:
                f.color.rgb = RGBColor(0, 0, 0)
                clr = rpr.find(qn("a:solidFill"))[0]
                clr.append(clr.makeelement(qn("a:alpha"), {"val": "0"}))
            elif color and sum(color) > 30:
                f.color.rgb = RGBColor(*(int(v) for v in color))
            hl = r.get("highlight")
            if hl and not transparent:
                h = rpr.makeelement(qn("a:highlight"), {})
                h.append(h.makeelement(qn("a:srgbClr"), {"val": "%02X%02X%02X" % tuple(int(v) for v in hl)}))
                rpr.append(h)
            if r.get("uri") and not transparent:
                run.hyperlink.address = r["uri"]
                self.w.stats["links"] += 1


class _Writer:
    def __init__(self, doc, mode: str):
        self.doc, self.mode = doc, mode
        self.stats = {"pages": 0, "slides": 0, "text_boxes": 0, "lines": 0, "ocr_lines": 0, "images": 0,
                      "fills": 0, "rules": 0, "links": 0, "comments": 0, "mode": mode}
        self.warnings: list[dict] = []

    def write(self, path: Path) -> dict:
        prs = Presentation()
        layouts = list(getattr(self.doc, "layouts", None) or [])
        if not layouts:
            raise ValueError("PPTX needs the layout-preserving decomposition (layout_mode='preserve')")
        selected = [p.source_index for p in getattr(self.doc, "pages", [])] or list(range(1, len(layouts) + 1))
        # the slide: the largest of the pages within 10 % of the most common displayed
        # size (ties: the earliest), so near-equal pages (a scan's) are placed unscaled
        sizes = [tuple(round(v, 1) for v in self._displayed(l)) for l in layouts]
        cw, ch = max(sizes, key=lambda z: (sizes.count(z), -sizes.index(z)))
        near = [(w, h) for w, h in sizes if abs(w - cw) <= 0.1 * cw and abs(h - ch) <= 0.1 * ch]
        sw, sh = max(w for w, _ in near), max(h for _, h in near)
        prs.slide_width, prs.slide_height = _emu(sw), _emu(sh)
        blank = prs.slide_layouts[6]
        noted = 0
        for k, layout in enumerate(layouts):
            page_no = selected[k] if k < len(selected) else k + 1
            self.stats["pages"] = k + 1
            slide = prs.slides.add_slide(blank)
            dw, dh = self._displayed(layout)
            scale, ox, oy = 1.0, 0.0, 0.0
            if dw <= sw + 0.5 and dh <= sh + 0.5:
                if sw - dw > 0.5 or sh - dh > 0.5:
                    self.warnings.append({"code": "PPTX_PAGE_PADDED", "page": page_no,
                                          "slide_margin_pt": [round(sw - dw, 1), round(sh - dh, 1)],
                                          "detail": "a presentation has one slide size; this smaller page is "
                                                    "placed unscaled at the top left, the rest of the slide empty"})
            else:
                scale = min(sw / dw, sh / dh)
                ox, oy = (sw - dw * scale) / 2, (sh - dh * scale) / 2
                self.warnings.append({"code": "PPTX_PAGE_SCALED", "page": page_no, "scale": round(scale, 4),
                                      "detail": "a presentation has one slide size; this page differs from the "
                                                "others by more than 10 % and is scaled to fit and centred"})
            rot = layout.rotation if layout.rotation in (90, 270) else 0
            if rot:
                group = slide.shapes.add_group_shape()
                self._page(_Slide(self, slide, _Place(scale), group.shapes), layout)
                self._turn(group, layout, scale, ox, oy, rot)
            else:
                self._page(_Slide(self, slide, _Place(scale, ox, oy), slide.shapes), layout)
            notes = [c for c in getattr(layout, "comments", [])]
            if notes:
                text = "\n".join(f"Comment{(' by ' + c.author) if getattr(c, 'author', None) else ''}: {c.text}"
                                 for c in notes)
                slide.notes_slide.notes_text_frame.text = text
                self.stats["comments"] += len(notes)
                noted += len(notes)
            self.stats["slides"] += 1
        if noted:
            self.warnings.append({"code": "PPTX_COMMENTS_AS_NOTES", "count": noted,
                                  "detail": "comments are written to each slide's speaker notes, not as PowerPoint comments"})
        _drop_printer_settings(prs)
        _list_notes_master(prs)
        prs.save(str(path))
        out = dict(self.stats)            # images_downsampled_*: disclosed per page by the worker
        out["max_picture_dpi"] = MAX_PICTURE_DPI
        out["warnings"] = self.warnings
        return out

    @staticmethod
    def _displayed(layout) -> tuple[float, float]:
        return (layout.height, layout.width) if layout.rotation in (90, 270) else (layout.width, layout.height)

    @staticmethod
    def _turn(group, layout, scale: float, ox: float, oy: float, rot: int) -> None:
        """The upright page as one group turned about its centre: /Rotate 90 turns
        it clockwise, as PowerPoint's positive rotation does."""
        w, h = layout.width * scale, layout.height * scale
        cx, cy = ox + h / 2, oy + w / 2              # the displayed page's centre
        xfrm = group._element.grpSpPr.get_or_add_xfrm()
        xfrm.set("rot", str(rot * 60000))
        off, ext = xfrm.get_or_add_off(), xfrm.get_or_add_ext()
        off.x, off.y = _emu(cx - w / 2), _emu(cy - h / 2)
        ext.cx, ext.cy = _emu(w), _emu(h)
        ch_off = xfrm.find(qn("a:chOff")) if xfrm.find(qn("a:chOff")) is not None else xfrm._add_chOff()
        ch_ext = xfrm.find(qn("a:chExt")) if xfrm.find(qn("a:chExt")) is not None else xfrm._add_chExt()
        ch_off.x, ch_off.y = 0, 0
        ch_ext.cx, ch_ext.cy = _emu(w), _emu(h)

    def _page(self, sl: _Slide, layout) -> None:
        page_box = BBox(0, 0, layout.width, layout.height)
        drawn: list[tuple[int, int, object]] = []    # (z, order, callable)
        n = 0
        if self.mode == "page_image" and getattr(layout, "drawing_png", None):
            png = layout.drawing_png
            drawn.append((-10 ** 9, n, lambda png=png: sl.picture(png, page_box))); n += 1
        else:
            for f in getattr(layout, "page_fills", []):
                if f.lbox.width < 0.1 or f.lbox.height < 0.1:
                    continue
                png = getattr(f, "png", None)
                z = getattr(f, "z", 0)
                if png is not None:
                    drawn.append((z, n, lambda f=f, png=png: sl.picture(png, f.lbox, page_box=page_box)))
                else:
                    drawn.append((z, n, lambda f=f: sl.rect(f.lbox, f.rgb, getattr(f, "alpha", 255))))
                n += 1
                self.stats["fills"] += 1
            for r in getattr(layout, "page_rules", []):
                drawn.append((getattr(r, "z", 0), n, lambda r=r: sl.rect(r.lbox, getattr(r, "rgb", (0, 0, 0)))))
                n += 1
                self.stats["rules"] += 1
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
                if self.mode == "page_image":
                    continue                           # a drawing under the text: in the background already
                z = -10
            elif getattr(im, "origin", "image") == "vector":
                z = 10 ** 9
            else:
                z = getattr(im, "z", 0)
            drawn.append((z, n, lambda it=it, im=im: sl.picture(im.png_bytes, it.lbox, getattr(im, "absorbed_text", ""),
                                                                page_box)))
            n += 1
        for _z, _n, draw in sorted(drawn, key=lambda d: (d[0], d[1])):
            draw()
        groups: list[list[TextLine]] = []            # paragraph text boxes, in page order
        group_of: dict[int, int] = {}                 # layout block → its group
        for band in layout.bands:
            for it in band.items:
                if it.kind == "figure":
                    continue
                if it.kind == "block":
                    # lines of one paragraph split by wide spacing share a box (layout.continues)
                    prev = getattr(it.payload, "continues", None)
                    g = group_of.get(id(prev)) if prev is not None else None
                    if g is None:
                        g = group_of.get(id(it.payload))
                    if g is None:
                        groups.append([]); g = len(groups) - 1
                    group_of[id(it.payload)] = g
                    groups[g].extend(_item_lines(it))
                    continue
                if it.kind == "table":
                    for c in it.payload.cells:
                        lines = lines_from_chars(c.chars)
                        for v in getattr(c, "values", []) or []:
                            lines.append(TextLine([{"text": v["text"], "font": v.get("font", ""),
                                                    "size": v.get("size", 8.0), "bold": v.get("bold", False),
                                                    "italic": False}], v["lbox"]))
                        sl.text_box(lines)
                else:
                    sl.text_box(_item_lines(it))
        for lines in groups:
            sl.text_box(lines)
        for ln in getattr(layout, "hidden", []):
            sl.text_box([ln], transparent=True)
            self.stats["ocr_lines"] += 1


def _list_notes_master(prs) -> None:
    """python-pptx creates the notes master without listing it in presentation.xml
    (<p:notesMasterIdLst>); PowerPoint tolerates that, Keynote 14 and 15 refuse to
    open the file at all (isolated with a one-slide deck, PROGRESS.md increment 16)."""
    pres = prs.part._element
    if pres.find(qn("p:notesMasterIdLst")) is not None:
        return
    rid = next((r.rId for r in prs.part.rels.values() if r.reltype.endswith("/notesMaster")), None)
    if rid is None:
        return
    lst = pres.makeelement(qn("p:notesMasterIdLst"), {})
    nm = lst.makeelement(qn("p:notesMasterId"), {})
    nm.set(qn("r:id"), rid)
    lst.append(nm)
    masters = pres.find(qn("p:sldMasterIdLst"))
    if masters is not None:
        masters.addnext(lst)
    else:
        pres.insert(0, lst)


def _drop_printer_settings(prs) -> None:
    """python-pptx's default template carries a binary printer-settings part
    (printerSettings1.bin); the output needs no binary parts."""
    part = prs.part
    for rel in list(part.rels.values()):
        if rel.reltype.endswith("/printerSettings"):
            part.drop_rel(rel.rId)


def write_pptx(doc, path: Path, mode: str = "editable") -> dict:
    if mode not in ("editable", "page_image"):
        raise ValueError(f"unknown PPTX mode {mode!r}")
    return _Writer(doc, mode).write(Path(path))
