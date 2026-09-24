"""Page design: crop boxes and the settings behind app-added overlays.

Crop coordinates are PDF user space (unrotated). Margins are given in the
page's visual orientation, so "top" is the edge shown at the top.
"""
import json
import math

import pikepdf

from engine.errors import EngineError, require
from transforms import op, query
from transforms.content import rotation, select_pages, visual_matrix, transform_rect

KINDS = ("Watermark", "HeaderFooter", "Background", "Bates")
MIN_SIZE = 18.0
OTHER_BOXES = ("/TrimBox", "/ArtBox", "/BleedBox")


# ---------------------------------------------------------------- boxes

def _inherited(obj, key):
    node = obj
    depth = 0
    while isinstance(node, pikepdf.Dictionary) and depth < 64:
        if key in node:
            return node[key]
        node = node.get("/Parent")
        depth += 1
    return None


def _normal(value):
    x0, y0, x1, y1 = [float(v) for v in value]
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


def media_box(page):
    value = _inherited(page.obj, "/MediaBox")
    return _normal(value) if value is not None else [0.0, 0.0, 612.0, 792.0]


def crop_box(page):
    value = _inherited(page.obj, "/CropBox")
    return _intersect(_normal(value), media_box(page)) or media_box(page) if value is not None else media_box(page)


def _intersect(a, b):
    box = [max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])]
    return box if box[2] > box[0] and box[3] > box[1] else None


def _inset(crop, margins, rotate):
    left, bottom, right, top = margins
    x0, y0, x1, y1 = crop
    # User-space edge shown at the visual (left, bottom, right, top).
    if rotate == 0:
        return [x0 + left, y0 + bottom, x1 - right, y1 - top]
    if rotate == 90:
        return [x0 + top, y0 + left, x1 - bottom, y1 - right]
    if rotate == 180:
        return [x0 + right, y0 + top, x1 - left, y1 - bottom]
    return [x0 + bottom, y0 + right, x1 - top, y1 - left]  # 270


def _numbers(values, count, message):
    require(isinstance(values, (list, tuple)) and len(values) == count, "INVALID_ARGUMENT", message)
    try:
        out = [float(v) for v in values]
    except (TypeError, ValueError):
        out = []
    require(len(out) == count and all(math.isfinite(v) for v in out), "INVALID_ARGUMENT", message)
    return out


def _content_box(doc, index, page):
    """User-space bounding box of non-white pixels, or None for a blank page."""
    from PIL import ImageChops
    scale = 100 / 72
    pdfium_page = doc[index]
    try:
        bitmap = pdfium_page.render(scale=scale, may_draw_forms=True)
        image = bitmap.to_pil().convert("RGB")
    finally:
        pdfium_page.close()
    r, g, b = image.split()
    darkest = ImageChops.darker(ImageChops.darker(r, g), b)
    bbox = darkest.point(lambda v: 255 if v < 250 else 0).getbbox()
    if bbox is None:
        return None
    left, upper, right, lower = bbox
    width, height = image.size
    x0, y0, x1, y1 = crop_box(page)
    vw, vh = (y1 - y0, x1 - x0) if rotation(page) in (90, 270) else (x1 - x0, y1 - y0)
    sx, sy = vw / width, vh / height
    visual = (left * sx, vh - lower * sy, right * sx, vh - upper * sy)
    box = list(transform_rect(_visual_to_user(page), visual))
    return [box[0] - 2, box[1] - 2, box[2] + 2, box[3] + 2]


def _visual_to_user(page):
    # Visual space is measured from the crop box, which content.visual_matrix
    # maps back to user space directly.
    return visual_matrix(page)


def _grow(box, media):
    """Expand a tiny automatic crop to the minimum size, within the media box."""
    x0, y0, x1, y1 = box
    for lo, hi, mlo, mhi in ((0, 2, media[0], media[2]), (1, 3, media[1], media[3])):
        size = box[hi] - box[lo]
        if size < MIN_SIZE:
            centre = (box[lo] + box[hi]) / 2
            lo_v = max(mlo, min(centre - MIN_SIZE / 2, mhi - MIN_SIZE))
            box[lo], box[hi] = lo_v, min(mhi, lo_v + MIN_SIZE)
    return box


def _apply_crop(page, box):
    obj = page.obj
    obj.CropBox = pikepdf.Array([round(v, 4) for v in box])
    for key in OTHER_BOXES:
        if key not in obj:
            continue
        try:
            current = _normal(obj[key])
        except (TypeError, ValueError):
            continue
        clamped = _intersect(current, box) or list(box)
        if clamped != current:
            obj[key] = pikepdf.Array([round(v, 4) for v in clamped])


@op("crop_pages")
def crop_pages(ctx, pages=None, box=None, margins=None, remove_white_margins=False, reset=False):
    pdf = ctx.pdf
    modes = [box is not None, margins is not None, bool(remove_white_margins), bool(reset)]
    require(sum(modes) == 1, "INVALID_ARGUMENT", "Choose one way to crop the pages.")
    targets = select_pages(pdf, pages)
    if box is not None:
        box = _normal(_numbers(box, 4, "The crop area is invalid."))
    if margins is not None:
        margins = _numbers(margins, 4, "The crop margins are invalid.")
    planned = []
    if remove_white_margins:
        with ctx.pdfium() as doc:
            for index in targets:
                page = pdf.pages[index]
                found = _content_box(doc, index, page)
                if found is None:
                    continue  # blank page: nothing to measure
                media = media_box(page)
                clamped = _intersect(found, media)
                if clamped is None:
                    continue
                planned.append((page, _grow(clamped, media)))
    else:
        for index in targets:
            page = pdf.pages[index]
            media = media_box(page)
            if reset:
                planned.append((page, None))
                continue
            wanted = box if box is not None else _inset(crop_box(page), margins, rotation(page))
            wanted = _normal(wanted)
            clamped = _intersect(wanted, media)
            require(clamped is not None and clamped[2] - clamped[0] >= MIN_SIZE and clamped[3] - clamped[1] >= MIN_SIZE,
                    "INVALID_ARGUMENT", "The crop area is too small.")
            planned.append((page, clamped))
    for page, new in planned:
        if new is None:
            if "/CropBox" in page.obj:
                del page.obj["/CropBox"]
            if _inherited(page.obj, "/CropBox") is not None:  # inherited from the page tree
                page.obj.CropBox = pikepdf.Array(media_box(page))
            new = media_box(page)
            for key in OTHER_BOXES:
                if key in page.obj:
                    clamped = _intersect(_normal(page.obj[key]), new) or new
                    page.obj[key] = pikepdf.Array(clamped)
            continue
        _apply_crop(page, new)
    return {"pages": len(planned)}


@query("page_boxes")
def page_boxes(ctx, pages=None):
    pdf = ctx.pdf
    return {"pages": [{"index": i, "media": media_box(pdf.pages[i]), "crop": crop_box(pdf.pages[i]),
                       "rotation": rotation(pdf.pages[i])} for i in select_pages(pdf, pages)]}


# ---------------------------------------------------------------- overlay settings

def _overlay_forms(page):
    """(kind, form) for app overlay forms referenced by the page resources."""
    res = _inherited(page.obj, "/Resources")
    xobjects = res.get("/XObject") if isinstance(res, pikepdf.Dictionary) else None
    if not isinstance(xobjects, pikepdf.Dictionary):
        return []
    found = []
    for name in list(xobjects.keys()):
        form = xobjects[name]
        if isinstance(form, pikepdf.Stream) and "/ZPDFKind" in form:
            found.append((str(form.ZPDFKind)[1:], form))
    return found


@op("tag_overlay_settings")
def tag_overlay_settings(ctx, kind, settings):
    require(kind in KINDS, "INVALID_ARGUMENT", "Unknown overlay.")
    require(isinstance(settings, dict), "INVALID_ARGUMENT", "Overlay settings are invalid.")
    try:
        encoded = json.dumps(settings, sort_keys=True, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise EngineError("INVALID_ARGUMENT", "Overlay settings are invalid.") from exc
    seen, count = set(), 0
    for page in ctx.pdf.pages:
        for found, form in _overlay_forms(page):
            if found != kind:
                continue
            key = form.objgen if form.is_indirect else id(form)
            if key in seen:
                continue
            seen.add(key)
            form.ZPDFSettings = pikepdf.String(encoded)
            count += 1
    return {"tagged": count}


@query("page_design")
def page_design(ctx):
    result = {kind: {"pages": [], "settings": None} for kind in KINDS}
    for index, page in enumerate(ctx.pdf.pages):
        for kind, form in _overlay_forms(page):
            if kind not in result:
                continue
            entry = result[kind]
            if not entry["pages"] or entry["pages"][-1] != index:
                entry["pages"].append(index)
            if entry["settings"] is None and "/ZPDFSettings" in form:
                try:
                    parsed = json.loads(str(form.ZPDFSettings))
                except ValueError:
                    parsed = None
                entry["settings"] = parsed if isinstance(parsed, dict) else None
    return result
