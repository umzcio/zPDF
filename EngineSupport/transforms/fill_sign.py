"""Fill & Sign marks that PDFKit can't serialize faithfully.

`place_image_stamp` puts a drawn/typed/imported signature (or initials) on a
page as a Stamp annotation whose appearance is the image (with its alpha
channel as a soft mask), so it prints and renders identically everywhere.
`add_markup_note` creates the simple note/highlight/underline comments used
by append-only saves of signed documents (the facade would rewrite them).
"""
import base64
import datetime as dt

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op
from transforms.content import fmt, image_xobject


def _rect(page, rect):
    require(isinstance(rect, (list, tuple)) and len(rect) == 4, "INVALID_ARGUMENT", "Invalid rectangle.")
    x0, y0, x1, y1 = [float(v) for v in rect]
    x0, x1 = sorted((x0, x1))
    y0, y1 = sorted((y0, y1))
    require(x1 - x0 >= 2 and y1 - y0 >= 2, "INVALID_ARGUMENT", "The mark is too small.")
    return [x0, y0, x1, y1]


def _now():
    moment = dt.datetime.now().astimezone()
    offset = moment.utcoffset() or dt.timedelta(0)
    minutes = int(offset.total_seconds() // 60)
    sign = "+" if minutes >= 0 else "-"
    minutes = abs(minutes)
    return moment.strftime("D:%Y%m%d%H%M%S") + f"{sign}{minutes // 60:02d}'{minutes % 60:02d}'"


@op("place_image_stamp")
def place_image_stamp(ctx, page, rect, image, name="Signature", kind="signature", author=""):
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "Choose a page in this document.")
    require(kind in ("signature", "initials", "image"), "INVALID_ARGUMENT", "Unknown stamp kind.")
    try:
        data = base64.b64decode(image)
    except (ValueError, TypeError):
        data = b""
    require(0 < len(data) <= 8 * 1024 * 1024, "INVALID_ARGUMENT", "The signature image is missing or too large.")
    path = ctx.scratch(".png")
    path.write_bytes(data)
    xobject, pw, ph = image_xobject(pdf, path)
    box = _rect(pdf.pages[page], rect)
    width, height = box[2] - box[0], box[3] - box[1]
    scale = min(width / pw, height / ph)
    dw, dh = pw * scale, ph * scale
    x, y = (width - dw) / 2, (height - dh) / 2
    ap = pikepdf.Stream(pdf, f"q {fmt(dw, 0, 0, dh, x, y)} cm /Im1 Do Q".encode())
    ap.Type, ap.Subtype = Name.XObject, Name.Form
    ap.BBox = pikepdf.Array([0, 0, width, height])
    ap.Resources = pikepdf.Dictionary(XObject=pikepdf.Dictionary(Im1=xobject))
    annot = pikepdf.Dictionary(
        Type=Name.Annot, Subtype=Name.Stamp, Rect=pikepdf.Array(box),
        Name=Name("/ZPDF" + kind.capitalize()), Contents=pikepdf.String(name or kind.capitalize()),
        F=4, M=pikepdf.String(_now()), AP=pikepdf.Dictionary(N=pdf.make_indirect(ap)),
        P=pdf.pages[page].obj)
    if author:
        annot.T = pikepdf.String(author)
    ref = pdf.make_indirect(annot)
    obj = pdf.pages[page].obj
    if "/Annots" not in obj:
        obj.Annots = pikepdf.Array()
    obj.Annots.append(ref)
    return {"page": page, "index": len(obj.Annots) - 1, "rect": box}


def _rgb(color):
    values = [float(v) for v in (color or [255, 230, 0])[:3]]
    if any(v > 1 for v in values):
        values = [v / 255 for v in values]
    return values


@op("add_markup_note")
def add_markup_note(ctx, page, kind, rect, contents="", author="", color=None):
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "Choose a page in this document.")
    box = _rect(pdf.pages[page], rect)
    rgb = _rgb(color)
    common = dict(Type=Name.Annot, Rect=pikepdf.Array(box), Contents=pikepdf.String(contents or ""),
                  T=pikepdf.String(author or ""), C=pikepdf.Array(rgb), F=4, M=pikepdf.String(_now()),
                  P=pdf.pages[page].obj)
    width, height = box[2] - box[0], box[3] - box[1]
    if kind == "sticky_note":
        annot = pikepdf.Dictionary(Subtype=Name.Text, Name=Name.Comment, **common)
    elif kind in ("highlight", "underline"):
        quads = pikepdf.Array([box[0], box[3], box[2], box[3], box[0], box[1], box[2], box[1]])
        if kind == "highlight":
            content = f"q /GS0 gs {fmt(*rgb)} rg 0 0 {fmt(width, height)} re f Q"
            resources = pikepdf.Dictionary(ExtGState=pikepdf.Dictionary(
                GS0=pikepdf.Dictionary(Type=Name.ExtGState, BM=Name.Multiply, CA=1, ca=1)))
            subtype = Name.Highlight
        else:
            line = max(0.5, height * 0.07)
            content = f"q {fmt(*rgb)} RG {fmt(line)} w 0 {fmt(line)} m {fmt(width, line)} l S Q"
            resources = pikepdf.Dictionary()
            subtype = Name.Underline
        ap = pikepdf.Stream(pdf, content.encode())
        ap.Type, ap.Subtype = Name.XObject, Name.Form
        ap.BBox = pikepdf.Array([0, 0, width, height])
        ap.Resources = resources
        annot = pikepdf.Dictionary(Subtype=subtype, QuadPoints=quads, AP=pikepdf.Dictionary(N=pdf.make_indirect(ap)), **common)
    else:
        require(False, "UNSUPPORTED_OPERATION", "Unsupported note type.")
    obj = pdf.pages[page].obj
    if "/Annots" not in obj:
        obj.Annots = pikepdf.Array()
    obj.Annots.append(pdf.make_indirect(annot))
    return {"page": page}
