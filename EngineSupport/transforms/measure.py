"""Measuring: snap geometry, measurement annotations and page scales.

* `vector_snap_points` reads the page's vector paths (and image bounds) through
  PDFium so the canvas can snap to endpoints, midpoints and intersections.
* `add_measurements` writes standard Line / PolyLine / Polygon annotations with
  a /Measure dictionary (ISO 32000 12.9) and a real appearance stream, so
  other viewers show and recognise them as measurements.
* `set_page_scale` / `page_scales` store and read a page scale as a /VP
  viewport with a rectilinear /Measure dictionary.

All coordinates are PDF user space of the page (unrotated), in points.
"""
from datetime import datetime, timezone
import ctypes
import math
import uuid

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op, query
from transforms.content import multiply, apply, page_box, select_pages, fmt

SCALE_NAME = "zPDF scale"
KINDS = {"distance": ("/Line", "/LineDimension"),
         "perimeter": ("/PolyLine", "/PolyLineDimension"),
         "area": ("/Polygon", "/PolygonDimension")}
INTENT_KIND = {"/LineDimension": "distance", "/PolyLineDimension": "perimeter", "/PolygonDimension": "area"}
SUBTYPE_KIND = {"/Line": "distance", "/PolyLine": "perimeter", "/Polygon": "area"}

# Helvetica advance widths (1/1000 em) for ASCII 32..126 (Adobe AFM).
_HELV = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
         556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
         1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
         667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
         333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
         556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]


def text_width(text, size):
    total = 0
    for ch in text:
        code = ord(ch)
        total += _HELV[code - 32] if 32 <= code <= 126 else 556
    return total * size / 1000.0


def pdf_literal(text):
    raw = str(text).encode("cp1252", errors="replace")
    return "(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)").decode("latin-1") + ")"


def pdf_date(moment=None):
    moment = moment or datetime.now(timezone.utc)
    return moment.strftime("D:%Y%m%d%H%M%S+00'00'")


# ---------------------------------------------------------------- snapping

def _collect(get, count, parent, out, images):
    import pypdfium2.raw as c
    for i in range(count):
        obj = get(i)
        kind = c.FPDFPageObj_GetType(obj)
        m = c.FS_MATRIX()
        c.FPDFPageObj_GetMatrix(obj, m)
        local = (m.a, m.b, m.c, m.d, m.e, m.f)
        if kind == c.FPDF_PAGEOBJ_FORM:
            # The form object's matrix is the CTM at `Do`; children already
            # include the form's own /Matrix.
            full = multiply(local, parent)
            _collect(lambda k, o=obj: c.FPDFFormObj_GetObject(o, k), c.FPDFFormObj_CountObjects(obj),
                     full, out, images)
        elif kind == c.FPDF_PAGEOBJ_PATH:
            full = multiply(local, parent)
            _path_segments(obj, full, out)
        elif kind == c.FPDF_PAGEOBJ_IMAGE:
            # Image objects draw the unit square through their matrix.
            full = multiply(local, parent)
            images.append([apply(full, x, y) for x, y in ((0, 0), (1, 0), (1, 1), (0, 1))])


def _path_segments(obj, matrix, out):
    import pypdfium2.raw as c
    x, y = ctypes.c_float(), ctypes.c_float()
    start = current = None
    pending = []
    for j in range(c.FPDFPath_CountSegments(obj)):
        seg = c.FPDFPath_GetPathSegment(obj, j)
        if not seg:
            continue
        c.FPDFPathSegment_GetPoint(seg, x, y)
        point = apply(matrix, x.value, y.value)
        stype = c.FPDFPathSegment_GetType(seg)
        if stype == c.FPDF_SEGMENT_MOVETO:
            start = current = point
            out["endpoints"].append(point)
            pending = []
        elif stype == c.FPDF_SEGMENT_LINETO and current is not None:
            out["lines"].append((current, point))
            out["endpoints"].append(point)
            current = point
        elif stype == c.FPDF_SEGMENT_BEZIERTO and current is not None:
            pending.append(point)
            if len(pending) == 3:
                p0, (p1, p2, p3) = current, pending
                previous = p0
                for step in range(1, 5):  # flattened sub-segments
                    t = step / 4
                    u = 1 - t
                    q = (u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                         u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1])
                    out["curves"].append((previous, q))
                    previous = q
                out["endpoints"].append(p3)
                current = p3
                pending = []
        if c.FPDFPathSegment_GetClose(seg) and start is not None and current is not None:
            if current != start:
                out["lines"].append((current, start))
            current = start


def _key(point):
    return (round(point[0], 2), round(point[1], 2))


def _dedupe(points, limit):
    seen, result = set(), []
    if limit <= 0:
        return result
    for p in points:
        k = _key(p)
        if k in seen or not all(math.isfinite(v) for v in k):
            continue
        seen.add(k)
        result.append([k[0], k[1]])
        if len(result) >= limit:
            break
    return result


def _intersect(a, b):
    (x1, y1), (x2, y2) = a
    (x3, y3), (x4, y4) = b
    d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if abs(d) < 1e-9:
        return None
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d
    u = ((x1 - x3) * (y1 - y2) - (y1 - y3) * (x1 - x2)) / d
    eps = 1e-6
    if -eps <= t <= 1 + eps and -eps <= u <= 1 + eps:
        p = (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
        # Shared endpoints (a polyline's joints) are already endpoints.
        at_end_a = t <= eps or t >= 1 - eps
        at_end_b = u <= eps or u >= 1 - eps
        if at_end_a and at_end_b:
            return None
        return p
    return None


def _intersections(lines, limit):
    """Straight-segment intersections using a uniform grid of buckets."""
    if len(lines) < 2:
        return []
    xs = [v for (p, q) in lines for v in (p[0], q[0])]
    ys = [v for (p, q) in lines for v in (p[1], q[1])]
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1.0)
    cells = max(1, min(256, int(math.sqrt(len(lines)))))
    size = span / cells
    ox, oy = min(xs), min(ys)
    buckets = {}
    for index, (p, q) in enumerate(lines):
        gx0, gx1 = sorted((int((p[0] - ox) / size), int((q[0] - ox) / size)))
        gy0, gy1 = sorted((int((p[1] - oy) / size), int((q[1] - oy) / size)))
        if (gx1 - gx0 + 1) * (gy1 - gy0 + 1) > 4096:  # huge segment: coarse fallback
            gx0, gx1 = max(gx0, 0), min(gx1, cells)
            gy0, gy1 = max(gy0, 0), min(gy1, cells)
        for gx in range(gx0, gx1 + 1):
            for gy in range(gy0, gy1 + 1):
                buckets.setdefault((gx, gy), []).append(index)
    found, tested = [], set()
    budget = 2_000_000
    for members in buckets.values():
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                a, b = members[i], members[j]
                pair = (a, b) if a < b else (b, a)
                if pair in tested:
                    continue
                tested.add(pair)
                budget -= 1
                if budget <= 0:
                    return found
                p = _intersect(lines[a], lines[b])
                if p is not None:
                    found.append(p)
                    if len(found) >= limit * 2:
                        return found
    return found


@query("vector_snap_points")
def vector_snap_points(ctx, page, max_points=4000):
    import pypdfium2.raw as c
    require(isinstance(page, int) and 0 <= page < len(ctx.pdf.pages), "INVALID_ARGUMENT", "The page is invalid.")
    limit = max(10, min(int(max_points), 100_000))
    out = {"endpoints": [], "lines": [], "curves": []}
    images = []
    with ctx.pdfium() as doc:
        handle = doc[page]
        raw = handle.raw
        _collect(lambda k: c.FPDFPage_GetObject(raw, k), c.FPDFPage_CountObjects(raw),
                 (1, 0, 0, 1, 0, 0), out, images)
        handle.close()
    endpoints = out["endpoints"] + [corner for quad in images for corner in quad]
    ends = _dedupe(endpoints, limit)
    remaining = max(0, limit - len(ends))
    crossings = _dedupe(_intersections(out["lines"], remaining), remaining)
    remaining = max(0, remaining - len(crossings))
    mids = _dedupe([((p[0] + q[0]) / 2, (p[1] + q[1]) / 2) for p, q in out["lines"]], remaining)
    segments = []
    seen = set()
    for p, q in out["lines"] + out["curves"]:
        k = (_key(p), _key(q))
        if k in seen or k[0] == k[1]:
            continue
        seen.add(k)
        segments.append([k[0][0], k[0][1], k[1][0], k[1][1]])
        if len(segments) >= limit:
            break
    return {"endpoints": ends, "midpoints": mids, "intersections": crossings, "segments": segments}


# ---------------------------------------------------------------- measurement annotations

def number_format(pdf, unit, factor):
    return pikepdf.Dictionary(Type=Name.NumberFormat, U=pikepdf.String(str(unit)), C=float(factor), D=100)


def measure_dict(pdf, ratio, unit, factor):
    linear = number_format(pdf, unit, factor)
    return pikepdf.Dictionary(Type=Name.Measure, Subtype=Name.RL, R=pikepdf.String(str(ratio)),
                              X=pikepdf.Array([linear]), D=pikepdf.Array([number_format(pdf, unit, factor)]),
                              A=pikepdf.Array([number_format(pdf, "sq " + str(unit), float(factor) ** 2)]))


def _points(value, kind):
    require(isinstance(value, list), "INVALID_ARGUMENT", "Measurement points are required.")
    pts = []
    for p in value:
        require(isinstance(p, (list, tuple)) and len(p) == 2, "INVALID_ARGUMENT", "Invalid measurement point.")
        x, y = float(p[0]), float(p[1])
        require(math.isfinite(x) and math.isfinite(y), "INVALID_ARGUMENT", "Invalid measurement point.")
        pts.append((x, y))
    minimum = {"distance": 2, "perimeter": 2, "area": 3}[kind]
    require(len(pts) >= minimum and (kind != "distance" or len(pts) == 2), "INVALID_ARGUMENT",
            "Not enough points for this measurement.")
    return pts


def _label_anchor(kind, pts):
    if kind == "distance":
        (x1, y1), (x2, y2) = pts
        return (x1 + x2) / 2, (y1 + y2) / 2 + 6
    if kind == "area":
        return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)
    mid = len(pts) // 2
    (x1, y1), (x2, y2) = pts[mid - 1], pts[mid]
    return (x1 + x2) / 2, (y1 + y2) / 2 + 6


def _arrow(tip, tail, length=8.0, spread=math.radians(25)):
    angle = math.atan2(tail[1] - tip[1], tail[0] - tip[0])
    a = (tip[0] + length * math.cos(angle + spread), tip[1] + length * math.sin(angle + spread))
    b = (tip[0] + length * math.cos(angle - spread), tip[1] + length * math.sin(angle - spread))
    return f"{fmt(a[0], a[1])} m {fmt(tip[0], tip[1])} l {fmt(b[0], b[1])} l S"


def _appearance(pdf, kind, pts, label, color, rect):
    r, g, b = [max(0, min(255, int(v))) / 255.0 for v in color]
    ops = [f"{fmt(r, g, b)} RG 1 w 1 J 1 j"]
    path = f"{fmt(*pts[0])} m " + " ".join(f"{fmt(*p)} l" for p in pts[1:])
    if kind == "area":
        ops.append(f"q /GSFill gs {fmt(r, g, b)} rg {path} h f Q")
        ops.append(f"{path} h S")
    else:
        ops.append(f"{path} S")
    if kind == "distance":
        ops.append(_arrow(pts[0], pts[1]))
        ops.append(_arrow(pts[1], pts[0]))
    size = 9.0
    width = text_width(label, size)
    lx, ly = _label_anchor(kind, pts)
    box = (lx - width / 2 - 3, ly - 3, lx + width / 2 + 3, ly + size + 2)
    if label:
        ops.append(f"q /GSLabel gs 1 1 1 rg {fmt(box[0], box[1], box[2] - box[0], box[3] - box[1])} re f Q")
        ops.append(f"BT 0 g /Helv {fmt(size)} Tf {fmt(lx - width / 2, ly)} Td {pdf_literal(label)} Tj ET")
    res = pikepdf.Dictionary(
        Font=pikepdf.Dictionary(Helv=pdf.make_indirect(pikepdf.Dictionary(
            Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica, Encoding=Name.WinAnsiEncoding))),
        ExtGState=pikepdf.Dictionary(
            GSFill=pikepdf.Dictionary(Type=Name.ExtGState, ca=0.15),
            GSLabel=pikepdf.Dictionary(Type=Name.ExtGState, ca=0.85)))
    stream = pikepdf.Stream(pdf, "\n".join(ops).encode("latin-1"))
    stream.Type, stream.Subtype = Name.XObject, Name.Form
    stream.BBox = pikepdf.Array([float(v) for v in rect])
    stream.Resources = res
    return pdf.make_indirect(stream), box


def _rect(pts, box, pad=10.0):
    xs = [p[0] for p in pts] + [box[0], box[2]]
    ys = [p[1] for p in pts] + [box[1], box[3]]
    return [min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad]


@op("add_measurements")
def add_measurements(ctx, items):
    pdf = ctx.pdf
    require(isinstance(items, list) and items, "INVALID_ARGUMENT", "Add at least one measurement.")
    planned = []
    for item in items:
        require(isinstance(item, dict), "INVALID_ARGUMENT", "Invalid measurement.")
        page = item.get("page")
        kind = item.get("kind")
        require(isinstance(page, int) and 0 <= page < len(pdf.pages), "INVALID_ARGUMENT", "The page is invalid.")
        require(kind in KINDS, "INVALID_ARGUMENT", "Unknown measurement kind.")
        factor = float(item.get("factor", 1.0 / 72.0))
        require(math.isfinite(factor) and factor > 0, "INVALID_ARGUMENT", "The scale factor is invalid.")
        planned.append((page, kind, _points(item.get("points"), kind), factor, item))
    names = []
    now = pdf_date()
    for page, kind, pts, factor, item in planned:
        label = str(item.get("label") or "")
        unit = str(item.get("unit") or "in")
        ratio = str(item.get("ratio") or "1 in = 1 in")
        color = item.get("color") or [230, 40, 40]
        require(isinstance(color, list) and len(color) == 3, "INVALID_ARGUMENT", "Invalid color.")
        name = str(item.get("name") or f"zpdf-measure-{uuid.uuid4().hex}")
        subtype, intent = KINDS[kind]
        # Label box first (the appearance BBox must enclose it), then the stream.
        size = 9.0
        width = text_width(label, size)
        lx, ly = _label_anchor(kind, pts)
        box = (lx - width / 2 - 3, ly - 3, lx + width / 2 + 3, ly + size + 2)
        rect = _rect(pts, box)
        ap, _ = _appearance(pdf, kind, pts, label, color, rect)
        target = pdf.pages[page]
        annot = pikepdf.Dictionary(
            Type=Name.Annot, Subtype=Name(subtype), Rect=pikepdf.Array(rect),
            Contents=pikepdf.String(label), C=pikepdf.Array([max(0, min(255, int(v))) / 255.0 for v in color]),
            BS=pikepdf.Dictionary(Type=Name.Border, W=1, S=Name.S), NM=pikepdf.String(name),
            M=pikepdf.String(now), CreationDate=pikepdf.String(now), F=4, IT=Name(intent),
            Measure=measure_dict(pdf, ratio, unit, factor), AP=pikepdf.Dictionary(N=ap), P=target.obj)
        if item.get("author"):
            annot.T = pikepdf.String(str(item["author"]))
        flat = pikepdf.Array([float(v) for p in pts for v in p])
        if kind == "distance":
            annot.L = flat
            annot.LE = pikepdf.Array([Name.OpenArrow, Name.OpenArrow])
            annot.Cap = True
        else:
            annot.Vertices = flat
        annot = pdf.make_indirect(annot)
        if "/Annots" not in target.obj:
            target.obj.Annots = pikepdf.Array()
        target.obj.Annots.append(annot)
        names.append(name)
    return {"added": len(names), "names": names}


def _text(value):
    return None if value is None else str(value)


@query("measurements")
def measurements(ctx):
    items = []
    for index, page in enumerate(ctx.pdf.pages):
        for annot in page.obj.get("/Annots", []):
            if not isinstance(annot, pikepdf.Dictionary):
                continue
            intent = str(annot.get("/IT", ""))
            measure = annot.get("/Measure")
            if measure is None and intent not in INTENT_KIND:
                continue
            subtype = str(annot.get("/Subtype", ""))
            kind = INTENT_KIND.get(intent) or SUBTYPE_KIND.get(subtype, "other")
            coords = annot.get("/L") if subtype == "/Line" else annot.get("/Vertices")
            values = [float(v) for v in coords] if coords is not None else []
            points = [[round(values[i], 4), round(values[i + 1], 4)] for i in range(0, len(values) - 1, 2)]
            ratio = measure.get("/R") if isinstance(measure, pikepdf.Dictionary) else None
            items.append({"page": index, "subtype": subtype.lstrip("/"), "kind": kind,
                          "name": _text(annot.get("/NM")), "points": points,
                          "label": str(annot.get("/Contents", "")), "ratio": _text(ratio),
                          "author": _text(annot.get("/T"))})
    return {"items": items}


# ---------------------------------------------------------------- page scale

@op("set_page_scale")
def set_page_scale(ctx, ratio, factor, unit, pages=None):
    pdf = ctx.pdf
    factor = float(factor)
    require(math.isfinite(factor) and factor > 0, "INVALID_ARGUMENT", "The scale factor is invalid.")
    require(str(unit).strip() != "", "INVALID_ARGUMENT", "Choose a unit.")
    targets = select_pages(pdf, pages)
    for index in targets:
        page = pdf.pages[index]
        existing = page.obj.get("/VP")
        kept = [vp for vp in (existing or []) if str(vp.get("/Name", "")) != SCALE_NAME]
        viewport = pikepdf.Dictionary(Type=Name.Viewport, BBox=pikepdf.Array([float(v) for v in page_box(page)]),
                                      Name=pikepdf.String(SCALE_NAME), Measure=measure_dict(pdf, ratio, unit, factor))
        page.obj.VP = pikepdf.Array(kept + [viewport])
    return {"pages": len(targets)}


@query("page_scales")
def page_scales(ctx):
    result = []
    for index, page in enumerate(ctx.pdf.pages):
        entry = {"page": index, "ratio": None, "factor": None, "unit": None, "bbox": None}
        for vp in page.obj.get("/VP", []):
            measure = vp.get("/Measure") if isinstance(vp, pikepdf.Dictionary) else None
            if not isinstance(measure, pikepdf.Dictionary) or str(measure.get("/Subtype", "/RL")) != "/RL":
                continue
            x = measure.get("/X")
            first = x[0] if isinstance(x, pikepdf.Array) and len(x) else None
            entry["ratio"] = _text(measure.get("/R"))
            if isinstance(first, pikepdf.Dictionary):
                entry["factor"] = float(first.get("/C", 1))
                entry["unit"] = _text(first.get("/U"))
            bbox = vp.get("/BBox")
            entry["bbox"] = [float(v) for v in bbox] if bbox is not None else None
            break
        result.append(entry)
    return {"pages": result}
