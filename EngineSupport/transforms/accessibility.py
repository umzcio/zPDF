"""Accessibility: Full Check, fixes, automatic tagging and structure editing.

Queries
  accessibility_check      Acrobat "Full Check" equivalents (Document, Page
                           Content, Forms, Alternate Text, Tables, Lists,
                           Headings) with fix ids the app can run.
  structure_tree           The tag tree (StructTreeRoot) as JSON.
  reading_order            Content-owning elements of one page, in order.

Operations
  set_language, set_title, set_page_tab_order, set_field_tooltips,
  tag_annotations, autotag, edit_structure, set_alt_text,
  set_reading_order, mark_pdfua

Element ids: indirect struct elements are "o<objnum>_<gen>"; direct ones get
a path id "p<i>.<j>..." (K-array index path from the StructTreeRoot). Ids are
valid for the revision they were read from; every structural edit converts
direct elements to indirect ones and rebuilds the ParentTree from the tree,
so the tree stays the single source of truth.

Autotag (best effort, documented quality)
  Pass 1 rewrites each page's content so every text-showing operator, image,
  Form XObject and inline image is wrapped in its own marked-content sequence
  with a provisional MCID, and vector paths/shadings become /Artifact.
  Wrapping happens at single-operator granularity (BDC/EMC is legal inside
  BT...ET), so marked content never crosses q/Q or BT/ET. Existing MCID
  marked content is stripped (optional content /OC and other properties are
  preserved; content inside existing /Artifact sequences is left alone).
  PDFium then reports the geometry, text, font size and weight for each
  provisional MCID (robust: keyed by MCID, not by operator matching).
  Classification:
    * text units on the same line with small gaps merge into segments;
    * reading order is top-to-bottom per region; a two-column layout is
      detected when a vertical gutter near the middle separates two sides of
      wide prose segments (full-width items split the page into sections);
    * headings: font size >= 1.2x the document's body-text median (or bold
      and >= 1.1x); levels by size rank, clamped so nesting never skips;
    * lists: bullet or number/letter labels; a label that is its own text
      operator becomes Lbl, the rest LBody;
    * tables: >= 2 rows x >= 3 columns (or >= 3 rows x >= 2 columns) of short
      text cells whose left/centre/right edges align; first row is TH;
    * paragraphs: consecutive lines of similar size that overlap
      horizontally with at most ~1 line of vertical gap;
    * images (>= 16x16 pt) are Figure with a Layout BBox and no /Alt, so the
      checker asks for alternate text; tiny images, paths and shadings are
      artifacts; Form XObjects are one Figure (images only), one P (text)
      or an Artifact (vector only) — their inner content is not split.
  Known limits: text order inside a line follows the content stream; tables
  with merged cells, multi-line cells or no alignment are read as
  paragraphs; forms with aligned label/value rows may be read as tables;
  rotated text, vertical writing and complex multi-column magazines are read
  in approximate order; headers/footers are not recognized as artifacts.
"""
import ctypes
import re
import statistics

import pikepdf
from pikepdf import Array, Dictionary, Name, Operator

from engine.errors import EngineError, require
from transforms import op, query
from transforms.content import invert, transform_rect, visual_matrix

STANDARD_TYPES = {
    "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index",
    "NonStruct", "Private", "P", "H", "H1", "H2", "H3", "H4", "H5", "H6", "L", "LI", "Lbl",
    "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot", "Span", "Quote", "Note",
    "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT",
    "WP", "Figure", "Formula", "Form", "Document", "DocumentFragment", "Aside", "Title", "FENote",
    "Sub", "Em", "Strong", "Artifact",
}
HEADINGS = {"H1": 1, "H2": 2, "H3": 3, "H4": 4, "H5": 5, "H6": 6}
TEXT_SHOW = {"Tj", "TJ", "'", '"'}
PATH_START = {"m", "re"}
PATH_CONT = {"m", "re", "l", "c", "v", "y", "h", "W", "W*"}
PAINT = {"S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"}
MULTIMEDIA = {"/Screen", "/Movie", "/Sound", "/RichMedia", "/3D"}
LANG = re.compile(r"^(?:[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*|[xXiI]-[A-Za-z0-9]{1,8}(?:-[A-Za-z0-9]{1,8})*)$")
LABEL_ONLY = re.compile(r"^\s*(?:[•◦▪▫‣⁃●○■□–—\-\*·∙]"
                        r"|\(?\d{1,3}[.)]|\(?[a-zA-Z][.)]|\(?[ivxlcIVXLC]{1,5}[.)])\s*$")
LIST_START = re.compile(r"^\s*(?:[•◦▪▫‣⁃●○■□–—\*·∙]\s*"
                        r"|[-]\s+|\(?\d{1,3}[.)]\s+|\(?[a-z][.)]\s+|\([A-Za-z]\)\s+)\S")


def _name(value):
    return str(value)[1:] if isinstance(value, Name) else (str(value) if value is not None else "")


def _text(value):
    if value is None:
        return None
    try:
        return str(value)
    except Exception:  # pragma: no cover - undecodable strings
        return None


# ================================================================ structure

class _Node:
    __slots__ = ("id", "obj", "parent", "kids", "content", "path")

    def __init__(self, nid, obj, parent, path):
        self.id, self.obj, self.parent, self.path = nid, obj, parent, path
        self.kids, self.content = [], []


def _is_elem(item):
    return isinstance(item, Dictionary) and "/S" in item and \
        item.get("/Type") not in (Name.MCR, Name.OBJR)


def _items(obj):
    k = obj.get("/K")
    if k is None:
        return []
    return list(k) if isinstance(k, Array) else [k]


def _walk(pdf, materialize=False):
    """Returns (root node, element nodes in tree order). With `materialize`
    direct elements become indirect (ids keep their original path) and every
    element's /P is repaired to point at its actual parent."""
    root = pdf.Root.get("/StructTreeRoot")
    if not isinstance(root, Dictionary):
        return None, []
    rnode = _Node("root", root, None, ())
    nodes, seen = [], set()

    def visit(node, is_root, depth):
        require(depth < 400, "INVALID_STRUCTURE", "The tag tree is nested too deeply.")
        k = node.obj.get("/K")
        items = _items(node.obj)
        for i, item in enumerate(items):
            if _is_elem(item):
                if item.is_indirect:
                    if item.objgen in seen:
                        continue
                    seen.add(item.objgen)
                    nid = f"o{item.objgen[0]}_{item.objgen[1]}"
                else:
                    nid = "p" + ".".join(str(x) for x in node.path + (i,))
                    if materialize:
                        new = pdf.make_indirect(item)
                        if isinstance(k, Array):
                            node.obj.K[i] = new
                        else:
                            node.obj.K = new
                        item = new
                        seen.add(item.objgen)
                if materialize:
                    item.P = node.obj
                child = _Node(nid, item, node, node.path + (i,))
                node.kids.append(child)
                nodes.append(child)
                visit(child, False, depth + 1)
            elif is_root:
                continue
            elif isinstance(item, int) or (isinstance(item, pikepdf.Object) and not isinstance(item, Dictionary)
                                           and _is_int(item)):
                node.content.append({"kind": "mcid", "mcid": int(item), "page": node.obj.get("/Pg"), "stm": None})
            elif isinstance(item, Dictionary) and item.get("/Type") == Name.MCR and "/MCID" in item:
                node.content.append({"kind": "mcid", "mcid": int(item.MCID),
                                     "page": item.get("/Pg") or node.obj.get("/Pg"), "stm": item.get("/Stm")})
            elif isinstance(item, Dictionary) and item.get("/Type") == Name.OBJR and "/Obj" in item:
                node.content.append({"kind": "objr", "obj": item.Obj, "page": item.get("/Pg") or node.obj.get("/Pg")})

    visit(rnode, True, 0)
    return rnode, nodes


def _is_int(value):
    try:
        int(value)
        return True
    except (TypeError, ValueError):
        return False


def _role_resolver(pdf):
    root = pdf.Root.get("/StructTreeRoot")
    rolemap = root.get("/RoleMap") if isinstance(root, Dictionary) else None

    def resolve(obj):
        name = _name(obj.get("/S"))
        seen = set()
        while name not in STANDARD_TYPES and isinstance(rolemap, Dictionary) and name not in seen:
            seen.add(name)
            mapped = rolemap.get("/" + name)
            if not isinstance(mapped, Name):
                break
            name = _name(mapped)
        return name
    return resolve


def _page_map(pdf):
    return {page.obj.objgen: i for i, page in enumerate(pdf.pages)}


def _page_of(node, pages):
    pg = node.obj.get("/Pg")
    if isinstance(pg, Dictionary) and pg.is_indirect:
        return pages.get(pg.objgen)
    for c in node.content:
        if isinstance(c.get("page"), Dictionary) and c["page"].is_indirect:
            return pages.get(c["page"].objgen)
    return None


def _is_tagged(pdf):
    mark = pdf.Root.get("/MarkInfo")
    marked = isinstance(mark, Dictionary) and bool(mark.get("/Marked", False))
    return marked and isinstance(pdf.Root.get("/StructTreeRoot"), Dictionary)


def _ensure_root(pdf):
    root = pdf.Root.get("/StructTreeRoot")
    if not isinstance(root, Dictionary):
        root = pdf.make_indirect(Dictionary(Type=Name.StructTreeRoot, K=Array()))
        pdf.Root.StructTreeRoot = root
    return root


def _annotations(page):
    annots = page.obj.get("/Annots")
    return [a for a in annots if isinstance(a, Dictionary)] if isinstance(annots, Array) else []


def _rebuild_parent_tree(pdf):
    """Recompute every StructParent(s) key and the ParentTree from the tree."""
    _, nodes = _walk(pdf, materialize=True)
    root = pdf.Root.StructTreeRoot
    for page in pdf.pages:
        if "/StructParents" in page.obj:
            del page.obj.StructParents
        for annot in _annotations(page):
            if "/StructParent" in annot:
                del annot.StructParent
    page_arrays, stm_arrays, objrs = {}, {}, []
    for node in nodes:
        for c in node.content:
            if c["kind"] == "mcid":
                stm, page = c.get("stm"), c.get("page")
                if isinstance(stm, pikepdf.Stream) and stm.is_indirect:
                    stm_arrays.setdefault(stm.objgen, (stm, {}))[1].setdefault(c["mcid"], node.obj)
                elif isinstance(page, Dictionary) and page.is_indirect:
                    page_arrays.setdefault(page.objgen, (page, {}))[1].setdefault(c["mcid"], node.obj)
            elif isinstance(c["obj"], Dictionary) and c["obj"].is_indirect:
                objrs.append((c["obj"], node.obj))
    nums, key = [], 0
    for page in pdf.pages:
        entry = page_arrays.get(page.obj.objgen)
        if entry is None:
            continue
        mapping = entry[1]
        page.obj.StructParents = key
        nums += [key, pdf.make_indirect(Array([mapping.get(i) for i in range(max(mapping) + 1)]))]
        key += 1
    for stm, mapping in stm_arrays.values():
        stm.StructParents = key
        nums += [key, pdf.make_indirect(Array([mapping.get(i) for i in range(max(mapping) + 1)]))]
        key += 1
    done = set()
    for annot, elem in objrs:
        if annot.objgen in done:
            continue
        done.add(annot.objgen)
        annot.StructParent = key
        nums += [key, elem]
        key += 1
    root.ParentTree = pdf.make_indirect(Dictionary(Nums=Array(nums)))
    root.ParentTreeNextKey = key
    return key


def _document_element(pdf):
    root = _ensure_root(pdf)
    for item in _items(root):
        if _is_elem(item) and item.is_indirect:
            return item
    doc = pdf.make_indirect(Dictionary(Type=Name.StructElem, S=Name.Document, P=root, K=Array()))
    k = root.get("/K")
    if isinstance(k, Array):
        k.append(doc)
    elif k is None:
        root.K = Array([doc])
    else:
        root.K = Array([k, doc])
    return doc


def _append_kid(parent, kid):
    k = parent.get("/K")
    if isinstance(k, Array):
        k.append(kid)
    elif k is None:
        parent.K = Array([kid])
    else:
        parent.K = Array([k, kid])


# ================================================================ PDFium scan

def _pdfium_c():
    import pypdfium2.raw as c
    return c


def _mark_info(c, obj):
    mcid, artifact = None, False
    for i in range(max(0, c.FPDFPageObj_CountMarks(obj))):
        mark = c.FPDFPageObj_GetMark(obj, i)
        if not mark:
            continue
        out = ctypes.c_ulong(0)
        name = ""
        if c.FPDFPageObjMark_GetName(mark, None, 0, ctypes.byref(out)) and out.value:
            buf = ctypes.create_string_buffer(out.value)
            if c.FPDFPageObjMark_GetName(mark, ctypes.cast(buf, ctypes.POINTER(c.FPDF_WCHAR)), out.value, ctypes.byref(out)):
                name = buf.raw[:out.value].decode("utf-16-le", "ignore").rstrip("\x00")
        if name == "Artifact":
            artifact = True
        value = ctypes.c_int(0)
        if c.FPDFPageObjMark_GetParamIntValue(mark, b"MCID", ctypes.byref(value)):
            mcid = value.value
    return mcid, artifact


def _bounds(c, obj):
    l, b, r, t = ctypes.c_float(), ctypes.c_float(), ctypes.c_float(), ctypes.c_float()
    if not c.FPDFPageObj_GetBounds(obj, ctypes.byref(l), ctypes.byref(b), ctypes.byref(r), ctypes.byref(t)):
        return None
    return [l.value, b.value, r.value, t.value]


def _obj_text(c, obj, textpage):
    n = c.FPDFTextObj_GetText(obj, textpage, None, 0)
    if n <= 2:
        return ""
    buf = ctypes.create_string_buffer(n)
    c.FPDFTextObj_GetText(obj, textpage, ctypes.cast(buf, ctypes.POINTER(c.FPDF_WCHAR)), n)
    return buf.raw[:n].decode("utf-16-le", "ignore").rstrip("\x00")


def _font_info(c, obj):
    size = ctypes.c_float(0)
    c.FPDFTextObj_GetFontSize(obj, ctypes.byref(size))
    matrix = c.FS_MATRIX()
    scale = 1.0
    if c.FPDFPageObj_GetMatrix(obj, ctypes.byref(matrix)):
        scale = (matrix.c ** 2 + matrix.d ** 2) ** 0.5 or ((matrix.a ** 2 + matrix.b ** 2) ** 0.5) or 1.0
    bold = False
    font = c.FPDFTextObj_GetFont(obj)
    if font:
        n = c.FPDFFont_GetBaseFontName(font, None, 0)
        if n > 1:
            buf = ctypes.create_string_buffer(n)
            c.FPDFFont_GetBaseFontName(font, buf, n)
            fname = buf.value.decode("latin-1", "ignore")
            bold = bool(re.search(r"bold|black|heavy|semibold|demi", fname, re.I))
        weight = c.FPDFFont_GetWeight(font)
        if weight and weight >= 600:
            bold = True
    return abs(size.value * scale), bold


def _scan_page(c, page, collect=True):
    """Top-level page objects: per-MCID content plus tagging statistics."""
    textpage = page.get_textpage()
    by_mcid, untagged, images, chars = {}, 0, 0, 0
    try:
        chars = textpage.count_chars()
        raw_tp = textpage.raw

        def gather(obj, depth):
            kind = c.FPDFPageObj_GetType(obj)
            if kind == c.FPDF_PAGEOBJ_TEXT:
                return _obj_text(c, obj, raw_tp), kind
            if kind == c.FPDF_PAGEOBJ_FORM and depth < 4:
                parts = [gather(c.FPDFFormObj_GetObject(obj, i), depth + 1)[0]
                         for i in range(max(0, c.FPDFFormObj_CountObjects(obj)))]
                return "".join(parts), kind
            return "", kind

        for i in range(max(0, c.FPDFPage_CountObjects(page.raw))):
            obj = c.FPDFPage_GetObject(page.raw, i)
            kind = c.FPDFPageObj_GetType(obj)
            if kind == c.FPDF_PAGEOBJ_IMAGE:
                images += 1
            mcid, artifact = _mark_info(c, obj)
            if mcid is None and not artifact:
                untagged += 1
            if mcid is None or not collect:
                continue
            text, _ = gather(obj, 0)
            rect = _bounds(c, obj)
            entry = by_mcid.setdefault(mcid, {"text": "", "rect": None, "size": 0.0, "bold": True,
                                              "kinds": set(), "chars": 0})
            entry["text"] += text
            entry["kinds"].add(kind)
            if rect:
                old = entry["rect"]
                entry["rect"] = rect if old is None else [min(old[0], rect[0]), min(old[1], rect[1]),
                                                          max(old[2], rect[2]), max(old[3], rect[3])]
            if kind == c.FPDF_PAGEOBJ_TEXT:
                size, bold = _font_info(c, obj)
                if len(text.strip()):
                    entry["size"] = max(entry["size"], size)
                    entry["bold"] = entry["bold"] and bold
                    entry["chars"] += len(text.strip())
    finally:
        textpage.close()
    return by_mcid, untagged, images, chars


def _content_map(ctx):
    """{page index: {mcid: {"text", "rect"}}} for queries on the source."""
    import pypdfium2 as pdfium
    c = _pdfium_c()
    doc = pdfium.PdfDocument(str(ctx.source), password=ctx.password)
    result = {}
    try:
        for index in range(len(doc)):
            page = doc[index]
            try:
                result[index] = _scan_page(c, page)[0]
            finally:
                page.close()
    finally:
        doc.close()
    return result


# ================================================================ checker

def _item(items, cid, category, title, status, detail, fix=None, pages=None):
    items.append({"id": cid, "category": category, "title": title, "status": status,
                  "detail": detail, "fix": fix if status == "failed" else None, "pages": sorted(set(pages or []))})


def _has_javascript(pdf):
    names = pdf.Root.get("/Names")
    if isinstance(names, Dictionary) and "/JavaScript" in names:
        return True
    action = pdf.Root.get("/OpenAction")
    if isinstance(action, Dictionary) and action.get("/S") == Name.JavaScript:
        return True
    if isinstance(pdf.Root.get("/AA"), Dictionary):
        return True
    for page in pdf.pages:
        if isinstance(page.obj.get("/AA"), Dictionary):
            return True
        for annot in _annotations(page):
            a = annot.get("/A")
            if isinstance(a, Dictionary) and a.get("/S") == Name.JavaScript:
                return True
            aa = annot.get("/AA")
            if isinstance(aa, Dictionary):
                for key in aa.keys():
                    act = aa[key]
                    if isinstance(act, Dictionary) and act.get("/S") == Name.JavaScript:
                        return True
    return False


def _title(pdf):
    title = _text(pdf.docinfo.get("/Title")) if pdf.docinfo is not None else None
    if title and title.strip():
        return title.strip()
    try:
        meta = pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=False)
        value = meta.get("dc:title")
        if value and str(value).strip():
            return str(value).strip()
    except Exception:
        pass
    return None


def _display_doc_title(pdf):
    prefs = pdf.Root.get("/ViewerPreferences")
    return isinstance(prefs, Dictionary) and bool(prefs.get("/DisplayDocTitle", False))


def _outline_count(pdf):
    outlines = pdf.Root.get("/Outlines")
    return 1 if isinstance(outlines, Dictionary) and isinstance(outlines.get("/First"), Dictionary) else 0


def _font_ok(font):
    if not isinstance(font, Dictionary):
        return True
    if "/ToUnicode" in font:
        return True
    subtype = font.get("/Subtype")
    encoding = font.get("/Encoding")
    if subtype == Name.Type0:
        descendants = font.get("/DescendantFonts")
        info = descendants[0].get("/CIDSystemInfo") \
            if isinstance(descendants, Array) and len(descendants) and isinstance(descendants[0], Dictionary) else None
        ordering = _text(info.get("/Ordering")) if isinstance(info, Dictionary) else ""
        return isinstance(encoding, Name) and not _name(encoding).startswith("Identity") and \
            ordering in ("Japan1", "GB1", "CNS1", "Korea1")
    if subtype == Name.Type3:
        return False
    if isinstance(encoding, Name):
        return _name(encoding) in ("WinAnsiEncoding", "MacRomanEncoding", "StandardEncoding", "PDFDocEncoding",
                                   "MacExpertEncoding")
    if isinstance(encoding, Dictionary):
        return True
    base = _name(font.get("/BaseFont"))
    base = base.split("+", 1)[-1]
    standard = ("Times", "Helvetica", "Courier", "Symbol", "ZapfDingbats", "Arial")
    if subtype == Name.Type1 and base.startswith(standard):
        return True
    descriptor = font.get("/FontDescriptor")
    flags = int(descriptor.get("/Flags", 0)) if isinstance(descriptor, Dictionary) else 0
    return not flags & 4  # non-symbolic simple fonts use StandardEncoding


def _resources(obj):
    node = obj
    for _ in range(64):
        res = node.get("/Resources")
        if isinstance(res, Dictionary):
            return res
        parent = node.get("/Parent")
        if not isinstance(parent, Dictionary):
            return None
        node = parent
    return None


def _page_fonts(page):
    fonts, seen = [], set()

    def visit(res, depth):
        if not isinstance(res, Dictionary) or depth > 3:
            return
        group = res.get("/Font")
        if isinstance(group, Dictionary):
            for key in group.keys():
                f = group[key]
                ident = f.objgen if f.is_indirect else id(f)
                if ident not in seen:
                    seen.add(ident)
                    fonts.append(f)
        xobjects = res.get("/XObject")
        if isinstance(xobjects, Dictionary):
            for key in xobjects.keys():
                x = xobjects[key]
                if isinstance(x, pikepdf.Stream) and x.get("/Subtype") == Name.Form and \
                        (not x.is_indirect or x.objgen not in seen):
                    if x.is_indirect:
                        seen.add(x.objgen)
                    visit(x.get("/Resources"), depth + 1)

    visit(_resources(page.obj), 0)
    return fonts


def _fields(pdf):
    """Terminal AcroForm fields as (field dict, full name, widgets)."""
    acro = pdf.Root.get("/AcroForm")
    out = []
    if not isinstance(acro, Dictionary) or not isinstance(acro.get("/Fields"), Array):
        return out
    seen = set()

    def visit(field, prefix, depth):
        if not isinstance(field, Dictionary) or depth > 32:
            return
        if field.is_indirect:
            if field.objgen in seen:
                return
            seen.add(field.objgen)
        partial = _text(field.get("/T"))
        name = ".".join(x for x in (prefix, partial) if x) if partial else prefix
        kids = field.get("/Kids")
        field_kids = [k for k in kids if isinstance(k, Dictionary) and "/T" in k] if isinstance(kids, Array) else []
        if field_kids:
            for kid in field_kids:
                visit(kid, name, depth + 1)
            return
        widgets = [k for k in kids if isinstance(k, Dictionary)] if isinstance(kids, Array) else [field]
        out.append((field, name or "", widgets))

    for field in acro.Fields:
        visit(field, "", 0)
    return out


def _humanize(name):
    name = re.sub(r"\[\d+\]", "", name or "")
    words = []
    for part in re.split(r"[_\-.\s]+", name):
        words += re.findall(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+", part)
    if not words:
        return ""
    text = " ".join(w if (w.isupper() and len(w) > 1) else w.lower() for w in words)
    return text[0].upper() + text[1:]


@query("accessibility_check")
def accessibility_check(ctx):
    import pypdfium2 as pdfium
    pdf = ctx.pdf
    items = []
    pages = _page_map(pdf)
    tagged = _is_tagged(pdf)
    count = len(pdf.pages)
    has_js = _has_javascript(pdf)
    annots = [(i, a) for i, page in enumerate(pdf.pages) for a in _annotations(page)]
    real_annots = [(i, a) for i, a in annots if a.get("/Subtype") != Name.Popup]
    widgets = [(i, a) for i, a in real_annots if a.get("/Subtype") == Name.Widget]
    links = [(i, a) for i, a in real_annots if a.get("/Subtype") == Name.Link]
    media = [(i, a) for i, a in real_annots if str(a.get("/Subtype")) in MULTIMEDIA]

    # PDFium scan: text, images and marked-content coverage per page.
    c = _pdfium_c()
    image_only, untagged_pages = [], []
    doc = pdfium.PdfDocument(str(ctx.source), password=ctx.password)
    try:
        for index in range(len(doc)):
            page = doc[index]
            try:
                _, untagged, images, chars = _scan_page(c, page, collect=False)
            finally:
                page.close()
            if chars == 0 and images:
                image_only.append(index)
            if untagged:
                untagged_pages.append(index)
    finally:
        doc.close()

    # ----- Document
    allowed = True
    if pdf.is_encrypted:
        try:
            allowed = bool(pdf.allow.accessibility)
        except Exception:
            allowed = True
    _item(items, "accessibility_permission", "Document", "Accessibility permission flag",
          "passed" if allowed else "failed",
          "Assistive technology may read this document." if allowed
          else "The security settings block content extraction for accessibility.")
    _item(items, "image_only", "Document", "Image-only PDF", "failed" if image_only else "passed",
          f"{len(image_only)} page(s) contain images but no text; run text recognition (OCR)." if image_only
          else "Every page with images also contains text.", None, image_only)
    _item(items, "tagged_pdf", "Document", "Tagged PDF", "passed" if tagged else "failed",
          "The document is tagged (MarkInfo and a structure tree)." if tagged
          else "The document has no tag structure for assistive technology.", "autotag")
    _item(items, "logical_reading_order", "Document", "Logical Reading Order", "manual",
          "Verify the reading order in the Reading Order tool or Tags panel.")
    lang = _text(pdf.Root.get("/Lang"))
    _item(items, "primary_language", "Document", "Primary language", "passed" if lang and lang.strip() else "failed",
          f"Document language is {lang}." if lang and lang.strip() else "No document language is set.", "set_language")
    title, display = _title(pdf), _display_doc_title(pdf)
    ok = bool(title) and display
    _item(items, "title", "Document", "Title", "passed" if ok else "failed",
          f"Title “{title}” is shown in the title bar." if ok
          else ("The title bar shows the file name instead of the title." if title else "The document has no title."),
          "set_title")
    needs = count > 20
    has_outline = _outline_count(pdf) > 0
    _item(items, "bookmarks", "Document", "Bookmarks", "failed" if needs and not has_outline else "passed",
          "Documents longer than 20 pages need bookmarks." if needs and not has_outline
          else ("Bookmarks are present." if has_outline else "Bookmarks are not required for 20 pages or fewer."),
          "bookmarks")
    _item(items, "color_contrast", "Document", "Color contrast", "manual",
          "Verify that text has enough contrast against its background (4.5:1 for body text).")

    # ----- Page content
    if not tagged:
        _item(items, "tagged_content", "Page Content", "Tagged content", "failed",
              "Page content is not tagged.", "autotag", list(range(count)))
    else:
        _item(items, "tagged_content", "Page Content", "Tagged content", "failed" if untagged_pages else "passed",
              f"{len(untagged_pages)} page(s) have content that is neither tagged nor an artifact." if untagged_pages
              else "All page content is tagged or marked as an artifact.", "autotag", untagged_pages)
    missing = [i for i, a in real_annots if "/StructParent" not in a]
    _item(items, "tagged_annotations", "Page Content", "Tagged annotations", "failed" if missing else "passed",
          f"{len(missing)} annotation(s) are not tagged." if missing else "All annotations are tagged.",
          "tag_annotations" if tagged else "autotag", missing)
    tab_pages = sorted({i for i, _ in real_annots if pdf.pages[i].obj.get("/Tabs") != Name.S})
    _item(items, "tab_order", "Page Content", "Tab order", "failed" if tab_pages else "passed",
          f"{len(tab_pages)} page(s) with annotations do not use structure tab order." if tab_pages
          else "Pages with annotations use structure tab order.", "set_page_tab_order", tab_pages)
    bad_fonts = [i for i, page in enumerate(pdf.pages) if not all(_font_ok(f) for f in _page_fonts(page))]
    _item(items, "character_encoding", "Page Content", "Character encoding", "failed" if bad_fonts else "passed",
          f"{len(bad_fonts)} page(s) use fonts without a reliable Unicode mapping." if bad_fonts
          else "Fonts map to Unicode.", None, bad_fonts)
    untagged_media = [i for i, a in media if "/StructParent" not in a]
    _item(items, "tagged_multimedia", "Page Content", "Tagged multimedia", "failed" if untagged_media else "passed",
          f"{len(untagged_media)} multimedia object(s) are not tagged." if untagged_media
          else ("Multimedia is tagged." if media else "No multimedia."), "tag_annotations" if tagged else "autotag",
          untagged_media)
    dynamic = has_js or bool(media)
    _item(items, "screen_flicker", "Page Content", "Screen flicker", "manual" if dynamic else "passed",
          "Verify scripts and multimedia do not cause flicker." if dynamic else "No scripts or multimedia.")
    _item(items, "scripts", "Page Content", "Scripts", "manual" if has_js else "passed",
          "Verify scripts are accessible and do not interfere with keyboard navigation." if has_js
          else "No JavaScript.")
    _item(items, "timed_responses", "Page Content", "Timed responses", "manual" if has_js else "passed",
          "Verify the document does not require timed responses." if has_js else "No scripts that could time out.")
    _item(items, "navigation_links", "Page Content", "Navigation links", "manual" if links else "passed",
          "Verify link text describes each destination." if links else "No links.", None, [i for i, _ in links])

    # ----- Tree based checks
    resolve = _role_resolver(pdf)
    _, nodes = _walk(pdf) if tagged else (None, [])
    roles = {n.id: resolve(n.obj) for n in nodes}

    # ----- Forms
    form_objrs = set()
    for n in nodes:
        for cont in n.content:
            if cont["kind"] == "objr" and roles[n.id] == "Form" and cont["obj"].is_indirect:
                form_objrs.add(cont["obj"].objgen)
    untagged_widgets = [i for i, w in widgets if not (w.is_indirect and w.objgen in form_objrs)]
    _item(items, "tagged_form_fields", "Forms", "Tagged form fields", "failed" if untagged_widgets else "passed",
          f"{len(untagged_widgets)} form field widget(s) are not tagged as Form elements." if untagged_widgets
          else ("Form fields are tagged." if widgets else "No form fields."),
          "tag_annotations" if tagged else "autotag", untagged_widgets)
    no_tu = []
    for field, _, fwidgets in _fields(pdf):
        if not _text(field.get("/TU")):
            for w in fwidgets:
                p = w.get("/P")
                no_tu.append(pages.get(p.objgen, 0) if isinstance(p, Dictionary) and p.is_indirect else 0)
            if not fwidgets:
                no_tu.append(0)
    _item(items, "field_descriptions", "Forms", "Field descriptions", "failed" if no_tu else "passed",
          f"{len(no_tu)} form field(s) have no tooltip (description)." if no_tu
          else "Every form field has a description.", "field_tooltips", no_tu)

    def tree_item(cid, category, title, failures, ok_detail, bad_detail, applies=True, fix=None):
        if not tagged or not applies:
            _item(items, cid, category, title, "skipped",
                  "The document is not tagged." if not tagged else ok_detail)
            return
        _item(items, cid, category, title, "failed" if failures else "passed",
              bad_detail.format(n=len(failures)) if failures else ok_detail, fix,
              [p for p in (_page_of(n, pages) for n in failures) if p is not None])

    def has_alt(n):
        return bool(_text(n.obj.get("/Alt")) or _text(n.obj.get("/ActualText")))

    def descendants(n):
        stack, out = list(n.kids), []
        while stack:
            d = stack.pop()
            out.append(d)
            stack.extend(d.kids)
        return out

    figures = [n for n in nodes if roles[n.id] == "Figure"]
    tree_item("figures_alt_text", "Alternate Text", "Figures alternate text", [n for n in figures if not has_alt(n)],
              "Figures have alternate text." if figures else "No figures.",
              "{n} figure(s) have no alternate text.")
    alt_nodes = [n for n in nodes if _text(n.obj.get("/Alt"))]
    tree_item("nested_alt_text", "Alternate Text", "Nested alternate text",
              [n for n in alt_nodes if any(_text(d.obj.get("/Alt")) for d in descendants(n))],
              "No alternate text is hidden by a parent's alternate text.",
              "{n} element(s) contain nested alternate text that will never be read.")
    tree_item("alt_associated_with_content", "Alternate Text", "Associated with content",
              [n for n in alt_nodes if not n.content and not any(d.content for d in descendants(n))],
              "Alternate text is associated with content.", "{n} element(s) have alternate text but no content.")
    tree_item("alt_hides_annotation", "Alternate Text", "Hides annotation",
              [n for n in alt_nodes if any(cn["kind"] == "objr" for d in [n] + descendants(n) for cn in d.content)],
              "Alternate text does not hide annotations.", "{n} element(s) hide annotations with alternate text.")
    formulas = [n for n in nodes if roles[n.id] == "Formula"]
    tree_item("other_elements_alt_text", "Alternate Text", "Other elements alternate text",
              [n for n in formulas if not has_alt(n)],
              "Other elements that need alternate text have it.", "{n} formula element(s) have no alternate text.")

    tables = [n for n in nodes if roles[n.id] == "Table"]

    def rows_of(t):
        rows, bad = [], []
        for kid in t.kids:
            r = roles[kid.id]
            if r == "TR":
                rows.append(kid)
            elif r in ("THead", "TBody", "TFoot"):
                for g in kid.kids:
                    (rows if roles[g.id] == "TR" else bad).append(g)
            elif r != "Caption":
                bad.append(kid)
        return rows, bad

    def span(cell):
        attrs = cell.obj.get("/A")
        for a in (list(attrs) if isinstance(attrs, Array) else [attrs]):
            if isinstance(a, Dictionary) and "/ColSpan" in a:
                return max(1, int(a.ColSpan))
        return 1

    applies = bool(tables)
    tree_item("table_rows", "Tables", "Rows", [t for t in tables if rows_of(t)[1] or not rows_of(t)[0]],
              "Table rows are children of Table, THead, TBody or TFoot." if tables else "No tables.",
              "{n} table(s) have children that are not rows.", applies)
    tree_item("table_th_td", "Tables", "TH and TD",
              [t for t in tables if any(roles[cell.id] not in ("TH", "TD") for r in rows_of(t)[0] for cell in r.kids)],
              "Table cells are TH or TD." if tables else "No tables.", "{n} table(s) have rows with non-cell children.",
              applies)
    tree_item("table_headers", "Tables", "Headers",
              [t for t in tables if not any(roles[cell.id] == "TH" for r in rows_of(t)[0] for cell in r.kids)],
              "Tables have header cells." if tables else "No tables.", "{n} table(s) have no header cells.", applies)
    tree_item("table_regularity", "Tables", "Regularity",
              [t for t in tables if len({sum(span(cell) for cell in r.kids) for r in rows_of(t)[0]}) > 1],
              "Every table row has the same number of columns." if tables else "No tables.",
              "{n} table(s) have rows with different numbers of columns.", applies)

    def summary(t):
        if _text(t.obj.get("/Alt")):
            return True
        attrs = t.obj.get("/A")
        return any(isinstance(a, Dictionary) and _text(a.get("/Summary")) for a in
                   (list(attrs) if isinstance(attrs, Array) else [attrs]))
    tree_item("table_summary", "Tables", "Summary", [t for t in tables if not summary(t)],
              "Tables have a summary." if tables else "No tables.", "{n} table(s) have no summary.", applies)

    lists = [n for n in nodes if roles[n.id] == "L"]
    tree_item("list_items", "Lists", "List items",
              [n for n in lists if any(roles[k.id] not in ("LI", "L", "Caption") for k in n.kids)],
              "List children are LI elements." if lists else "No lists.", "{n} list(s) have children that are not LI.",
              bool(lists))
    lis = [n for n in nodes if roles[n.id] == "LI"]
    tree_item("lbl_lbody", "Lists", "Lbl and LBody",
              [n for n in lis if any(roles[k.id] not in ("Lbl", "LBody") for k in n.kids) or n.content],
              "List items contain Lbl and LBody." if lis else "No list items.",
              "{n} list item(s) contain elements other than Lbl and LBody.", bool(lis))
    headings = [n for n in nodes if roles[n.id] in HEADINGS]
    bad, previous = [], 0
    for n in headings:
        level = HEADINGS[roles[n.id]]
        if level > previous + 1:
            bad.append(n)
        previous = level
    tree_item("heading_nesting", "Headings", "Appropriate nesting", bad,
              "Headings are nested appropriately." if headings else "No numbered headings.",
              "{n} heading(s) skip a level.", bool(headings))

    counts = {"passed": 0, "failed": 0, "manual": 0, "skipped": 0}
    for entry in items:
        counts[entry["status"]] += 1
    claimed = False
    try:
        claimed = str(pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=False)
                      .get("pdfuaid:part") or "").strip() != ""
    except Exception:
        pass
    return {"tagged": tagged, "pdfua": {"claimed": claimed}, "summary": counts, "items": items,
            "page_count": count}


# ================================================================ simple fixes

@op("set_language")
def set_language(ctx, lang):
    require(isinstance(lang, str) and LANG.match(lang.strip() or "-"), "INVALID_ARGUMENT",
            "Enter a language tag such as en-US.")
    ctx.pdf.Root.Lang = pikepdf.String(lang.strip())
    return {"lang": lang.strip()}


def _set_display_doc_title(pdf, value=True):
    prefs = pdf.Root.get("/ViewerPreferences")
    if not isinstance(prefs, Dictionary):
        prefs = Dictionary()
        pdf.Root.ViewerPreferences = prefs
    prefs.DisplayDocTitle = bool(value)


@op("set_title")
def set_title(ctx, title, display_doc_title=True):
    require(isinstance(title, str) and title.strip(), "INVALID_ARGUMENT", "Enter a document title.")
    title = title.strip()
    pdf = ctx.pdf
    with pdf.open_metadata(set_pikepdf_as_editor=False) as meta:
        meta["dc:title"] = title
    pdf.docinfo["/Title"] = pikepdf.String(title)
    if display_doc_title:
        _set_display_doc_title(pdf, True)
    return {"title": title}


@op("set_page_tab_order")
def set_page_tab_order(ctx, order="S", pages=None):
    require(order in ("S", "R", "C"), "INVALID_ARGUMENT", "Tab order must be S, R or C.")
    indexes = _page_indexes(ctx.pdf, pages)
    for i in indexes:
        ctx.pdf.pages[i].obj.Tabs = Name("/" + order)
    return {"pages": len(indexes)}


def _page_indexes(pdf, pages):
    count = len(pdf.pages)
    if pages is None:
        return list(range(count))
    require(isinstance(pages, list) and all(isinstance(p, int) and 0 <= p < count for p in pages),
            "INVALID_PAGE_RANGE", "Choose pages within this document.")
    return sorted(set(pages))


@op("set_field_tooltips")
def set_field_tooltips(ctx, overwrite=False):
    updated = 0
    for field, full, _ in _fields(ctx.pdf):
        if _text(field.get("/TU")) and not overwrite:
            continue
        label = _humanize(_text(field.get("/T")) or "") or _humanize(full)
        if not label:
            continue
        field.TU = pikepdf.String(label)
        updated += 1
    return {"updated": updated}


def _tag_annotations(pdf, parent=None, pages=None):
    parent = parent if parent is not None else _document_element(pdf)
    tagged = 0
    for index, page in enumerate(pdf.pages):
        if pages is not None and index not in pages:
            continue
        annots = [a for a in _annotations(page)
                  if a.get("/Subtype") != Name.Popup and "/StructParent" not in a and a.is_indirect]

        def top(a):
            rect = a.get("/Rect")
            try:
                return -max(float(rect[1]), float(rect[3]))
            except Exception:
                return 0.0
        for annot in sorted(annots, key=top):
            subtype = annot.get("/Subtype")
            s = "Form" if subtype == Name.Widget else ("Link" if subtype == Name.Link else "Annot")
            elem = pdf.make_indirect(Dictionary(
                Type=Name.StructElem, S=Name("/" + s), P=parent, Pg=page.obj,
                K=Array([Dictionary(Type=Name.OBJR, Obj=annot, Pg=page.obj)])))
            contents = _text(annot.get("/Contents")) or _text(annot.get("/TU"))
            if s in ("Link", "Annot") and contents:
                elem.Alt = pikepdf.String(contents)
            _append_kid(parent, elem)
            annot.StructParent = -1  # placeholder; real key assigned by the ParentTree rebuild
            tagged += 1
    return tagged


@op("tag_annotations")
def tag_annotations(ctx):
    require(_is_tagged(ctx.pdf), "NOT_TAGGED", "Tag the document before tagging annotations.")
    count = _tag_annotations(ctx.pdf)
    _rebuild_parent_tree(ctx.pdf)
    return {"tagged": count}


@op("mark_pdfua")
def mark_pdfua(ctx, enabled=True):
    pdf = ctx.pdf
    if enabled:
        require(_is_tagged(pdf), "NOT_TAGGED", "PDF/UA requires a tagged document. Autotag it first.")
    with pdf.open_metadata(set_pikepdf_as_editor=False) as meta:
        if enabled:
            meta["pdfuaid:part"] = "1"
        elif "pdfuaid:part" in meta:
            del meta["pdfuaid:part"]
    if enabled:
        pdf.Root.MarkInfo = Dictionary(Marked=True) if not isinstance(pdf.Root.get("/MarkInfo"), Dictionary) \
            else pdf.Root.MarkInfo
        pdf.Root.MarkInfo.Marked = True
        _set_display_doc_title(pdf, True)
    return {"pdfua": bool(enabled)}


# ================================================================ autotag: pass 1

def _instr(operands, operator):
    return pikepdf.ContentStreamInstruction(operands, Operator(operator))


def _xobject_kind(res, name, depth=0):
    xobjects = res.get("/XObject") if isinstance(res, Dictionary) else None
    x = xobjects.get(str(name)) if isinstance(xobjects, Dictionary) else None
    if not isinstance(x, pikepdf.Stream):
        return "unknown"
    subtype = x.get("/Subtype")
    if subtype == Name.Image:
        return "image"
    if subtype != Name.Form or depth > 3:
        return "form_art"
    text = image = False
    try:
        for ins in pikepdf.parse_content_stream(x):
            if isinstance(ins, pikepdf.ContentStreamInlineImage):
                image = True
                continue
            o = str(ins.operator)
            if o in TEXT_SHOW:
                text = True
            elif o == "Do" and ins.operands:
                kind = _xobject_kind(x.get("/Resources") or res, ins.operands[0], depth + 1)
                text = text or kind == "form_text"
                image = image or kind in ("image", "form_image")
    except pikepdf.PdfError:
        return "form_text"
    return "form_text" if text else ("form_image" if image else "form_art")


def _mcid_props(operand, props):
    if isinstance(operand, Dictionary):
        return "/MCID" in operand
    if isinstance(operand, Name) and isinstance(props, Dictionary):
        entry = props.get(str(operand))
        return isinstance(entry, Dictionary) and "/MCID" in entry
    return False


def _wrap_content(instructions, res):
    """Pass 1: every content item in its own provisional marked content."""
    props = res.get("/Properties") if isinstance(res, Dictionary) else None
    out, kinds, where = [], {}, {}
    stack, artifact_depth, in_bt = [], 0, False
    path = None
    counter = [0]

    def wrap(items, kind, tag):
        n = counter[0]
        counter[0] += 1
        kinds[n] = kind
        where[n] = len(out)
        out.append(_instr([Name("/" + tag), Dictionary(MCID=n)], "BDC"))
        out.extend(items)
        out.append(_instr([], "EMC"))

    def artifact(items):
        out.append(_instr([Name.Artifact], "BMC"))
        out.extend(items)
        out.append(_instr([], "EMC"))

    for ins in instructions:
        if isinstance(ins, pikepdf.ContentStreamInlineImage):
            if path is not None:
                out.extend(path)
                path = None
            (out.append(ins) if artifact_depth else wrap([ins], "image", "Figure"))
            continue
        o = str(ins.operator)
        if path is not None:
            if o in PATH_CONT:
                path.append(ins)
                continue
            if o in PAINT:
                path.append(ins)
                artifact(path)
                path = None
                continue
            out.extend(path)  # malformed path: leave as authored
            path = None
        if o in PATH_START and not artifact_depth:
            path = [ins]
            continue
        if o in ("BDC", "BMC"):
            tag = ins.operands[0] if ins.operands else None
            if o == "BDC" and len(ins.operands) > 1 and _mcid_props(ins.operands[1], props):
                stack.append("strip")
                continue
            is_artifact = tag == Name.Artifact
            stack.append("artifact" if is_artifact else "keep")
            artifact_depth += is_artifact
            out.append(ins)
            continue
        if o == "EMC":
            if not stack:
                out.append(ins)
                continue
            kind = stack.pop()
            if kind == "strip":
                continue
            if kind == "artifact":
                artifact_depth -= 1
            out.append(ins)
            continue
        if o == "BT":
            in_bt = True
        elif o == "ET":
            in_bt = False
        if artifact_depth:
            out.append(ins)
            continue
        if o in TEXT_SHOW:
            wrap([ins], "text", "Span")
        elif o == "Do" and ins.operands:
            kind = _xobject_kind(res, ins.operands[0])
            if kind == "image":
                wrap([ins], "image", "Figure")
            elif kind == "form_image":
                wrap([ins], "form_image", "Figure")
            elif kind in ("form_text", "unknown"):
                wrap([ins], "form_text", "P")
            else:
                artifact([ins])
        elif o == "sh":
            artifact([ins])
        else:
            out.append(ins)
    if path is not None:
        out.extend(path)
    # Unterminated stripped sequences are simply dropped; unmatched kept ones
    # were authored that way and are left untouched.
    return out, kinds, where


def _strip_form_mcids(pdf):
    """Replace mode: remove MCID marked content inside Form XObjects that
    belonged to the old structure tree (those with /StructParents)."""
    seen = set()
    for page in pdf.pages:
        res = _resources(page.obj)
        xobjects = res.get("/XObject") if isinstance(res, Dictionary) else None
        if not isinstance(xobjects, Dictionary):
            continue
        for key in xobjects.keys():
            x = xobjects[key]
            if not isinstance(x, pikepdf.Stream) or "/StructParents" not in x or \
                    (x.is_indirect and x.objgen in seen):
                continue
            if x.is_indirect:
                seen.add(x.objgen)
            props = (x.get("/Resources") or Dictionary()).get("/Properties")
            out, stack = [], []
            for ins in pikepdf.parse_content_stream(x):
                if not isinstance(ins, pikepdf.ContentStreamInlineImage):
                    o = str(ins.operator)
                    if o in ("BDC", "BMC"):
                        strip = o == "BDC" and len(ins.operands) > 1 and _mcid_props(ins.operands[1], props)
                        stack.append(strip)
                        if strip:
                            continue
                    elif o == "EMC" and stack:
                        if stack.pop():
                            continue
                out.append(ins)
            x.write(pikepdf.unparse_content_stream(out))
            del x.StructParents


# ================================================================ autotag: classification

class _Unit:
    __slots__ = ("mcid", "kind", "text", "rect", "vrect", "size", "bold")

    def __init__(self, mcid, kind, text, rect, vrect, size, bold):
        self.mcid, self.kind, self.text, self.rect = mcid, kind, text, rect
        self.vrect, self.size, self.bold = vrect, size, bold


class _Seg:
    """A run of units on one line (or a single figure)."""

    def __init__(self, unit, figure=False):
        self.units = [unit]
        self.figure = figure
        self.l, self.b, self.r, self.t = unit.vrect
        self.size = unit.size
        self.bold = unit.bold
        self.text = unit.text

    def add(self, unit):
        gap = unit.vrect[0] - self.r
        self.text += (" " if gap > 0.15 * self.size and not self.text.endswith(" ") else "") + unit.text
        self.units.append(unit)
        self.l, self.b = min(self.l, unit.vrect[0]), min(self.b, unit.vrect[1])
        self.r, self.t = max(self.r, unit.vrect[2]), max(self.t, unit.vrect[3])
        self.size = max(self.size, unit.size)
        self.bold = self.bold and unit.bold

    @property
    def mcids(self):
        return [u.mcid for u in self.units]

    @property
    def height(self):
        return max(0.1, self.t - self.b)


def _overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def _segments(units):
    segs, cur = [], None
    for u in units:
        if u.kind in ("image", "form_image"):
            segs.append(_Seg(u, figure=True))
            cur = None
            continue
        if cur is not None and not cur.figure:
            size = max(cur.size, u.size, 1.0)
            same_line = _overlap(cur.b, cur.t, u.vrect[1], u.vrect[3]) >= \
                0.5 * min(cur.height, max(0.1, u.vrect[3] - u.vrect[1]))
            similar = 0.75 <= (u.size or size) / (cur.size or size) <= 1.33
            gap = u.vrect[0] - cur.r
            if same_line and similar and -0.3 * size <= gap <= 1.0 * size:
                cur.add(u)
                continue
        cur = _Seg(u)
        segs.append(cur)
    return segs


def _rows(items):
    rows = []
    for item in sorted(items, key=lambda s: (-s.t, s.l)):
        for row in rows:
            first = row[0]
            if not item.figure and not first.figure and \
                    _overlap(first.b, first.t, item.b, item.t) >= 0.5 * min(first.height, item.height):
                row.append(item)
                break
        else:
            rows.append([item])
    for row in rows:
        row.sort(key=lambda s: s.l)
    rows.sort(key=lambda r: -max(s.t for s in r))
    return rows


def _regions(segs, width):
    """Rows of the page in reading order, grouped by region (column)."""
    text = [s for s in segs if not s.figure]
    gutter = None
    for frac in [i / 40 for i in range(12, 29)]:
        x = width * frac
        left = [s for s in text if s.r <= x]
        right = [s for s in text if s.l >= x]
        crossing = [s for s in text if s.l < x < s.r and (s.r - s.l) <= 0.6 * width]
        if crossing or len(left) < 5 or len(right) < 5:
            continue
        if statistics.median(s.r - s.l for s in left) >= 0.25 * width and \
                statistics.median(s.r - s.l for s in right) >= 0.25 * width:
            gutter = x
            break
    if gutter is None:
        return [_rows(segs)]
    spanning = sorted([s for s in segs if s.l < gutter < s.r], key=lambda s: -(s.t + s.b))
    rest = [s for s in segs if not (s.l < gutter < s.r)]
    centers = [(sp.t + sp.b) / 2 for sp in spanning]
    regions = []
    for k in range(len(spanning) + 1):
        upper = centers[k - 1] if k > 0 else float("inf")
        lower = centers[k] if k < len(spanning) else -float("inf")
        band = [s for s in rest if lower < (s.t + s.b) / 2 <= upper]
        left = [s for s in band if (s.l + s.r) / 2 < gutter]
        right = [s for s in band if (s.l + s.r) / 2 >= gutter]
        if left:
            regions.append(_rows(left))
        if right:
            regions.append(_rows(right))
        if k < len(spanning):
            regions.append([[spanning[k]]])
    return regions


def _aligned(a, b, tol):
    return abs(a.l - b.l) <= tol or abs(a.r - b.r) <= tol or abs((a.l + a.r) - (b.l + b.r)) / 2 <= tol


def _table_run(rows, i, body):
    first = rows[i]
    if len(first) < 2 or any(s.figure or len(s.text) > 80 for s in first):
        return 0
    size = max(s.size for s in first) or body
    tol = max(4.0, 0.5 * size)
    run = 1
    while i + run < len(rows):
        row, prev = rows[i + run], rows[i + run - 1]
        if len(row) != len(first) or any(s.figure or len(s.text) > 80 for s in row):
            break
        if not all(_aligned(a, b, tol) for a, b in zip(first, row)):
            break
        if min(s.b for s in prev) - max(s.t for s in row) > 2.5 * size:
            break
        run += 1
    cols = len(first)
    return run if (run >= 2 and cols >= 3) or (run >= 3 and cols >= 2) else 0


def _is_heading(seg, body):
    return len(seg.text) <= 200 and bool(seg.text.strip()) and (
        seg.size >= 1.2 * body or (seg.bold and seg.size >= 1.1 * body))


def _blocks(regions, body):
    blocks = []
    for rows in regions:
        last = None
        i = 0
        while i < len(rows):
            run = _table_run(rows, i, body)
            if run:
                blocks.append({"type": "Table", "rows": [[s.mcids for s in r] for r in rows[i:i + run]],
                               "seg": rows[i + run - 1][0]})
                last = None
                i += run
                continue
            for seg in rows[i]:
                last = _place(blocks, last, seg, body)
            i += 1
    return blocks


def _place(blocks, last, seg, body):
    size = seg.size or body
    if seg.figure:
        u = seg.units[0]
        blocks.append({"type": "Figure", "mcids": seg.mcids, "rect": u.rect})
        return None
    close = last is not None and "seg" in last and \
        -0.5 * size <= last["seg"].b - seg.t <= 1.0 * max(size, last["seg"].size)
    first = seg.units[0].text
    if len(seg.units) > 1 and LABEL_ONLY.match(first):
        item = {"lbl": [seg.units[0].mcid], "body": seg.mcids[1:], "x": seg.l}
    elif LIST_START.match(seg.text):
        item = {"lbl": [], "body": seg.mcids, "x": seg.l}
    else:
        item = None
    if item is not None:
        if last is not None and last["type"] == "L" and close:
            last["items"].append(item)
            last["seg"] = seg
            return last
        block = {"type": "L", "items": [item], "seg": seg}
        blocks.append(block)
        return block
    if last is not None and last["type"] == "L" and close and seg.l > last["items"][-1]["x"] + 0.3 * size \
            and not _is_heading(seg, body):
        last["items"][-1]["body"] += seg.mcids
        last["seg"] = seg
        return last
    if _is_heading(seg, body):
        if last is not None and last["type"] == "H" and close and abs(last["size"] - seg.size) < 0.5:
            last["mcids"] += seg.mcids
            last["seg"] = seg
            return last
        block = {"type": "H", "mcids": seg.mcids, "size": seg.size, "seg": seg}
        blocks.append(block)
        return block
    if last is not None and last["type"] == "P" and close and \
            0.85 <= seg.size / max(0.1, last["seg"].size) <= 1.18 and \
            _overlap(last["l"], last["r"], seg.l, seg.r) > 0:
        last["mcids"] += seg.mcids
        last["seg"] = seg
        last["l"], last["r"] = min(last["l"], seg.l), max(last["r"], seg.r)
        return last
    block = {"type": "P", "mcids": seg.mcids, "seg": seg, "l": seg.l, "r": seg.r}
    blocks.append(block)
    return block


@op("autotag")
def autotag(ctx, replace=False, pages=None, language=None):
    import pypdfium2  # noqa: F401 - fail early if PDFium is unavailable
    pdf = ctx.pdf
    had_tree = isinstance(pdf.Root.get("/StructTreeRoot"), Dictionary)
    if (had_tree or _is_tagged(pdf)) and not replace:
        raise EngineError("ALREADY_TAGGED", "This document is already tagged. Choose Replace to retag it.")
    if language:
        set_language(ctx, language)
    notes = []
    indexes = _page_indexes(pdf, pages)
    if had_tree:
        _strip_form_mcids(pdf)
        del pdf.Root.StructTreeRoot
    for page in pdf.pages:
        if "/StructParents" in page.obj:
            del page.obj.StructParents
        for annot in _annotations(page):
            if "/StructParent" in annot:
                del annot.StructParent

    # Pass 1: provisional marked content.
    rewritten = {}
    for index in indexes:
        page = pdf.pages[index]
        res = _resources(page.obj)
        try:
            instructions = pikepdf.parse_content_stream(page)
        except pikepdf.PdfError:
            notes.append(f"Page {index + 1}: the content could not be parsed and was left untagged.")
            continue
        out, kinds, where = _wrap_content(instructions, res)
        page.obj.Contents = pdf.make_stream(pikepdf.unparse_content_stream(out))
        rewritten[index] = (out, kinds, where)

    # Geometry from PDFium, keyed by provisional MCID.
    c = _pdfium_c()
    geometry = {}
    with ctx.pdfium() as doc:
        for index in rewritten:
            page = doc[index]
            try:
                geometry[index] = _scan_page(c, page)[0]
            finally:
                page.close()

    sizes = []
    units_by_page = {}
    for index, (out, kinds, where) in rewritten.items():
        page = pdf.pages[index]
        inv = invert(visual_matrix(page))
        units = []
        for mcid in sorted(kinds):
            g = geometry[index].get(mcid)
            if g is None or g["rect"] is None:
                continue
            kind = kinds[mcid]
            text = g["text"]
            if kind in ("text", "form_text") and not text.strip():
                continue
            vrect = transform_rect(inv, g["rect"])
            if kind in ("image", "form_image"):
                if (vrect[2] - vrect[0]) < 16 or (vrect[3] - vrect[1]) < 16:
                    continue
            size = g["size"] or max(1.0, vrect[3] - vrect[1]) * 0.8
            units.append(_Unit(mcid, kind, text, g["rect"], vrect, size, g["bold"] and g["chars"] > 0))
            if kind == "text":
                sizes += [round(size, 1)] * max(1, min(g["chars"], 200))
        units_by_page[index] = units
    body = statistics.median(sizes) if sizes else 11.0

    blocks_by_page = {}
    for index, units in units_by_page.items():
        width = _visual_width(pdf.pages[index])
        segs = _segments(units)
        try:
            blocks_by_page[index] = _blocks(_regions(segs, width), body)
        except Exception:  # pragma: no cover - defensive: never fail a page on layout analysis
            notes.append(f"Page {index + 1}: layout analysis failed; each text item was tagged as a paragraph.")
            blocks_by_page[index] = [{"type": "P", "mcids": [u.mcid]} for u in units if u.kind != "image"] + \
                [{"type": "Figure", "mcids": [u.mcid], "rect": u.rect} for u in units if u.kind == "image"]

    # Heading levels: rank distinct sizes, then clamp so levels never skip.
    heading_sizes = sorted({round(b["size"] * 2) / 2 for bl in blocks_by_page.values() for b in bl
                            if b["type"] == "H"}, reverse=True)
    previous = 0
    for index in sorted(blocks_by_page):
        for b in blocks_by_page[index]:
            if b["type"] == "H":
                level = min(3, heading_sizes.index(round(b["size"] * 2) / 2) + 1)
                level = min(level, previous + 1)
                b["level"] = level
                previous = level

    # Pass 2: final tags, structure elements and MCIDs.
    root = pdf.make_indirect(Dictionary(Type=Name.StructTreeRoot, K=Array()))
    pdf.Root.StructTreeRoot = root
    document = pdf.make_indirect(Dictionary(Type=Name.StructElem, S=Name.Document, P=root, K=Array()))
    root.K.append(document)
    stats = {"elements": 1, "headings": 0, "paragraphs": 0, "lists": 0, "tables": 0, "figures": 0,
             "artifacts": 0, "pages": len(rewritten)}

    for index in sorted(rewritten):
        out, kinds, where = rewritten[index]
        page = pdf.pages[index]
        final = {}  # provisional mcid -> (tag, new mcid)
        counter = [0]

        def elem(s, parent, **extra):
            e = pdf.make_indirect(Dictionary(Type=Name.StructElem, S=Name("/" + s), P=parent, Pg=page.obj,
                                             K=Array(), **extra))
            parent.K.append(e)
            stats["elements"] += 1
            return e

        def own(e, tag, mcids):
            for old in mcids:
                new = counter[0]
                counter[0] += 1
                final[old] = (tag, new)
                e.K.append(new)

        for b in blocks_by_page.get(index, []):
            t = b["type"]
            if t == "H":
                tag = f"H{b['level']}"
                own(elem(tag, document), tag, b["mcids"])
                stats["headings"] += 1
            elif t == "P":
                own(elem("P", document), "P", b["mcids"])
                stats["paragraphs"] += 1
            elif t == "Figure":
                l, bb, r, tt = b["rect"]
                fig = elem("Figure", document, A=Dictionary(O=Name.Layout, BBox=Array([l, bb, r, tt])))
                own(fig, "Figure", b["mcids"])
                stats["figures"] += 1
            elif t == "L":
                lst = elem("L", document)
                for item in b["items"]:
                    li = elem("LI", lst)
                    if item["lbl"]:
                        own(elem("Lbl", li), "Lbl", item["lbl"])
                    own(elem("LBody", li), "LBody", item["body"])
                stats["lists"] += 1
            elif t == "Table":
                table = elem("Table", document)
                for r, row in enumerate(b["rows"]):
                    tr = elem("TR", table)
                    for cell in row:
                        tag = "TH" if r == 0 else "TD"
                        extra = {"A": Dictionary(O=Name.Table, Scope=Name.Column)} if r == 0 else {}
                        own(elem(tag, tr, **extra), tag, cell)
                stats["tables"] += 1
        for old, position in where.items():
            if old in final:
                tag, new = final[old]
                out[position] = _instr([Name("/" + tag), Dictionary(MCID=new)], "BDC")
            else:
                out[position] = _instr([Name.Artifact], "BMC")
                stats["artifacts"] += 1
        stats["artifacts"] += sum(1 for ins in out if not isinstance(ins, pikepdf.ContentStreamInlineImage)
                                  and str(ins.operator) == "BMC" and ins.operands
                                  and ins.operands[0] == Name.Artifact)
        page.obj.Contents = pdf.make_stream(pikepdf.unparse_content_stream(out))
        if kinds and not final:
            notes.append(f"Page {index + 1}: no readable content was found; everything was marked as an artifact.")

    pdf.Root.MarkInfo = Dictionary(Marked=True)
    before = stats["elements"]
    tagged_annots = _tag_annotations(pdf, document, set(indexes))
    stats["elements"] = before + tagged_annots
    stats["annotations"] = tagged_annots
    for index in indexes:
        if _annotations(pdf.pages[index]):
            pdf.pages[index].obj.Tabs = Name.S
    _rebuild_parent_tree(pdf)
    if any(k in ("form_text",) for _, kinds, _ in rewritten.values() for k in kinds.values()):
        notes.append("Text inside Form XObjects was tagged as whole paragraphs; review those in the Tags panel.")
    if stats["figures"]:
        notes.append(f"{stats['figures']} figure(s) need alternate text.")
    stats["notes"] = notes
    return stats


def _visual_width(page):
    from transforms.content import visual_size
    return visual_size(page)[0]


# ================================================================ structure queries

def _snippet(node, content, pages, limit=120):
    parts = []
    for c in node.content:
        if c["kind"] != "mcid" or c.get("stm") is not None:
            continue
        page = c.get("page")
        index = pages.get(page.objgen) if isinstance(page, Dictionary) and page.is_indirect else None
        entry = content.get(index, {}).get(c["mcid"]) if index is not None else None
        if entry and entry["text"]:
            parts.append(entry["text"])
    text = " ".join(p.strip() for p in parts if p.strip())
    return text[:limit]


@query("structure_tree")
def structure_tree(ctx, max_nodes=5000):
    pdf = ctx.pdf
    tagged = _is_tagged(pdf)
    rnode, nodes = _walk(pdf)
    if rnode is None:
        return {"tagged": tagged, "truncated": False, "root": None}
    pages = _page_map(pdf)
    content = _content_map(ctx)
    budget = [int(max_nodes)]
    truncated = [False]
    resolve = _role_resolver(pdf)

    def build(node, is_root=False):
        budget[0] -= 1
        obj = node.obj
        data = {"id": node.id, "type": "StructTreeRoot" if is_root else _name(obj.get("/S")),
                "role": None if is_root else resolve(obj),
                "alt": None if is_root else _text(obj.get("/Alt")),
                "actual_text": None if is_root else _text(obj.get("/ActualText")),
                "title": None if is_root else _text(obj.get("/T")),
                "lang": None if is_root else _text(obj.get("/Lang")),
                "page": None if is_root else _page_of(node, pages),
                "text": "" if is_root else _snippet(node, content, pages),
                "annotations": sum(1 for c in node.content if c["kind"] == "objr"),
                "children": []}
        for kid in node.kids:
            if budget[0] <= 0:
                truncated[0] = True
                break
            data["children"].append(build(kid))
        if not is_root and not data["text"] and data["children"]:
            data["text"] = " ".join(ch["text"] for ch in data["children"] if ch["text"])[:120]
        return data

    tree = build(rnode, True)
    return {"tagged": tagged, "truncated": truncated[0], "root": tree, "count": len(nodes)}


@query("reading_order")
def reading_order(ctx, page):
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "INVALID_PAGE_RANGE", "Choose a page in this document.")
    _, nodes = _walk(pdf)
    target = pdf.pages[page].obj.objgen
    content = _content_map(ctx).get(page, {})
    items = []
    for node in nodes:
        mcids = [c["mcid"] for c in node.content if c["kind"] == "mcid" and c.get("stm") is None
                 and isinstance(c.get("page"), Dictionary) and c["page"].is_indirect and c["page"].objgen == target]
        if not mcids:
            continue
        rect, texts = None, []
        for m in mcids:
            entry = content.get(m)
            if not entry:
                continue
            if entry["text"].strip():
                texts.append(entry["text"].strip())
            r = entry["rect"]
            if r:
                rect = r if rect is None else [min(rect[0], r[0]), min(rect[1], r[1]),
                                               max(rect[2], r[2]), max(rect[3], r[3])]
        items.append({"id": node.id, "type": _name(node.obj.get("/S")), "order": len(items) + 1,
                      "rect": [round(v, 2) for v in rect] if rect else None, "text": " ".join(texts)[:120]})
    return {"page": page, "items": items}


# ================================================================ structure edits

def _resolve(pdf):
    """Materialized tree + id -> node (ids from the unmodified tree)."""
    require(isinstance(pdf.Root.get("/StructTreeRoot"), Dictionary), "NOT_TAGGED", "This document has no tags.")
    rnode, nodes = _walk(pdf, materialize=True)
    index = {n.id: n for n in nodes}
    index["root"] = rnode
    return rnode, index


def _lookup(index, nid, allow_root=False):
    node = index.get(nid) if isinstance(nid, str) else None
    if node is None or (node.id == "root" and not allow_root):
        raise EngineError("STALE_STRUCTURE", "The tag tree changed. Refresh and try again.")
    return node


def _same(a, b):
    return a.is_indirect and b.is_indirect and a.objgen == b.objgen


def _parent_obj(pdf, elem):
    parent = elem.get("/P")
    return parent if isinstance(parent, Dictionary) else pdf.Root.StructTreeRoot


def _position(parent, elem):
    for i, item in enumerate(_items(parent)):
        if isinstance(item, Dictionary) and _same(item, elem):
            return i
    return None


def _set_kids(parent, items):
    parent.K = Array(items)


def _detach(pdf, elem):
    parent = _parent_obj(pdf, elem)
    items = _items(parent)
    pos = _position(parent, elem)
    require(pos is not None, "STALE_STRUCTURE", "The tag tree changed. Refresh and try again.")
    del items[pos]
    _set_kids(parent, items)
    return parent, pos


def _insert(parent, elem, index):
    items = _items(parent)
    index = max(0, min(int(index), len(items)))
    items.insert(index, elem)
    _set_kids(parent, items)
    elem.P = parent


def _is_ancestor(pdf, maybe, elem):
    """True when `maybe` is `elem` or one of its descendants."""
    node = maybe
    root = pdf.Root.StructTreeRoot
    for _ in range(1000):
        if _same(node, elem):
            return True
        if _same(node, root) or not isinstance(node.get("/P"), Dictionary):
            return False
        node = node.P
    return True


_SET_KEYS = {"type": "/S", "alt": "/Alt", "actual_text": "/ActualText", "title": "/T", "lang": "/Lang"}


def _apply_set(elem, values):
    require(isinstance(values, dict) and values, "INVALID_ARGUMENT", "Nothing to change.")
    for key, value in values.items():
        require(key in _SET_KEYS and isinstance(value, str), "INVALID_ARGUMENT", f"Unsupported tag property {key!r}.")
        pdf_key = _SET_KEYS[key]
        if key == "type":
            require(re.match(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$", value), "INVALID_ARGUMENT", "Enter a valid tag type.")
            elem.S = Name("/" + value)
        elif value == "":
            if pdf_key in elem:
                del elem[pdf_key]
        else:
            if key == "lang":
                require(LANG.match(value), "INVALID_ARGUMENT", "Enter a language tag such as en-US.")
            elem[pdf_key] = pikepdf.String(value)


def _delete(pdf, elem):
    parent, pos = _detach(pdf, elem)
    root = pdf.Root.StructTreeRoot
    moved = []
    page = elem.get("/Pg")
    for item in _items(elem):
        if _is_elem(item):
            item.P = parent
            moved.append(item)
            continue
        require(not _same(parent, root), "INVALID_STRUCTURE_EDIT",
                "A top-level tag that owns content can't be deleted; change its type instead.")
        if isinstance(item, Dictionary):
            if "/Pg" not in item and isinstance(page, Dictionary):
                item.Pg = page
            moved.append(item)
        elif _is_int(item):
            mcr = Dictionary(Type=Name.MCR, MCID=int(item))
            if isinstance(page, Dictionary):
                mcr.Pg = page
            moved.append(mcr)
    items = _items(parent)
    items[pos:pos] = moved
    _set_kids(parent, items)


@op("edit_structure")
def edit_structure(ctx, edits):
    pdf = ctx.pdf
    require(isinstance(edits, list) and edits, "INVALID_ARGUMENT", "No tag edits were given.")
    _, index = _resolve(pdf)
    resolved = []
    for edit in edits:
        require(isinstance(edit, dict), "INVALID_ARGUMENT", "Invalid tag edit.")
        node = _lookup(index, edit.get("id"))
        target = None
        if "move" in edit:
            move = edit["move"]
            require(isinstance(move, dict) and isinstance(move.get("index", 0), int), "INVALID_ARGUMENT",
                    "Invalid move.")
            target = _lookup(index, move.get("parent"), allow_root=True)
        resolved.append((edit, node, target))
    deleted = set()
    for edit, node, target in resolved:
        elem = node.obj
        require(elem.objgen not in deleted, "STALE_STRUCTURE", "That tag was already deleted.")
        if "set" in edit:
            _apply_set(elem, edit["set"])
        if "move" in edit:
            parent = target.obj
            require(not _is_ancestor(pdf, parent, elem), "INVALID_STRUCTURE_EDIT",
                    "A tag can't be moved inside itself.")
            require(target.id != "root" or not node.content, "INVALID_STRUCTURE_EDIT",
                    "Tags that own content can't be placed directly under the root.")
            _detach(pdf, elem)
            new_index = edit["move"].get("index", 0)
            _insert(parent, elem, new_index)
        if edit.get("delete") is True:
            _delete(pdf, elem)
            deleted.add(elem.objgen)
    _rebuild_parent_tree(pdf)
    return {"edited": len(resolved)}


@op("set_alt_text")
def set_alt_text(ctx, items):
    pdf = ctx.pdf
    require(isinstance(items, list) and items, "INVALID_ARGUMENT", "No alternate text was given.")
    _, index = _resolve(pdf)
    targets = [(_lookup(index, item.get("id") if isinstance(item, dict) else None), item) for item in items]
    for node, item in targets:
        alt = item.get("alt")
        require(isinstance(alt, str), "INVALID_ARGUMENT", "Alternate text must be text.")
        if alt.strip():
            node.obj.Alt = pikepdf.String(alt.strip())
        elif "/Alt" in node.obj:
            del node.obj.Alt
    _rebuild_parent_tree(pdf)
    return {"updated": len(targets)}


@op("set_reading_order")
def set_reading_order(ctx, page, ids):
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "INVALID_PAGE_RANGE", "Choose a page in this document.")
    require(isinstance(ids, list) and ids and len(set(ids)) == len(ids), "INVALID_ARGUMENT", "Invalid reading order.")
    _, index = _resolve(pdf)
    nodes = [_lookup(index, nid) for nid in ids]
    elems = [n.obj for n in nodes]
    for a in elems:
        for b in elems:
            require(a is b or _same(a, b) or not _is_ancestor(pdf, a, b), "INVALID_STRUCTURE_EDIT",
                    "Reorder sibling tags, not a tag and its contents.")
    parents = [_parent_obj(pdf, e) for e in elems]
    if all(_same(p, parents[0]) for p in parents):
        parent = parents[0]
        items = _items(parent)
        positions = sorted(_position(parent, e) for e in elems)
        require(None not in positions, "STALE_STRUCTURE", "The tag tree changed. Refresh and try again.")
        for pos, elem in zip(positions, elems):
            items[pos] = elem
        _set_kids(parent, items)
    else:
        parent = parents[0]
        pos = _position(parent, elems[0])
        require(pos is not None, "STALE_STRUCTURE", "The tag tree changed. Refresh and try again.")
        for elem in elems:
            p, removed = _detach(pdf, elem)
            if _same(p, parent) and removed < pos:
                pos -= 1
        for offset, elem in enumerate(elems):
            _insert(parent, elem, pos + offset)
    _rebuild_parent_tree(pdf)
    return {"reordered": len(elems)}
