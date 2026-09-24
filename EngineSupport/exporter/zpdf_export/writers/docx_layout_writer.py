"""Layout-preserving DOCX writer (spec §9, ``layout_mode: "preserve"``).

Each source page becomes a Word section of the same size and margins. Bands
are emitted top to bottom: ruled grids as fixed-layout tables with measured
column widths, row heights, per-edge borders and cell shading; side-by-side
content as borderless fixed-layout tables; single blocks as paragraphs with
exact spacing. Fonts are mapped from the PDF font names. Everything remains
editable text; images are inline pictures at source size.
"""
from __future__ import annotations

import io
from pathlib import Path

from docx import Document as DocxDocument
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_TAB_ALIGNMENT, WD_TAB_LEADER, WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.opc.constants import RELATIONSHIP_TYPE as RT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Emu, Pt, RGBColor

from ..fonts import installed_family, map_font, text_width
from ..geometry import BBox
from ..layout_preserve import token_runs, Band, Item, PageLayout, TextLine, lines_from_chars

TWIP = 20  # twips per point
_CELL_PAD = 1.5  # pt


def _twips(pt: float) -> int:
    return max(0, int(round(pt * TWIP)))


def _set_cell_width(cell, width_pt: float) -> None:
    tcPr = cell._tc.get_or_add_tcPr()
    tcW = tcPr.find(qn("w:tcW"))
    if tcW is None:
        tcW = OxmlElement("w:tcW"); tcPr.append(tcW)
    tcW.set(qn("w:w"), str(_twips(width_pt))); tcW.set(qn("w:type"), "dxa")


def _add_table(container, rows: int, cols: int):
    """A table in the body or in a cell. python-docx appends an empty paragraph
    after a table added to a cell; Word requires it (a cell ending with a table
    is "unreadable content"), but at its default height it would take a line of
    its own, so it is made the smallest exact line instead."""
    if hasattr(container, "_tc"):
        table = container.add_table(rows, cols)
        trailing = container._tc[-1]
        if trailing.tag == qn("w:p") and not trailing.xpath(".//w:t"):
            from docx.text.paragraph import Paragraph
            _fmt_paragraph(Paragraph(trailing, container), 0.0, 0.5)
        return table
    return container.add_table(rows=rows, cols=cols)


def _fit_scale(ln: TextLine, available: float) -> float | None:
    """Character scale (0.5–1) that keeps a measured line on one line in Word's
    fonts, or None when it already fits. Lines with positioned segments (tabs)
    are not scaled."""
    if any(r.get("tab_to") is not None for r in ln.runs):
        return None
    est = sum(_run_width(r) for r in ln.runs)
    # Word's setting of the same TrueType differs from the advance sum by a
    # fraction of a percent (twip rounding); keep 1.5 % clear of the room
    target = min(available * 0.985 - 1.0, ln.lbox.width * 1.05) if available > 0 else ln.lbox.width * 1.05
    if est <= target or target <= 0:
        return None
    return max(0.5, target / est)


def _run_width(r: dict) -> float:
    family, fbold, fitalic = map_font(r.get("font", ""))
    family = installed_family(family)
    return text_width(r["text"], family or "Arial", r.get("size") or 8.0,
                      bool(r.get("bold") or fbold), bool(r.get("italic") or fitalic))


def _segment_scales(ln: TextLine, runs: list[dict], right_edge: float) -> list[float | None]:
    """Per-run character scale for a line with positioned segments: each
    segment between tab stops is condensed to the room it has in Word's fonts
    (to the next stop, or to the line's end), so a wide stand-in font cannot
    push a segment past its stop and wrap the line. Segments that fit are None."""
    segs: list[list[int]] = [[]]
    for k, r in enumerate(runs):
        if r.get("tab_to") is not None:
            segs.append([k]); segs.append([])
        else:
            segs[-1].append(k)
    scales: list[float | None] = [None] * len(runs)
    start = ln.lbox.x0
    for i in range(0, len(segs), 2):
        text_idx = segs[i]
        tab = runs[segs[i + 1][0]] if i + 1 < len(segs) else None
        if tab is None:
            avail = max(right_edge, ln.lbox.x1) - start - 1.0
        elif tab.get("tab_align") == "right":
            nxt = segs[i + 2] if i + 2 < len(segs) else []
            avail = tab["tab_to"] - start - sum(_run_width(runs[k]) for k in nxt) - 2.0
        else:
            avail = tab["tab_to"] - start - 1.0
        est = sum(_run_width(runs[k]) for k in text_idx)
        if text_idx and est > avail > 0:
            sc = max(0.5, avail / est)
            for k in text_idx:
                scales[k] = sc
        if tab is not None:
            start = tab["tab_to"] if tab.get("tab_align") != "right" else start
    return scales


def _set_table_fixed(table, col_widths_pt: list[float]) -> None:
    tbl = table._tbl
    tblPr = tbl.tblPr
    layout = OxmlElement("w:tblLayout"); layout.set(qn("w:type"), "fixed"); tblPr.append(layout)
    # zero cell margins: Word adds margins on top of exact row heights, which
    # inflates every row (Acrobat's export also uses 0); text is indented instead
    mar = OxmlElement("w:tblCellMar")
    for side in ("top", "left", "bottom", "right"):
        el = OxmlElement(f"w:{side}"); el.set(qn("w:w"), "0"); el.set(qn("w:type"), "dxa"); mar.append(el)
    tblPr.append(mar)
    tblW = tblPr.find(qn("w:tblW"))
    if tblW is None:
        tblW = OxmlElement("w:tblW"); tblPr.append(tblW)
    tblW.set(qn("w:w"), str(_twips(sum(col_widths_pt)))); tblW.set(qn("w:type"), "dxa")
    grid = tbl.tblGrid
    for gc in list(grid):
        grid.remove(gc)
    for w in col_widths_pt:
        gc = OxmlElement("w:gridCol"); gc.set(qn("w:w"), str(_twips(w))); grid.append(gc)


def _set_table_indent(table, indent_pt: float) -> None:
    tblPr = table._tbl.tblPr
    ind = OxmlElement("w:tblInd"); ind.set(qn("w:w"), str(_twips(indent_pt))); ind.set(qn("w:type"), "dxa")
    tblPr.append(ind)


def _set_row_height(row, height_pt: float, exact: bool) -> None:
    trPr = row._tr.get_or_add_trPr()
    h = OxmlElement("w:trHeight"); h.set(qn("w:val"), str(_twips(height_pt)))
    h.set(qn("w:hRule"), "exact" if exact else "atLeast"); trPr.append(h)


def _set_borders(cell, edges: dict[str, bool], size_eighths: int = 6) -> None:
    tcPr = cell._tc.get_or_add_tcPr()
    borders = OxmlElement("w:tcBorders")
    for side in ("top", "left", "bottom", "right"):
        el = OxmlElement(f"w:{side}")
        if edges.get(side):
            el.set(qn("w:val"), "single"); el.set(qn("w:sz"), str(size_eighths)); el.set(qn("w:color"), "000000")
        else:
            el.set(qn("w:val"), "nil")
        borders.append(el)
    tcPr.append(borders)


def _set_nowrap(cell) -> None:
    tcPr = cell._tc.get_or_add_tcPr()
    tcPr.append(OxmlElement("w:noWrap"))


def _set_shading(cell, rgb: tuple[int, int, int]) -> None:
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd"); shd.set(qn("w:val"), "clear"); shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "%02X%02X%02X" % rgb); tcPr.append(shd)


def _no_table_borders(table) -> None:
    tblPr = table._tbl.tblPr
    b = OxmlElement("w:tblBorders")
    for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
        el = OxmlElement(f"w:{side}"); el.set(qn("w:val"), "nil"); b.append(el)
    tblPr.append(b)


def _fmt_paragraph(p, space_before_pt: float = 0.0, line_pt: float | None = None, align: str = "left") -> None:
    pf = p.paragraph_format
    pf.space_before = Pt(max(0.0, space_before_pt)); pf.space_after = Pt(0)
    if line_pt:
        pf.line_spacing_rule = WD_LINE_SPACING.EXACTLY; pf.line_spacing = Pt(line_pt)
    pf.alignment = {"center": WD_ALIGN_PARAGRAPH.CENTER, "right": WD_ALIGN_PARAGRAPH.RIGHT}.get(align, WD_ALIGN_PARAGRAPH.LEFT)


def _add_runs(p, runs: list[dict], stats: dict, left_x: float | None = None, scale=None) -> list:
    """Write runs into a paragraph with their measured typography: mapped font,
    size, weight, the PDF's text colour, underline (a rule under the glyphs),
    and a working hyperlink when the glyphs sit under a link annotation (the
    link keeps the source's own styling; nothing blue is invented). Returns the
    python-docx runs so comments can anchor to them."""
    written = []
    for idx, r in enumerate(runs):
        if not r["text"]:
            continue
        run_scale = scale[idx] if isinstance(scale, list) else scale   # one scale per line, or per run (segments)
        if r.get("tab_to") is not None and left_x is not None:
            # Word measures tab stops from the text margin (cell or column edge),
            # not from the paragraph's left indent
            pos = r["tab_to"] - left_x
            if pos > 0:
                leader = WD_TAB_LEADER.LINES if r.get("leader") == "underscore" else WD_TAB_LEADER.SPACES
                kind = WD_TAB_ALIGNMENT.RIGHT if r.get("tab_align") == "right" else WD_TAB_ALIGNMENT.LEFT
                p.paragraph_format.tab_stops.add_tab_stop(Pt(pos), kind, leader)
        run = p.add_run(r["text"])
        family, fbold, fitalic = map_font(r.get("font", ""))
        family = installed_family(family)   # name a font Word has, so it lays out what was measured
        if family:
            run.font.name = family
            rpr = run._r.get_or_add_rPr()
            rfonts = rpr.find(qn("w:rFonts"))
            if rfonts is None:
                rfonts = OxmlElement("w:rFonts"); rpr.append(rfonts)
            rfonts.set(qn("w:hAnsi"), family); rfonts.set(qn("w:cs"), family)
            stats.setdefault("fonts", {})[r.get("font", "")] = family
        size = r.get("size") or 0
        if size:
            run.font.size = Pt(round(size * 2) / 2)
        run.bold = bool(r.get("bold") or fbold) or None
        run.italic = bool(r.get("italic") or fitalic) or None
        color = r.get("color")
        if color and sum(color) > 90:   # near-black stays the default text colour
            run.font.color.rgb = RGBColor(*color)
        if r.get("underline"):
            run.underline = True
        if r.get("strike"):
            run.font.strike = True
        hl = r.get("highlight")
        if hl:
            # the source's highlight colour as run shading (Word's highlighter has a fixed palette)
            rpr = run._r.get_or_add_rPr()
            shd = OxmlElement("w:shd"); shd.set(qn("w:val"), "clear"); shd.set(qn("w:color"), "auto")
            shd.set(qn("w:fill"), "%02X%02X%02X" % tuple(int(v) for v in hl))
            rpr.insert_element_before(shd, "w:fitText", "w:vertAlign", "w:rtl", "w:cs", "w:em", "w:lang",
                                      "w:eastAsianLayout", "w:specVanish", "w:oMath")
        if run_scale is not None and run_scale < 0.995:
            rpr = run._r.get_or_add_rPr()
            w = OxmlElement("w:w"); w.set(qn("w:val"), str(int(round(run_scale * 100))))
            # schema order: Word refuses the file ("unreadable content") when the
            # scale follows the size
            rpr.insert_element_before(w, "w:kern", "w:position", "w:sz", "w:szCs", "w:highlight", "w:u", "w:effect",
                                      "w:bdr", "w:shd", "w:fitText", "w:vertAlign", "w:rtl", "w:cs", "w:em", "w:lang",
                                      "w:eastAsianLayout", "w:specVanish", "w:oMath")
            stats["lines_condensed"] = stats.get("lines_condensed", 0) + 1
        uri = r.get("uri")
        if uri:
            r_id = p.part.relate_to(uri, RT.HYPERLINK, is_external=True)
            link = OxmlElement("w:hyperlink"); link.set(qn("r:id"), r_id)
            run._r.addprevious(link); link.append(run._r)
            stats["links"] = stats.get("links", 0) + 1
        written.append(run)
    if "_lines" in stats:
        stats["_lines"][-1][1].extend(written)
    return written


def _glyph_top_offset(height: float, size: float) -> float:
    """Word centers a line's natural box inside an exact line height; the glyph
    top then sits below the paragraph top by about (h − 1.15·size)/2 + 0.2·size
    (calibrated against Word's own PDF export)."""
    return (height - 1.15 * size) / 2 + 0.2 * size


def _line_heights(lines: list[TextLine], bottom: float | None = None) -> list[float]:
    """Exact paragraph heights from measured line pitch so a block of lines
    occupies exactly its source height: pitch to the next line, and for the
    last line the distance to ``bottom`` (or its own glyph height). Word honors
    exact heights smaller than the font size, so no font-size floor is applied."""
    out: list[float] = []
    for i, ln in enumerate(lines):
        if i + 1 < len(lines):
            h = lines[i + 1].lbox.y0 - ln.lbox.y0
        elif bottom is not None:
            h = bottom - ln.lbox.y0
        else:
            h = ln.lbox.height * 1.15
        out.append(max(h, 1.0))
    return out


NATURAL = 1.15   # Word's line box height relative to the font size (Arial/Times)
# paragraphs outside the bands, in points: Word's smallest exact line is 0.5 pt
HOST_PARA = 0.5      # carries the page's anchored pictures
HIDDEN_PARA = 0.5    # the page's invisible (OCR) text, hidden
BREAK_PARA = 0.5     # carries the section break to the next page
# Word centres the natural line box (1.15 × size) in an exact height and sets the
# glyph top 0.2 × size below the box top: at 0.85 × size the glyph top lands
# exactly on the line top, so nothing is clipped; below that, caps lose their tops
MIN_LINE = 0.85


def _line_layout(lines: list[TextLine], bottom: float | None = None) -> list[tuple[float, float]]:
    """(exact paragraph height, filler after it) per line. A pitch far larger
    than the font (a label above a tall field, a heading over white space) is
    not one tall paragraph: Word would centre the glyphs in it. The line keeps a
    normal height and an empty exact paragraph fills the rest."""
    out: list[tuple[float, float]] = []
    for ln, h in zip(lines, _line_heights(lines, bottom)):
        size = max((r["size"] for r in ln.runs), default=8.0)
        if h > 2.2 * size:
            normal = max(NATURAL * size, min(h, ln.lbox.height * 1.15))
            out.append((normal, h - normal))
        else:
            # never shorter than the font size: Word clips the glyph tops of a
            # shorter exact line (a caps-only word measured by its glyph box
            # would lose its top); tightly leaded body text keeps its pitch, and
            # so do glyphs whose box is far smaller than their size (text set
            # sideways, whose size is not its height)
            # the floor applies only to a line standing on its own: when the next
            # line starts inside this one's glyph box (letters of a sideways label
            # stacked a few points apart, or two overlapping rows) the pitch stays
            upright = ln.lbox.height >= 0.5 * size and h >= ln.lbox.height - 0.5
            out.append((max(h, MIN_LINE * size) if upright else h, 0.0))
    return out


def _lines_total(lines: list[TextLine], first_space_before: float, bottom: float | None) -> float:
    """Height _write_lines will emit for these lines (gap included)."""
    return first_space_before + sum(h + f for h, f in _line_layout(lines, bottom))


def _first_line_shift(lines: list[TextLine], heights: list[float]) -> float:
    """How much earlier the first paragraph must start so its glyph top lands on
    the measured y0 (see _glyph_top_offset)."""
    if not lines:
        return 0.0
    size = max((r["size"] for r in lines[0].runs), default=8.0)
    return max(0.0, _glyph_top_offset(heights[0], size))


def _filler(container, height: float) -> None:
    p = container.add_paragraph()
    _fmt_paragraph(p, 0.0, max(height, 0.5))
    p.add_run(" ").font.size = Pt(1)


def _write_lines(container, lines: list[TextLine], stats: dict, first_space_before: float = 0.0,
                 container_box: BBox | None = None, first_paragraph=None, bottom: float | None = None,
                 indent: float | None = None) -> float:
    """Emit visual lines as paragraphs with exact line spacing equal to the
    measured pitch; source line breaks are kept. ``indent`` (pt) offsets
    left-aligned lines inside a cell to their measured x position. Returns the
    part of the glyph-position shift the gap before could not absorb (the text
    lands that much lower than measured); page-level callers budget it."""
    layout = _line_layout(lines, bottom)
    heights = [h for h, _f in layout]
    shift = _first_line_shift(lines, heights)
    lead = max(0.0, first_space_before - shift)
    surplus = max(0.0, shift - first_space_before)
    heights[-1] = max(1.0, heights[-1] + first_space_before - lead)  # keep the block's bottom where it was
    for i, ln in enumerate(lines):
        p = first_paragraph if (i == 0 and first_paragraph is not None) else container.add_paragraph()
        align = ln.align if container_box is None else _align(ln.lbox, container_box)
        runs = ln.runs
        if any(r.get("tab_to") is not None for r in runs):
            # the stops position the segments: the paragraph itself stays left-aligned
            # (Word wraps a right-aligned paragraph whose stop sits near the margin),
            # and a segment flush with the right edge gets a right stop at its own
            # edge, so a width mismatch in Word's fonts cannot push it to a new line
            align = "left"
            if container_box is not None and container_box.x1 - ln.lbox.x1 < 3:
                last = max(k for k, r in enumerate(runs) if r.get("tab_to") is not None)
                runs = list(runs); runs[last] = dict(runs[last], tab_to=ln.lbox.x1, tab_align="right")
        _fmt_paragraph(p, lead if i == 0 else 0.0, heights[i], align)
        if align == "left" and container_box is not None:
            off = ln.lbox.x0 - container_box.x0 if indent is None else indent
            if off > 0.3:
                p.paragraph_format.left_indent = Pt(min(off, max(0.0, container_box.width - 4)))
        if "_lines" in stats:
            stats["_lines"].append((ln, []))
        avail = 0.0
        if container_box is not None and container_box.width > 0:
            avail = container_box.width - (p.paragraph_format.left_indent.pt if p.paragraph_format.left_indent else 0.0)
        if any(r.get("tab_to") is not None for r in runs):
            scale = _segment_scales(ln, runs, container_box.x1 if container_box is not None else ln.lbox.x1)
        else:
            scale = _fit_scale(ln, avail)
        _add_runs(p, runs, stats, container_box.x0 if container_box is not None else None, scale)
        if layout[i][1] > 0:
            _filler(container, layout[i][1])
    return surplus


def _align(lbox: BBox, box: BBox) -> str:
    """Alignment of a line inside its container from its measured position.
    Centred: equal side gaps within a few points. Right: flush right and clearly
    narrower than the container. Everything else (including an indented line that
    reaches the right edge) is left-aligned at its measured x."""
    left = lbox.x0 - box.x0; right = box.x1 - lbox.x1
    if box.width <= 0:
        return "left"
    if left > 4 and abs(left - right) <= max(3.0, 0.02 * box.width):
        return "center"
    if right < 3 and left > 0.3 * box.width:
        return "right"
    return "left"


_ANCHOR_ID = [1000]


def _anchor_picture(paragraph, png: bytes, x_pt: float, y_pt: float, width_pt: float, height_pt: float,
                    behind: bool = True, stats: dict | None = None, descr: str = "") -> None:
    """Add a picture anchored at an absolute page position (no text wrapping),
    the way Acrobat's export places images. The host paragraph keeps no height."""
    run = paragraph.add_run()
    png = _fit_picture(png, width_pt, height_pt, stats)
    pic = run.add_picture(io.BytesIO(png), width=Pt(max(width_pt, 2)), height=Pt(max(height_pt, 2)))
    _describe(pic, descr)
    drawing = run._r.find(qn("w:drawing"))
    inline = drawing.find(qn("wp:inline"))
    anchor = OxmlElement("wp:anchor")
    for k, v in (("distT", "0"), ("distB", "0"), ("distL", "0"), ("distR", "0"), ("simplePos", "0"),
                 ("relativeHeight", str(_ANCHOR_ID[0])), ("behindDoc", "1" if behind else "0"), ("locked", "0"),
                 ("layoutInCell", "1"), ("allowOverlap", "1")):
        anchor.set(k, v)
    _ANCHOR_ID[0] += 1
    sp = OxmlElement("wp:simplePos"); sp.set("x", "0"); sp.set("y", "0"); anchor.append(sp)
    for tag, off in (("wp:positionH", x_pt), ("wp:positionV", y_pt)):
        pos = OxmlElement(tag); pos.set("relativeFrom", "page")
        po = OxmlElement("wp:posOffset"); po.text = str(int(round(off * 12700))); pos.append(po); anchor.append(pos)
    for child_tag in ("wp:extent", "wp:effectExtent"):
        el = inline.find(qn(child_tag))
        if el is not None:
            anchor.append(el)
    anchor.append(OxmlElement("wp:wrapNone"))
    for child_tag in ("wp:docPr", "wp:cNvGraphicFramePr"):
        el = inline.find(qn(child_tag))
        if el is not None:
            anchor.append(el)
    graphic = inline.find("{http://schemas.openxmlformats.org/drawingml/2006/main}graphic")
    if graphic is not None:
        anchor.append(graphic)
    drawing.remove(inline); drawing.append(anchor)


_FLAT_CACHE: dict = {}


def _flat_png(rgb: tuple[int, int, int]) -> bytes:
    """A tiny solid-colour PNG (Word scales it to the anchor's extent)."""
    if rgb not in _FLAT_CACHE:
        from PIL import Image
        buf = io.BytesIO(); Image.new("RGB", (4, 4), tuple(rgb)).save(buf, format="PNG")
        _FLAT_CACHE[rgb] = buf.getvalue()
    return _FLAT_CACHE[rgb]


def _crop_png(png: bytes, box: BBox, keep: BBox) -> bytes:
    """Crop a bitmap placed at ``box`` (sheet points) to the part inside ``keep``."""
    from PIL import Image
    im = Image.open(io.BytesIO(png))
    sx = im.width / max(box.width, 1e-6); sy = im.height / max(box.height, 1e-6)
    l = int((keep.x0 - box.x0) * sx); t = int((keep.y0 - box.y0) * sy)
    r = int(round((keep.x1 - box.x0) * sx)); b = int(round((keep.y1 - box.y0) * sy))
    im = im.crop((max(0, l), max(0, t), min(im.width, max(r, l + 1)), min(im.height, max(b, t + 1))))
    buf = io.BytesIO(); im.save(buf, format="PNG")
    return buf.getvalue()


def _rotated_png(png: bytes, rot: int) -> bytes:
    """The bitmap turned the way the page is displayed (90: clockwise)."""
    from PIL import Image
    im = Image.open(io.BytesIO(png))
    im = im.rotate(-90 if rot == 90 else 90, expand=True)
    buf = io.BytesIO(); im.save(buf, format="PNG")
    return buf.getvalue()


# Pictures are embedded at no more than this resolution for the size they are
# placed at. This lowers the quality of high-resolution sources (scans arrive
# at 300–600 dpi) and is reported per page (IMAGE_DOWNSAMPLED). Chosen after
# one observed failure: Word for Mac declined to export a 1904 scan whose four
# pages carried ~15 MB pictures each (61 MB document). It is not a documented
# Word limit.
MAX_PICTURE_DPI = 200


def _fit_picture(png: bytes, width_pt: float, height_pt: float | None, stats: dict | None = None) -> bytes:
    """The bytes a picture is embedded as: at most MAX_PICTURE_DPI for the size
    it is placed at, no alpha channel unless it is used, grey content kept
    grey, and photographic colour content as JPEG. A 1904 scan came in as four
    3105×4668 RGBA PNGs of 15 MB each and Word did not export the file.
    A downsampled picture is counted in ``stats`` (by section) for disclosure."""
    try:
        from PIL import Image, ImageChops
        im = Image.open(io.BytesIO(png)); im.load()
    except Exception:  # noqa: BLE001
        return png
    changed = False
    max_w = int(max(width_pt, 1.0) / 72 * MAX_PICTURE_DPI) + 1
    max_h = int(max(height_pt, 1.0) / 72 * MAX_PICTURE_DPI) + 1 if height_pt else None
    scale = min(max_w / im.width, (max_h / im.height) if max_h else 1.0, 1.0)
    if scale < 0.999:
        im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
        changed = True
        if stats is not None:
            stats["images_downsampled"] = stats.get("images_downsampled", 0) + 1
            pages = stats.setdefault("images_downsampled_pages", [])
            sec = stats.get("pages") or 0
            if sec and sec not in pages:
                pages.append(sec)
            by = stats.setdefault("images_downsampled_by_section", {})
            by[sec] = by.get(sec, 0) + 1
    if im.mode == "RGBA":
        lo, _hi = im.getchannel("A").getextrema()
        if lo >= 250:
            im = im.convert("RGB"); changed = True
    elif im.mode not in ("RGB", "L", "1", "P", "LA"):
        im = im.convert("RGB"); changed = True
    if im.mode == "RGB":
        r, g, b = im.split()
        if ImageChops.difference(r, g).getbbox() is None and ImageChops.difference(g, b).getbbox() is None:
            im = im.convert("L"); changed = True
    if not changed:
        return png
    out = io.BytesIO()
    photographic = False
    if im.mode == "RGB" and im.width * im.height > 1_000_000:
        thumb = im.copy(); thumb.thumbnail((128, 128))
        photographic = thumb.getcolors(2000) is None   # more than 2000 colours in a thumbnail: a photograph
    if photographic:
        im.save(out, "JPEG", quality=90, optimize=True)
    else:
        im.save(out, "PNG", optimize=True)
    return out.getvalue()


def _describe(pic, descr: str) -> None:
    """The picture's description (Word's alt text): the labels a picture keeps
    (a map's place names, a diagram's), which are no longer editable text."""
    if descr:
        pic._inline.docPr.set("descr", descr)


def _picture(container_paragraph, asset_png: bytes, width_pt: float, height_pt: float | None = None,
             stats: dict | None = None, descr: str = "") -> None:
    run = container_paragraph.add_run()
    asset_png = _fit_picture(asset_png, width_pt, height_pt, stats)
    pic = run.add_picture(io.BytesIO(asset_png), width=Pt(max(width_pt, 4)))
    _describe(pic, descr)
    h = height_pt if height_pt else pic.height.pt
    pf = container_paragraph.paragraph_format
    pf.line_spacing_rule = WD_LINE_SPACING.EXACTLY; pf.line_spacing = Pt(h + 0.5)
    pf.space_before = pf.space_before or Pt(0); pf.space_after = Pt(0)


class LayoutWriter:
    def __init__(self) -> None:
        self.doc = DocxDocument()
        cp = self.doc.core_properties
        cp.author = "zPDF Export"; cp.last_modified_by = "zPDF Export"; cp.title = ""; cp.comments = ""
        # base style: no automatic spacing anywhere
        normal = self.doc.styles["Normal"]
        normal.paragraph_format.space_before = Pt(0); normal.paragraph_format.space_after = Pt(0)
        normal.paragraph_format.line_spacing = 1.0
        self.stats = {"pages": 0, "tables": 0, "paragraphs": 0, "images": 0, "fonts": {}, "links": 0,
                      "links_dropped_unsafe_scheme": 0, "comments": 0, "comments_unanchored": 0, "_lines": []}
        self._first_page = True
        self._debt = 0.0  # pt the page is already over budget (minimum spacers, borders, unabsorbed shifts)
        self._body = self.doc  # where bands are emitted
        self._rot = 0          # 0 on an upright page; 90/270 while a turned page is written (tables transposed)

    # -- pages -------------------------------------------------------------
    def add_page(self, layout: PageLayout, assets: dict, ir_doc) -> None:
        if self._first_page:
            sec = self.doc.sections[0]
        else:
            sec = self.doc.add_section(WD_SECTION.NEW_PAGE)
            # the paragraph carrying the section break must not take a line of its own
            brk = self.doc.paragraphs[-1]
            _fmt_paragraph(brk, 0.0, BREAK_PARA); brk.paragraph_format.line_spacing_rule = WD_LINE_SPACING.EXACTLY
            brk.paragraph_format.line_spacing = Pt(BREAK_PARA)
            r = brk.add_run(" "); r.font.size = Pt(1)
        self._first_page = False
        rot = layout.rotation % 360
        self._body = self.doc
        self._rot = rot if rot in (90, 270) else 0
        if self._rot:
            # the displayed page is the upright page turned: the sheet is swapped
            # and the page margins, which are physical, turn with it
            sec.page_width = Pt(layout.height); sec.page_height = Pt(layout.width)
            m = (layout.margin_left, layout.margin_top, layout.margin_right, layout.margin_bottom)  # upright L,T,R,B
            if rot == 90:
                phys_left, phys_top, phys_right, phys_bottom = m[3], m[0], m[1], m[2]
            else:
                phys_left, phys_top, phys_right, phys_bottom = m[1], m[2], m[3], m[0]
            sec.left_margin = Pt(phys_left); sec.right_margin = Pt(phys_right)
            sec.top_margin = Pt(phys_top); sec.bottom_margin = Pt(phys_bottom)
        else:
            sec.page_width = Pt(layout.width); sec.page_height = Pt(layout.height)
            sec.left_margin = Pt(layout.margin_left); sec.right_margin = Pt(layout.margin_right)
            sec.top_margin = Pt(layout.margin_top); sec.bottom_margin = Pt(layout.margin_bottom)
        sec.header_distance = Pt(0); sec.footer_distance = Pt(0)
        self.stats["pages"] += 1
        self.stats["_lines"] = []
        # paragraphs outside the bands still take space on the page: the picture
        # host, the hidden-text paragraph and the paragraph carrying the section
        # break. They are debt repaid from the page's first gap, so a page whose
        # content runs to the bottom margin (a scan's footer stamp) still fits.
        reserve = BREAK_PARA
        if self._hidden_texts(layout):
            reserve += HIDDEN_PARA
        if layout.figures or layout.backdrops:
            reserve += HOST_PARA
            host = self.doc.add_paragraph()
            _fmt_paragraph(host, 0.0, HOST_PARA)
            sheet_w = layout.height if self._rot else layout.width
            sheet_h = layout.width if self._rot else layout.height
            # anchors follow the page's paint order (z): a bar painted after a
            # photograph is anchored after it; a drawing rendered from under the
            # text goes first of all
            queue = [(getattr(f, "z", 0), 0, "fill", f) for f in layout.backdrops]
            for it in layout.figures:
                z = -10 if getattr(it.payload, "behind", False) else getattr(it.payload, "z", 0)
                queue.append((z, 1, "figure", it))
            queue.sort(key=lambda q: (q[0], q[1]))
            for _z, _k, kind, obj in queue:
                if kind == "fill":
                    # a flat colour picture of the fill's box, clamped to the sheet
                    fb = obj.bbox
                    x0 = max(0.0, fb.x0); y0 = max(0.0, fb.y0)
                    x1 = min(sheet_w, fb.x1); y1 = min(sheet_h, fb.y1)
                    if x1 - x0 < 1 or y1 - y0 < 1:
                        continue
                    # a blended fill (pictures show through it) comes as a render of
                    # its region; every other fill is a flat colour picture
                    png = getattr(obj, "png", None)
                    if png is not None and (x0, y0, x1, y1) != (fb.x0, fb.y0, fb.x1, fb.y1):
                        png = _crop_png(png, fb, BBox(x0, y0, x1, y1))
                    _anchor_picture(host, png or _flat_png(obj.rgb), x0, y0, x1 - x0, y1 - y0, stats=self.stats)
                    self.stats["backdrops"] = self.stats.get("backdrops", 0) + 1
                    continue
                it = obj
                im = it.payload
                box = im.bbox if self._rot else it.lbox   # anchors are sheet positions
                # a picture running past the sheet (a bleed) is clamped: Word treats an
                # overhanging anchor as spilling onto the next page
                x0 = max(0.0, box.x0); y0 = max(0.0, box.y0)
                x1 = min(sheet_w, box.x1); y1 = min(sheet_h, box.y1)
                if x1 - x0 < 1 or y1 - y0 < 1:
                    continue
                png = _rotated_png(im.png_bytes, rot) if self._rot else im.png_bytes
                if (x0, y0, x1, y1) != (box.x0, box.y0, box.x1, box.y1):
                    png = _crop_png(png, box, BBox(x0, y0, x1, y1))
                # photographs sit behind the text (the source paints text over
                # them); a rendered drawing carries no text of its own and sits in
                # front, or a shaded cell behind it would paint it out (a white
                # mark on a dark footer bar)
                in_front = getattr(im, "origin", "image") == "vector" and not getattr(im, "behind", False)
                _anchor_picture(host, png, x0, y0, x1 - x0, y1 - y0, behind=not in_front, stats=self.stats,
                                descr=getattr(im, "absorbed_text", ""))
                self.stats["images"] += 1
        self._debt = 0.0 if self._rot else reserve   # a rotated sheet is already 2 pt short
        if self._rot:
            self._rotated_page(layout, assets)
        else:
            y = layout.margin_top
            content_left = layout.margin_left
            for band in layout.bands:
                gap = self._take_gap(band.lbox.y0 - y)
                if not self._emit_band(band, gap, layout, assets, self.doc):
                    self._debt = max(0.0, self._debt - gap)   # nothing written: the gap is still ahead of us
                    continue
                y = band.lbox.y1
        self._write_hidden(layout)
        self._attach_comments(layout)

    def _write_hidden(self, layout: PageLayout) -> None:
        """Invisible source text (an OCR layer) as hidden paragraphs: searchable
        when Word shows hidden text, taking no space otherwise."""
        texts = self._hidden_texts(layout)
        if not texts:
            return
        # one paragraph for the whole page: Word still reserves an exact line for
        # each hidden paragraph, and a scan page has dozens of OCR lines
        p = self.doc.add_paragraph()
        _fmt_paragraph(p, 0.0, HIDDEN_PARA)
        pPr = p._p.get_or_add_pPr(); rpr = OxmlElement("w:rPr"); rpr.append(OxmlElement("w:vanish")); pPr.append(rpr)
        for k, text in enumerate(texts):
            run = p.add_run(("" if k == 0 else " ") + text); run.font.hidden = True; run.font.size = Pt(1)
        self.stats["hidden_lines"] = self.stats.get("hidden_lines", 0) + len(texts)

    @staticmethod
    def _hidden_texts(layout: PageLayout) -> list[str]:
        texts = ["".join(r["text"] for r in ln.runs).strip() for ln in layout.hidden]
        return [t for t in texts if t]

    def _emit_band(self, band: Band, gap: float, layout: PageLayout, assets, container, first=None) -> bool:
        """Write one band into ``container`` after ``gap`` points. Returns False
        when the band has nothing to write."""
        content_left = layout.margin_left
        content_right = layout.width - layout.margin_right
        if band.kind == "table":
            self._table_band(band, gap, content_left, container, first)
        elif band.kind == "row":
            self._row_band(band, gap, content_left, assets, container, first)
        elif band.kind == "rule":
            self._rule_band(band, gap, content_left, content_right, container, first)
        else:
            return self._flow_band(band, gap, content_left, layout, assets, container, first)
        return True

    def _rotated_page(self, layout: PageLayout, assets) -> None:
        """A page displayed at 90°/270°. Word turns paragraph text with a cell's
        text direction but never a table's geometry, so the page is rebuilt
        transposed: bands stacked along the upright page become the columns of
        one sheet-wide row, each band's tables are transposed (rows ↔ columns,
        edges turned) and every text cell's direction is turned; the result is
        the upright page seen through a quarter turn."""
        rot = self._rot
        flow_len = layout.height - layout.margin_top - layout.margin_bottom - 2.0   # along the reading flow
        flow_wid = layout.width - layout.margin_left - layout.margin_right - 2.0    # across it
        # entries along the flow: (kind, height, band)
        entries: list[tuple[str, float, Band | None]] = []
        y = layout.margin_top
        for band in layout.bands:
            if band.kind == "flow" and band.fill is None and not _item_lines(band.items[0]):
                continue
            gap = band.lbox.y0 - y
            if gap > 0.5:
                entries.append(("gap", gap, None))
            elif gap < -0.5 and entries and entries[-1][0] == "gap":
                pass
            entries.append(("band", band.lbox.height, band))
            y = band.lbox.y1
        used = sum(h for _k, h, _b in entries)
        if used < flow_len - 0.5:
            entries.append(("gap", flow_len - used, None))
        elif used > flow_len:
            # shrink gaps proportionally so the row fits the sheet
            excess = used - flow_len
            gaps = sum(h for k, h, _b in entries if k == "gap")
            entries = [(k, h - excess * h / gaps if (k == "gap" and gaps) else h, b) for k, h, b in entries]
        outer = _Grid(self.doc, len(entries), 1, rot)
        outer.set_col_widths([flow_wid])
        for i, (_k, h, _b) in enumerate(entries):
            outer.set_row_height(i, h, True)
        outer.finalize()
        for i, (kind, h, band) in enumerate(entries):
            if kind == "gap":
                cell = outer.cell(i, 0, text=False)
                p = cell.paragraphs[0]; _fmt_paragraph(p, 0.0, 1.0); p.add_run(" ").font.size = Pt(1)
                continue
            holds_table = band.kind in ("table", "row", "rule") or band.fill is not None
            cell = outer.cell(i, 0, text=not holds_table)
            if holds_table:
                # position along the upright x axis: a spacer above the nested table
                x0 = band.lbox.x0 if band.kind != "rule" else band.lbox.x0
                lead = (x0 - layout.margin_left) if rot == 90 else (layout.width - layout.margin_right - band.lbox.x1)
                first = cell.paragraphs[0]
                _fmt_paragraph(first, 0.0, max(0.5, lead)); first.add_run(" ").font.size = Pt(1)
                self._emit_band(band, 0.0, layout, assets, cell, None)
                # a nested table must be followed by a paragraph inside its cell
                tail = cell.add_paragraph(); _fmt_paragraph(tail, 0.0, 0.5); tail.add_run(" ").font.size = Pt(1)
            else:
                self._emit_band(band, 0.0, layout, assets, cell, cell.paragraphs[0])

    def _attach_comments(self, layout: PageLayout) -> None:
        """Source annotations become Word comments on the text under them (or the
        nearest line for a note icon in the margin)."""
        lines = [(ln, runs) for ln, runs in self.stats["_lines"] if runs]
        for c in layout.comments:
            cb = c.lbox
            hit = [(ln, runs) for ln, runs in lines
                   if ln.lbox.x1 > cb.x0 and ln.lbox.x0 < cb.x1 and ln.lbox.y1 > cb.y0 and ln.lbox.y0 < cb.y1]
            if not hit and lines:
                def gap(lr):
                    b = lr[0].lbox
                    dx = max(0.0, b.x0 - cb.x1, cb.x0 - b.x1); dy = max(0.0, b.y0 - cb.y1, cb.y0 - b.y1)
                    return dx * dx + dy * dy
                hit = [min(lines, key=gap)]
                self.stats["comments_unanchored"] += 1
            if not hit:
                continue
            runs = [hit[0][1][0], hit[-1][1][-1]] if len(hit) > 1 or len(hit[0][1]) > 1 else [hit[0][1][0]]
            text = f"[{c.kind}] {c.text}".strip()
            try:
                self.doc.add_comment(runs, text=text, author=c.author or "", initials=(c.author or "")[:2])
                self.stats["comments"] += 1
            except Exception:  # noqa: BLE001
                self.doc.add_comment(runs[0], text=text, author=c.author or "", initials=(c.author or "")[:2])
                self.stats["comments"] += 1

    # -- bands -------------------------------------------------------------
    def _take_gap(self, gap: float) -> float:
        """The gap to emit before the next band once earlier overruns are repaid."""
        g = gap - self._debt
        self._debt = 0.0
        if g < 0:
            self._debt = -g
            g = 0.0
        return g

    def _spacer(self, gap_pt: float, container=None, first=None) -> None:
        """A paragraph of exactly the vertical gap before a table. Always emitted
        on an upright page: two adjacent tables would otherwise get an
        uncontrolled paragraph (or be merged) by Word. Its 0.5 pt minimum is
        repaid by the next gap. Inside a rotated page's band cell the gap is
        already a column of the outer table, so nothing is written."""
        if self._rot:
            return
        h = max(gap_pt, 0.5)
        if gap_pt < h:
            self._debt += h - gap_pt
        p = first if first is not None else (container or self._body).add_paragraph()
        _fmt_paragraph(p, 0.0, h)
        p.paragraph_format.line_spacing_rule = WD_LINE_SPACING.EXACTLY
        p.paragraph_format.line_spacing = Pt(h)
        run = p.add_run(" "); run.font.size = Pt(1)

    def _banner_band(self, band: Band, gap: float, content_left: float, container, first=None) -> None:
        """Text on a filled bar: a shaded single-cell table of exactly the bar's
        size, the lines positioned inside it."""
        self._spacer(gap, container, first)
        f = band.fill
        fb = f.lbox
        lines = _merge_rows([ln for it in band.items for ln in _item_lines(it)])
        row_h = fb.height
        if lines:
            row_h = max(row_h, _lines_total(lines, lines[0].lbox.y0 - fb.y0, fb.y1))
        self._debt += row_h - fb.height
        g = _Grid(container, 1, 1, self._rot)
        g.set_col_widths([fb.width]); g.set_row_height(0, row_h, True); g.indent(fb.x0 - content_left); g.finalize()
        cell = g.cell(0, 0); _set_shading(cell, f.rgb)
        if lines:
            _write_lines(cell, lines, self.stats, lines[0].lbox.y0 - fb.y0, fb, cell.paragraphs[0], fb.y1)
            self.stats["paragraphs"] += len(lines)
        else:
            p = cell.paragraphs[0]; _fmt_paragraph(p, 0.0, max(fb.height, 1.0)); p.add_run(" ").font.size = Pt(1)
        self.stats["tables"] += 1

    def _flow_band(self, band: Band, gap: float, content_left: float, layout: PageLayout, assets,
                   container, first=None) -> bool:
        """Returns False when the band has nothing to write (an empty field)."""
        if band.fill is not None:
            self._banner_band(band, gap, content_left, container, first)
            return True
        it = band.items[0]
        if it.kind == "figure":
            self._spacer(gap, container, first)
            p = container.add_paragraph()
            _fmt_paragraph(p, 0.0, None, _align(it.lbox, BBox(content_left, 0, layout.width - layout.margin_right, 0)))
            p.paragraph_format.left_indent = Pt(max(0.0, it.lbox.x0 - content_left)) if _align(it.lbox, BBox(content_left, 0, layout.width - layout.margin_right, 0)) == "left" else None
            _picture(p, assets[it.payload.image_id].data if hasattr(assets.get(it.payload.image_id, None), "data") else it.payload.png_bytes, it.lbox.width, it.lbox.height, self.stats,
                     descr=getattr(it.payload, "absorbed_text", ""))
            self.stats["images"] += 1
            return True
        lines = _item_lines(it)
        if not lines:
            return False
        box = BBox(content_left, 0, layout.width - layout.margin_right, 0)
        lines = _merge_rows(lines)
        gap += lines[0].lbox.y0 - band.lbox.y0
        # a glyph box (descenders) can reach past the page's text area: a footer
        # stamp on a scan; the block cannot extend beyond the page
        bottom = min(band.lbox.y1, layout.height - layout.margin_bottom)
        # lines lifted to their natural height make the band taller than measured
        over = max(0.0, _lines_total(lines, gap, bottom) - (gap + (bottom - band.lbox.y0)))
        if over > 0 and band.lbox.y1 + over > layout.height - layout.margin_bottom - 0.01:
            # the excess would run past the page's text area and no later gap can
            # repay it: start the block that much higher instead of spilling it
            take = min(gap, over); gap -= take; over -= take
        self._debt += _write_lines(container, lines, self.stats, gap, box, first, bottom)
        self._debt += over
        self.stats["paragraphs"] += len(lines)
        return True

    def _rule_band(self, band: Band, gap: float, content_left: float, content_right: float, container, first=None) -> None:
        if band.rules:
            # stroked line segments on one row: an exact borderless table row; a
            # thin line is a cell's top border (the row is 1 pt), a thicker bar
            # shades a cell of exactly its own height
            self._spacer(gap, container, first)
            thick = band.lbox.height >= 1.5
            segs = sorted((r.lbox.x0, r.lbox.x1) for r in band.rules)
            widths: list[float] = []; drawn: list[bool] = []
            x = segs[0][0]
            for x0, x1 in segs:
                if x0 - x > 1.0:
                    widths.append(x0 - x); drawn.append(False)
                x0 = max(x0, x)
                if x1 - x0 >= 1.0:
                    widths.append(x1 - x0); drawn.append(True); x = x1
            g = _Grid(container, 1, len(widths), self._rot)
            g.set_col_widths(widths); g.set_row_height(0, band.lbox.height, True)
            g.indent(max(0.0, segs[0][0] - content_left)); g.finalize()
            sz = max(2, round(max(r.lbox.height for r in band.rules) * 8))
            for i, on in enumerate(drawn):
                cell = g.cell(0, i, text=False)
                p = cell.paragraphs[0]; _fmt_paragraph(p, 0.0, max(1.0, band.lbox.height)); p.add_run(" ").font.size = Pt(1)
                if on and thick:
                    _set_shading(cell, (0, 0, 0))
                elif on:
                    g.borders(cell, {"top": True}, sz)
            if not thick:
                self._debt += 0.5  # Word adds the border's thickness to the 1 pt row (calibrated)
            return
        self._spacer(gap, container, first)
        f = band.fill
        g = _Grid(container, 1, 1, self._rot)
        g.set_col_widths([f.lbox.width]); g.set_row_height(0, f.lbox.height, True); g.indent(f.lbox.x0 - content_left); g.finalize()
        cell = g.cell(0, 0, text=False); _set_shading(cell, f.rgb)
        p = cell.paragraphs[0]; _fmt_paragraph(p, 0.0, max(f.lbox.height, 1.0)); p.add_run(" ").font.size = Pt(1)

    def _row_band(self, band: Band, gap: float, content_left: float, assets, container, first=None) -> None:
        if band.fill is not None and all(it.kind in ("block", "field", "sentence") for it in band.items):
            self._banner_band(band, gap, content_left, container, first)
            return
        self._spacer(gap, container, first)
        cols = band.columns
        # column boundaries: each column's extent, gaps become their own empty columns
        extents = []
        for col in cols:
            b = col[0].lbox
            for it in col[1:]:
                b = b.union(it.lbox)
            extents.append((b.x0, b.x1, col))
        extents.sort(key=lambda e: e[0])
        # give text columns slack: extend each column into the gaps beside it
        # (Word's font metrics differ slightly from the PDF's) and keep only
        # gaps wider than the slack as empty columns
        SLACK = 6.0
        widths: list[float] = []
        content_cols: list[list[Item] | None] = []
        edges: list[tuple[float, float]] = []
        x = extents[0][0]
        for i, (x0, x1, col) in enumerate(extents):
            nxt = extents[i + 1][0] if i + 1 < len(extents) else None
            start = x0 if i == 0 else max(x, x0 - SLACK)
            end = x1 + SLACK if nxt is None else min(x1 + SLACK, (x1 + nxt) / 2)
            if start - x > 2:
                widths.append(start - x); content_cols.append(None); edges.append((x, start))
            widths.append(max(end - start, 4.0)); content_cols.append(col); edges.append((start, end))
            x = end
        # exact: a side-by-side band occupies its source height so the page budget
        # holds; a column whose lines need more (natural line boxes) grows the row
        # and the excess is repaid from the next gap
        col_lines: dict[int, list[TextLine]] = {}
        row_h = band.lbox.height
        for i, col in enumerate(content_cols):
            if col and all(it.kind in ("block", "field", "sentence") for it in col):
                lines = _merge_rows([ln for it in col for ln in _item_lines(it)])
                col_lines[i] = lines
                if lines:
                    row_h = max(row_h, _lines_total(lines, lines[0].lbox.y0 - band.lbox.y0, max(it.lbox.y1 for it in col)))
        self._debt += row_h - band.lbox.height
        g = _Grid(container, 1, len(widths), self._rot)
        g.set_col_widths(widths); g.set_row_height(0, row_h, True)
        g.indent(max(0.0, extents[0][0] - content_left)); g.finalize()
        for i, (w, col) in enumerate(zip(widths, content_cols)):
            holds_table = bool(col) and any(it.kind == "table" for it in col)
            cell = g.cell(0, i, text=not holds_table)
            cell.paragraphs[0].paragraph_format.space_after = Pt(0)
            if holds_table:
                # the cell's mandatory first paragraph sits above the nested table:
                # a default line there would move every row of the table down
                _fmt_paragraph(cell.paragraphs[0], 0.0, HOST_PARA)
                cell.paragraphs[0].add_run(" ").font.size = Pt(1)
            if not col:
                continue
            box = BBox(edges[i][0], band.lbox.y0, edges[i][1], band.lbox.y1)  # the cell's own edges
            if i in col_lines:
                lines = col_lines[i]
                if lines:
                    _write_lines(cell, lines, self.stats, lines[0].lbox.y0 - band.lbox.y0, box, cell.paragraphs[0],
                                 max(it.lbox.y1 for it in col))
                    self.stats["paragraphs"] += len(lines)
                continue
            y = band.lbox.y0
            first_p = True
            for it in col:
                gg = it.lbox.y0 - y
                if it.kind == "figure":
                    p = cell.paragraphs[0] if first_p else cell.add_paragraph()
                    _fmt_paragraph(p, gg, None, "left")
                    _picture(p, it.payload.png_bytes, it.lbox.width, it.lbox.height, self.stats,
                             descr=getattr(it.payload, "absorbed_text", "")); self.stats["images"] += 1
                elif it.kind == "table":
                    self._grid_table(cell, it.payload, it.lbox.x0)
                else:
                    lines = _item_lines(it)
                    if lines:
                        _write_lines(cell, lines, self.stats, gg, box, cell.paragraphs[0] if first_p else None, it.lbox.y1)
                        self.stats["paragraphs"] += len(lines)
                first_p = False
                y = it.lbox.y1
        self.stats["tables"] += 1

    def _table_band(self, band: Band, gap: float, content_left: float, container, first=None) -> None:
        self._spacer(gap, container, first)
        t = band.items[0].payload
        self._grid_table(container, t, content_left)

    def _grid_table(self, container, t, content_left: float) -> None:
        xs, ys = _grid_edges(t)
        n_rows, n_cols = len(ys) - 1, len(xs) - 1
        if n_rows < 1 or n_cols < 1:
            return
        widths = [xs[i + 1] - xs[i] for i in range(n_cols)]
        g = _Grid(container, n_rows, n_cols, self._rot)
        g.set_col_widths(widths)
        if container is self.doc:
            g.indent(xs[0] - content_left)
        for r in range(n_rows):
            row_h = ys[r + 1] - ys[r]
            needed = _needed_height(t, r, ys)
            g.set_row_height(r, row_h, exact=needed <= row_h)
        g.finalize()
        fills = getattr(t, "fills", [])
        for cell_def in t.cells:
            r0, c0 = cell_def.row, cell_def.col
            rs, cs = cell_def.rowspan, cell_def.colspan
            if r0 >= n_rows or c0 >= n_cols:
                continue
            r1 = min(r0 + rs - 1, n_rows - 1); c1 = min(c0 + cs - 1, n_cols - 1)
            cell = g.merge(r0, c0, r1, c1) if (r1, c1) != (r0, c0) else g.cell(r0, c0)
            box = BBox(xs[c0], ys[r0], xs[c1 + 1], ys[r1 + 1])
            edges = _cell_edges(t, box)
            g.borders(cell, edges)
            for f in fills:
                if _covers(f.lbox, box):
                    _set_shading(cell, f.rgb)
                    break
            lines = lines_from_chars(cell_def.chars) if cell_def.chars else []
            value_lines = sorted(_value_lines(cell_def), key=lambda vl: (vl.lbox.y0, vl.lbox.x0))
            # values are visual lines too; interleave by vertical position
            all_lines = sorted(lines + value_lines, key=lambda ln: (round(ln.lbox.y0), ln.lbox.x0))
            if box.width < 20:
                _set_nowrap(cell)
            if all_lines:
                first_gap = max(0.0, all_lines[0].lbox.y0 - box.y0)
                avail = box.height
                heights = _line_heights(all_lines, None)
                if first_gap + sum(heights) > avail:
                    # never let cell content grow the row: shrink the leading gap first
                    first_gap = max(0.0, avail - sum(heights))
                _write_lines(cell, all_lines, self.stats, first_gap, box, cell.paragraphs[0])
                self.stats["paragraphs"] += len(all_lines)
        self.stats["tables"] += 1

    def save(self, path: Path) -> dict:
        # the body must end with a paragraph; make it cost nothing so the last
        # page's table does not spawn an empty page
        tail = self.doc.add_paragraph()
        _fmt_paragraph(tail, 0.0, BREAK_PARA)
        tail.add_run(" ").font.size = Pt(1)
        self.doc.save(str(path))
        return self.stats


# -- helpers ---------------------------------------------------------------


class _Grid:
    """A table addressed in the upright page's terms (rows stack along upright
    y, columns along upright x). Upright pages map straight onto a Word table.
    A page displayed at 90°/270° is transposed: upright columns become the
    physical rows, upright rows the physical columns (in reverse for 90°), cell
    borders turn with the page and every text cell's direction is turned, so
    Word shows the upright grid through a quarter turn."""

    def __init__(self, container, n_rows: int, n_cols: int, rot: int = 0) -> None:
        self.rot = rot; self.n_rows = n_rows; self.n_cols = n_cols
        if rot:
            self.t = _add_table(container, n_cols, n_rows)
        else:
            self.t = _add_table(container, n_rows, n_cols)
        self.t.alignment = WD_TABLE_ALIGNMENT.LEFT
        _no_table_borders(self.t)
        self._col_widths: list[float] = [4.0] * n_cols
        self._row_heights: list[tuple[float, bool]] = [(4.0, True)] * n_rows
        self._indent = 0.0
        self._text_dir = {90: "tbRl", 270: "btLr"}.get(rot)

    # -- upright → physical
    def _pos(self, r: int, c: int) -> tuple[int, int]:
        if not self.rot:
            return r, c
        if self.rot == 90:      # upright x → down the sheet; upright y → leftwards
            return c, self.n_rows - 1 - r
        return self.n_cols - 1 - c, r   # 270: upright x → up the sheet; upright y → rightwards

    def set_col_widths(self, widths: list[float]) -> None:
        self._col_widths = list(widths)

    def set_row_height(self, r: int, h: float, exact: bool) -> None:
        self._row_heights[r] = (h, exact)

    def indent(self, pt: float) -> None:
        self._indent = pt

    def finalize(self) -> None:
        if not self.rot:
            _set_table_fixed(self.t, self._col_widths)
            _set_table_indent(self.t, max(0.0, self._indent))
            for r, (h, exact) in enumerate(self._row_heights):
                _set_row_height(self.t.rows[r], h, exact)
            for c, w in enumerate(self._col_widths):
                for r in range(self.n_rows):
                    _set_cell_width(self.t.cell(r, c), w)
            return
        # physical columns are the upright rows (heights become widths)
        order = list(range(self.n_rows)) if self.rot == 270 else list(reversed(range(self.n_rows)))
        phys_widths = [self._row_heights[r][0] for r in order]
        _set_table_fixed(self.t, phys_widths)
        _set_table_indent(self.t, 0.0)
        # physical rows are the upright columns (widths become heights)
        for c in range(self.n_cols):
            pr, _pc = self._pos(0, c)
            _set_row_height(self.t.rows[pr], self._col_widths[c], True)
        for pc, w in enumerate(phys_widths):
            for pr in range(self.n_cols):
                _set_cell_width(self.t.cell(pr, pc), w)

    def cell(self, r: int, c: int, text: bool = True):
        pr, pc = self._pos(r, c)
        cell = self.t.cell(pr, pc)
        if self.rot and text:
            self._turn(cell)
        return cell

    def _turn(self, cell) -> None:
        tcPr = cell._tc.get_or_add_tcPr()
        if tcPr.find(qn("w:textDirection")) is None:
            td = OxmlElement("w:textDirection"); td.set(qn("w:val"), self._text_dir); tcPr.append(td)

    def merge(self, r0: int, c0: int, r1: int, c1: int):
        a = self._pos(r0, c0); b = self._pos(r1, c1)
        top = self.t.cell(min(a[0], b[0]), min(a[1], b[1])); bottom = self.t.cell(max(a[0], b[0]), max(a[1], b[1]))
        cell = top.merge(bottom)
        if self.rot:
            self._turn(cell)
        return cell

    def borders(self, cell, edges: dict[str, bool], size_eighths: int = 6) -> None:
        if self.rot == 90:      # upright top → right, bottom → left, left → top, right → bottom
            m = {"top": "right", "bottom": "left", "left": "top", "right": "bottom"}
        elif self.rot == 270:   # upright top → left, bottom → right, left → bottom, right → top
            m = {"top": "left", "bottom": "right", "left": "bottom", "right": "top"}
        else:
            m = {k: k for k in ("top", "bottom", "left", "right")}
        _set_borders(cell, {m[k]: v for k, v in edges.items() if k in m}, size_eighths)


def _grid_edges(t) -> tuple[list[float], list[float]]:
    """One edge per detector row and column index. Cells of a row split into
    aligned sub-rows carry their text-line box, so edges taken from cell boxes
    alone would interleave gap rows and put shading and text one row off; each
    row's edge is the smallest y0 among the cells starting in it, and a gap
    between rows belongs to the row above."""
    n_rows = max((c.row + c.rowspan for c in t.cells), default=0)
    n_cols = max((c.col + c.colspan for c in t.cells), default=0)
    if n_rows == 0 or n_cols == 0:
        return [], []
    row_start = [None] * n_rows; row_end = [None] * n_rows
    col_start = [None] * n_cols; col_end = [None] * n_cols
    for c in t.cells:
        r, k = c.row, c.col
        row_start[r] = c.lbox.y0 if row_start[r] is None else min(row_start[r], c.lbox.y0)
        rl = r + c.rowspan - 1
        row_end[rl] = c.lbox.y1 if row_end[rl] is None else max(row_end[rl], c.lbox.y1)
        col_start[k] = c.lbox.x0 if col_start[k] is None else min(col_start[k], c.lbox.x0)
        cl = k + c.colspan - 1
        col_end[cl] = c.lbox.x1 if col_end[cl] is None else max(col_end[cl], c.lbox.x1)

    def edges(starts, ends, lo, hi):
        out = []
        prev = lo
        for i, st in enumerate(starts):
            v = st if st is not None else (ends[i - 1] if i and ends[i - 1] is not None else prev)
            v = max(v, prev + 0.5) if out else v
            out.append(v); prev = v
        last = max((e for e in ends if e is not None), default=hi)
        out.append(max(last, prev + 0.5))
        return out

    ys = edges(row_start, row_end, t.lbox.y0, t.lbox.y1)
    xs = edges(col_start, col_end, t.lbox.x0, t.lbox.x1)
    return xs, ys


def _dedupe(vals: list[float], tol: float = 1.0) -> list[float]:
    out: list[float] = []
    for v in vals:
        if out and v - out[-1] < tol:
            out[-1] = (out[-1] + v) / 2
        else:
            out.append(v)
    return out


def _covers(fill: BBox, cell: BBox) -> bool:
    ix = max(0.0, min(fill.x1, cell.x1) - max(fill.x0, cell.x0))
    iy = max(0.0, min(fill.y1, cell.y1) - max(fill.y0, cell.y0))
    return ix * iy >= 0.6 * cell.width * cell.height


def _cell_edges(t, box: BBox) -> dict[str, bool]:
    rules = getattr(t, "rules", None) or []
    def has_h(y, x0, x1):
        return any(r.orientation == "h" and abs(r.lbox.cy - y) <= 2.5 and min(r.lbox.x1, x1) - max(r.lbox.x0, x0) >= 0.5 * (x1 - x0) for r in rules)
    def has_v(x, y0, y1):
        return any(r.orientation == "v" and abs(r.lbox.cx - x) <= 2.5 and min(r.lbox.y1, y1) - max(r.lbox.y0, y0) >= 0.5 * (y1 - y0) for r in rules)
    if not rules:
        return {"top": True, "left": True, "bottom": True, "right": True}
    return {"top": has_h(box.y0, box.x0, box.x1), "bottom": has_h(box.y1, box.x0, box.x1),
            "left": has_v(box.x0, box.y0, box.y1), "right": has_v(box.x1, box.y0, box.y1)}


def _needed_height(t, r: int, ys: list[float]) -> float:
    need = 0.0
    for c in t.cells:
        if c.row == r and c.rowspan == 1 and (c.chars or getattr(c, "values", None)):
            lines = sorted((lines_from_chars(c.chars) if c.chars else []) + _value_lines(c), key=lambda ln: ln.lbox.y0)
            if lines:
                need = max(need, sum(h + f for h, f in _line_layout(lines, None)))
    return need


def _value_lines(cell_def) -> list[TextLine]:
    """Field values recorded on the cell (set by reconstruct) as their own lines."""
    out = []
    for v in getattr(cell_def, "values", []) or []:
        out.append(TextLine([{"text": v["text"], "font": v.get("font", ""), "size": v.get("size", 9.0),
                              "bold": v.get("bold", False), "italic": False}], v["lbox"]))
    return out


def _item_lines(it) -> list[TextLine]:
    if it.kind == "field":
        return _field_lines(it.payload)
    if it.kind == "sentence":
        return _sentence_lines(it.payload, it.lbox)
    return list(it.lines)


def _merge_rows(lines: list[TextLine]) -> list[TextLine]:
    """Lines that share a text row (from different items: a short label, its
    field and the text continuing right of it) become one line, segments in x
    order separated by tab stops at their measured positions. Segments that
    overlap horizontally stay separate lines."""
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
                size = max((r["size"] for r in ln.runs), default=8.0)
                if gap < 2.5:
                    joint: list[dict] = []          # touching pieces (a small-caps word) run on
                elif gap < 1.2 * size:
                    joint = [{"text": " ", "font": "", "size": size, "bold": False, "italic": False}]
                else:
                    joint = [_tab(ln.lbox.x0)]      # a real gap: a stop at the measured position
                merged[-1] = TextLine(prev.runs + joint + ln.runs, _row_box(prev, ln), prev.align,
                                      prev.anchor or ln.anchor)
            else:
                merged.append(TextLine(list(ln.runs), ln.lbox, ln.align, ln.anchor))
        out.extend(merged)
    return out


def _row_box(a: TextLine, b: TextLine) -> BBox:
    """Box of two merged segments: full x-range; the y-range of measured text
    only, so a tall field widget does not lift or drop its label."""
    u = a.lbox.union(b.lbox)
    if a.anchor and not b.anchor:
        return BBox(u.x0, a.lbox.y0, u.x1, a.lbox.y1)
    if b.anchor and not a.anchor:
        return BBox(u.x0, b.lbox.y0, u.x1, b.lbox.y1)
    return u


def _tab(x: float, leader: str | None = None) -> dict:
    r = {"text": "\t", "font": "", "size": 8.0, "bold": False, "italic": False, "tab_to": x}
    if leader:
        r["leader"] = leader
    return r


_RULE_ROW = 9.0  # pt: the row a stand-alone field rule is drawn in (an underscore leader needs a text row)


def _rule_line(x0: float, x1: float, bottom: float) -> TextLine:
    """A field's bottom rule with no text on its row: an underscore leader from x0 to x1."""
    return TextLine([_tab(x1, "underscore")], BBox(x0, bottom - _RULE_ROW, x1, bottom), anchor=False)


def _value_run(w) -> dict:
    is_box = w.field_type in ("checkbox", "radio")
    if is_box:
        return {"text": "\u2612" if w.checked else "\u2610", "font": "", "size": max(5.0, min(w.lbox.height * 0.8, 10.0)),
                "bold": False, "italic": False}
    return {"text": w.value.strip(), "font": "", "size": max(6.0, min(w.lbox.height * 0.55, 11.0)), "bold": True, "italic": False}


def _sentence_lines(sn, lbox: BBox) -> list[TextLine]:
    """A check-box sentence as its measured source rows (one paragraph each), so
    Word cannot add wrapped lines. Rows carry positioned segments: text with its
    real fonts, box glyphs, and field values with their rule as a tab leader."""
    rows = getattr(sn, "rows", None) or []
    if not rows:
        return [TextLine([{"text": r.text, "font": "", "size": 8.0, "bold": r.bold, "italic": r.italic} for r in sn.runs], lbox)]
    out = []
    for row in rows:
        box, runs = row[0], row[1]
        segs = row[2] if len(row) > 2 else []
        if not segs:
            size = max(6.0, min(box.height * 0.9, 9.0))
            out.append(TextLine([{"text": r.text, "font": "", "size": size, "bold": r.bold, "italic": r.italic} for r in runs], box))
            continue
        text_boxes = [seg for seg in segs if seg[2] == "text"]
        line_runs: list[dict] = []
        prev_x1 = None
        for x0, x1, kind, payload in segs:
            if prev_x1 is not None:
                if x0 - prev_x1 > 3.0:
                    line_runs.append(_tab(x0))
                else:
                    line_runs.append({"text": " ", "font": "", "size": 8.0, "bold": False, "italic": False})
            if kind == "text":
                line_runs.extend(_token_runs(payload))
            elif kind == "box":
                line_runs.append(_value_run(payload))
            else:  # value
                w = payload
                if w.value.strip():
                    line_runs.append(_value_run(w))
                if getattr(w, "underlined", False):
                    line_runs.append(_tab(w.lbox.x1, "underscore"))
                elif not w.value.strip():
                    line_runs.append({"text": "____", "font": "", "size": 8.0, "bold": False, "italic": False})
            prev_x1 = x1
        if text_boxes:
            from ..forms import _tokens_lbox
            tb = _tokens_lbox(text_boxes[0][3])
            for seg in text_boxes[1:]:
                tb = tb.union(_tokens_lbox(seg[3]))
            lb = BBox(box.x0, tb.y0, box.x1, tb.y1)
        else:
            lb = BBox(box.x0, box.y1 - _RULE_ROW, box.x1, box.y1)  # a row holding only a field: its rule
        out.append(TextLine(line_runs, lb, anchor=bool(text_boxes)))
    return out


def _token_runs(tokens) -> list[dict]:
    return token_runs(tokens)


def _field_lines(fp) -> list[TextLine]:
    """An inline (non-cell) field as visual lines with real fonts: the label's
    own lines (with a list marker the label opened), the value at the widget
    with the field's bottom rule as an underscore tab leader, and a trailing hint
    such as "(mm/dd/yyyy)". Pieces sharing a text row merge into one line in x
    order (tab stops at measured positions); a widget below its label becomes a
    line of its own at the widget's bottom row."""
    from ..forms import _token_lines, _tokens_lbox
    w = fp.widget
    tokens = getattr(fp, "sentence_tokens", None) or []
    sub = getattr(fp, "sub_tokens", None) or []
    marker = getattr(fp, "marker_tokens", None) or []
    is_box = w.field_type in ("checkbox", "radio")
    underlined = bool(getattr(w, "underlined", False)) and not is_box
    value = "" if is_box else w.value.strip()
    space = {"text": " ", "font": "", "size": 8.0, "bold": False, "italic": False}
    vrun = _value_run(w)
    row_h = min(w.lbox.height, 1.3 * vrun["size"])
    value_box = BBox(w.lbox.x0, w.lbox.y1 - row_h, w.lbox.x1, w.lbox.y1)   # the widget's text row

    def value_runs() -> list[dict]:
        runs = [vrun] if (is_box or value) else []
        if underlined:
            runs.append(_tab(w.lbox.x1, "underscore"))
        return runs

    lines: list[TextLine] = []
    label_lines = [TextLine(_token_runs(toks), _tokens_lbox(toks)) for toks in _token_lines(tokens)]
    if marker and label_lines:
        first = label_lines[0]
        label_lines[0] = TextLine(_token_runs(marker) + [space] + first.runs, first.lbox.union(_tokens_lbox(marker)))
    lines.extend(label_lines)
    if is_box and label_lines:
        # the box glyph belongs to the label's own row, whichever side it sits on
        first = label_lines[0]
        left = w.lbox.x0 <= first.lbox.x0
        runs = ([vrun, space] + first.runs) if left else (first.runs + [space, vrun])
        lines[0] = TextLine(runs, BBox(min(first.lbox.x0, w.lbox.x0), first.lbox.y0, max(first.lbox.x1, w.lbox.x1), first.lbox.y1))
    elif is_box or value or underlined:
        inside = [ln for ln in label_lines if ln.lbox.x1 > value_box.x0 + 2 and ln.lbox.x0 < value_box.x1 - 2
                  and min(ln.lbox.y1, value_box.y1) - max(ln.lbox.y0, value_box.y0) > 0.5 * min(ln.lbox.height, value_box.height)]
        if inside:
            # the label is printed inside the field box: value follows it on the same line
            k = lines.index(inside[0])
            lines[k] = TextLine(inside[0].runs + [space] + value_runs(), inside[0].lbox.union(value_box))
        else:
            lines.append(TextLine(value_runs(), value_box, anchor=False))
    if sub:
        lines.extend(TextLine(_token_runs(toks), _tokens_lbox(toks)) for toks in _token_lines(sub))
    return _merge_rows(lines)



def write_docx_layout(doc, path: Path) -> dict:
    """Write the layout-preserving DOCX for an IR Document carrying page layouts."""
    writer = LayoutWriter()
    layouts = getattr(doc, "layouts", None) or []
    for layout in layouts:
        writer.add_page(layout, doc.assets, doc)
    stats = writer.save(path)
    stats.pop("_lines", None)   # comment-anchoring scratch, not a result
    stats.setdefault("images_downsampled", 0)
    stats.setdefault("images_downsampled_pages", [])
    stats["max_picture_dpi"] = MAX_PICTURE_DPI
    stats["layout_mode"] = "preserve"
    stats["font_substitution"] = "mapped from PDF font names (see fonts)"
    return stats
