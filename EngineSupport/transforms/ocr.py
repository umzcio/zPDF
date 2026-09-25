"""OCR text layers and scan cleanup.

Recognition runs in the app (Apple Vision). This module writes the result:
an invisible (render mode 3) text layer whose words are positioned and
horizontally scaled to the recognized boxes, so scanned pages become
searchable, selectable and copyable in PDFKit and other readers. The layer is
one tagged overlay per page (/ZPDFKind /OCRText) and is replaced on re-run.

`visible=True` instead draws real, visible text objects (optionally covering
the recognized words of the scan with white) — "OCR to editable text".
"""
from pathlib import Path

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op, query
from transforms.content import (form_xobject, place_form, remove_overlays, visual_matrix, visual_size,
                                image_xobject, fmt, resources)
from transforms.fonts import EmbeddedFont

KINDS = ("OCRText", "OCRVisible")


def _has_overlay(page, kind):
    xobjects = resources(page).get("/XObject", pikepdf.Dictionary())
    return any(str(x.get("/ZPDFKind", "")) == "/" + kind for x in xobjects.values()
               if isinstance(x, pikepdf.Stream))


def _box(values):
    require(isinstance(values, list) and len(values) == 4, "INVALID_ARGUMENT", "Word boxes need four values.")
    x0, y0, x1, y1 = [float(v) for v in values]
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


@op("ocr_text_layer")
def ocr_text_layer(ctx, pages, replace=True, visible=False, cover=False, font=None, color=(0, 0, 0)):
    """pages: [{"page": i, "lines": [[{"t": "word", "b": [x0, y0, x1, y1]}, ...], ...]}]
    Boxes are in points in the page's visual (upright, bottom-left origin) space."""
    pdf = ctx.pdf
    require(isinstance(pages, list), "INVALID_ARGUMENT", "OCR results are required.")
    embedded = EmbeddedFont(pdf, font)
    kind = "OCRVisible" if visible else "OCRText"
    words_written = 0
    for entry in pages:
        index = entry.get("page")
        require(isinstance(index, int) and 0 <= index < len(pdf.pages), "INVALID_ARGUMENT", "An OCR page is out of range.")
        page = pdf.pages[index]
        if replace:
            for k in KINDS:
                remove_overlays(pdf, page, k)
        lines = entry.get("lines") or []
        vw, vh = visual_size(page)
        span = embedded.ascent - embedded.descent
        text_ops, cover_ops = [], []
        for line in lines:
            require(isinstance(line, list), "INVALID_ARGUMENT", "OCR lines must be lists of words.")
            for n, word in enumerate(line):
                text = str(word.get("t", "")).strip()
                if not text:
                    continue
                x0, y0, x1, y1 = _box(word.get("b"))
                w, h = x1 - x0, y1 - y0
                if w <= 0.5 or h <= 0.5:
                    continue
                size = h / span if span > 0 else h
                content = text + (" " if n < len(line) - 1 else "")
                natural = embedded.width(text, size)
                if natural <= 0:
                    continue
                scale = max(1.0, min(1000.0, w / natural * 100))
                baseline = y0 - embedded.descent * size
                if cover:
                    pad = h * 0.08
                    cover_ops.append(f"{fmt(x0 - pad, y0 - pad, w + 2 * pad, h + 2 * pad)} re")
                text_ops.append(f"/F1 {fmt(size)} Tf {fmt(scale)} Tz 1 0 0 1 {fmt(x0, baseline)} Tm "
                                f"{embedded.encode(content)} Tj")
                words_written += 1
        if not text_ops:
            continue
        stream = []
        if cover_ops:
            stream += ["q 1 1 1 rg"] + cover_ops + ["f Q"]
        r, g, b = [c / 255 if c > 1 else c for c in list(color)[:3]]
        stream += ["BT", "0 Tr" if visible else "3 Tr", f"{r:.3f} {g:.3f} {b:.3f} rg"] + text_ops + ["ET"]
        res = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=embedded.ref))
        form = form_xobject(pdf, "\n".join(stream).encode(), (0, 0, vw, vh), res, kind)
        place_form(pdf, page, form, visual_matrix(page), prefix="ZPDFocr")
    embedded.finish()
    return {"pages": len(pages), "words": words_written}


@op("remove_ocr_layer")
def remove_ocr_layer(ctx, pages=None):
    pdf = ctx.pdf
    targets = range(len(pdf.pages)) if pages is None else pages
    removed = 0
    for index in targets:
        for kind in KINDS:
            removed += remove_overlays(pdf, pdf.pages[index], kind)
    return {"removed": removed}


@op("replace_page_image")
def replace_page_image(ctx, pages):
    """pages: [{"page": i, "path": image}] — replaces the page's content with a
    (cleaned/deskewed) image filling the visual page. Annotations are kept;
    any previous OCR layer is removed (run OCR again on the new image)."""
    pdf = ctx.pdf
    require(isinstance(pages, list) and pages, "INVALID_ARGUMENT", "Choose pages to replace.")
    for entry in pages:
        index, path = entry.get("page"), entry.get("path")
        require(isinstance(index, int) and 0 <= index < len(pdf.pages), "INVALID_ARGUMENT", "A page is out of range.")
        require(isinstance(path, str) and Path(path).is_file(), "INVALID_ARGUMENT", "A cleaned page image is missing.")
        page = pdf.pages[index]
        xobj, _, _ = image_xobject(pdf, path)
        vw, vh = visual_size(page)
        a, b, c, d, e, f = visual_matrix(page)
        obj = page.obj
        for key in ("/ZPDFWrapped", "/Group", "/Thumb"):
            if key in obj:
                del obj[key]
        obj.Resources = pikepdf.Dictionary(XObject=pikepdf.Dictionary(ZPDFscan=xobj))
        obj.Contents = pdf.make_indirect(pikepdf.Stream(
            pdf, f"q {fmt(a, b, c, d, e, f)} cm q {fmt(vw)} 0 0 {fmt(vh)} 0 0 cm /ZPDFscan Do Q Q\n".encode()))
    return {"pages": len(pages)}


@query("text_status")
def text_status(ctx, pages=None):
    """Per page: characters of original text, and whether an OCR layer exists."""
    pdf = ctx.pdf
    indexes = range(len(pdf.pages)) if pages is None else pages
    ocr = {i: _has_overlay(pdf.pages[i], "OCRText") or _has_overlay(pdf.pages[i], "OCRVisible") for i in indexes}
    out = []
    with ctx.pdfium() as doc:
        for i in indexes:
            page = doc[i]
            tp = page.get_textpage()
            chars = tp.count_chars()
            tp.close()
            images = 0
            try:
                import pypdfium2.raw as raw
                for obj in page.get_objects(filter=[raw.FPDF_PAGEOBJ_IMAGE], max_depth=2):
                    images += 1
            except Exception:  # noqa: BLE001 - informational only
                pass
            page.close()
            out.append({"page": i, "chars": chars, "ocr": ocr[i], "images": images})
    return {"pages": out}
