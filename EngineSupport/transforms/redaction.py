"""Applying redactions: content under the marked areas is removed, not covered.

For every area (from /Redact annotations, or passed explicitly) this removes
  * text: every glyph whose box is substantially inside the area (all render
    modes, inside forms too); remaining glyphs keep their positions;
  * images: pixels inside the area are overwritten in a new copy of the image
    (an image fully inside is removed); undecodable images are removed;
  * vector art: paths fully inside are removed, overlapping ones are clipped;
  * annotations and form widgets touching the area (fields left without
    widgets are removed from the form);
  * marked-content /ActualText, /Alt and /E that describe removed text;
then draws the overlay (fill color, overlay text) into the page content and
removes the /Redact annotations. Replaced forms and images are dropped from
the page's resources, so the original data is no longer referenced.
"""
import re
import zlib

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op, query
from transforms.content import add_content, page_box, fmt
from transforms.fonts import EmbeddedFont
from transforms.interpret import (Plan, walk_page, rewrite_page, apply, invert, safe_invert, quad_bbox,
                                  rect_intersects, point_in_rect, instr, num)

GLYPH_FRACTION = 0.4


def normalize(rect):
    x0, y0, x1, y1 = [float(v) for v in rect]
    return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def inside_any(point, rects):
    return any(point_in_rect(point, r) for r in rects)


def quad_samples(quad, n=5):
    p0, p1, p2, p3 = quad
    out = []
    for i in range(n):
        u = (i + 0.5) / n
        for j in range(n):
            v = (j + 0.5) / n
            bottom = (p0[0] + (p1[0] - p0[0]) * u, p0[1] + (p1[1] - p0[1]) * u)
            top = (p3[0] + (p2[0] - p3[0]) * u, p3[1] + (p2[1] - p3[1]) * u)
            out.append((bottom[0] + (top[0] - bottom[0]) * v, bottom[1] + (top[1] - bottom[1]) * v))
    return out


def covered_fraction(quad, rects):
    samples = quad_samples(quad)
    return sum(1 for p in samples if inside_any(p, rects)) / len(samples)


def fully_covered(bbox, rects):
    x0, y0, x1, y1 = bbox
    if x1 - x0 <= 0 and y1 - y0 <= 0:
        return inside_any((x0, y0), rects)
    quad = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    corners_inside = all(inside_any(p, rects) for p in quad)
    return corners_inside and covered_fraction(quad, rects) == 1.0


# ---------------------------------------------------------------- images

def _fill_samples(components, space, decode, image_mask):
    """Sample values (0..max as fraction) that paint black / nothing."""
    if image_mask:
        # Decode [0 1] (default): 1 leaves the page unchanged.
        return [0.0] if decode and float(decode[0]) == 1 else [1.0]
    if space in ("/DeviceCMYK",) or components == 4:
        values = [0.0, 0.0, 0.0, 1.0]
    elif space in ("/Separation", "/DeviceN"):
        values = [1.0] * components
    else:
        values = [0.0] * components
    if decode and len(decode) >= 2 * components:
        values = [1.0 - v if float(decode[2 * i]) > float(decode[2 * i + 1]) else v for i, v in enumerate(values)]
    return values


def _components(pdf, xobj):
    if xobj.get("/ImageMask") is True:
        return 1, "/ImageMask"
    cs = xobj.get("/ColorSpace")
    if cs is None:
        return None, None
    if isinstance(cs, Name):
        return {"/DeviceGray": 1, "/DeviceRGB": 3, "/DeviceCMYK": 4}.get(str(cs)), str(cs)
    if isinstance(cs, pikepdf.Array) and len(cs):
        family = str(cs[0])
        if family == "/ICCBased":
            return int(cs[1].get("/N", 3)), family
        if family == "/Indexed":
            return 1, family
        if family in ("/CalRGB", "/Lab"):
            return 3, family
        if family == "/CalGray":
            return 1, family
        if family == "/Separation":
            return 1, family
        if family == "/DeviceN":
            return len(cs[1]), family
    return None, None


def _pixel_polygons(ctm, rects, width, height):
    inv = safe_invert(ctm)
    if inv is None:
        return []
    polys = []
    for r in rects:
        pts = []
        for x, y in ((r[0], r[1]), (r[2], r[1]), (r[2], r[3]), (r[0], r[3])):
            u, v = apply(inv, x, y)
            pts.append((u * width, (1 - v) * height))
        polys.append(pts)
    return polys


def _mask(width, height, polys):
    from PIL import Image, ImageDraw
    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    for pts in polys:
        draw.polygon(pts, fill=255)
        # Include partially covered edge pixels.
        draw.line(pts + [pts[0]], fill=255, width=1)
    return mask


def _redact_raw(pdf, xobj, polys):
    """Overwrite samples of an image whose filters pikepdf can decode."""
    width, height = int(xobj.Width), int(xobj.Height)
    components, space = _components(pdf, xobj)
    if components is None:
        return None
    image_mask = xobj.get("/ImageMask") is True
    bpc = 1 if image_mask else int(xobj.get("/BitsPerComponent", 8))
    if bpc not in (1, 2, 4, 8, 16):
        return None
    try:
        raw = bytearray(xobj.read_bytes())
    except pikepdf.PdfError:
        return None
    stride = (width * components * bpc + 7) // 8
    if len(raw) < stride * height:
        return None
    mask = _mask(width, height, polys)
    box = mask.getbbox()
    if box is None:
        return False
    decode = xobj.get("/Decode")
    fill = _fill_samples(components, space, list(decode) if isinstance(decode, pikepdf.Array) else None, image_mask)
    if space == "/Indexed":
        fill = [_darkest_index(xobj.ColorSpace)]
        maxval = 1
    else:
        maxval = (1 << bpc) - 1
    values = [int(round(f * maxval)) if space != "/Indexed" else int(f) for f in fill]
    data = mask.tobytes()
    x0, y0, x1, y1 = box
    for y in range(y0, y1):
        row = data[y * width + x0:y * width + x1]
        start = row.find(b"\xff")
        if start < 0:
            continue
        end = row.rfind(b"\xff")
        a, b = x0 + start, x0 + end + 1
        base = y * stride
        if bpc == 8:
            chunk = bytes(values) * (b - a)
            raw[base + a * components: base + b * components] = chunk
        elif bpc == 16:
            one = b"".join(v.to_bytes(2, "big") for v in values)
            raw[base + a * components * 2: base + b * components * 2] = one * (b - a)
        else:
            for x in range(a, b):
                for c, v in enumerate(values):
                    bit = (x * components + c) * bpc
                    byte, shift = base + bit // 8, 8 - bpc - bit % 8
                    m = ((1 << bpc) - 1) << shift
                    raw[byte] = (raw[byte] & ~m & 0xFF) | ((v << shift) & m)
    new = pikepdf.Stream(pdf, zlib.compress(bytes(raw), 6))
    for key, value in xobj.items():
        if key in ("/Length", "/Filter", "/DecodeParms", "/Alternates", "/OPI", "/Metadata", "/StructParent"):
            continue
        new[key] = value
    new.Filter = Name.FlateDecode
    return pdf.make_indirect(new)


def _darkest_index(cs):
    try:
        base, hival, lookup = cs[1], int(cs[2]), cs[3]
        table = lookup.read_bytes() if isinstance(lookup, pikepdf.Stream) else bytes(lookup)
        n = {"/DeviceGray": 1, "/DeviceRGB": 3, "/DeviceCMYK": 4}.get(str(base), 3)
        if isinstance(base, pikepdf.Array) and str(base[0]) == "/ICCBased":
            n = int(base[1].get("/N", 3))
        best, score = 0, None
        for i in range(hival + 1):
            entry = table[i * n:(i + 1) * n]
            s = sum(entry) if n != 4 else 255 * 3 - sum(entry[:3]) + (255 - entry[3]) * 0 - entry[3]
            if score is None or s < score:
                best, score = i, s
        return best
    except Exception:
        return 0


def _redact_decoded(pdf, xobj, polys):
    """Decode through Pillow (JPEG, JPEG 2000, ...) and re-encode."""
    from PIL import ImageDraw
    from pikepdf import PdfImage
    image = PdfImage(xobj).as_pil_image()
    if image.mode not in ("L", "RGB", "1"):
        image = image.convert("RGB")
    draw = ImageDraw.Draw(image)
    fill = {"L": 0, "RGB": (0, 0, 0), "1": 0}[image.mode]
    for pts in polys:
        draw.polygon(pts, fill=fill)
        draw.line(pts + [pts[0]], fill=fill, width=1)
    import io
    was_jpeg = "/DCTDecode" in str(xobj.get("/Filter", ""))
    if was_jpeg and image.mode in ("L", "RGB"):
        buffer = io.BytesIO()
        image.save(buffer, "JPEG", quality=92)
        new = pikepdf.Stream(pdf, buffer.getvalue())
        new.Filter = Name.DCTDecode
    else:
        mode = image.mode if image.mode != "1" else "L"
        new = pikepdf.Stream(pdf, zlib.compress(image.convert(mode).tobytes(), 6))
        new.Filter = Name.FlateDecode
    new.Type, new.Subtype = Name.XObject, Name.Image
    new.Width, new.Height = image.width, image.height
    new.ColorSpace = Name.DeviceGray if image.mode in ("L", "1") else Name.DeviceRGB
    new.BitsPerComponent = 8
    for key in ("/SMask", "/Interpolate", "/Intent"):
        if key in xobj:
            new[key] = xobj[key]
    return pdf.make_indirect(new)


def redact_image(pdf, xobj, ctm, rects):
    """A redacted copy of `xobj`, False when untouched, None when it must be removed."""
    width, height = int(num(xobj.get("/Width", 0))), int(num(xobj.get("/Height", 0)))
    if width <= 0 or height <= 0:
        return None
    polys = _pixel_polygons(ctm, rects, width, height)
    if not polys:
        return None
    filters = xobj.get("/Filter")
    names = [str(f) for f in (filters if isinstance(filters, pikepdf.Array) else [filters] if filters else [])]
    simple = all(n in ("/FlateDecode", "/LZWDecode", "/RunLengthDecode", "/ASCIIHexDecode", "/ASCII85Decode",
                       "/Fl", "/LZW", "/RL", "/AHx", "/A85") for n in names)
    try:
        if simple:
            result = _redact_raw(pdf, xobj, polys)
            if result is not None:
                return result
        if xobj.get("/ImageMask") is True:
            return None
        return _redact_decoded(pdf, xobj, polys)
    except Exception:
        return None


def inline_to_xobject(pdf, inline):
    """Convert a parsed inline image to an image XObject (for redaction)."""
    image = inline.operands[0]
    try:
        pil = image.as_pil_image()
    except Exception:
        return None
    xobj = None
    if pil.mode == "1":
        xobj = pikepdf.Stream(pdf, zlib.compress(pil.tobytes(), 6))
        xobj.ImageMask = True
        xobj.BitsPerComponent = 1
    else:
        if pil.mode not in ("L", "RGB"):
            pil = pil.convert("RGB")
        xobj = pikepdf.Stream(pdf, zlib.compress(pil.tobytes(), 6))
        xobj.ColorSpace = Name.DeviceGray if pil.mode == "L" else Name.DeviceRGB
        xobj.BitsPerComponent = 8
    xobj.Type, xobj.Subtype = Name.XObject, Name.Image
    xobj.Width, xobj.Height = pil.width, pil.height
    xobj.Filter = Name.FlateDecode
    return pdf.make_indirect(xobj)


# ---------------------------------------------------------------- plan

class RedactPlan(Plan):
    def __init__(self, pdf, rects):
        self.pdf = pdf
        self.rects = rects
        self.glyphs = 0
        self.images = 0
        self.images_removed = 0
        self.paths = 0
        self.clipped = 0
        self.affected_marked = set()
        self.decided = {}

    def _near(self, bbox):
        return bbox is not None and any(rect_intersects(bbox, r) for r in self.rects)

    def glyph(self, g):
        box = g.bbox()
        if not self._near(box):
            return None
        center = g.center()
        if inside_any(center, self.rects) or covered_fraction(g.quad, self.rects) >= GLYPH_FRACTION:
            self.glyphs += 1
            self.affected_marked.update(g.marked or ())
            return "remove"
        return None

    def path(self, item):
        if not self._near(item.bbox):
            return None
        hits = [r for r in self.rects if rect_intersects(item.bbox, r)]
        if fully_covered(item.bbox, self.rects):
            self.paths += 1
            return "remove"
        self.clipped += 1
        return ("exclude", hits)

    def image(self, item):
        if not self._near(item.bbox):
            return None
        key = ("image", item.id)
        if key in self.decided:
            return self.decided[key]
        if all(inside_any(p, self.rects) for p in item.quad) and covered_fraction(item.quad, self.rects) == 1.0:
            self.images_removed += 1
            decision = "remove"
        else:
            hits = [r for r in self.rects if rect_intersects(item.bbox, r)]
            xobj = item.xobject
            if xobj is None:
                xobj = inline_to_xobject(self.pdf, item.inline)
                if xobj is None:
                    self.images_removed += 1
                    self.decided[key] = "remove"
                    return "remove"
            copy = redact_image(self.pdf, xobj, item.ctm, hits)
            if copy is False:
                decision = None if item.xobject is not None else ("replace", xobj, None)
            elif copy is None:
                self.images_removed += 1
                decision = "remove"
            else:
                self.images += 1
                decision = ("replace", copy, None)
        self.decided[key] = decision
        return decision

    def form(self, item):
        if not self._near(item.bbox):
            return "keep"
        if item.extra in ("Watermark", "HeaderFooter", "Background", "Bates"):
            return None
        if fully_covered(item.bbox, self.rects):
            return "remove"
        return None

    def marked(self, tag, properties, counter):
        if counter not in self.affected_marked or not isinstance(properties, pikepdf.Dictionary):
            return None
        if not any(k in properties for k in ("/ActualText", "/Alt", "/E")):
            return None
        cleaned = pikepdf.Dictionary({k: v for k, v in properties.items() if k not in ("/ActualText", "/Alt", "/E")})
        return instr([Name(tag), cleaned], "BDC")


class ReplayPlan(RedactPlan):
    """Second pass: reuse the first pass's decisions (same traversal order)."""

    def __init__(self, first):
        super().__init__(first.pdf, first.rects)
        self.first = first
        self.affected_marked = first.affected_marked
        self.decided = first.decided

    def glyph(self, g):
        return RedactPlan.glyph(self, g)


# ---------------------------------------------------------------- annotations and fields

def _field_root_remove(pdf, widget):
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return 0
    removed = 0
    node = widget
    parent = node.get("/Parent")
    # Detach the widget (or merged field/widget) from its parent's /Kids or from /Fields.
    while True:
        container = parent.get("/Kids") if parent is not None else acro.get("/Fields")
        if isinstance(container, pikepdf.Array):
            kept = [k for k in container if not (k.is_indirect and node.is_indirect and k.objgen == node.objgen)]
            if len(kept) != len(container):
                if parent is not None:
                    parent.Kids = pikepdf.Array(kept)
                else:
                    acro.Fields = pikepdf.Array(kept)
                removed += 1
            if parent is not None and not kept:
                node = parent
                parent = node.get("/Parent")
                continue
        break
    return removed


def remove_annotations(pdf, page, rects, redact_only=False):
    annots = page.obj.get("/Annots")
    if not isinstance(annots, pikepdf.Array):
        return 0, 0
    removed, fields = set(), 0
    for annot in annots:
        subtype = str(annot.get("/Subtype", ""))
        if subtype == "/Redact":
            if annot.is_indirect:
                removed.add(annot.objgen)
            continue
        if redact_only or subtype == "/Popup":
            continue
        rect = annot.get("/Rect")
        if not isinstance(rect, pikepdf.Array) or len(rect) != 4:
            continue
        box = normalize(rect)
        if any(rect_intersects(box, r) for r in rects):
            if annot.is_indirect:
                removed.add(annot.objgen)
            if subtype == "/Widget":
                fields += _field_root_remove(pdf, annot)
    # Popups and replies of removed annotations.
    changed = True
    while changed:
        changed = False
        for annot in annots:
            if not annot.is_indirect or annot.objgen in removed:
                continue
            for key in ("/Parent", "/IRT"):
                target = annot.get(key)
                if isinstance(target, pikepdf.Dictionary) and target.is_indirect and target.objgen in removed \
                        and str(annot.get("/Subtype", "")) != "/Widget":
                    removed.add(annot.objgen)
                    changed = True
    kept = [a for a in annots if not (a.is_indirect and a.objgen in removed)]
    count = sum(1 for a in annots if a.is_indirect and a.objgen in removed and str(a.get("/Subtype", "")) != "/Redact")
    page.obj.Annots = pikepdf.Array(kept)
    return count, fields


# ---------------------------------------------------------------- overlay

def _parse_da(da):
    size, color = 0.0, (1.0, 1.0, 1.0)
    if not da:
        return size, None
    text = str(da)
    m = re.search(r"([-\d.]+)\s+Tf", text)
    if m:
        size = float(m.group(1))
    m = re.search(r"([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+rg", text)
    if m:
        color = tuple(float(v) for v in m.groups())
    else:
        m = re.search(r"([-\d.]+)\s+g\b", text)
        if m:
            color = (float(m.group(1)),) * 3
    return size, color


def _color_values(value):
    if value is None:
        return None
    values = [float(v) for v in value]
    if any(v > 1 for v in values):
        values = [v / 255 for v in values]
    if len(values) == 1:
        return (values[0],) * 3
    if len(values) == 4:
        c, m, y, k = values
        return ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
    if len(values) >= 3:
        return tuple(values[:3])
    return None


def _luminance(rgb):
    return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]


def draw_overlay(pdf, page, font, rects, fill, text=None, text_color=None, size=0.0, repeat=False, align=1):
    ops = []
    if fill is not None:
        ops.append(f"{fmt(*[float(v) for v in fill])} rg")
        for r in rects:
            ops.append(f"{fmt(r[0], r[1], r[2] - r[0], r[3] - r[1])} re f")
    if text:
        if text_color is None:
            text_color = (1.0, 1.0, 1.0) if fill is None or _luminance(fill) < 0.5 else (0.0, 0.0, 0.0)
        box = (min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects))
        for r in (rects if len(rects) > 1 else [box]):
            w, h = r[2] - r[0], r[3] - r[1]
            if w < 2 or h < 2:
                continue
            s = size if size > 0 else min(12.0, h * 0.7)
            s = min(s, h * 0.9)
            width = font.width(text, s)
            if width > w * 0.96 and width > 0:
                s = max(3.0, s * w * 0.96 / width)
                width = font.width(text, s)
            ops.append("q")
            ops.append(f"{fmt(r[0], r[1], w, h)} re W n")
            ops.append(f"{fmt(*[float(v) for v in text_color])} rg BT /ZPDFrf1 {fmt(float(s))} Tf")
            baseline = r[1] + (h - s * (font.ascent - font.descent)) / 2 - font.descent * s
            if repeat and width > 0:
                y = r[3] - s * font.ascent - 1
                while y > r[1] - s * 0.2:
                    x = r[0] + 1
                    while x < r[2]:
                        ops.append(f"1 0 0 1 {fmt(x, y)} Tm {font.encode(text)} Tj")
                        x += width + s * 0.6
                    y -= s * 1.15
            else:
                x = {0: r[0] + 1, 1: r[0] + (w - width) / 2, 2: r[2] - width - 1}.get(align, r[0] + (w - width) / 2)
                ops.append(f"1 0 0 1 {fmt(x, baseline)} Tm {font.encode(text)} Tj")
            ops.append("ET Q")
    if not ops:
        return
    from transforms.content import resources
    res = resources(page)
    if "/Font" not in res:
        res.Font = pikepdf.Dictionary()
    res.Font[Name("/ZPDFrf1")] = font.ref
    add_content(pdf, page, ("q\n" + "\n".join(ops) + "\nQ\n").encode())


# ---------------------------------------------------------------- driver

def _areas_from_annotations(page):
    marks = []
    for annot in page.obj.get("/Annots", []):
        if str(annot.get("/Subtype", "")) != "/Redact":
            continue
        rects = []
        quads = annot.get("/QuadPoints")
        if isinstance(quads, pikepdf.Array) and len(quads) >= 8:
            values = [float(v) for v in quads]
            for i in range(0, len(values) - 7, 8):
                xs, ys = values[i:i + 8:2], values[i + 1:i + 8:2]
                rects.append((min(xs), min(ys), max(xs), max(ys)))
        elif isinstance(annot.get("/Rect"), pikepdf.Array):
            rects.append(normalize(annot.Rect))
        rects = [r for r in rects if r[2] - r[0] > 0.1 and r[3] - r[1] > 0.1]
        if not rects:
            continue
        size, text_color = _parse_da(annot.get("/DA"))
        overlay = annot.get("/OverlayText")
        marks.append({
            "rects": rects,
            "fill": _color_values(annot.get("/IC")) if "/IC" in annot else None,
            "text": str(overlay) if overlay is not None else None,
            "text_color": text_color if "/DA" in annot and overlay is not None else None,
            "size": size,
            "repeat": bool(annot.get("/Repeat", False)),
            "align": int(num(annot.get("/Q", 1), 1)),
        })
    return marks


def redact_page(ctx, index, marks, font, cache):
    pdf = ctx.pdf
    page = pdf.pages[index]
    rects = [r for m in marks for r in m["rects"]]
    crop = page_box(page)
    media = page_box(page, "/MediaBox")
    counts = {"glyphs": 0, "images": 0, "images_removed": 0, "paths": 0, "clipped": 0, "annotations": 0, "fields": 0}
    whole = any(r[0] <= crop[0] + 0.5 and r[1] <= crop[1] + 0.5 and r[2] >= crop[2] - 0.5 and r[3] >= crop[3] - 0.5
                for r in rects)
    if whole:
        walker = walk_page(pdf, page, None, cache)
        counts["glyphs"] = len(walker.glyphs)
        counts["images_removed"] = sum(1 for i in walker.items if i.kind in ("image", "inline_image"))
        counts["paths"] = sum(1 for i in walker.items if i.kind in ("path", "shading"))
        page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, b""))
        page.obj.Resources = pikepdf.Dictionary()
        if "/ZPDFWrapped" in page.obj:
            del page.obj["/ZPDFWrapped"]
        for annot in list(page.obj.get("/Annots", [])):
            if str(annot.get("/Subtype", "")) == "/Widget":
                counts["fields"] += _field_root_remove(pdf, annot)
        counts["annotations"] = sum(1 for a in page.obj.get("/Annots", []) if str(a.get("/Subtype", "")) not in ("/Redact", "/Popup"))
        page.obj.Annots = pikepdf.Array()
    else:
        plan = RedactPlan(pdf, rects)
        walk_page(pdf, page, plan, cache)
        if plan.glyphs or plan.images or plan.images_removed or plan.paths or plan.clipped:
            replay = ReplayPlan(plan)
            rewrite_page(pdf, page, replay, cache)
        counts.update(glyphs=plan.glyphs, images=plan.images, images_removed=plan.images_removed,
                      paths=plan.paths, clipped=plan.clipped)
        counts["annotations"], counts["fields"] = remove_annotations(pdf, page, rects)
    for key in ("/Thumb", "/PieceInfo"):
        if key in page.obj:
            del page.obj[key]
    for mark in marks:
        draw_overlay(pdf, page, font, mark["rects"], mark.get("fill"), mark.get("text"), mark.get("text_color"), float(mark.get("size") or 0),
                     bool(mark.get("repeat")), int(mark.get("align", 1)))
    return counts


@op("apply_redactions")
def apply_redactions(ctx, pages=None, areas=None, marks=True):
    """Apply /Redact annotations (marks=True) and/or explicit `areas`:
    [{"page": i, "rects": [[x0,y0,x1,y1], ...], "fill": [r,g,b] (0-255 or 0-1) | None,
      "text": str|None, "text_color": [...], "size": pt, "repeat": bool}]."""
    pdf = ctx.pdf
    count = len(pdf.pages)
    targets = range(count) if pages is None else pages
    require(all(isinstance(p, int) and 0 <= p < count for p in targets), "INVALID_ARGUMENT", "The page range is invalid.")
    per_page = {}
    if marks:
        for index in targets:
            found = _areas_from_annotations(pdf.pages[index])
            for mark in found:
                mark["from_annotation"] = True
            if found:
                per_page.setdefault(index, []).extend(found)
    for area in areas or []:
        index = area.get("page")
        require(isinstance(index, int) and 0 <= index < count, "INVALID_ARGUMENT", "A redaction refers to a missing page.")
        rects = [normalize(r) for r in area.get("rects", [])]
        require(rects, "INVALID_ARGUMENT", "A redaction area is empty.")
        fill = area.get("fill", [0, 0, 0])
        per_page.setdefault(index, []).append({
            "rects": rects, "fill": _color_values(fill) if fill is not None else None, "text": area.get("text"),
            "text_color": _color_values(area.get("text_color")) if area.get("text_color") else None,
            "size": float(area.get("size") or 0), "repeat": bool(area.get("repeat")), "align": int(area.get("align", 1))})
    require(per_page, "NOTHING_TO_REDACT", "Mark something for redaction first.")
    font = EmbeddedFont(pdf, {"family": "sans", "bold": True})
    totals = {"pages": 0, "marks": 0, "glyphs": 0, "images": 0, "images_removed": 0, "paths": 0, "clipped": 0,
              "annotations": 0, "fields": 0}
    cache = {}
    for index in sorted(per_page):
        marks_here = per_page[index]
        counts = redact_page(ctx, index, marks_here, font, cache)
        totals["pages"] += 1
        totals["marks"] += len(marks_here)
        for key, value in counts.items():
            totals[key] += max(0, value)
    # Leftover /Redact marks on untouched pages stay; marks on redacted pages are gone.
    if font.used:
        font.finish()
    acro = pdf.Root.get("/AcroForm")
    if acro is not None and "/Fields" in acro and not len(acro.Fields) and not any(
            str(a.get("/Subtype", "")) == "/Widget" for p in pdf.pages for a in p.obj.get("/Annots", [])):
        del pdf.Root["/AcroForm"]
    return totals


@query("redaction_marks")
def redaction_marks(ctx):
    out = []
    for index, page in enumerate(ctx.pdf.pages):
        for mark in _areas_from_annotations(page):
            out.append({"page": index, "rects": [list(r) for r in mark["rects"]], "text": mark["text"]})
    return {"marks": out}


@query("page_text")
def page_text(ctx, pages=None):
    """PDFium's extracted text per page (used to verify redactions)."""
    count = len(ctx.pdf.pages)
    targets = range(count) if pages is None else [p for p in pages if isinstance(p, int) and 0 <= p < count]
    out = []
    with ctx.pdfium() as doc:
        for index in targets:
            page = doc[index]
            textpage = page.get_textpage()
            out.append({"page": index, "text": textpage.get_text_range()})
            textpage.close()
            page.close()
    return {"pages": out}


@query("image_samples")
def image_samples(ctx, page, points):
    """Decoded RGB of the topmost image under each user-space point (verification)."""
    from pikepdf import PdfImage
    require(isinstance(page, int) and 0 <= page < len(ctx.pdf.pages), "INVALID_ARGUMENT", "That page does not exist.")
    walker = walk_page(ctx.pdf, ctx.pdf.pages[page])
    images = [i for i in walker.items if i.kind == "image" and i.xobject is not None]
    out = []
    for x, y in points:
        value = None
        for item in reversed(images):
            inv = safe_invert(item.ctm)
            if inv is None:
                continue
            u, v = apply(inv, float(x), float(y))
            if 0 <= u <= 1 and 0 <= v <= 1:
                pil = PdfImage(item.xobject).as_pil_image().convert("RGB")
                px = min(pil.width - 1, int(u * pil.width))
                py = min(pil.height - 1, int((1 - v) * pil.height))
                value = list(pil.getpixel((px, py)))
                break
        out.append(value)
    return {"samples": out}
