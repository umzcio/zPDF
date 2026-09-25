"""Comment review: threads, status, media comments, FDF/XFDF interchange,
imports from other PDFs, and comparisons between versions.

The app creates and edits comments on the PDFKit display copy; they reach the
document of record through the generic annotation path (`annotations.py`).
This module completes what PDFKit cannot serialize:

* `/ZPDFSpec` (JSON the app attaches to a new or edited annotation) carries
  opacity (/CA), intent (/IT), cloudy borders (/BE), callout geometry, icon
  names, flags, and media: an embedded file for FileAttachment and PCM audio
  for Sound annotations.
* Updates keep data PDFKit drops when it rewrites an annotation it only knows
  generically (appearance streams, embedded files, sounds) and keep vertex
  geometry in step with a moved or resized rectangle.

Queries are read-only; `import_comments` is an ordinary operation (one Undo
step in the app). Interchange formats follow the Adobe FDF / XFDF specs.
"""
import base64
import io
import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path

import pikepdf
from pikepdf import Array, Dictionary, Name

from engine.errors import require
from transforms import op, query
from transforms import annotations as generic

# Subtypes the comment tools own. Widgets, links, popups and screen/media
# annotations are document structure, not comments.
COMMENT_SUBTYPES = ("/Text", "/FreeText", "/Line", "/Square", "/Circle", "/Polygon", "/PolyLine",
                    "/Highlight", "/Underline", "/Squiggly", "/StrikeOut", "/Stamp", "/Caret", "/Ink",
                    "/FileAttachment", "/Sound", "/Redact")
MAX_MEDIA_BYTES = 64 * 1024 * 1024


# ---------------------------------------------------------------- helpers

def _num(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _rect(annot):
    r = [_num(v) for v in annot.get("/Rect", [0, 0, 0, 0])]
    if len(r) != 4:
        return [0.0, 0.0, 0.0, 0.0]
    return [min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3])]


def _fmt(*values):
    return " ".join(f"{float(v):.3f}".rstrip("0").rstrip(".") for v in values)


def _color(value):
    """PDF colour array -> [r, g, b] floats, or None."""
    if value is None:
        return None
    values = [_num(v) for v in value]
    if len(values) == 1:
        return [values[0]] * 3
    if len(values) == 3:
        return values
    if len(values) == 4:  # CMYK
        c, m, y, k = values
        return [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)]
    return None


def _hex(rgb):
    if rgb is None:
        return None
    return "#" + "".join(f"{max(0, min(255, round(v * 255))):02X}" for v in rgb)


def _from_hex(text):
    if not text:
        return None
    text = text.strip().lstrip("#")
    if len(text) != 6 or not re.fullmatch(r"[0-9A-Fa-f]{6}", text):
        return None
    return [int(text[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def _text(value):
    if value is None:
        return None
    try:
        return str(value)
    except Exception:  # noqa: BLE001 - undecodable strings are skipped, not fatal
        return None


def _name(value):
    return str(value)[1:] if value is not None and str(value).startswith("/") else (str(value) if value is not None else None)


def _pdf_date(moment=None):
    moment = moment or datetime.now(timezone.utc)
    return moment.strftime("D:%Y%m%d%H%M%SZ")


def _is_comment(annot):
    return str(annot.get("/Subtype", "")) in COMMENT_SUBTYPES


def _positions(pdf):
    """objgen -> (page, index) for every annotation in the document."""
    table = {}
    for page_index, page in enumerate(pdf.pages):
        for index, annot in enumerate(page.obj.get("/Annots", [])):
            if annot.is_indirect:
                table[annot.objgen] = (page_index, index)
    return table


def _stream(pdf, data, bbox, resources=None, matrix=None):
    form = pikepdf.Stream(pdf, data.encode() if isinstance(data, str) else data)
    form.Type, form.Subtype = Name.XObject, Name.Form
    form.BBox = Array([float(v) for v in bbox])
    form.Resources = resources if resources is not None else Dictionary()
    if matrix:
        form.Matrix = Array([float(v) for v in matrix])
    return pdf.make_indirect(form)


def _appearance_is_empty(annot):
    ap = annot.get("/AP")
    if ap is None or "/N" not in ap:
        return True
    normal = ap.N
    if isinstance(normal, pikepdf.Stream):
        bbox = [_num(v) for v in normal.get("/BBox", [0, 0, 0, 0])]
        if len(bbox) != 4 or abs(bbox[2] - bbox[0]) < 1e-6 or abs(bbox[3] - bbox[1]) < 1e-6:
            return True
        try:
            return len(normal.read_bytes().strip()) <= 3
        except pikepdf.PdfError:
            return False
    return False  # appearance-state dictionaries (checkboxes, toggled stamps) are kept


# ---------------------------------------------------------------- geometry

def cloud_path(points, radius, closed=True):
    """Cloudy border (PDF /BE /S /C) as PDF path operators through `points`.

    Semicircular scallops bulge outward along each edge of a counter-clockwise
    polygon. The same construction draws the on-screen version in the app.
    """
    pts = list(points)
    if len(pts) < 2:
        return ""
    if closed:
        area = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
        if area < 0:
            pts.reverse()
    ops = [f"{_fmt(*pts[0])} m"]
    edges = len(pts) if closed else len(pts) - 1
    k = 0.5523  # quarter-circle bezier constant
    for i in range(edges):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
        length = math.hypot(x1 - x0, y1 - y0)
        if length < 1e-6:
            continue
        count = max(1, round(length / (2 * radius)))
        ux, uy = (x1 - x0) / length, (y1 - y0) / length
        nx, ny = uy, -ux  # outward for counter-clockwise order
        step = length / count
        r = step / 2
        for j in range(count):
            sx, sy = x0 + ux * step * j, y0 + uy * step * j
            cx, cy = sx + ux * r, sy + uy * r
            ex, ey = sx + ux * step, sy + uy * step
            tx, ty = cx + nx * r, cy + ny * r  # arc apex
            ops.append(f"{_fmt(sx + nx * r * k, sy + ny * r * k, tx - ux * r * k, ty - uy * r * k, tx, ty)} c")
            ops.append(f"{_fmt(tx + ux * r * k, ty + uy * r * k, ex + nx * r * k, ey + ny * r * k, ex, ey)} c")
    return " ".join(ops)


def _arrow_head(style, tip, toward, width):
    """Line ending path ops at `tip`, the line arriving from `toward`."""
    style = _name(style) or "None"
    if style == "None":
        return "", False
    (x, y), (fx, fy) = tip, toward
    length = math.hypot(x - fx, y - fy) or 1
    ux, uy = (x - fx) / length, (y - fy) / length
    size = max(6.0, width * 3.5)
    bx, by = x - ux * size, y - uy * size
    px, py = -uy * size * 0.5, ux * size * 0.5
    if style in ("OpenArrow", "ClosedArrow"):
        path = f"{_fmt(bx + px, by + py)} m {_fmt(x, y)} l {_fmt(bx - px, by - py)} l"
        return (path + " h", True) if style == "ClosedArrow" else (path, False)
    if style in ("ROpenArrow", "RClosedArrow"):
        bx, by = x + ux * size, y + uy * size
        path = f"{_fmt(bx + px, by + py)} m {_fmt(x, y)} l {_fmt(bx - px, by - py)} l"
        return (path + " h", True) if style == "RClosedArrow" else (path, False)
    if style == "Butt":
        return f"{_fmt(x + px, y + py)} m {_fmt(x - px, y - py)} l", False
    if style == "Slash":
        return f"{_fmt(x + px + ux * size * 0.5, y + py + uy * size * 0.5)} m {_fmt(x - px - ux * size * 0.5, y - py - uy * size * 0.5)} l", False
    r = size * 0.4
    if style == "Square":
        return f"{_fmt(x - r, y - r, 2 * r, 2 * r)} re", True
    if style in ("Circle", "Diamond"):
        if style == "Diamond":
            return f"{_fmt(x, y + r)} m {_fmt(x + r, y)} l {_fmt(x, y - r)} l {_fmt(x - r, y)} l h", True
        k = r * 0.5523
        return (f"{_fmt(x + r, y)} m {_fmt(x + r, y + k, x + k, y + r, x, y + r)} c {_fmt(x - k, y + r, x - r, y + k, x - r, y)} c "
                f"{_fmt(x - r, y - k, x - k, y - r, x, y - r)} c {_fmt(x + k, y - r, x + r, y - k, x + r, y)} c h"), True
    return "", False


def _points(values):
    nums = [_num(v) for v in values]
    return [(nums[i], nums[i + 1]) for i in range(0, len(nums) - 1, 2)]


def _border(annot):
    bs = annot.get("/BS")
    width, dash = 1.0, None
    if bs is not None:
        width = _num(bs.get("/W", 1), 1.0)
        if str(bs.get("/S", "")) == "/D":
            dash = [_num(v) for v in bs.get("/D", [3])] or [3]
    elif "/Border" in annot:
        border = list(annot.Border)
        if len(border) >= 3:
            width = _num(border[2], 1.0)
        if len(border) >= 4:
            dash = [_num(v) for v in border[3]]
    return width, dash


def _cloud_intensity(annot):
    be = annot.get("/BE")
    if be is None or str(be.get("/S", "")) != "/C":
        return 0.0
    return _num(be.get("/I", 1), 1.0)


# ---------------------------------------------------------------- appearances

def _graphics_state(pdf, annot, resources):
    opacity = _num(annot.get("/CA", 1), 1.0)
    if opacity >= 0.999:
        return ""
    gs = pdf.make_indirect(Dictionary(Type=Name.ExtGState, CA=opacity, ca=opacity))
    resources.ExtGState = Dictionary(GS0=gs)
    return "/GS0 gs "


def build_appearance(pdf, annot):
    """Normal appearance for comment types that arrive without one (imports).

    Returns True when an appearance was created. Existing appearances are the
    author's rendering and are never replaced here.
    """
    subtype = str(annot.get("/Subtype", ""))
    rect = _rect(annot)
    if rect[2] - rect[0] < 0.5 or rect[3] - rect[1] < 0.5:
        return False
    stroke = _color(annot.get("/C"))
    fill = _color(annot.get("/IC"))
    width, dash = _border(annot)
    res = Dictionary()
    gs = _graphics_state(pdf, annot, res)
    ops = ["q", gs]
    if stroke:
        ops.append(_fmt(*stroke) + " RG")
    if fill:
        ops.append(_fmt(*fill) + " rg")
    ops.append(_fmt(width) + " w 1 j 1 J")
    if dash:
        ops.append("[" + _fmt(*dash) + "] 0 d")
    cloud = _cloud_intensity(annot)
    paint = ("B" if fill else "S") if stroke else ("f" if fill else "n")
    if subtype in ("/Square", "/Circle"):
        rd = [_num(v) for v in annot.get("/RD", [0, 0, 0, 0])] if "/RD" in annot else [0, 0, 0, 0]
        inset = width / 2
        x0, y0 = rect[0] + rd[0] + inset, rect[1] + rd[1] + inset
        x1, y1 = rect[2] - rd[2] - inset, rect[3] - rd[3] - inset
        if cloud and subtype == "/Square":
            ops.append(cloud_path([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], 4 + 2 * cloud) + " h " + paint)
        elif subtype == "/Square":
            ops.append(f"{_fmt(x0, y0, x1 - x0, y1 - y0)} re {paint}")
        else:
            cx, cy, rx, ry = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
            kx, ky = rx * 0.5523, ry * 0.5523
            ops.append(f"{_fmt(cx + rx, cy)} m {_fmt(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)} c "
                       f"{_fmt(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)} c "
                       f"{_fmt(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)} c "
                       f"{_fmt(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)} c h {paint}")
    elif subtype in ("/Polygon", "/PolyLine"):
        pts = _points(annot.get("/Vertices", []))
        if len(pts) < 2:
            return False
        if subtype == "/Polygon" and cloud:
            ops.append(cloud_path(pts, 4 + 2 * cloud) + " h " + paint)
        else:
            path = f"{_fmt(*pts[0])} m " + " ".join(f"{_fmt(*p)} l" for p in pts[1:])
            if subtype == "/Polygon":
                ops.append(path + " h " + paint)
            else:
                ops.append(path + " S")
                ops.append(_line_endings(annot, pts[0], pts[1], pts[-1], pts[-2], width, stroke))
    elif subtype == "/Line":
        pts = _points(annot.get("/L", []))
        if len(pts) != 2:
            return False
        ops.append(f"{_fmt(*pts[0])} m {_fmt(*pts[1])} l S")
        ops.append(_line_endings(annot, pts[0], pts[1], pts[1], pts[0], width, stroke))
    elif subtype == "/Ink":
        for stroke_points in annot.get("/InkList", []):
            pts = _points(stroke_points)
            if not pts:
                continue
            ops.append(f"{_fmt(*pts[0])} m " + " ".join(f"{_fmt(*p)} l" for p in pts[1:]) + (" S" if len(pts) > 1 else " 0.5 0 l S"))
    elif subtype in ("/Highlight", "/Underline", "/StrikeOut", "/Squiggly"):
        quads = _points(annot.get("/QuadPoints", []))
        if len(quads) < 4:
            quads = [(rect[0], rect[3]), (rect[2], rect[3]), (rect[0], rect[1]), (rect[2], rect[1])]
        colour = stroke or [1, 1, 0]
        ops = ["q", gs]
        if subtype == "/Highlight":
            res.ExtGState = res.get("/ExtGState", Dictionary())
            res.ExtGState.GSm = pdf.make_indirect(Dictionary(Type=Name.ExtGState, BM=Name.Multiply))
            ops.append("/GSm gs " + _fmt(*colour) + " rg")
        else:
            ops.append(_fmt(*colour) + " RG")
        for i in range(0, len(quads) - 3, 4):
            (ax, ay), (bx, by), (cx, cy), (dx, dy) = quads[i:i + 4]
            height = abs(ay - cy) or 10
            if subtype == "/Highlight":
                ops.append(f"{_fmt(ax, ay)} m {_fmt(bx, by)} l {_fmt(dx, dy)} l {_fmt(cx, cy)} l h f")
            elif subtype == "/Underline":
                ops.append(f"{_fmt(max(0.5, height / 14))} w {_fmt(cx, cy + height * 0.08)} m {_fmt(dx, dy + height * 0.08)} l S")
            elif subtype == "/StrikeOut":
                ops.append(f"{_fmt(max(0.5, height / 14))} w {_fmt(cx, (ay + cy) / 2)} m {_fmt(dx, (by + dy) / 2)} l S")
            else:
                step = max(2.0, height / 6)
                x, y = cx, cy + step / 2
                path = [f"{_fmt(x, y)} m"]
                up = False
                while x < dx:
                    x = min(dx, x + step)
                    path.append(f"{_fmt(x, y + (step / 2 if up else -step / 2))} l")
                    up = not up
                ops.append(f"{_fmt(max(0.5, height / 18))} w " + " ".join(path) + " S")
    elif subtype == "/Caret":
        colour = stroke or [0, 0, 1]
        x0, y0, x1, y1 = rect
        ops = ["q", gs, _fmt(*colour) + " rg",
               f"{_fmt(x0, y0)} m {_fmt((x0 + x1) / 2, y1)} l {_fmt(x1, y0)} l {_fmt((x0 + x1) / 2, y0 + (y1 - y0) * 0.3)} l h f"]
    elif subtype == "/Text":
        colour = stroke or [1, 0.85, 0.15]
        x0, y0, x1, y1 = rect
        w, h = x1 - x0, y1 - y0
        ops = ["q", gs, _fmt(*colour) + " rg 0 G 0.6 w",
               f"{_fmt(x0 + 0.5, y0 + h * 0.2, w - 1, h * 0.8 - 0.5)} re B",
               f"{_fmt(x0 + w * 0.2, y0 + h * 0.2)} m {_fmt(x0 + w * 0.2, y0)} l {_fmt(x0 + w * 0.45, y0 + h * 0.2)} l h B",
               f"{_fmt(x0 + w * 0.2, y0 + h * 0.7)} m {_fmt(x1 - w * 0.2, y0 + h * 0.7)} l {_fmt(x0 + w * 0.2, y0 + h * 0.5)} m "
               f"{_fmt(x1 - w * 0.2, y0 + h * 0.5)} l S"]
    elif subtype in ("/FileAttachment", "/Sound"):
        colour = stroke or [0.2, 0.4, 0.9]
        x0, y0, x1, y1 = rect
        w, h = x1 - x0, y1 - y0
        ops = ["q", gs, "1 1 1 rg", _fmt(*colour) + " RG 1.2 w 1 J 1 j",
               f"{_fmt(x0 + 0.6, y0 + 0.6, w - 1.2, h - 1.2)} re B"]
        if subtype == "/Sound":
            ops.append(f"{_fmt(*colour)} rg {_fmt(x0 + w * 0.25, y0 + h * 0.38, w * 0.15, h * 0.24)} re f "
                       f"{_fmt(x0 + w * 0.4, y0 + h * 0.38)} m {_fmt(x0 + w * 0.6, y0 + h * 0.2)} l "
                       f"{_fmt(x0 + w * 0.6, y0 + h * 0.8)} l {_fmt(x0 + w * 0.4, y0 + h * 0.62)} l h f")
        else:
            ops.append(f"{_fmt(x0 + w * 0.62, y0 + h * 0.72)} m {_fmt(x0 + w * 0.36, y0 + h * 0.3)} l "
                       f"{_fmt(x0 + w * 0.3, y0 + h * 0.2, x0 + w * 0.46, y0 + h * 0.12, x0 + w * 0.5, y0 + h * 0.2)} c "
                       f"{_fmt(x0 + w * 0.72, y0 + h * 0.56)} l S")
    elif subtype == "/FreeText":
        return _free_text_appearance(pdf, annot, rect)
    elif subtype == "/Stamp":
        return _stamp_appearance(pdf, annot, rect)
    else:
        return False
    ops.append("Q")
    annot.AP = Dictionary(N=_stream(pdf, "\n".join(o for o in ops if o), rect, res))
    return True


def _line_endings(annot, start, start_next, end, end_prev, width, stroke):
    le = list(annot.get("/LE", [])) if "/LE" in annot else []
    chunks = []
    for style, tip, toward in ((le[0] if le else None, start, start_next), (le[1] if len(le) > 1 else None, end, end_prev)):
        path, closed = _arrow_head(style, tip, toward, width)
        if path:
            fill = _color(annot.get("/IC")) or stroke
            chunks.append(path + (f" q {_fmt(*fill)} rg B Q" if closed and fill else " S"))
    return " ".join(chunks)


def _wrap(text, width, size, measure):
    lines = []
    for paragraph in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        words, line = paragraph.split(" "), ""
        for word in words:
            candidate = word if not line else line + " " + word
            if measure(candidate, size) <= width or not line:
                line = candidate
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def _helvetica_width(text, size):
    return len(text) * size * 0.5


def _parse_da(da):
    """(font size, [r, g, b]) from a default-appearance string."""
    da = da or ""
    size, colour = 12.0, [0, 0, 0]
    match = re.search(r"([\d.]+)\s+Tf", da)
    if match:
        size = _num(match.group(1), 12.0) or 12.0
    match = re.search(r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+rg", da)
    if match:
        colour = [_num(g) for g in match.groups()]
    else:
        match = re.search(r"([\d.]+)\s+g(\s|$)", da)
        if match:
            colour = [_num(match.group(1))] * 3
    return size, colour


def _free_text_appearance(pdf, annot, rect):
    from transforms.fonts import pdf_string
    size, colour = _parse_da(_text(annot.get("/DA")))
    rd = [_num(v) for v in annot.get("/RD", [0, 0, 0, 0])] if "/RD" in annot else [0, 0, 0, 0]
    x0, y0, x1, y1 = rect[0] + rd[0], rect[1] + rd[1], rect[2] - rd[2], rect[3] - rd[3]
    res = Dictionary(Font=Dictionary(Helv=pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1,
                                                                        BaseFont=Name.Helvetica, Encoding=Name.WinAnsiEncoding))))
    gs = _graphics_state(pdf, annot, res)
    ops = ["q", gs]
    background = _color(annot.get("/C"))
    width, _ = _border(annot)
    if background:
        ops.append(f"{_fmt(*background)} rg {_fmt(x0, y0, x1 - x0, y1 - y0)} re f")
    callout = _points(annot.get("/CL", [])) if "/CL" in annot else []
    if width > 0 and (callout or background or str(annot.get("/IT", "")) == "/FreeTextCallout"):
        ops.append(f"{_fmt(*colour)} RG {_fmt(width)} w {_fmt(x0 + width / 2, y0 + width / 2, x1 - x0 - width, y1 - y0 - width)} re S")
    if len(callout) >= 2:
        ops.append(f"{_fmt(*colour)} RG {_fmt(max(width, 1))} w {_fmt(*callout[0])} m " + " ".join(f"{_fmt(*p)} l" for p in callout[1:]) + " S")
        le = _name(annot.get("/LE")) if "/LE" in annot and not isinstance(annot.get("/LE"), pikepdf.Array) else "OpenArrow"
        path, closed = _arrow_head(le, callout[0], callout[1], max(width, 1))
        if path:
            ops.append(f"{_fmt(*colour)} rg " + path + (" B" if closed else " S"))
    lines = _wrap(_text(annot.get("/Contents")) or "", max(10, x1 - x0 - 4), size, _helvetica_width)
    ops.append(f"BT /Helv {_fmt(size)} Tf {_fmt(*colour)} rg")
    y = y1 - 2 - size
    for line in lines:
        if y < y0 - size:
            break
        ops.append(f"1 0 0 1 {_fmt(x0 + 2, y)} Tm {pdf_string(line)} Tj")
        y -= size * 1.15
    ops.append("ET Q")
    annot.AP = Dictionary(N=_stream(pdf, "\n".join(ops), rect, res))
    return True


STANDARD_STAMPS = {
    "Approved": ("APPROVED", (0.13, 0.55, 0.13)), "NotApproved": ("NOT APPROVED", (0.8, 0.1, 0.1)),
    "Draft": ("DRAFT", (0.1, 0.3, 0.7)), "Final": ("FINAL", (0.13, 0.55, 0.13)),
    "Confidential": ("CONFIDENTIAL", (0.8, 0.1, 0.1)), "ForComment": ("FOR COMMENT", (0.1, 0.3, 0.7)),
    "ForPublicRelease": ("FOR PUBLIC RELEASE", (0.13, 0.55, 0.13)),
    "NotForPublicRelease": ("NOT FOR PUBLIC RELEASE", (0.8, 0.1, 0.1)), "AsIs": ("AS IS", (0.1, 0.3, 0.7)),
    "Departmental": ("DEPARTMENTAL", (0.1, 0.3, 0.7)), "Experimental": ("EXPERIMENTAL", (0.1, 0.3, 0.7)),
    "Expired": ("EXPIRED", (0.8, 0.1, 0.1)), "Sold": ("SOLD", (0.1, 0.3, 0.7)),
    "TopSecret": ("TOP SECRET", (0.8, 0.1, 0.1)),
}


def _stamp_appearance(pdf, annot, rect):
    from transforms.fonts import pdf_string
    name = _name(annot.get("/Name")) or "Draft"
    label, colour = STANDARD_STAMPS.get(name, ((_text(annot.get("/Contents")) or name).upper()[:40], (0.8, 0.1, 0.1)))
    x0, y0, x1, y1 = rect
    w, h = x1 - x0, y1 - y0
    size = max(6.0, min(h * 0.55, w / max(1, len(label)) * 1.6))
    res = Dictionary(Font=Dictionary(HelvB=pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1,
                                                                         BaseFont=Name("/Helvetica-Bold"),
                                                                         Encoding=Name.WinAnsiEncoding))))
    gs = _graphics_state(pdf, annot, res)
    tw = len(label) * size * 0.62
    ops = ["q", gs, f"{_fmt(*colour)} RG {_fmt(*colour)} rg 2 w",
           f"{_fmt(x0 + 1.5, y0 + 1.5, w - 3, h - 3)} re S",
           f"BT /HelvB {_fmt(size)} Tf 1 0 0 1 {_fmt(x0 + max(3, (w - tw) / 2), y0 + (h - size * 0.7) / 2)} Tm {pdf_string(label)} Tj ET",
           "Q"]
    annot.AP = Dictionary(N=_stream(pdf, "\n".join(ops), rect, res))
    return True


# ---------------------------------------------------------------- media

def _wav_to_sound(pdf, path):
    import wave
    data = Path(path).read_bytes()
    require(len(data) <= MAX_MEDIA_BYTES, "INVALID_ARGUMENT", "That recording is too large to embed.")
    try:
        with wave.open(io.BytesIO(data)) as wav:
            rate, channels, width = wav.getframerate(), wav.getnchannels(), wav.getsampwidth()
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError) as exc:
        from engine.errors import EngineError
        raise EngineError("INVALID_ARGUMENT", "Sound comments need 8- or 16-bit PCM WAV audio.") from exc
    require(width in (1, 2) and channels in (1, 2) and rate > 0, "INVALID_ARGUMENT",
            "Sound comments need 8- or 16-bit PCM WAV audio.")
    if width == 2:  # PDF sound samples are big-endian; WAV is little-endian
        swapped = bytearray(frames)
        swapped[0::2], swapped[1::2] = frames[1::2], frames[0::2]
        frames = bytes(swapped)
    sound = pikepdf.Stream(pdf, frames)
    sound.Type = Name.Sound
    sound.R = rate
    sound.C = channels
    sound.B = width * 8
    sound.E = Name.Signed if width == 2 else Name.Raw
    return pdf.make_indirect(sound), len(frames) / max(1, rate * channels * width)


def sound_to_wav(sound):
    """PDF Sound stream -> WAV bytes (PCM encodings only)."""
    import wave
    rate = int(_num(sound.get("/R", 8000), 8000))
    channels = int(_num(sound.get("/C", 1), 1))
    bits = int(_num(sound.get("/B", 8), 8))
    encoding = str(sound.get("/E", "/Raw"))
    require(bits in (8, 16) and encoding in ("/Raw", "/Signed"), "UNSUPPORTED_OPERATION",
            "This sound uses an encoding zPDF can't play.")
    data = sound.read_bytes()
    if bits == 16:
        swapped = bytearray(data[: len(data) // 2 * 2])
        swapped[0::2], swapped[1::2] = data[1::2][: len(swapped) // 2], data[0::2][: len(swapped) // 2]
        data = bytes(swapped)
    elif encoding == "/Signed":
        data = bytes((b + 128) & 0xFF for b in data)  # WAV 8-bit PCM is unsigned
    out = io.BytesIO()
    with wave.open(out, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(bits // 8)
        wav.setframerate(rate)
        wav.writeframes(data)
    return out.getvalue()


def _embed_file(pdf, path, name, description=None, mime=None):
    source = Path(path)
    require(source.is_file(), "INVALID_ARGUMENT", "The attached file is no longer available.")
    data = source.read_bytes()
    require(len(data) <= MAX_MEDIA_BYTES, "INVALID_ARGUMENT", "That file is too large to attach.")
    stream = pikepdf.Stream(pdf, data)
    stream.Type = Name.EmbeddedFile
    if mime:
        stream.Subtype = Name("/" + mime.replace("/", "#2F"))
    stream.Params = Dictionary(Size=len(data), ModDate=pikepdf.String(_pdf_date()))
    spec = Dictionary(Type=Name.Filespec, F=pikepdf.String(name), UF=pikepdf.String(name),
                      EF=Dictionary(F=pdf.make_indirect(stream), UF=pdf.make_indirect(stream)))
    if description:
        spec.Desc = pikepdf.String(description)
    return pdf.make_indirect(spec)


def _file_data(annot):
    spec = annot.get("/FS")
    if spec is None or not isinstance(spec, pikepdf.Dictionary):
        return None, None
    ef = spec.get("/EF")
    stream = None
    if ef is not None:
        stream = ef.get("/UF") or ef.get("/F")
    name = _text(spec.get("/UF")) or _text(spec.get("/F")) or "attachment"
    if not isinstance(stream, pikepdf.Stream):
        return name, None
    return name, stream


# ---------------------------------------------------------------- graft hooks

GEOMETRY = ("/Vertices", "/CL")


def _keep_on_update(ctx, target, copied):
    """PDFKit rewrites annotations it only knows generically without their
    appearance, embedded file or sound. Keep the document's versions."""
    if _appearance_is_empty(copied) and not _appearance_is_empty(target):
        copied.AP = target.AP
    if str(target.get("/Subtype", "")) == "/FileAttachment" and "/FS" in target:
        _, stream = _file_data(copied)
        if stream is None or len(stream.read_bytes()) == 0:
            copied.FS = target.FS
    # Vertex geometry follows a moved/resized rectangle when the app did not
    # send new geometry (the scratch copy then repeats the original values).
    old, new = _rect(target), _rect(copied)
    if old != new and old[2] > old[0] and old[3] > old[1]:
        sx, sy = (new[2] - new[0]) / (old[2] - old[0]), (new[3] - new[1]) / (old[3] - old[1])
        for key in GEOMETRY:
            if key in target and key in copied and [_num(v) for v in target[key]] == [_num(v) for v in copied[key]]:
                pts = _points(copied[key])
                copied[key] = Array([c for x, y in pts for c in (new[0] + (x - old[0]) * sx, new[1] + (y - old[1]) * sy)])


def apply_spec(ctx, annot, page, spec):
    """Complete an annotation from the app's /ZPDFSpec JSON."""
    if not spec:
        if _appearance_is_empty(annot) and _is_comment(annot):
            build_appearance(ctx.pdf, annot)
        return
    pdf = ctx.pdf
    if "opacity" in spec:
        opacity = max(0.05, min(1.0, _num(spec["opacity"], 1.0)))
        if opacity < 0.999:
            annot.CA = opacity
        elif "/CA" in annot:
            del annot["/CA"]
    if spec.get("intent"):
        annot.IT = Name("/" + str(spec["intent"]).lstrip("/"))
    elif "intent" in spec and "/IT" in annot:
        del annot["/IT"]
    if "cloudy" in spec:
        intensity = _num(spec["cloudy"], 0)
        if intensity > 0:
            annot.BE = Dictionary(S=Name.C, I=min(2.0, intensity))
        elif "/BE" in annot:
            del annot["/BE"]
    if "rd" in spec and isinstance(spec["rd"], list) and len(spec["rd"]) == 4:
        annot.RD = Array([max(0.0, _num(v)) for v in spec["rd"]])
    if "callout" in spec and isinstance(spec["callout"], list):
        values = [_num(v) for v in spec["callout"]]
        if len(values) in (4, 6):
            annot.CL = Array(values)
            annot.LE = Name("/" + str(spec.get("callout_end", "OpenArrow")))
        elif "/CL" in annot:
            del annot["/CL"]
    if "vertices" in spec and isinstance(spec["vertices"], list) and len(spec["vertices"]) >= 4:
        annot.Vertices = Array([_num(v) for v in spec["vertices"]])
    if "line_endings" in spec and isinstance(spec["line_endings"], list) and len(spec["line_endings"]) == 2:
        annot.LE = Array([Name("/" + str(v)) for v in spec["line_endings"]])
    if spec.get("icon"):
        annot.Name = Name("/" + str(spec["icon"]))
    if spec.get("symbol"):  # Caret: /P paragraph symbol or /None
        annot.Sy = Name("/" + str(spec["symbol"]))
    if "flags" in spec:
        annot.F = int(_num(spec["flags"], 4))
    if spec.get("subject"):
        annot.Subj = pikepdf.String(str(spec["subject"]))
    if spec.get("creation_date"):
        annot.CreationDate = pikepdf.String(str(spec["creation_date"]))
    if spec.get("nm") and "/NM" not in annot:
        annot.NM = pikepdf.String(str(spec["nm"]))
    if isinstance(spec.get("attach"), dict):
        media = spec["attach"]
        annot.FS = _embed_file(pdf, media.get("path", ""), str(media.get("name") or "attachment"),
                               media.get("description"), media.get("mime"))
        annot.Name = Name("/" + str(media.get("icon") or "PushPin"))
    if isinstance(spec.get("sound"), dict):
        annot.Sound, _ = _wav_to_sound(pdf, spec["sound"].get("path", ""))
        annot.Name = Name("/" + str(spec["sound"].get("icon") or "Speaker"))
    if spec.get("rebuild_appearance") or (_appearance_is_empty(annot) and _is_comment(annot)):
        build_appearance(pdf, annot)


generic.UPDATE_HOOKS.append(_keep_on_update)
generic.GRAFT_HOOKS.append(apply_spec)


# ---------------------------------------------------------------- inventory

def _describe(annot, positions):
    subtype = _name(annot.get("/Subtype"))
    irt = annot.get("/IRT")
    parent = positions.get(irt.objgen) if irt is not None and irt.is_indirect else None
    info = {
        "subtype": subtype,
        "rect": _rect(annot),
        "nm": _text(annot.get("/NM")),
        "author": _text(annot.get("/T")),
        "contents": _text(annot.get("/Contents")),
        "subject": _text(annot.get("/Subj")),
        "modified": _text(annot.get("/M")),
        "created": _text(annot.get("/CreationDate")),
        "color": _hex(_color(annot.get("/C"))),
        "fill": _hex(_color(annot.get("/IC"))),
        "opacity": _num(annot.get("/CA", 1), 1.0),
        "flags": int(_num(annot.get("/F", 0))),
        "irt": list(parent) if parent else None,
        "rt": _name(annot.get("/RT")) if irt is not None else None,
        "state": _name(annot.get("/State")),
        "state_model": _name(annot.get("/StateModel")),
        "intent": _name(annot.get("/IT")),
        "icon": _name(annot.get("/Name")),
        "cloudy": _cloud_intensity(annot),
    }
    if subtype == "FileAttachment":
        name, stream = _file_data(annot)
        info["file_name"] = name
        info["file_size"] = int(_num(stream.get("/Params", {}).get("/Size", 0))) if stream is not None and "/Params" in stream else (
            len(stream.read_bytes()) if stream is not None else 0)
    if subtype == "Sound":
        sound = annot.get("/Sound")
        if isinstance(sound, pikepdf.Stream):
            rate, channels, bits = _num(sound.get("/R", 8000), 8000), _num(sound.get("/C", 1), 1), _num(sound.get("/B", 8), 8)
            info["duration"] = round(len(sound.read_bytes()) / max(1, rate * channels * bits / 8), 2)
    return info


@query("comment_threads")
def comment_threads(ctx):
    """Every comment's review metadata in page/annotation-index terms."""
    positions = _positions(ctx.pdf)
    pages = []
    for page in ctx.pdf.pages:
        items = []
        for index, annot in enumerate(page.obj.get("/Annots", [])):
            if not _is_comment(annot):
                continue
            items.append({"index": index, **_describe(annot, positions)})
        pages.append(items)
    return {"pages": pages}


def _annotation_at(pdf, page, index):
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "That page no longer exists.")
    annots = pdf.pages[page].obj.get("/Annots", [])
    require(isinstance(index, int) and 0 <= index < len(annots), "STALE_ANNOTATION", "That comment no longer exists.")
    return annots[index]


@query("comment_attachment")
def comment_attachment(ctx, page, index):
    annot = _annotation_at(ctx.pdf, page, index)
    require(str(annot.get("/Subtype", "")) == "/FileAttachment", "INVALID_ARGUMENT", "That comment has no attached file.")
    name, stream = _file_data(annot)
    require(stream is not None, "INVALID_ARGUMENT", "The attached file's data is missing.")
    data = stream.read_bytes()
    return {"name": name, "size": len(data), "data": base64.b64encode(data).decode("ascii")}


@query("comment_sound")
def comment_sound(ctx, page, index):
    annot = _annotation_at(ctx.pdf, page, index)
    sound = annot.get("/Sound")
    require(str(annot.get("/Subtype", "")) == "/Sound" and isinstance(sound, pikepdf.Stream), "INVALID_ARGUMENT",
            "That comment has no recording.")
    return {"wav": base64.b64encode(sound_to_wav(sound)).decode("ascii")}


# ---------------------------------------------------------------- FDF

def _comment_list(pdf, pages=None):
    """(page_index, index, annot) for comments, replies after their parents."""
    wanted = set(pages) if pages is not None else None
    out = []
    for page_index, page in enumerate(pdf.pages):
        if wanted is not None and page_index not in wanted:
            continue
        for index, annot in enumerate(page.obj.get("/Annots", [])):
            if _is_comment(annot):
                out.append((page_index, index, annot))
    return out


def _ensure_names(pdf):
    """Stable names used only in exported files (the document is not changed)."""
    names = {}
    for page_index, index, annot in _comment_list(pdf):
        names[annot.objgen] = _text(annot.get("/NM")) or f"zpdf-{page_index}-{index}"
    return names


@query("export_comments")
def export_comments(ctx, format="xfdf", file_name="document.pdf"):
    require(format in ("xfdf", "fdf"), "INVALID_ARGUMENT", "Choose FDF or XFDF.")
    if format == "fdf":
        return {"format": "fdf", "data": base64.b64encode(_export_fdf(ctx, file_name)).decode("ascii"),
                "count": len(_comment_list(ctx.pdf))}
    xml, count = _export_xfdf(ctx.pdf, file_name)
    return {"format": "xfdf", "text": xml, "count": count}


def _export_fdf(ctx, file_name):
    fdf = pikepdf.new()
    source = ctx.pdf
    comments = _comment_list(source)
    copies = {}
    for page_index, index, annot in comments:
        clone = Dictionary()
        for key, value in annot.items():
            if key in ("/P", "/Popup", "/IRT", "/Parent", "/StructParent", "/OC"):
                continue
            clone[key] = value
        clone.Page = page_index
        copies[annot.objgen] = fdf.make_indirect(fdf.copy_foreign(source.make_indirect(clone)))
    for page_index, index, annot in comments:
        irt = annot.get("/IRT")
        if irt is not None and irt.is_indirect and irt.objgen in copies:
            copies[annot.objgen].IRT = copies[irt.objgen]
    # qpdf needs an (empty) page tree to serialize; FDF readers only use /FDF.
    fdf.Root.FDF = Dictionary(Annots=Array(list(copies.values())), F=pikepdf.String(file_name))
    out = io.BytesIO()
    fdf.save(out, compress_streams=True, static_id=True)
    data = out.getvalue()
    # FDF uses the PDF object syntax with its own header line.
    header_end = data.index(b"\n")
    return b"%FDF-1.2" + b" " * max(0, header_end - 8) + data[header_end:]


def _load_fdf(path):
    raw = Path(path).read_bytes()
    require(raw[:5] in (b"%FDF-", b"%PDF-"), "INVALID_ARGUMENT", "That file is not an FDF file.")
    header_end = raw.index(b"\n") if b"\n" in raw[:64] else 8
    patched = b"%PDF-1.7" + b" " * max(0, header_end - 8) + raw[header_end:]
    try:
        doc = pikepdf.open(io.BytesIO(patched))
    except pikepdf.PdfError as exc:
        from engine.errors import EngineError
        raise EngineError("INVALID_ARGUMENT", "That FDF file could not be read.") from exc
    fdf = doc.Root.get("/FDF")
    require(fdf is not None, "INVALID_ARGUMENT", "That FDF file contains no comments.")
    return doc, list(fdf.get("/Annots", []))


# ---------------------------------------------------------------- XFDF

XFDF_NS = "http://ns.adobe.com/xfdf/"
XFDF_TAGS = {"Text": "text", "FreeText": "freetext", "Line": "line", "Square": "square", "Circle": "circle",
             "Polygon": "polygon", "PolyLine": "polyline", "Highlight": "highlight", "Underline": "underline",
             "Squiggly": "squiggly", "StrikeOut": "strikeout", "Stamp": "stamp", "Caret": "caret", "Ink": "ink",
             "FileAttachment": "fileattachment", "Sound": "sound"}
SUBTYPES_BY_TAG = {v: k for k, v in XFDF_TAGS.items()}
FLAG_NAMES = [(1, "invisible"), (2, "hidden"), (4, "print"), (8, "nozoom"), (16, "norotate"), (32, "noview"),
              (64, "readonly"), (128, "locked"), (256, "togglenoview")]


def _coords(values):
    return ",".join(_fmt(v) for v in values)


def _export_xfdf(pdf, file_name):
    from lxml import etree
    names = _ensure_names(pdf)
    root = etree.Element("{%s}xfdf" % XFDF_NS, nsmap={None: XFDF_NS})
    root.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
    annots = etree.SubElement(root, "{%s}annots" % XFDF_NS)
    count = 0
    for page_index, index, annot in _comment_list(pdf):
        subtype = _name(annot.get("/Subtype"))
        tag = XFDF_TAGS.get(subtype)
        if tag is None:
            continue
        el = etree.SubElement(annots, "{%s}%s" % (XFDF_NS, tag))
        el.set("page", str(page_index))
        el.set("rect", _coords(_rect(annot)))
        el.set("name", names[annot.objgen])
        flags = int(_num(annot.get("/F", 0)))
        if flags:
            el.set("flags", ",".join(label for bit, label in FLAG_NAMES if flags & bit))
        for key, attr in (("/T", "title"), ("/Subj", "subject"), ("/M", "date"), ("/CreationDate", "creationdate")):
            value = _text(annot.get(key))
            if value:
                el.set(attr, value)
        colour = _hex(_color(annot.get("/C")))
        if colour:
            el.set("color", colour)
        fill = _hex(_color(annot.get("/IC")))
        if fill:
            el.set("interior-color", fill)
        if "/CA" in annot:
            el.set("opacity", _fmt(_num(annot.CA, 1)))
        width, dash = _border(annot)
        if subtype not in ("Text", "Highlight", "Underline", "StrikeOut", "Squiggly", "FileAttachment", "Sound", "Stamp"):
            el.set("width", _fmt(width))
            if dash:
                el.set("style", "dash")
                el.set("dashes", _coords(dash))
            if _cloud_intensity(annot):
                el.set("style", "cloudy")
                el.set("intensity", _fmt(_cloud_intensity(annot)))
        irt = annot.get("/IRT")
        if irt is not None and irt.is_indirect and irt.objgen in names:
            el.set("inreplyto", names[irt.objgen])
            if str(annot.get("/RT", "/R")) == "/Group":
                el.set("replyType", "group")
        for key, attr in (("/State", "state"), ("/StateModel", "statemodel"), ("/IT", "intent")):
            if key in annot:
                el.set(attr, _name(annot[key]))
        if "/Name" in annot and subtype in ("Text", "Stamp", "FileAttachment", "Sound"):
            el.set("icon", _name(annot.Name))
        if "/QuadPoints" in annot:
            el.set("coords", _coords(annot.QuadPoints))
        if subtype == "Line" and "/L" in annot:
            line = [_num(v) for v in annot.L]
            el.set("start", _coords(line[:2]))
            el.set("end", _coords(line[2:4]))
        if "/LE" in annot:
            le = annot.LE
            if isinstance(le, pikepdf.Array):
                if len(le) > 0:
                    el.set("head", _name(le[0]))
                if len(le) > 1:
                    el.set("tail", _name(le[1]))
            else:
                el.set("head", _name(le))
        if "/RD" in annot:
            el.set("fringe", _coords(annot.RD))
        if subtype == "Caret" and "/Sy" in annot:
            el.set("symbol", _name(annot.Sy))
        if subtype == "FreeText":
            if "/CL" in annot:
                el.set("callout", _coords(annot.CL))
            da = _text(annot.get("/DA"))
            if da:
                etree.SubElement(el, "{%s}defaultappearance" % XFDF_NS).text = da
        contents = _text(annot.get("/Contents"))
        if contents:
            etree.SubElement(el, "{%s}contents" % XFDF_NS).text = contents
        if subtype in ("Polygon", "PolyLine") and "/Vertices" in annot:
            etree.SubElement(el, "{%s}vertices" % XFDF_NS).text = ";".join(_coords(p) for p in _points(annot.Vertices))
        if subtype == "Ink" and "/InkList" in annot:
            inklist = etree.SubElement(el, "{%s}inklist" % XFDF_NS)
            for gesture in annot.InkList:
                etree.SubElement(inklist, "{%s}gesture" % XFDF_NS).text = ";".join(_coords(p) for p in _points(gesture))
        if subtype == "FileAttachment":
            name, stream = _file_data(annot)
            el.set("file", name or "attachment")
            if stream is not None:
                data = etree.SubElement(el, "{%s}data" % XFDF_NS)
                payload = stream.read_bytes()
                data.set("MODE", "raw")
                data.set("encoding", "base64")
                data.set("length", str(len(payload)))
                data.text = base64.b64encode(payload).decode("ascii")
        if subtype == "Sound" and isinstance(annot.get("/Sound"), pikepdf.Stream):
            sound = annot.Sound
            el.set("bits", str(int(_num(sound.get("/B", 8)))))
            el.set("channels", str(int(_num(sound.get("/C", 1)))))
            el.set("rate", str(int(_num(sound.get("/R", 8000)))))
            el.set("encoding", _name(sound.get("/E", Name.Raw)))
            data = etree.SubElement(el, "{%s}data" % XFDF_NS)
            payload = sound.read_bytes()
            data.set("MODE", "raw")
            data.set("encoding", "base64")
            data.set("length", str(len(payload)))
            data.text = base64.b64encode(payload).decode("ascii")
        count += 1
    etree.SubElement(root, "{%s}f" % XFDF_NS).set("href", file_name)
    text = etree.tostring(root, xml_declaration=True, encoding="UTF-8", pretty_print=True).decode("utf-8")
    return text, count


def _floats(text):
    return [_num(v) for v in re.split(r"[,;\s]+", (text or "").strip()) if v]


def _xfdf_annotations(pdf, path):
    """Parse XFDF into (page, dictionary, name, inreplyto, replytype)."""
    from lxml import etree
    parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=False)
    try:
        tree = etree.parse(str(path), parser)
    except etree.XMLSyntaxError as exc:
        from engine.errors import EngineError
        raise EngineError("INVALID_ARGUMENT", "That XFDF file could not be read.") from exc
    out = []
    for el in tree.getroot().iter():
        if not isinstance(el.tag, str):
            continue
        tag = etree.QName(el).localname
        subtype = SUBTYPES_BY_TAG.get(tag)
        if subtype is None:
            continue
        rect = _floats(el.get("rect"))
        if len(rect) != 4:
            continue
        annot = Dictionary(Type=Name.Annot, Subtype=Name("/" + subtype), Rect=Array(rect))
        flags = 0
        for part in (el.get("flags") or "print").split(","):
            flags |= next((bit for bit, label in FLAG_NAMES if label == part.strip().lower()), 0)
        annot.F = flags
        for attr, key in (("title", "/T"), ("subject", "/Subj"), ("date", "/M"), ("creationdate", "/CreationDate"),
                          ("name", "/NM")):
            if el.get(attr):
                annot[Name(key)] = pikepdf.String(el.get(attr))
        for attr, key in (("color", "/C"), ("interior-color", "/IC")):
            rgb = _from_hex(el.get(attr))
            if rgb:
                annot[Name(key)] = Array(rgb)
        if el.get("opacity"):
            annot.CA = max(0.0, min(1.0, _num(el.get("opacity"), 1)))
        if el.get("width") or el.get("style"):
            bs = Dictionary(W=_num(el.get("width"), 1))
            if el.get("style") == "dash":
                bs.S = Name.D
                bs.D = Array(_floats(el.get("dashes")) or [3, 3])
            annot.BS = bs
            if el.get("style") == "cloudy":
                annot.BE = Dictionary(S=Name.C, I=_num(el.get("intensity"), 1))
        for attr, key in (("state", "/State"), ("statemodel", "/StateModel"), ("intent", "/IT"),
                          ("icon", "/Name"), ("symbol", "/Sy")):
            if el.get(attr):
                annot[Name(key)] = Name("/" + el.get(attr))
        if el.get("coords"):
            annot.QuadPoints = Array(_floats(el.get("coords")))
        if el.get("start") and el.get("end"):
            annot.L = Array(_floats(el.get("start"))[:2] + _floats(el.get("end"))[:2])
        if el.get("head") or el.get("tail"):
            annot.LE = Array([Name("/" + (el.get("head") or "None")), Name("/" + (el.get("tail") or "None"))])
        if el.get("fringe"):
            annot.RD = Array(_floats(el.get("fringe")))
        if el.get("callout"):
            annot.CL = Array(_floats(el.get("callout")))
        for child in el:
            if not isinstance(child.tag, str):
                continue
            name = etree.QName(child).localname
            if name == "contents":
                annot.Contents = pikepdf.String(child.text or "")
            elif name == "contents-richtext" and "/Contents" not in annot:
                annot.Contents = pikepdf.String("".join(child.itertext()))
            elif name == "defaultappearance":
                annot.DA = pikepdf.String(child.text or "")
            elif name == "vertices":
                annot.Vertices = Array(_floats(child.text))
            elif name == "inklist":
                annot.InkList = Array([Array(_floats(g.text)) for g in child if isinstance(g.tag, str)])
            elif name == "data":
                payload = (child.text or "").strip()
                try:
                    raw = base64.b64decode(payload) if child.get("encoding", "hex") == "base64" else bytes.fromhex(payload)
                except ValueError:
                    raw = b""
                require(len(raw) <= MAX_MEDIA_BYTES, "INVALID_ARGUMENT", "An attachment in that file is too large.")
                if subtype == "FileAttachment":
                    stream = pikepdf.Stream(pdf, raw)
                    stream.Type = Name.EmbeddedFile
                    stream.Params = Dictionary(Size=len(raw))
                    file_name = el.get("file") or "attachment"
                    annot.FS = pdf.make_indirect(Dictionary(Type=Name.Filespec, F=pikepdf.String(file_name),
                                                            UF=pikepdf.String(file_name),
                                                            EF=Dictionary(F=pdf.make_indirect(stream))))
                elif subtype == "Sound":
                    stream = pikepdf.Stream(pdf, raw)
                    stream.Type = Name.Sound
                    stream.R = int(_num(el.get("rate"), 8000))
                    stream.C = int(_num(el.get("channels"), 1))
                    stream.B = int(_num(el.get("bits"), 8))
                    stream.E = Name("/" + (el.get("encoding") or "Raw"))
                    annot.Sound = pdf.make_indirect(stream)
        out.append((int(_num(el.get("page"), 0)), annot, el.get("name"), el.get("inreplyto"),
                    "Group" if (el.get("replyType") or "").lower() == "group" else "R"))
    return out


# ---------------------------------------------------------------- import

def _existing_names(pdf):
    return {str(a.NM) for p in pdf.pages for a in p.obj.get("/Annots", []) if "/NM" in a}


@op("import_comments")
def import_comments(ctx, path, format=None, replace_existing=False):
    """Add comments from an FDF, XFDF or PDF file. Comments whose /NM already
    exists in this document are skipped (re-importing is idempotent)."""
    pdf = ctx.pdf
    source = Path(path)
    require(source.is_file(), "INVALID_ARGUMENT", "The comments file is no longer available.")
    if format is None:
        format = {".fdf": "fdf", ".xfdf": "xfdf", ".pdf": "pdf"}.get(source.suffix.lower(), "")
    require(format in ("fdf", "xfdf", "pdf"), "INVALID_ARGUMENT", "Choose an FDF, XFDF or PDF file.")
    entries = []  # (page, dict-in-this-pdf, name, parent-name | parent-foreign-objgen, reply type)
    foreign_parents = {}
    if format == "xfdf":
        entries = _xfdf_annotations(pdf, source)
    else:
        if format == "fdf":
            other, annots = _load_fdf(source)
            listed = [(int(_num(a.get("/Page", 0))), a) for a in annots]
        else:
            try:
                other = pikepdf.open(source)
            except pikepdf.PasswordError as exc:
                from engine.errors import EngineError
                raise EngineError("PASSWORD_REQUIRED", "That PDF needs its password; open it and export its comments instead.") from exc
            except pikepdf.PdfError as exc:
                from engine.errors import EngineError
                raise EngineError("INVALID_PDF", "That file could not be read as a PDF.") from exc
            listed = [(page_index, annot) for page_index, _, annot in _comment_list(other)]
        with other:
            for page_index, annot in listed:
                if not _is_comment(annot):
                    continue
                clone = Dictionary()
                for key, value in annot.items():
                    if key in ("/P", "/Popup", "/IRT", "/Parent", "/Page", "/StructParent", "/OC"):
                        continue
                    clone[key] = value
                copied = pdf.copy_foreign(other.make_indirect(clone))
                irt = annot.get("/IRT")
                parent = irt.objgen if irt is not None and irt.is_indirect else None
                foreign_parents[id(copied)] = annot.objgen if annot.is_indirect else None
                entries.append((page_index, copied, _text(annot.get("/NM")), parent,
                                "Group" if str(annot.get("/RT", "/R")) == "/Group" else "R"))
    existing = _existing_names(pdf)
    created_by_name, created_by_foreign = {}, {}
    added = skipped = 0
    placed = []
    for page_index, annot, name, parent, reply_type in entries:
        if not (0 <= page_index < len(pdf.pages)):
            skipped += 1
            continue
        if name and name in existing:
            skipped += 1
            continue
        obj = annot if annot.is_indirect else pdf.make_indirect(annot)
        page = pdf.pages[page_index]
        obj.P = page.obj
        if "/Annots" not in page.obj:
            page.obj.Annots = Array()
        page.obj.Annots.append(obj)
        if _appearance_is_empty(obj):
            build_appearance(pdf, obj)
        if name:
            created_by_name[name] = obj
        foreign = foreign_parents.get(id(annot))
        if foreign is not None:
            created_by_foreign[foreign] = obj
        placed.append((obj, parent, reply_type))
        added += 1
    for obj, parent, reply_type in placed:
        target = created_by_name.get(parent) if isinstance(parent, str) else created_by_foreign.get(parent)
        if target is None and isinstance(parent, str):
            target = next((a for p in pdf.pages for a in p.obj.get("/Annots", []) if _text(a.get("/NM")) == parent
                           and a.objgen != obj.objgen), None)
        if target is not None:
            obj.IRT = target
            obj.RT = Name("/" + reply_type)
    return {"added": added, "skipped": skipped}


# ---------------------------------------------------------------- compare

def _signature(page_index, info):
    rect = [round(v) for v in info["rect"]]
    return (page_index, info["subtype"], info.get("author") or "", tuple(rect))


@query("compare_comments")
def compare_comments(ctx, other):
    """Comments added, removed or changed in this document relative to `other`."""
    source = Path(other)
    require(source.is_file(), "INVALID_ARGUMENT", "The comparison file is no longer available.")
    try:
        theirs_pdf = pikepdf.open(source)
    except pikepdf.PdfError as exc:
        from engine.errors import EngineError
        raise EngineError("INVALID_PDF", "The comparison file could not be read as a PDF.") from exc

    def inventory(pdf):
        positions = _positions(pdf)
        return [(page_index, index, _describe(annot, positions)) for page_index, index, annot in _comment_list(pdf)]

    with theirs_pdf:
        theirs = inventory(theirs_pdf)
    ours = inventory(ctx.pdf)
    unmatched = list(range(len(theirs)))

    def take(predicate):
        for position, k in enumerate(unmatched):
            if predicate(theirs[k]):
                return unmatched.pop(position)
        return None

    added, changed, unchanged = [], [], 0
    for page_index, index, info in ours:
        k = None
        if info.get("nm"):
            k = take(lambda t: t[2].get("nm") == info["nm"])
        if k is None:
            k = take(lambda t: _signature(t[0], t[2]) == _signature(page_index, info))
        if k is None:
            k = take(lambda t: t[0] == page_index and t[2]["subtype"] == info["subtype"]
                     and (t[2].get("contents") or "") == (info.get("contents") or "") and (info.get("contents") or ""))
        entry = {"page": page_index, "index": index, **info}
        if k is None:
            added.append(entry)
            continue
        before = theirs[k][2]
        differences = [field for field in ("contents", "color", "fill", "state", "author", "opacity")
                       if (before.get(field) or None) != (info.get(field) or None)]
        if theirs[k][0] != page_index or any(abs(a - b) > 1 for a, b in zip(before["rect"], info["rect"])):
            differences.append("position")
        if differences:
            changed.append({**entry, "changes": differences, "before": {f: before.get(f) for f in differences if f != "position"}})
        else:
            unchanged += 1
    removed = [{"page": theirs[k][0], "index": theirs[k][1], **theirs[k][2]} for k in unmatched]
    return {"added": added, "removed": removed, "changed": changed, "unchanged": unchanged}
