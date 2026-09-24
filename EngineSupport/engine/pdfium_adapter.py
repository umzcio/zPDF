"""Native operations extracted from pdfium_chain, extended_forms and probe.

All entry points are called by the single worker. No app/reader dependencies.
The installed pypdfium2 package owns platform-specific native-library loading.
"""

from contextlib import contextmanager, ExitStack, closing
import ctypes as c
import math

import pypdfium2 as pdf
import pypdfium2.raw as r

from .errors import EngineError, require


def wide(value):
    data = value.encode("utf-16-le") + b"\0\0"
    return (c.c_ushort * (len(data) // 2)).from_buffer_copy(data)


def getwide(fn, *args):
    size = fn(*args, None, 0)
    if not size:
        return ""
    buffer = (c.c_ushort * ((size + 1) // 2))()
    fn(*args, buffer, size)
    return bytes(buffer).decode("utf-16-le", errors="replace").rstrip("\0")


def native(ok, operation):
    require(bool(ok), "ENGINE_FAILED", "PDFium failed to " + operation + ".")


@contextmanager
def document(path, password=None, forms=True):
    try:
        doc = pdf.PdfDocument(path, password=password)
    except pdf.PdfiumError as exc:
        code = "ENGINE_FAILED"
        if r.FPDF_GetLastError() == r.FPDF_ERR_PASSWORD:
            code = "PASSWORD_REQUIRED" if password is None else "INVALID_PASSWORD"
        raise EngineError(code, "PDFium could not open the document.") from exc
    try:
        if forms and r.FPDF_GetFormType(doc) in (r.FORMTYPE_NONE, r.FORMTYPE_ACRO_FORM):
            doc.init_forms()
        yield doc
    finally:
        doc.close()


@contextmanager
def annotation(page, index):
    handle = r.FPDFPage_GetAnnot(page, index)
    native(handle, "open annotation")
    try:
        yield handle
    finally:
        r.FPDFPage_CloseAnnot(handle)


def pdf_string(value):
    if isinstance(value, str) and value.startswith("u:"):
        return value[2:]
    return value


def inventory(doc, structure):
    pages, fields, annots = [], {}, []
    for pi in range(len(doc)):
        with closing(doc[pi]) as page:
            pages.append({"index": pi, "crop_box": list(page.get_cropbox()),
                          "rotation": r.FPDFPage_GetRotation(page) * 90})
            for ai in range(r.FPDFPage_GetAnnotCount(page)):
                with annotation(page, ai) as annot:
                    typ = r.FPDFAnnot_GetSubtype(annot)
                    if typ != r.FPDF_ANNOT_WIDGET:
                        rect = r.FS_RECTF()
                        native(r.FPDFAnnot_GetRect(annot, rect), "read annotation rectangle")
                        annots.append({"page": pi, "index": ai, "type": typ,
                                       "contents": getwide(r.FPDFAnnot_GetStringValue, annot, b"Contents"),
                                       "rect": [rect.left, rect.bottom, rect.right, rect.top]})
                        continue
                    # XFA fallback viewing must not depend on an AcroForm environment.
                    if not doc.formenv:
                        continue
                    key, node = structure.field(pi, ai)
                    options = []
                    for oi, option in enumerate(structure.inherited(node, "/Opt", [])):
                        if isinstance(option, list):
                            export, label = map(pdf_string, option)
                        else:
                            export = label = pdf_string(option)
                        options.append({"index": oi, "label": label, "export": export})
                    field = fields.setdefault(key, {
                        "key": key, "name": getwide(r.FPDFAnnot_GetFormFieldName, doc.formenv, annot),
                        "type": r.FPDFAnnot_GetFormFieldType(doc.formenv, annot),
                        "flags": r.FPDFAnnot_GetFormFieldFlags(doc.formenv, annot),
                        "value": getwide(r.FPDFAnnot_GetFormFieldValue, doc.formenv, annot),
                        "options": options, "widgets": []})
                    field["widgets"].append({"page": pi, "index": ai,
                        "value": getwide(r.FPDFAnnot_GetFormFieldValue, doc.formenv, annot),
                        "export": getwide(r.FPDFAnnot_GetFormFieldExportValue, doc.formenv, annot),
                        "checked": bool(r.FPDFAnnot_IsChecked(doc.formenv, annot))})
    return {"pages": pages, "fields": list(fields.values()), "annotations": annots}


def plan_fill(field, value):
    require(not field["flags"] & 1, "READ_ONLY_FIELD", "Field is read-only.")
    typ = field["type"]
    widget = field["widgets"][0]
    if typ == r.FPDF_FORMFIELD_TEXTFIELD:
        require(isinstance(value, str) and "\0" not in value, "INVALID_ARGUMENT", "Text field requires a string without NUL.")
        return widget, "text", value
    if typ == r.FPDF_FORMFIELD_CHECKBOX:
        require(type(value) is bool, "INVALID_ARGUMENT", "Checkbox requires a boolean.")
        return widget, "button", value
    if typ == r.FPDF_FORMFIELD_RADIOBUTTON:
        matches = [w for w in field["widgets"] if w["export"] == value]
        require(isinstance(value, str) and len(matches) == 1, "INVALID_ARGUMENT", "Select a unique radio export value.")
        return matches[0], "button", True
    if typ == r.FPDF_FORMFIELD_COMBOBOX:
        require(type(value) is int and 0 <= value < len(field["options"]), "INVALID_ARGUMENT", "Invalid dropdown option.")
        return widget, "choice", value
    raise EngineError("UNSUPPORTED_OPERATION", "This form control is outside the v0 facade.")


def fill(doc, plan):
    widget, kind, value = plan
    # Loading the linked pages preserves PDFium appearance invalidation behavior
    # proven by extended_forms.py. Large-document tuning is outside this increment.
    with ExitStack() as stack:
        pages = [stack.enter_context(closing(doc[i])) for i in range(len(doc))]
        page = pages[widget["page"]]
        with annotation(page, widget["index"]) as annot:
            native(r.FORM_SetFocusedAnnot(doc.formenv, annot), "focus field")
            if kind == "text":
                native(r.FORM_SelectAllText(doc.formenv, page), "select field text")
                r.FORM_ReplaceSelection(doc.formenv, page, wide(value))
            elif kind == "choice":
                native(r.FORM_SetIndexSelected(doc.formenv, page, value, True), "select dropdown option")
            elif bool(r.FPDFAnnot_IsChecked(doc.formenv, annot)) != value:
                rect = r.FS_RECTF()
                native(r.FPDFAnnot_GetRect(annot, rect), "read widget rectangle")
                x, y = (rect.left + rect.right) / 2, (rect.bottom + rect.top) / 2
                native(r.FORM_OnLButtonDown(doc.formenv, page, 0, x, y), "press widget")
                native(r.FORM_OnLButtonUp(doc.formenv, page, 0, x, y), "release widget")
            native(r.FORM_ForceToKillFocus(doc.formenv), "commit field focus")


def validate_annotation(spec):
    require(isinstance(spec, dict), "INVALID_ARGUMENT", "Annotation must be an object.")
    kind = spec.get("type")
    require(kind in ("highlight", "underline", "sticky_note"), "UNSUPPORTED_OPERATION", "Unsupported annotation type.")
    for name in ("contents", "author"):
        require(isinstance(spec.get(name), str) and "\0" not in spec[name], "INVALID_ARGUMENT", "Annotation text must be a string without NUL.")
    color = spec.get("color")
    require(isinstance(color, (list, tuple)) and len(color) == 4 and
            all(type(x) is int and 0 <= x <= 255 for x in color), "INVALID_ARGUMENT", "Color must be four RGBA bytes.")
    if kind == "sticky_note":
        rect = spec.get("rect")
        require(isinstance(rect, (list, tuple)) and len(rect) == 4 and finite(rect), "INVALID_ARGUMENT", "Invalid note rectangle.")
        require(rect[0] < rect[2] and rect[1] < rect[3], "INVALID_ARGUMENT", "Empty note rectangle.")
    else:
        quads = spec.get("quads")
        require(isinstance(quads, list) and len(quads) > 0, "INVALID_ARGUMENT", "Markup requires quads.")
        for quad in quads:
            require(isinstance(quad, dict), "INVALID_ARGUMENT", "Invalid quad.")
            for key in ("top_left", "top_right", "bottom_left", "bottom_right"):
                point = quad.get(key)
                require(isinstance(point, (list, tuple)) and len(point) == 2 and finite(point), "INVALID_ARGUMENT", "Invalid quad point.")


def finite(values):
    return all(type(x) in (int, float) and math.isfinite(x) for x in values)


def annotate(doc, page_index, spec):
    subtype = {"highlight": r.FPDF_ANNOT_HIGHLIGHT, "underline": r.FPDF_ANNOT_UNDERLINE,
               "sticky_note": r.FPDF_ANNOT_TEXT}[spec["type"]]
    with closing(doc[page_index]) as page:
        index = r.FPDFPage_GetAnnotCount(page)
        handle = r.FPDFPage_CreateAnnot(page, subtype)
        native(handle, "create annotation")
        try:
            quads = []
            if subtype == r.FPDF_ANNOT_TEXT:
                left, bottom, right, top = spec["rect"]
            else:
                quads = [[xy for key in ("top_left", "top_right", "bottom_left", "bottom_right")
                          for xy in q[key]] for q in spec["quads"]]
                xs = [v for q in quads for v in q[0::2]]
                ys = [v for q in quads for v in q[1::2]]
                left, bottom, right, top = min(xs), min(ys), max(xs), max(ys)
            native(r.FPDFAnnot_SetRect(handle, r.FS_RECTF(left, top, right, bottom)), "set annotation rectangle")
            native(r.FPDFAnnot_SetColor(handle, r.FPDFANNOT_COLORTYPE_Color, *spec["color"]), "set annotation color")
            for key, value in ((b"Contents", spec["contents"]), (b"T", spec["author"])):
                native(r.FPDFAnnot_SetStringValue(handle, key, wide(value)), "set annotation text")
            native(r.FPDFAnnot_SetFlags(handle, r.FPDF_ANNOT_FLAG_PRINT), "set annotation flags")
            for quad in quads:
                native(r.FPDFAnnot_AppendAttachmentPoints(handle, r.FS_QUADPOINTSF(*quad)), "set annotation quad")
        finally:
            r.FPDFPage_CloseAnnot(handle)
    return page_index, index


def save(doc, path):
    if doc.formenv:
        page_index, focused = c.c_int(-1), r.FPDF_ANNOTATION()
        native(r.FORM_GetFocusedAnnot(doc.formenv, page_index, focused), "inspect focused field")
        if focused:
            try:
                native(r.FORM_ForceToKillFocus(doc.formenv), "commit focus before serialization")
            finally:
                r.FPDFPage_CloseAnnot(focused)
    doc.save(path, flags=r.FPDF_NO_INCREMENTAL)


def render(doc, index, scale, clip):
    require(type(scale) in (int, float) and math.isfinite(scale) and 0 < scale <= 8,
            "INVALID_ARGUMENT", "Scale must be finite and within (0, 8].")
    with closing(doc[index]) as page:
        width, height = math.ceil(page.get_width() * scale), math.ceil(page.get_height() * scale)
        require(width * height <= 16_000_000, "INVALID_ARGUMENT", "Raster exceeds the v0 size limit.")
        with closing(page.render(scale=scale, draw_annots=True, force_bitmap_format=r.FPDFBitmap_BGRA,
                                 rev_byteorder=True)) as bitmap:
            conv = bitmap.get_posconv(page)
            origin, xaxis, yaxis = conv.to_page(0, 0), conv.to_page(1, 0), conv.to_page(0, 1)
            ux, uy = xaxis[0] - origin[0], xaxis[1] - origin[1]
            vx, vy = yaxis[0] - origin[0], yaxis[1] - origin[1]
            determinant = ux * vy - uy * vx
            a, c_, b, d = vy / determinant, -vx / determinant, -uy / determinant, ux / determinant
            e, f = -a * origin[0] - c_ * origin[1], -b * origin[0] - d * origin[1]
            left, top, right, bottom = 0, 0, bitmap.width, bitmap.height
            if clip is not None:
                require(isinstance(clip, (list, tuple)) and len(clip) == 4 and finite(clip)
                        and clip[0] < clip[2] and clip[1] < clip[3], "INVALID_ARGUMENT", "Invalid clip rectangle.")
                corners = [conv.to_bitmap(x, y) for x in (clip[0], clip[2]) for y in (clip[1], clip[3])]
                left, right = max(0, min(p[0] for p in corners)), min(bitmap.width, max(p[0] for p in corners))
                top, bottom = max(0, min(p[1] for p in corners)), min(bitmap.height, max(p[1] for p in corners))
                require(left < right and top < bottom, "INVALID_ARGUMENT", "Clip is outside the page.")
            buffer = bytes(bitmap.buffer)
            pixels = b"".join(buffer[y * bitmap.stride + left * 4:y * bitmap.stride + right * 4]
                              for y in range(top, bottom))
            return {"pixels": pixels, "format": "RGBA", "width": right-left, "height": bottom-top,
                    "stride": (right-left)*4, "page_to_pixel": [a, b, c_, d, e-left, f-top]}


def search(doc, query, case_sensitive, start, limit):
    hits = []
    for pi in range(start[0], len(doc)):
        with closing(doc[pi]) as page, closing(page.get_textpage()) as text:
            with closing(text.search(query, index=start[1] if pi == start[0] else 0,
                                     match_case=case_sensitive)) as finder:
                while True:
                    hit = finder.get_next()
                    if hit is None:
                        break
                    index, count = hit
                    rects = [list(text.get_rect(i)) for i in range(text.count_rects(index, count))]
                    hits.append({"page": pi, "start": index, "count": count, "rectangles": rects})
                    if len(hits) == limit:
                        return hits, (pi, index + max(count, 1))
    return hits, None
