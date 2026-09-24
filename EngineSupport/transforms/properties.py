"""Document Properties: description metadata (Info + XMP kept in sync), custom
metadata, initial view (/PageLayout, /PageMode, /OpenAction,
/ViewerPreferences), fonts, security summary, fast web view, and the
document JavaScript inspector.

zPDF never executes document JavaScript. The inspector lists every script
location it knows (document-level name tree, open/document actions, page
actions, field and annotation actions, chained /Next actions) so scripts can
be read and deleted.
"""
import re

import pikepdf
from pikepdf import Array, Dictionary, Name, String

from engine.errors import EngineError, require
from transforms import op, query, REGISTRY, QUERIES
from transforms.navigation import (describe_destination, make_destination, name_tree_items, names_tree,
                                   oid, page_index_map, pdf_date, text)
from transforms.content import visual_size

STANDARD_INFO = ("/Title", "/Author", "/Subject", "/Keywords", "/Creator", "/Producer", "/CreationDate",
                 "/ModDate", "/Trapped")
LAYOUTS = ("SinglePage", "OneColumn", "TwoColumnLeft", "TwoColumnRight", "TwoPageLeft", "TwoPageRight")
MODES = ("UseNone", "UseOutlines", "UseThumbs", "FullScreen", "UseOC", "UseAttachments")
VIEWER_BOOLS = ("HideToolbar", "HideMenubar", "HideWindowUI", "FitWindow", "CenterWindow", "DisplayDocTitle",
                "PickTrayByPDFSize")
PDFX = "http://ns.adobe.com/pdfx/1.3/"


@query("list_operations")
def list_operations(ctx):
    return {"ops": sorted(REGISTRY), "queries": sorted(QUERIES)}


# ------------------------------------------------------------------ fonts

def _font_info(font):
    subtype = text(font.get("/Subtype")) or ""
    base = text(font.get("/BaseFont")) or ""
    descriptor = font.get("/FontDescriptor")
    descendant = None
    if subtype == "/Type0":
        kids = font.get("/DescendantFonts")
        if isinstance(kids, Array) and len(kids):
            descendant = kids[0]
            descriptor = descendant.get("/FontDescriptor")
    embedded = False
    embedded_type = None
    if isinstance(descriptor, Dictionary):
        for key, label in (("/FontFile", "Type 1"), ("/FontFile2", "TrueType"), ("/FontFile3", None)):
            if key in descriptor:
                embedded = True
                stream = descriptor[key]
                embedded_type = label or (text(stream.get("/Subtype"))[1:] if isinstance(stream, pikepdf.Stream)
                                          and stream.get("/Subtype") is not None else "Type 1C")
    if subtype == "/Type3":
        embedded = True
        embedded_type = "Type 3"
    name = base[1:] if base.startswith("/") else base
    subset = bool(re.match(r"^[A-Z]{6}\+", name))
    encoding = font.get("/Encoding")
    if isinstance(encoding, Name):
        encoding_text = str(encoding)[1:]
    elif isinstance(encoding, Dictionary):
        encoding_text = "Custom" + (f" ({str(encoding.BaseEncoding)[1:]})" if "/BaseEncoding" in encoding else "")
    elif encoding is not None:
        encoding_text = "Custom"
    else:
        encoding_text = "Built-in"
    kind = subtype[1:] if subtype else "Unknown"
    if descendant is not None:
        kind = f"Type 0 ({text(descendant.get('/Subtype'))[1:]})"
    return {"name": name or "(unnamed)", "type": kind, "embedded": embedded, "subset": subset,
            "embedded_type": embedded_type, "encoding": encoding_text, "to_unicode": "/ToUnicode" in font}


def collect_fonts(pdf, page_limit=None):
    fonts = {}
    visited = set()

    def walk_resources(resources, page_index, depth=0):
        if not isinstance(resources, Dictionary) or depth > 12:
            return
        for key in resources.get("/Font", Dictionary()).keys():
            font = resources.Font[key]
            if not isinstance(font, Dictionary):
                continue
            ident = font.objgen if font.is_indirect else id(font)
            entry = fonts.get(ident)
            if entry is None:
                entry = fonts[ident] = _font_info(font)
                entry["pages"] = []
            if page_index not in entry["pages"] and len(entry["pages"]) < 50:
                entry["pages"].append(page_index)
        for key in resources.get("/XObject", Dictionary()).keys():
            xobj = resources.XObject[key]
            if isinstance(xobj, pikepdf.Stream) and xobj.get("/Subtype") == Name.Form:
                ident = (xobj.objgen, page_index)
                if ident in visited:
                    continue
                visited.add(ident)
                walk_resources(xobj.get("/Resources"), page_index, depth + 1)

    for index, page in enumerate(pdf.pages):
        if page_limit is not None and index >= page_limit:
            break
        walk_resources(page.obj.get("/Resources"), index)
        for annot in page.obj.get("/Annots", []):
            ap = annot.get("/AP") if isinstance(annot, Dictionary) else None
            normal = ap.get("/N") if isinstance(ap, Dictionary) else None
            streams = [normal] if isinstance(normal, pikepdf.Stream) else \
                [normal[k] for k in normal.keys()] if isinstance(normal, Dictionary) else []
            for stream in streams:
                if isinstance(stream, pikepdf.Stream):
                    walk_resources(stream.get("/Resources"), index, 1)
    return sorted(fonts.values(), key=lambda f: f["name"].lower())


@query("fonts")
def fonts_query(ctx):
    return {"items": collect_fonts(ctx.pdf)}


# ------------------------------------------------------------- properties

def _xmp(pdf):
    metadata = pdf.Root.get("/Metadata")
    if isinstance(metadata, pikepdf.Stream):
        try:
            return metadata.read_bytes().decode("utf-8", "replace")
        except pikepdf.PdfError:
            return None
    return None


def _open_action(pdf):
    action = pdf.Root.get("/OpenAction")
    dest = None
    if isinstance(action, Array):
        dest = action
    elif isinstance(action, Dictionary) and action.get("/S") == Name.GoTo:
        dest = action.get("/D")
    if dest is None:
        return {"page": None, "zoom": None, "fit": None, "javascript": isinstance(action, Dictionary)
                and action.get("/S") == Name.JavaScript}
    info = describe_destination(pdf, dest)
    zoom = "default"
    if info["fit"] in ("Fit", "FitB"):
        zoom = "fit_page"
    elif info["fit"] in ("FitH", "FitBH"):
        zoom = "fit_width"
    elif info["fit"] in ("FitV", "FitBV"):
        zoom = "fit_height"
    elif info["fit"] == "XYZ" and info["zoom"]:
        zoom = round(info["zoom"] * 100, 1)
    return {"page": info["page"], "zoom": zoom, "fit": info["fit"], "javascript": False}


@query("document_properties")
def document_properties(ctx):
    pdf = ctx.pdf
    info = pdf.docinfo if "/Info" in pdf.trailer else Dictionary()
    described = {}
    for key in STANDARD_INFO:
        value = info.get(key)
        if key in ("/CreationDate", "/ModDate"):
            described[key[1:].lower()] = pdf_date(value)
        else:
            described[key[1:].lower()] = text(value)
    custom = {}
    for key in info.keys():
        if key not in STANDARD_INFO:
            value = info[key]
            if isinstance(value, (String, Name)) or not isinstance(value, (Dictionary, Array, pikepdf.Stream)):
                custom[key[1:]] = text(value)
    first = pdf.pages[0]
    width, height = visual_size(first)
    prefs = pdf.Root.get("/ViewerPreferences", Dictionary())
    viewer = {key: bool(prefs.get("/" + key, False)) for key in VIEWER_BOOLS}
    for key in ("NonFullScreenPageMode", "Direction", "PrintScaling", "Duplex"):
        value = prefs.get("/" + key)
        viewer[key] = str(value)[1:] if isinstance(value, Name) else None
    copies = prefs.get("/NumCopies")
    viewer["NumCopies"] = int(copies) if copies is not None else None
    encryption = None
    if pdf.is_encrypted:
        enc = pdf.encryption
        encryption = {"R": enc.R, "V": enc.V, "bits": enc.bits, "method": str(enc.stream_method).split(".")[-1]}
    allow = pdf.allow
    permissions = {"print": allow.print_lowres, "print_high": allow.print_highres, "modify": allow.modify_other,
                   "extract": allow.extract, "annotate": allow.modify_annotation, "fill_forms": allow.modify_form,
                   "accessibility": allow.accessibility, "assemble": allow.modify_assembly}
    acroform = pdf.Root.get("/AcroForm")
    has_xfa = isinstance(acroform, Dictionary) and "/XFA" in acroform
    fields = acroform.get("/Fields", []) if isinstance(acroform, Dictionary) else []
    xmp = _xmp(pdf)
    pdfa = None
    pdfua = False
    if xmp:
        part = re.search(r"pdfaid:part\s*=\s*['\"](\d)['\"]|<pdfaid:part>(\d)</pdfaid:part>", xmp)
        conf = re.search(r"pdfaid:conformance\s*=\s*['\"](\w)['\"]|<pdfaid:conformance>(\w)</pdfaid:conformance>", xmp)
        if part:
            pdfa = "PDF/A-" + (part.group(1) or part.group(2)) + ((conf.group(1) or conf.group(2)).upper() if conf else "")
        pdfua = bool(re.search(r"pdfuaid:part\s*=\s*['\"]1['\"]|<pdfuaid:part>1</pdfuaid:part>", xmp))
    page_layout = pdf.Root.get("/PageLayout")
    page_mode = pdf.Root.get("/PageMode")
    labels = "/PageLabels" in pdf.Root
    embedded = pdf.Root.get("/Names", Dictionary()).get("/EmbeddedFiles")
    return {
        "info": described, "custom": custom, "xmp": xmp,
        "version": str(pdf.pdf_version), "page_count": len(pdf.pages), "page_size": [width, height],
        "tagged": bool(pdf.Root.get("/MarkInfo", Dictionary()).get("/Marked", False)) and "/StructTreeRoot" in pdf.Root,
        "linearized": bool(pdf.is_linearized), "encrypted": bool(pdf.is_encrypted), "encryption": encryption,
        "permissions": permissions,
        "lang": text(pdf.Root.get("/Lang")),
        "has_xfa": has_xfa, "xfa_only": has_xfa and len(fields) == 0,
        "needs_rendering": bool(pdf.Root.get("/NeedsRendering", False)),
        "form_fields": len(fields), "page_labels": labels,
        "attachments": sum(1 for _ in name_tree_items(embedded)),
        "pdfa": pdfa, "pdfua": pdfua,
        "initial_view": {
            "page_layout": str(page_layout)[1:] if isinstance(page_layout, Name) else None,
            "page_mode": str(page_mode)[1:] if isinstance(page_mode, Name) else None,
            "open": _open_action(pdf), "viewer_preferences": viewer,
        },
    }


def _sync_xmp(pdf, updates, custom=None, removed=()):
    """Write dc/pdf/xmp fields (docinfo is updated from XMP by pikepdf)."""
    with pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=True) as meta:
        for key, value in updates.items():
            if value is None:
                continue
            if key == "title":
                meta["dc:title"] = value
            elif key == "author":
                authors = [a.strip() for a in re.split(r"[;\n]", value) if a.strip()]
                if authors:
                    meta["dc:creator"] = authors
                elif "dc:creator" in meta:
                    del meta["dc:creator"]
            elif key == "subject":
                meta["dc:description"] = value
            elif key == "keywords":
                meta["pdf:Keywords"] = value
                subjects = [k.strip() for k in re.split(r"[,;]", value) if k.strip()]
                if subjects:
                    meta["dc:subject"] = subjects
                elif "dc:subject" in meta:
                    del meta["dc:subject"]
            elif key == "creator":
                meta["xmp:CreatorTool"] = value
            elif key == "producer":
                meta["pdf:Producer"] = value
        for key, value in (custom or {}).items():
            meta[f"{{{PDFX}}}{key}"] = value
        for key in removed:
            qualified = f"{{{PDFX}}}{key}"
            if qualified in meta:
                del meta[qualified]


VALID_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9_\-]{0,63}$")


@op("set_metadata")
def set_metadata(ctx, info=None, custom=None, remove_custom=None):
    """Update standard Info fields + XMP, custom Info keys (mirrored in XMP pdfx:)."""
    pdf = ctx.pdf
    info = info or {}
    custom = {str(k): str(v) for k, v in (custom or {}).items()}
    removed = [str(k) for k in (remove_custom or [])]
    for key in list(custom) + removed:
        require(VALID_KEY.match(key) and "/" + key not in STANDARD_INFO, "INVALID_ARGUMENT",
                f"“{key}” can't be used as a custom property name.")
    allowed = {"title", "author", "subject", "keywords", "creator", "producer"}
    require(set(info) <= allowed, "INVALID_ARGUMENT", "Unknown metadata field.")
    updates = {k: (str(v) if v is not None else None) for k, v in info.items()}
    _sync_xmp(pdf, {k: v for k, v in updates.items() if v}, custom, removed)
    docinfo = pdf.docinfo
    for key, value in updates.items():
        name = Name("/" + key.capitalize())
        if value is None:
            continue
        if value == "":
            if name in docinfo:
                del docinfo[name]
        else:
            docinfo[name] = String(value)
    for key, value in custom.items():
        docinfo[Name("/" + key)] = String(value)
    for key in removed:
        if Name("/" + key) in docinfo:
            del docinfo[Name("/" + key)]
    # Blank standard fields must also leave XMP.
    blanks = [k for k, v in updates.items() if v == ""]
    if blanks:
        with pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=False) as meta:
            mapping = {"title": ["dc:title"], "author": ["dc:creator"], "subject": ["dc:description"],
                       "keywords": ["pdf:Keywords", "dc:subject"], "creator": ["xmp:CreatorTool"],
                       "producer": ["pdf:Producer"]}
            for key in blanks:
                for qualified in mapping[key]:
                    if qualified in meta:
                        del meta[qualified]
    return {"updated": len(updates) + len(custom) + len(removed)}


@op("set_xmp")
def set_xmp(ctx, xmp):
    """Replace the raw XMP packet (validated as XML)."""
    from lxml import etree
    data = str(xmp or "").encode("utf-8")
    require(data.strip(), "INVALID_ARGUMENT", "The XMP metadata is empty.")
    try:
        body = re.sub(rb"<\?xpacket[^>]*\?>", b"", data)
        root = etree.fromstring(body.strip())
    except etree.XMLSyntaxError as exc:
        raise EngineError("INVALID_XMP", f"The XMP metadata is not valid XML: {exc}") from exc
    require(root.tag in ("{adobe:ns:meta/}xmpmeta", "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}RDF"),
            "INVALID_XMP", "XMP must start with an x:xmpmeta or rdf:RDF element.")
    stream = ctx.pdf.make_stream(data)
    stream.Type, stream.Subtype = Name.Metadata, Name.XML
    ctx.pdf.Root.Metadata = stream
    # Refresh Info from the new packet so both stay consistent.
    with ctx.pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=True):
        pass
    return {"bytes": len(data)}


@op("set_initial_view")
def set_initial_view(ctx, page_layout="keep", page_mode="keep", open_page=None, open_zoom=None,
                     viewer_preferences=None):
    """`keep` leaves a field unchanged; None/"default" removes it."""
    pdf = ctx.pdf
    root = pdf.Root
    for key, value, allowed in (("/PageLayout", page_layout, LAYOUTS), ("/PageMode", page_mode, MODES)):
        if value == "keep":
            continue
        if value in (None, "", "default"):
            if key in root:
                del root[key]
        else:
            require(value in allowed, "INVALID_ARGUMENT", f"Unsupported {key[1:]}: {value}.")
            root[key] = Name("/" + value)
    if open_page is not None or open_zoom is not None:
        page = int(open_page or 0)
        require(0 <= page < len(pdf.pages), "INVALID_PAGE", "Choose a page in this document.")
        zoom = open_zoom if open_zoom is not None else "default"
        if zoom == "default":
            dest = make_destination(pdf, page, None, None, None, "XYZ")
        elif zoom == "fit_page":
            dest = make_destination(pdf, page, fit="Fit")
        elif zoom == "fit_width":
            dest = make_destination(pdf, page, top=None, fit="FitH")
        elif zoom == "fit_height":
            dest = make_destination(pdf, page, left=None, fit="FitV")
        elif zoom == "fit_visible":
            dest = make_destination(pdf, page, top=None, fit="FitBH")
        else:
            value = float(zoom)
            require(1 <= value <= 6400, "INVALID_ARGUMENT", "Zoom must be between 1% and 6400%.")
            dest = make_destination(pdf, page, None, None, value / 100, "XYZ")
        existing = root.get("/OpenAction")
        require(not (isinstance(existing, Dictionary) and existing.get("/S") == Name.JavaScript),
                "OPEN_ACTION_SCRIPT", "The document runs a script when it opens. Remove it in the JavaScript inspector first.")
        if page == 0 and zoom == "default":
            if "/OpenAction" in root:
                del root["/OpenAction"]
        else:
            root.OpenAction = dest
    if viewer_preferences:
        prefs = root.get("/ViewerPreferences")
        if not isinstance(prefs, Dictionary):
            prefs = root.ViewerPreferences = Dictionary()
        for key, value in viewer_preferences.items():
            if key in VIEWER_BOOLS:
                if value:
                    prefs["/" + key] = True
                elif "/" + key in prefs:
                    del prefs["/" + key]
            elif key in ("NonFullScreenPageMode", "Direction", "PrintScaling", "Duplex"):
                if value in (None, "", "default"):
                    if "/" + key in prefs:
                        del prefs["/" + key]
                else:
                    prefs["/" + key] = Name("/" + str(value))
            elif key == "NumCopies":
                if value:
                    prefs.NumCopies = max(1, min(5, int(value)))
                elif "/NumCopies" in prefs:
                    del prefs["/NumCopies"]
            else:
                raise EngineError("INVALID_ARGUMENT", f"Unknown viewer preference {key}.")
        if not len(prefs.keys()):
            del root["/ViewerPreferences"]
    return {"page_layout": text(root.get("/PageLayout")), "page_mode": text(root.get("/PageMode"))}


@op("linearize")
def linearize(ctx, enabled=True):
    """Fast Web View: linearize on save."""
    ctx.save_options["linearize"] = bool(enabled)
    return {"linearized": bool(enabled)}


# ------------------------------------------------------------- JavaScript

def _script(action):
    js = action.get("/JS")
    if isinstance(js, pikepdf.Stream):
        try:
            return js.read_bytes().decode("utf-8", "replace")
        except pikepdf.PdfError:
            return ""
    value = text(js) or ""
    if value.startswith("﻿"):
        value = value[1:]
    return value


def _js_actions(action, depth=0):
    """JavaScript actions in an action and its /Next chain."""
    if not isinstance(action, Dictionary) or depth > 32:
        return []
    found = [action] if action.get("/S") == Name.JavaScript else []
    nxt = action.get("/Next")
    for item in (nxt if isinstance(nxt, Array) else [nxt] if nxt is not None else []):
        found += _js_actions(item, depth + 1)
    return found


def _javascript_items(pdf):
    """[(id, location, name, event, page, action_holder, key)]"""
    items = []
    tree = pdf.Root.get("/Names", Dictionary()).get("/JavaScript")
    for key, action in name_tree_items(tree):
        for a in _js_actions(action):
            items.append((f"names:{key}", "document", key or "(unnamed)", None, None, a))
    open_action = pdf.Root.get("/OpenAction")
    for a in _js_actions(open_action):
        items.append(("open", "open_action", "Open action", "Open", None, a))
    catalog_aa = pdf.Root.get("/AA", Dictionary())
    events = {"/WC": "Will close", "/WS": "Will save", "/DS": "Did save", "/WP": "Will print", "/DP": "Did print"}
    for key in catalog_aa.keys():
        for a in _js_actions(catalog_aa[key]):
            items.append((f"catalog_aa:{key[1:]}", "document_action", events.get(key, key[1:]), key[1:], None, a))
    seen_fields = set()
    for page_index, page in enumerate(pdf.pages):
        aa = page.obj.get("/AA", Dictionary())
        for key in aa.keys():
            for a in _js_actions(aa[key]):
                items.append((f"page_aa:{page_index}:{key[1:]}", "page", "Page " + ("open" if key == "/O" else "close"),
                              key[1:], page_index, a))
        for annot_index, annot in enumerate(page.obj.get("/Annots", [])):
            if not isinstance(annot, Dictionary):
                continue
            subtype = text(annot.get("/Subtype")) or ""
            label = text(annot.get("/T")) or subtype[1:]
            if subtype == "/Widget":
                parent = annot
                while "/T" not in parent and isinstance(parent.get("/Parent"), Dictionary):
                    parent = parent.Parent
                label = _field_name(parent) or "Field"
            location = "field" if subtype == "/Widget" else "link" if subtype == "/Link" else "annotation"
            for a in _js_actions(annot.get("/A")):
                items.append((f"annot_a:{page_index}:{annot_index}", location, label, "Activate", page_index, a))
            aa = annot.get("/AA", Dictionary())
            for key in aa.keys():
                for a in _js_actions(aa[key]):
                    items.append((f"annot_aa:{page_index}:{annot_index}:{key[1:]}", location, label, key[1:], page_index, a))
            # Field-level (non-widget parent) actions.
            parent = annot.get("/Parent")
            while isinstance(parent, Dictionary) and parent.is_indirect and parent.objgen not in seen_fields:
                seen_fields.add(parent.objgen)
                aa = parent.get("/AA", Dictionary())
                for key in aa.keys():
                    for a in _js_actions(aa[key]):
                        items.append((f"field_aa:{oid(parent)}:{key[1:]}", "field", _field_name(parent) or "Field",
                                      key[1:], page_index, a))
                parent = parent.get("/Parent")
    return items


def _field_name(field):
    parts = []
    node = field
    depth = 0
    while isinstance(node, Dictionary) and depth < 32:
        if "/T" in node:
            parts.append(text(node.T))
        node = node.get("/Parent")
        depth += 1
    return ".".join(reversed(parts)) if parts else None


EVENTS = {"K": "Keystroke", "F": "Format", "V": "Validate", "C": "Calculate", "E": "Mouse enter", "X": "Mouse exit",
          "D": "Mouse down", "U": "Mouse up", "Fo": "Focus", "Bl": "Blur", "PO": "Page open", "PC": "Page close",
          "PV": "Page visible", "PI": "Page invisible", "O": "Page open", "Open": "Open", "Activate": "Activate"}


@query("document_javascript")
def document_javascript(ctx, max_chars=200000):
    items = []
    for ident, location, name, event, page, action in _javascript_items(ctx.pdf):
        script = _script(action)
        items.append({"id": ident, "location": location, "name": name, "event": EVENTS.get(event, event),
                      "page": page, "length": len(script), "script": script[:int(max_chars)]})
    return {"items": items, "count": len(items)}


def _strip_js(action, depth=0):
    """Remove JavaScript from an action chain; returns (replacement or None, removed)."""
    if not isinstance(action, Dictionary) or depth > 32:
        return action, 0
    removed = 0
    nxt = action.get("/Next")
    if nxt is not None:
        kept = []
        for item in (nxt if isinstance(nxt, Array) else [nxt]):
            replacement, count = _strip_js(item, depth + 1)
            removed += count
            if replacement is not None:
                kept.append(replacement)
        if kept:
            action.Next = kept[0] if len(kept) == 1 else Array(kept)
        elif "/Next" in action:
            del action["/Next"]
    if action.get("/S") == Name.JavaScript:
        removed += 1
        rest = action.get("/Next")
        return (rest if isinstance(rest, Dictionary) else rest[0] if isinstance(rest, Array) and len(rest) else None), removed
    return action, removed


def _remove_from(holder, key):
    if not isinstance(holder, Dictionary) or key not in holder:
        return 0
    replacement, removed = _strip_js(holder[key])
    if replacement is None:
        del holder[key]
    else:
        holder[key] = replacement
    return removed


@op("remove_javascript")
def remove_javascript(ctx, ids=None):
    """Delete scripts by inspector id (all scripts when ids is None)."""
    pdf = ctx.pdf
    current = {item[0] for item in _javascript_items(pdf)}
    targets = current if ids is None else {str(i) for i in ids}
    require(targets <= current, "STALE_OBJECT", "Some scripts no longer exist. Refresh the list.")
    removed = 0
    for ident in sorted(targets):
        kind, _, rest = ident.partition(":")
        if kind == "names":
            tree = names_tree(pdf, "/JavaScript")
            if tree is not None and rest in tree:
                del tree[rest]
                removed += 1
        elif kind == "open":
            removed += _remove_from(pdf.Root, "/OpenAction")
        elif kind == "catalog_aa":
            removed += _remove_from(pdf.Root.get("/AA"), "/" + rest)
        elif kind == "page_aa":
            page, event = rest.split(":")
            removed += _remove_from(pdf.pages[int(page)].obj.get("/AA"), "/" + event)
        elif kind in ("annot_a", "annot_aa"):
            parts = rest.split(":")
            annot = pdf.pages[int(parts[0])].obj.Annots[int(parts[1])]
            if kind == "annot_a":
                removed += _remove_from(annot, "/A")
            else:
                removed += _remove_from(annot.get("/AA"), "/" + parts[2])
        elif kind == "field_aa":
            ref, event = rest.rsplit(":", 1)
            from transforms.navigation import resolve_oid
            removed += _remove_from(resolve_oid(pdf, ref).get("/AA"), "/" + event)
    for holder in [pdf.Root] + [p.obj for p in pdf.pages]:
        aa = holder.get("/AA")
        if isinstance(aa, Dictionary) and not len(aa.keys()):
            del holder["/AA"]
    names = pdf.Root.get("/Names")
    if isinstance(names, Dictionary) and "/JavaScript" in names:
        if not any(True for _ in name_tree_items(names.JavaScript)):
            del names["/JavaScript"]
    return {"removed": removed}
