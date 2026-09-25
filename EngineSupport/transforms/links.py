"""Link annotations: list, add, retarget and remove.

Targets are either a web/mail URI (http, https, mailto) or a page of this
document. Rects are PDF user space; page numbers are 0-based.
"""
import math
from urllib.parse import urlsplit

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op, query
from transforms.content import page_box, rotation

HIGHLIGHT = {"invert": Name.I, "none": Name.N, "outline": Name.O, "push": Name.P}


# ---------------------------------------------------------------- helpers

def _page(pdf, page):
    require(isinstance(page, int) and not isinstance(page, bool) and 0 <= page < len(pdf.pages),
            "STALE_PAGE", "That page no longer exists.")
    return pdf.pages[page]


def _rect(rect):
    require(isinstance(rect, (list, tuple)) and len(rect) == 4, "INVALID_ARGUMENT", "A link needs a rectangle.")
    try:
        values = [float(v) for v in rect]
    except (TypeError, ValueError):
        values = []
    require(len(values) == 4 and all(math.isfinite(v) for v in values), "INVALID_ARGUMENT",
            "A link needs a rectangle.")
    x0, y0, x1, y1 = values
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    require(x1 - x0 > 0 and y1 - y0 > 0, "INVALID_ARGUMENT", "The link area is empty.")
    return [x0, y0, x1, y1]


def _check_uri(uri):
    require(isinstance(uri, str) and uri.strip(), "INVALID_ARGUMENT", "Enter a web or email address.")
    uri = uri.strip()
    parts = urlsplit(uri)
    scheme = parts.scheme.lower()
    require(scheme in ("http", "https", "mailto"), "INVALID_ARGUMENT",
            "Links can only open web (http, https) or email (mailto) addresses.")
    if scheme in ("http", "https"):
        require(bool(parts.netloc), "INVALID_ARGUMENT", "That web address is incomplete.")
    else:
        require(len(uri) > len("mailto:"), "INVALID_ARGUMENT", "That email address is incomplete.")
    return uri


def _destination(pdf, dest_page, zoom):
    target = _page(pdf, dest_page)
    require(zoom in ("fit", "xyz"), "INVALID_ARGUMENT", "Unknown link zoom.")
    if zoom == "fit":
        return pikepdf.Array([target.obj, Name.Fit])
    x0, y0, x1, y1 = page_box(target)
    # "Top of the page" as displayed, expressed in user space.
    null = None
    left, top = {0: (null, y1), 90: (x0, null), 180: (null, y0), 270: (x1, null)}[rotation(target)]
    return pikepdf.Array([target.obj, Name.XYZ, left, top, null])


def _set_target(pdf, annot, uri, dest_page, zoom):
    require((uri is None) != (dest_page is None), "INVALID_ARGUMENT",
            "Choose either a web address or a page for the link.")
    for key in ("/A", "/Dest"):
        if key in annot:
            del annot[key]
    if uri is not None:
        annot.A = pikepdf.Dictionary(S=Name.URI, URI=pikepdf.String(_check_uri(uri)))
    else:
        annot.Dest = _destination(pdf, dest_page, zoom)


def _page_numbers(pdf):
    return {page.obj.objgen: i for i, page in enumerate(pdf.pages)}


def _named(pdf, name):
    root = pdf.Root
    value = None
    if isinstance(name, pikepdf.Name):
        dests = root.get("/Dests")
        if isinstance(dests, pikepdf.Dictionary):
            value = dests.get(name)
    else:
        names = root.get("/Names")
        if isinstance(names, pikepdf.Dictionary) and "/Dests" in names:
            try:
                value = pikepdf.NameTree(names.Dests).get(str(name))
            except Exception:
                value = None
        if value is None and isinstance(root.get("/Dests"), pikepdf.Dictionary):
            value = root.Dests.get("/" + str(name))
    if isinstance(value, pikepdf.Dictionary):
        value = value.get("/D")
    return value


def _dest_page(pdf, dest, numbers, depth=0):
    if dest is None or depth > 4:
        return None
    if isinstance(dest, (pikepdf.Name, pikepdf.String, str)):
        return _dest_page(pdf, _named(pdf, dest), numbers, depth + 1)
    if isinstance(dest, pikepdf.Array) and len(dest) > 0:
        first = dest[0]
        if isinstance(first, pikepdf.Dictionary) and first.is_indirect:
            return numbers.get(first.objgen)
        if isinstance(first, int) and 0 <= int(first) < len(pdf.pages):
            return int(first)
    return None


def _describe(pdf, annot, index, numbers):
    rect = [float(v) for v in annot.get("/Rect", [0, 0, 0, 0])]
    rect = [min(rect[0], rect[2]), min(rect[1], rect[3]), max(rect[0], rect[2]), max(rect[1], rect[3])]
    uri, dest_page = None, None
    action = annot.get("/A")
    if isinstance(action, pikepdf.Dictionary):
        kind = str(action.get("/S", ""))
        if kind == "/URI" and "/URI" in action:
            uri = str(action.URI)
        elif kind == "/GoTo":
            dest_page = _dest_page(pdf, action.get("/D"), numbers)
    elif "/Dest" in annot:
        dest_page = _dest_page(pdf, annot.Dest, numbers)
    kind = "uri" if uri is not None else "page" if dest_page is not None else "other"
    return {"index": index, "rect": rect, "uri": uri, "dest_page": dest_page, "kind": kind}


def _link_at(page, index):
    annots = page.obj.get("/Annots")
    require(isinstance(annots, pikepdf.Array) and isinstance(index, int) and not isinstance(index, bool)
            and 0 <= index < len(annots), "STALE_ANNOTATION", "A link no longer matches the opened file.")
    annot = annots[index]
    require(isinstance(annot, pikepdf.Dictionary) and str(annot.get("/Subtype", "")) == "/Link",
            "STALE_ANNOTATION", "A link no longer matches the opened file.")
    return annot


# ---------------------------------------------------------------- query / ops

@query("links")
def links(ctx, page=0):
    pdf = ctx.pdf
    target = _page(pdf, page)
    numbers = _page_numbers(pdf)
    found = []
    for index, annot in enumerate(target.obj.get("/Annots", [])):
        if isinstance(annot, pikepdf.Dictionary) and str(annot.get("/Subtype", "")) == "/Link":
            found.append(_describe(pdf, annot, index, numbers))
    return {"links": found}


@op("link_add")
def link_add(ctx, page, rect, uri=None, dest_page=None, zoom="fit", highlight="invert", border=None):
    pdf = ctx.pdf
    target = _page(pdf, page)
    require(highlight in HIGHLIGHT, "INVALID_ARGUMENT", "Unknown link highlight.")
    annot = pikepdf.Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=pikepdf.Array(_rect(rect)),
                               F=4, H=HIGHLIGHT[highlight])
    if border is None:
        annot.Border = pikepdf.Array([0, 0, 0])
    else:
        require(isinstance(border, (list, tuple)) and len(border) == 3
                and all(isinstance(c, (int, float)) and 0 <= c <= 255 for c in border),
                "INVALID_ARGUMENT", "The link border color is invalid.")
        annot.C = pikepdf.Array([float(c) / 255 for c in border])
        annot.Border = pikepdf.Array([0, 0, 1])
    _set_target(pdf, annot, uri, dest_page, zoom)
    annot.P = target.obj
    annot = pdf.make_indirect(annot)
    annots = target.obj.get("/Annots")
    if not isinstance(annots, pikepdf.Array):
        target.obj.Annots = pikepdf.Array()
        annots = target.obj.Annots
    annots.append(annot)
    return {"index": len(annots) - 1}


@op("link_update")
def link_update(ctx, page, index, rect=None, uri=None, dest_page=None, zoom="fit"):
    pdf = ctx.pdf
    annot = _link_at(_page(pdf, page), index)
    new_rect = _rect(rect) if rect is not None else None
    if uri is not None or dest_page is not None:
        _set_target(pdf, annot, uri, dest_page, zoom)
    if new_rect is not None:
        annot.Rect = pikepdf.Array(new_rect)
    return {"index": index}


@op("link_remove")
def link_remove(ctx, page, indexes):
    pdf = ctx.pdf
    target = _page(pdf, page)
    require(isinstance(indexes, list) and indexes, "INVALID_ARGUMENT", "Choose the links to remove.")
    doomed = set()
    for index in indexes:
        _link_at(target, index)
        doomed.add(index)
    annots = target.obj.Annots
    target.obj.Annots = pikepdf.Array([a for i, a in enumerate(annots) if i not in doomed])
    return {"removed": len(doomed)}
