"""Page-content drawing: appearances, overlays, watermarks, headers/footers,
backgrounds and Bates numbers.

Every overlay the app adds is one Form XObject tagged with /ZPDFKind and
invoked by its own content stream, so it can be found, replaced or removed
later without touching the page's original content. Drawing happens in the
page's *visual* coordinate space (after /Rotate), so text is upright as shown.
"""
from datetime import date
import re

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op
from transforms.fonts import EmbeddedFont, color_ops, alpha

INVOCATION = re.compile(rb"^\s*q\s+(?:[-\d.]+\s+){6}cm\s+/(ZPDF[\w.-]+)\s+Do\s+Q\s*$")


# ---------------------------------------------------------------- geometry

def page_box(page, box="/CropBox"):
    obj = page.obj
    value = obj.get(box) or obj.get("/MediaBox")
    node = obj
    while value is None and "/Parent" in node:
        node = node.Parent
        value = node.get(box) or node.get("/MediaBox")
    x0, y0, x1, y1 = [float(v) for v in value]
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


def rotation(page):
    node = page.obj
    while True:
        if "/Rotate" in node:
            return int(node.Rotate) % 360
        if "/Parent" not in node:
            return 0
        node = node.Parent


def visual_size(page):
    x0, y0, x1, y1 = page_box(page)
    w, h = x1 - x0, y1 - y0
    return (h, w) if rotation(page) in (90, 270) else (w, h)


def visual_matrix(page):
    """cm operands mapping visual (upright, origin bottom-left) -> user space."""
    x0, y0, x1, y1 = page_box(page)
    return {0: (1, 0, 0, 1, x0, y0), 90: (0, 1, -1, 0, x1, y0),
            180: (-1, 0, 0, -1, x1, y1), 270: (0, -1, 1, 0, x0, y1)}[rotation(page)]


def multiply(m, n):
    """m then n (PDF row-vector convention): returns m x n."""
    a, b, c, d, e, f = m
    A, B, C, D, E, F = n
    return (a * A + b * C, a * B + b * D, c * A + d * C, c * B + d * D,
            e * A + f * C + E, e * B + f * D + F)


def apply(m, x, y):
    a, b, c, d, e, f = m
    return a * x + c * y + e, b * x + d * y + f


def invert(m):
    a, b, c, d, e, f = m
    det = a * d - b * c
    require(abs(det) > 1e-12, "INVALID_ARGUMENT", "Degenerate transform.")
    return (d / det, -b / det, -c / det, a / det, (c * f - d * e) / det, (b * e - a * f) / det)


def transform_rect(m, rect):
    x0, y0, x1, y1 = rect
    points = [apply(m, x, y) for x, y in ((x0, y0), (x1, y0), (x0, y1), (x1, y1))]
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def fmt(*values):
    return " ".join(f"{v:.4f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v) for v in values)


# ---------------------------------------------------------------- resources

def resources(page):
    obj = page.obj
    if "/Resources" not in obj:
        node = obj
        inherited = None
        while "/Parent" in node and inherited is None:
            node = node.Parent
            inherited = node.get("/Resources")
        obj.Resources = pikepdf.Dictionary(inherited) if inherited is not None else pikepdf.Dictionary()
    return obj.Resources


def add_resource(page_or_dict, category, obj, prefix):
    res = resources(page_or_dict) if hasattr(page_or_dict, "obj") else page_or_dict
    key = Name("/" + category)
    if key not in res:
        res[key] = pikepdf.Dictionary()
    group = res[key]
    n = 1
    while Name(f"/{prefix}{n}") in group:
        n += 1
    name = Name(f"/{prefix}{n}")
    group[name] = obj
    return name


def ext_gstate(pdf, fill_alpha=1.0, stroke_alpha=None, blend=None):
    gs = pikepdf.Dictionary(Type=Name.ExtGState, ca=float(fill_alpha),
                            CA=float(fill_alpha if stroke_alpha is None else stroke_alpha))
    if blend:
        gs.BM = Name("/" + blend)
    return pdf.make_indirect(gs)


def _wrap_existing(pdf, page):
    """Balance the original content so appended drawing starts from a clean state."""
    obj = page.obj
    contents = obj.get("/Contents")
    if contents is None:
        return
    if obj.get("/ZPDFWrapped") is True:
        return
    streams = list(contents) if isinstance(contents, pikepdf.Array) else [contents]
    obj.Contents = pikepdf.Array([pdf.make_indirect(pikepdf.Stream(pdf, b"q\n"))] + streams +
                                 [pdf.make_indirect(pikepdf.Stream(pdf, b"\nQ\n"))])
    obj.ZPDFWrapped = True


def add_content(pdf, page, data, under=False):
    obj = page.obj
    stream = pdf.make_indirect(pikepdf.Stream(pdf, data))
    _wrap_existing(pdf, page)
    contents = obj.get("/Contents")
    if contents is None:
        obj.Contents = pikepdf.Array([stream])
    else:
        streams = list(contents) if isinstance(contents, pikepdf.Array) else [contents]
        obj.Contents = pikepdf.Array([stream] + streams if under else streams + [stream])
    return stream


def form_xobject(pdf, content, bbox, res=None, kind=None, matrix=None):
    form = pikepdf.Stream(pdf, content)
    form.Type = Name.XObject
    form.Subtype = Name.Form
    form.BBox = pikepdf.Array([float(v) for v in bbox])
    form.Resources = res if res is not None else pikepdf.Dictionary()
    if matrix:
        form.Matrix = pikepdf.Array([float(v) for v in matrix])
    if kind:
        form.ZPDFKind = Name("/" + kind)
    return pdf.make_indirect(form)


def place_form(pdf, page, form, matrix, under=False, prefix="ZPDFx"):
    name = add_resource(page, "XObject", form, prefix)
    return add_content(pdf, page, f"q {fmt(*matrix)} cm {name} Do Q\n".encode(), under)


def remove_overlays(pdf, page, kind):
    """Remove overlays tagged `kind` added by this app. Returns the count."""
    obj = page.obj
    contents = obj.get("/Contents")
    if contents is None:
        return 0
    streams = list(contents) if isinstance(contents, pikepdf.Array) else [contents]
    xobjects = resources(page).get("/XObject", pikepdf.Dictionary())
    kept, removed = [], 0
    for stream in streams:
        try:
            data = stream.read_bytes()
        except pikepdf.PdfError:
            kept.append(stream)
            continue
        match = INVOCATION.match(data) if len(data) < 256 else None
        if match:
            name = Name("/" + match.group(1).decode())
            target = xobjects.get(name)
            if target is not None and str(target.get("/ZPDFKind", "")) == "/" + kind:
                del xobjects[name]
                removed += 1
                continue
        kept.append(stream)
    if removed:
        obj.Contents = pikepdf.Array(kept)
    return removed


def stamp_appearances(pdf, page, annots):
    """Draw annotation normal appearances into page content (flattening)."""
    chunks = []
    for annot in annots:
        ap = annot.AP.N
        if isinstance(ap, pikepdf.Dictionary) and not isinstance(ap, pikepdf.Stream):
            state = annot.get("/AS")
            ap = ap.get(state) if state is not None else None
            if ap is None:
                continue
        if not isinstance(ap, pikepdf.Stream):
            continue
        if "/Subtype" not in ap:
            ap.Type, ap.Subtype = Name.XObject, Name.Form
        bbox = [float(v) for v in ap.get("/BBox", [0, 0, 0, 0])]
        matrix = tuple(float(v) for v in ap.get("/Matrix", [1, 0, 0, 1, 0, 0]))
        tb = transform_rect(matrix, bbox)
        rect = [float(v) for v in annot.Rect]
        rx0, ry0, rx1, ry1 = min(rect[0], rect[2]), min(rect[1], rect[3]), max(rect[0], rect[2]), max(rect[1], rect[3])
        bw, bh = tb[2] - tb[0], tb[3] - tb[1]
        if bw <= 0 or bh <= 0:
            continue
        sx, sy = (rx1 - rx0) / bw, (ry1 - ry0) / bh
        a = (sx, 0, 0, sy, rx0 - tb[0] * sx, ry0 - tb[1] * sy)
        name = add_resource(page, "XObject", ap if ap.is_indirect else pdf.make_indirect(ap), "ZPDFfl")
        chunks.append(f"q {fmt(*a)} cm {name} Do Q")
    if chunks:
        add_content(pdf, page, ("\n".join(chunks) + "\n").encode())


# ---------------------------------------------------------------- images

def image_xobject(pdf, path, max_pixels=40_000_000):
    from PIL import Image
    image = Image.open(path)
    require(image.width * image.height <= max_pixels, "INVALID_ARGUMENT", "That image is too large.")
    image.load()
    fmt_name = image.format
    stream_args = {}
    smask = None
    if image.mode in ("RGBA", "LA", "P") or (image.mode == "P" and "transparency" in image.info):
        rgba = image.convert("RGBA")
        a = rgba.getchannel("A")
        if a.getextrema() != (255, 255):
            import zlib
            smask = pikepdf.Stream(pdf, zlib.compress(a.tobytes()))
            smask.Type, smask.Subtype = Name.XObject, Name.Image
            smask.Width, smask.Height = image.width, image.height
            smask.ColorSpace, smask.BitsPerComponent = Name.DeviceGray, 8
            smask.Filter = Name.FlateDecode
        image = rgba.convert("RGB")
        fmt_name = None
    if fmt_name == "JPEG" and image.mode in ("RGB", "L", "CMYK"):
        with open(path, "rb") as f:
            data = f.read()
        xobj = pikepdf.Stream(pdf, data)
        xobj.Filter = Name.DCTDecode
        space = {"RGB": Name.DeviceRGB, "L": Name.DeviceGray, "CMYK": Name.DeviceCMYK}[image.mode]
        if image.mode == "CMYK":
            xobj.Decode = pikepdf.Array([1, 0, 1, 0, 1, 0, 1, 0])  # Adobe inverted CMYK JPEGs
    else:
        import zlib
        if image.mode not in ("RGB", "L"):
            image = image.convert("RGB")
        xobj = pikepdf.Stream(pdf, zlib.compress(image.tobytes(), 6))
        xobj.Filter = Name.FlateDecode
        space = Name.DeviceRGB if image.mode == "RGB" else Name.DeviceGray
    xobj.Type, xobj.Subtype = Name.XObject, Name.Image
    xobj.Width, xobj.Height = image.width, image.height
    xobj.ColorSpace, xobj.BitsPerComponent = space, 8
    if smask is not None:
        xobj.SMask = pdf.make_indirect(smask)
    return pdf.make_indirect(xobj), image.width, image.height


# ---------------------------------------------------------------- text blocks

def text_form(pdf, font, lines, size, color, align="left", leading=1.2, kind=None, fill_alpha=1.0,
              outline=False):
    """A Form XObject containing `lines` of text; origin at its bottom-left."""
    widths = [font.width(line, size) for line in lines]
    width = max(widths + [1])
    line_height = size * leading
    height = line_height * len(lines)
    ops = []
    res = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font.ref))
    if fill_alpha < 1:
        res.ExtGState = pikepdf.Dictionary(GS1=ext_gstate(pdf, fill_alpha))
        ops.append("/GS1 gs")
    ops.append(color_ops(color))
    if outline:
        ops.append(color_ops(color, stroke=True))
    ops.append("BT")
    ops.append(f"/F1 {fmt(float(size))} Tf")
    if outline:
        ops.append("1 Tr 0.8 w")
    for i, (line, w) in enumerate(zip(lines, widths)):
        x = {"left": 0, "center": (width - w) / 2, "right": width - w}[align]
        y = height - line_height * (i + 1) + (line_height - size) / 2 - font.descent * size
        ops.append(f"1 0 0 1 {fmt(float(x), float(y))} Tm {font.encode(line)} Tj")
    ops.append("ET")
    return form_xobject(pdf, "\n".join(ops).encode(), (0, 0, width, height), res, kind), width, height


def select_pages(pdf, pages):
    count = len(pdf.pages)
    if pages is None:
        return list(range(count))
    require(isinstance(pages, list) and all(isinstance(p, int) and 0 <= p < count for p in pages),
            "INVALID_ARGUMENT", "The page range is invalid.")
    return sorted(set(pages))


ANCHORS = {
    "top-left": (0, 1), "top-center": (0.5, 1), "top-right": (1, 1),
    "center-left": (0, 0.5), "center": (0.5, 0.5), "center-right": (1, 0.5),
    "bottom-left": (0, 0), "bottom-center": (0.5, 0), "bottom-right": (1, 0),
}


def anchored(page, width, height, anchor, margin=(36, 36), offset=(0, 0), angle=0.0, scale=1.0):
    """Matrix placing a (width x height) box at a visual anchor of the page."""
    import math
    vw, vh = visual_size(page)
    ax, ay = ANCHORS[anchor]
    mx, my = margin
    cx = mx + (vw - 2 * mx) * ax + offset[0]
    cy = my + (vh - 2 * my) * ay + offset[1]
    w, h = width * scale, height * scale
    rad = math.radians(angle)
    cos, sin = math.cos(rad), math.sin(rad)
    # Rotated extents so the box stays inside the margin at its anchor.
    ew = abs(w * cos) + abs(h * sin)
    eh = abs(w * sin) + abs(h * cos)
    cx += {0: ew / 2, 0.5: 0, 1: -ew / 2}[ax]
    cy += {0: eh / 2, 0.5: 0, 1: -eh / 2}[ay]
    # Box centre -> origin, scale, rotate, then to anchor point in visual space.
    m = (1, 0, 0, 1, -width / 2, -height / 2)
    m = multiply(m, (scale, 0, 0, scale, 0, 0))
    m = multiply(m, (cos, sin, -sin, cos, 0, 0))
    m = multiply(m, (1, 0, 0, 1, cx, cy))
    return multiply(m, visual_matrix(page))


# ---------------------------------------------------------------- operations

@op("watermark")
def watermark(ctx, text=None, image=None, font=None, size=48, color=(255, 0, 0), opacity=0.3,
              angle=45, anchor="center", pages=None, under=False, scale=1.0, replace=True,
              offset=(0, 0), fit=False):
    require(text or image, "INVALID_ARGUMENT", "A watermark needs text or an image.")
    pdf = ctx.pdf
    targets = select_pages(pdf, pages)
    if replace:
        for i in range(len(pdf.pages)):
            remove_overlays(pdf, pdf.pages[i], "Watermark")
    if text:
        embedded = EmbeddedFont(pdf, font)
        form, w, h = text_form(pdf, embedded, str(text).split("\n"), float(size), color, "center",
                               kind="Watermark", fill_alpha=float(opacity))
        embedded.finish()
    else:
        xobj, pw, ph = image_xobject(pdf, image)
        w, h = float(pw), float(ph)
        res = pikepdf.Dictionary(XObject=pikepdf.Dictionary(Im1=xobj),
                                 ExtGState=pikepdf.Dictionary(GS1=ext_gstate(pdf, float(opacity))))
        form = form_xobject(pdf, f"/GS1 gs q {fmt(w)} 0 0 {fmt(h)} 0 0 cm /Im1 Do Q".encode(),
                            (0, 0, w, h), res, "Watermark")
    for index in targets:
        page = pdf.pages[index]
        s = float(scale)
        if fit:
            vw, vh = visual_size(page)
            s = min(vw * 0.8 / w, vh * 0.8 / h)
        place_form(pdf, page, form, anchored(page, w, h, anchor, (0, 0), tuple(offset), float(angle), s),
                   under=bool(under), prefix="ZPDFwm")
    return {"pages": len(targets)}


@op("remove_overlays")
def remove_overlay_op(ctx, kind):
    require(kind in ("Watermark", "HeaderFooter", "Background", "Bates"), "INVALID_ARGUMENT", "Unknown overlay.")
    return {"removed": sum(remove_overlays(ctx.pdf, page, kind) for page in ctx.pdf.pages)}


def expand(template, page_number, page_count, bates=None, today=None):
    today = today or date.today()
    values = {"page": str(page_number), "pages": str(page_count), "date": today.strftime("%m/%d/%Y"),
              "isodate": today.isoformat(), "bates": bates or ""}
    return re.sub(r"<<(\w+)>>", lambda m: values.get(m.group(1).lower(), m.group(0)), template)


@op("header_footer")
def header_footer(ctx, items, font=None, size=10, color=(0, 0, 0), margins=(36, 36, 36, 36),
                  pages=None, start=1, replace=True, kind="HeaderFooter", bates=None):
    """items: {"top-left": "...", "bottom-center": "Page <<page>> of <<pages>>", ...}.

    margins: (left, bottom, right, top) in points. Tokens: <<page>> <<pages>>
    <<date>> <<isodate>> <<bates>>.
    """
    pdf = ctx.pdf
    require(isinstance(items, dict) and items, "INVALID_ARGUMENT", "Add some header or footer text.")
    for key in items:
        require(key in ANCHORS and not key.startswith("center"), "INVALID_ARGUMENT", "Unknown header/footer position.")
    targets = select_pages(pdf, pages)
    if replace:
        for i in range(len(pdf.pages)):
            remove_overlays(pdf, pdf.pages[i], kind)
    embedded = EmbeddedFont(pdf, font)
    count = len(pdf.pages)
    left, bottom, right, top = [float(m) for m in margins]
    numbers = {}
    for n, index in enumerate(targets):
        page = pdf.pages[index]
        vw, vh = visual_size(page)
        chunks, res_fonts = [], None
        number = int(start) + n
        bates_text = None
        if bates:
            bates_text = f"{bates.get('prefix', '')}{int(bates.get('start', 1)) + n:0{int(bates.get('digits', 6))}d}{bates.get('suffix', '')}"
            numbers[index] = bates_text
        ops = [color_ops(color), "BT", f"/F1 {fmt(float(size))} Tf"]
        for anchor, template in items.items():
            text = expand(str(template), number, count if pages is None else len(targets), bates_text)
            if not text:
                continue
            w = embedded.width(text, float(size))
            ax, ay = ANCHORS[anchor]
            x = {0: left, 0.5: (vw - w) / 2, 1: vw - right - w}[ax]
            y = vh - top - float(size) * 0.8 if ay == 1 else bottom
            ops.append(f"1 0 0 1 {fmt(float(x), float(y))} Tm {embedded.encode(text)} Tj")
        ops.append("ET")
        res = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=embedded.ref))
        form = form_xobject(pdf, "\n".join(ops).encode(), (0, 0, vw, vh), res, kind)
        place_form(pdf, page, form, visual_matrix(page), prefix="ZPDFhf")
    embedded.finish()
    return {"pages": len(targets), "bates": [numbers[i] for i in sorted(numbers)] if bates else None}


@op("bates")
def bates(ctx, prefix="", suffix="", start=1, digits=6, anchor="bottom-right", font=None, size=10,
          color=(0, 0, 0), margins=(36, 24, 36, 24), pages=None):
    require(0 < int(digits) <= 15 and int(start) >= 0, "INVALID_ARGUMENT", "Invalid Bates numbering.")
    result = header_footer(ctx, {anchor: "<<bates>>"}, font, size, color, margins, pages, 1, True, "Bates",
                           {"prefix": prefix, "suffix": suffix, "start": start, "digits": digits})
    return {"pages": result["pages"], "first": result["bates"][0], "last": result["bates"][-1],
            "next": int(start) + result["pages"]}


@op("background")
def background(ctx, color=None, image=None, opacity=1.0, pages=None, replace=True, scale_to_fit=True):
    require(color is not None or image, "INVALID_ARGUMENT", "Choose a background color or image.")
    pdf = ctx.pdf
    targets = select_pages(pdf, pages)
    if replace:
        for i in range(len(pdf.pages)):
            remove_overlays(pdf, pdf.pages[i], "Background")
    xobj = None
    if image:
        xobj, pw, ph = image_xobject(pdf, image)
    gs = ext_gstate(pdf, float(opacity)) if float(opacity) < 1 else None
    for index in targets:
        page = pdf.pages[index]
        vw, vh = visual_size(page)
        res = pikepdf.Dictionary()
        ops = []
        if gs is not None:
            res.ExtGState = pikepdf.Dictionary(GS1=gs)
            ops.append("/GS1 gs")
        if xobj is not None:
            res.XObject = pikepdf.Dictionary(Im1=xobj)
            if scale_to_fit:
                ops.append(f"q {fmt(float(vw))} 0 0 {fmt(float(vh))} 0 0 cm /Im1 Do Q")
            else:
                s = min(vw / pw, vh / ph)
                ops.append(f"q {fmt(pw * s)} 0 0 {fmt(ph * s)} {fmt((vw - pw * s) / 2)} {fmt((vh - ph * s) / 2)} cm /Im1 Do Q")
        else:
            ops.append(f"{color_ops(color)} 0 0 {fmt(float(vw))} {fmt(float(vh))} re f")
        form = form_xobject(pdf, "\n".join(ops).encode(), (0, 0, vw, vh), res, "Background")
        place_form(pdf, page, form, visual_matrix(page), under=True, prefix="ZPDFbg")
    return {"pages": len(targets)}
