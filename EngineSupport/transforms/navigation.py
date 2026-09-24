"""Document navigation structures: bookmarks (outlines), named destinations,
embedded-file attachments, optional-content layers, article threads, 3D
annotations and a per-page content-object listing.

Queries return plain JSON; operations edit the working revision in place.
Object identities exposed to the app are `"o<num>_<gen>"` strings for
indirect objects so the app can round-trip them (e.g. layer ids).
"""
import base64
from datetime import datetime, timezone
import mimetypes
from pathlib import Path
import re

import pikepdf
from pikepdf import Array, Dictionary, Name, String

from engine.errors import EngineError, require
from transforms import op, query

MAX_OUTLINE_ITEMS = 20000


# ---------------------------------------------------------------- helpers

def oid(obj):
    if obj is not None and getattr(obj, "is_indirect", False):
        num, gen = obj.objgen
        return f"o{num}_{gen}"
    return None


def resolve_oid(pdf, ident):
    match = re.fullmatch(r"o(\d+)_(\d+)", str(ident or ""))
    require(match is not None, "INVALID_ARGUMENT", "Unknown object identifier.")
    try:
        obj = pdf.get_object(int(match.group(1)), int(match.group(2)))
    except (pikepdf.PdfError, ValueError) as exc:
        raise EngineError("STALE_OBJECT", "The item no longer exists in this document.") from exc
    require(obj is not None and not isinstance(obj, type(None)), "STALE_OBJECT",
            "The item no longer exists in this document.")
    return obj


def text(value):
    if value is None:
        return None
    try:
        return str(value)
    except (UnicodeDecodeError, ValueError):
        return bytes(value).decode("latin-1", "replace")


def page_index_map(pdf):
    return {page.obj.objgen: index for index, page in enumerate(pdf.pages)}


def number(value):
    try:
        return None if value is None or isinstance(value, Name) else float(value)
    except (TypeError, ValueError):
        return None


def pdf_date(value):
    """PDF date string -> ISO-8601 (or the raw string when unparseable)."""
    raw = text(value)
    if not raw:
        return None
    match = re.match(r"D?:?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?([Zz+\-])?(\d{2})?'?(\d{2})?", raw)
    if not match:
        return raw
    year, month, day, hour, minute, second, sign, tzh, tzm = match.groups()
    iso = f"{year}-{month or '01'}-{day or '01'}T{hour or '00'}:{minute or '00'}:{second or '00'}"
    if sign in ("Z", "z"):
        iso += "Z"
    elif sign in ("+", "-"):
        iso += f"{sign}{tzh or '00'}:{tzm or '00'}"
    return iso


def now_pdf_date():
    return datetime.now(timezone.utc).strftime("D:%Y%m%d%H%M%SZ")


def name_tree_items(node, seen=None):
    """Yield (key, value) pairs of a name tree, tolerating malformed nodes."""
    if node is None:
        return
    seen = seen if seen is not None else set()
    if getattr(node, "is_indirect", False):
        if node.objgen in seen:
            return
        seen.add(node.objgen)
    names = node.get("/Names")
    if isinstance(names, Array):
        for index in range(0, len(names) - 1, 2):
            yield text(names[index]), names[index + 1]
    kids = node.get("/Kids")
    if isinstance(kids, Array):
        for kid in kids:
            yield from name_tree_items(kid, seen)


def names_tree(pdf, key, create=False):
    root = pdf.Root
    if "/Names" not in root:
        if not create:
            return None
        root.Names = pdf.make_indirect(Dictionary())
    names = root.Names
    if key not in names:
        if not create:
            return None
        names[key] = pdf.make_indirect(Dictionary(Names=Array()))
    return pikepdf.NameTree(names[key])


# ------------------------------------------------------------ destinations

FITS = ("/XYZ", "/Fit", "/FitH", "/FitV", "/FitR", "/FitB", "/FitBH", "/FitBV")


def named_destinations(pdf):
    found = {}
    tree = pdf.Root.get("/Names", Dictionary()).get("/Dests")
    for key, value in name_tree_items(tree):
        if key is not None:
            found[key] = value
    legacy = pdf.Root.get("/Dests")
    if isinstance(legacy, Dictionary):
        for key in legacy.keys():
            found.setdefault(key[1:], legacy[key])
    return found


def explicit(dest):
    if isinstance(dest, Dictionary):
        dest = dest.get("/D")
    return dest if isinstance(dest, Array) and len(dest) >= 1 else None


def describe_destination(pdf, dest, pages=None, named=None):
    """Destination (array, name or string) -> {page, fit, left, top, zoom, name}."""
    pages = pages if pages is not None else page_index_map(pdf)
    result = {"page": None, "fit": None, "left": None, "top": None, "zoom": None, "name": None}
    if isinstance(dest, (Name, String)) or (dest is not None and not isinstance(dest, (Array, Dictionary))):
        key = text(dest)
        if isinstance(dest, Name):
            key = key[1:]
        result["name"] = key
        named = named if named is not None else named_destinations(pdf)
        dest = named.get(key)
    array = explicit(dest)
    if array is None:
        return result
    target = array[0]
    if isinstance(target, Dictionary) and target.is_indirect:
        result["page"] = pages.get(target.objgen)
    else:
        idx = number(target)
        if idx is not None and 0 <= int(idx) < len(pdf.pages):
            result["page"] = int(idx)
    if len(array) > 1 and isinstance(array[1], Name):
        fit = str(array[1])
        result["fit"] = fit[1:]
        params = [number(v) for v in list(array)[2:]]
        if fit == "/XYZ":
            result["left"], result["top"], result["zoom"] = (params + [None, None, None])[:3]
        elif fit in ("/FitH", "/FitBH"):
            result["top"] = params[0] if params else None
        elif fit in ("/FitV", "/FitBV"):
            result["left"] = params[0] if params else None
        elif fit == "/FitR" and len(params) >= 4:
            result["left"], result["top"] = params[0], params[3]
    return result


def make_destination(pdf, page, left=None, top=None, zoom=None, fit=None):
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "INVALID_PAGE", "Choose a page in this document.")
    target = pdf.pages[page].obj
    fit = (fit or ("XYZ" if top is not None or left is not None or zoom is not None else "Fit")).lstrip("/")
    require("/" + fit in FITS, "INVALID_ARGUMENT", "Unsupported destination view.")
    if fit == "XYZ":
        def value(v):
            return float(v) if v is not None else None
        return Array([target, Name.XYZ, value(left), value(top), value(zoom)])
    if fit in ("FitH", "FitBH"):
        return Array([target, Name("/" + fit), float(top) if top is not None else None])
    if fit in ("FitV", "FitBV"):
        return Array([target, Name("/" + fit), float(left) if left is not None else None])
    return Array([target, Name("/" + fit)])


@query("destinations")
def destinations_query(ctx):
    pdf = ctx.pdf
    pages = page_index_map(pdf)
    named = named_destinations(pdf)
    items = []
    for key in sorted(named, key=lambda k: (k or "").lower()):
        info = describe_destination(pdf, named[key], pages, named)
        info["name"] = key
        items.append(info)
    return {"items": items}


def _set_named(pdf, name, dest):
    legacy = pdf.Root.get("/Dests")
    if isinstance(legacy, Dictionary) and Name("/" + name) in legacy:
        legacy[Name("/" + name)] = dest
        return
    tree = names_tree(pdf, "/Dests", create=True)
    tree[name] = dest


def _remove_named(pdf, name):
    removed = False
    legacy = pdf.Root.get("/Dests")
    key = Name("/" + name)
    if isinstance(legacy, Dictionary) and key in legacy:
        del legacy[key]
        removed = True
    tree = names_tree(pdf, "/Dests")
    if tree is not None and name in tree:
        del tree[name]
        removed = True
    return removed


@op("add_destination")
def add_destination(ctx, name, page, left=None, top=None, zoom=None, fit=None, replace=False):
    name = str(name or "").strip()
    require(0 < len(name) <= 200, "INVALID_ARGUMENT", "Enter a destination name.")
    existing = named_destinations(ctx.pdf)
    require(replace or name not in existing, "DUPLICATE_NAME", f"A destination named “{name}” already exists.")
    _set_named(ctx.pdf, name, make_destination(ctx.pdf, page, left, top, zoom, fit))
    return {"name": name}


@op("remove_destinations")
def remove_destinations(ctx, names):
    require(isinstance(names, list) and names, "INVALID_ARGUMENT", "Choose destinations to delete.")
    count = sum(1 for name in names if _remove_named(ctx.pdf, str(name)))
    require(count > 0, "STALE_OBJECT", "Those destinations no longer exist.")
    return {"removed": count}


def _rewrite_dest_references(pdf, old, new):
    """Point outline items, link annotations and GoTo actions at a renamed dest."""
    changed = 0

    def fix(holder, key):
        nonlocal changed
        value = holder.get(key)
        if isinstance(value, (String, Name)):
            current = text(value)[1:] if isinstance(value, Name) else text(value)
            if current == old:
                holder[key] = String(new)
                changed += 1

    def fix_action(action, depth=0):
        if not isinstance(action, Dictionary) or depth > 32:
            return
        if action.get("/S") in (Name.GoTo,):
            fix(action, "/D")
        nxt = action.get("/Next")
        if isinstance(nxt, Dictionary):
            fix_action(nxt, depth + 1)
        elif isinstance(nxt, Array):
            for item in nxt:
                fix_action(item, depth + 1)

    for item in _walk_outline_dicts(pdf):
        fix(item, "/Dest")
        fix_action(item.get("/A"))
    for page in pdf.pages:
        for annot in page.obj.get("/Annots", []):
            fix(annot, "/Dest")
            fix_action(annot.get("/A"))
    fix_action(pdf.Root.get("/OpenAction"))
    return changed


@op("rename_destination")
def rename_destination(ctx, old, new):
    old, new = str(old), str(new or "").strip()
    require(0 < len(new) <= 200, "INVALID_ARGUMENT", "Enter a destination name.")
    named = named_destinations(ctx.pdf)
    require(old in named, "STALE_OBJECT", "That destination no longer exists.")
    require(new == old or new not in named, "DUPLICATE_NAME", f"A destination named “{new}” already exists.")
    if new == old:
        return {"name": new, "references": 0}
    dest = named[old]
    _remove_named(ctx.pdf, old)
    _set_named(ctx.pdf, new, dest)
    return {"name": new, "references": _rewrite_dest_references(ctx.pdf, old, new)}


# ---------------------------------------------------------------- outlines

def _walk_outline_dicts(pdf):
    outlines = pdf.Root.get("/Outlines")
    if not isinstance(outlines, Dictionary):
        return
    seen = set()
    stack = [outlines.get("/First")]
    while stack:
        node = stack.pop()
        while isinstance(node, Dictionary):
            key = node.objgen if node.is_indirect else id(node)
            if key in seen or len(seen) > MAX_OUTLINE_ITEMS:
                break
            seen.add(key)
            yield node
            if "/First" in node:
                stack.append(node.First)
            node = node.get("/Next")


def _outline_nodes(pdf, first, pages, named, seen, budget):
    items = []
    node = first
    while isinstance(node, Dictionary) and budget[0] > 0:
        key = node.objgen if node.is_indirect else id(node)
        if key in seen:
            break
        seen.add(key)
        budget[0] -= 1
        dest = node.get("/Dest")
        action = node.get("/A")
        uri = None
        action_type = None
        if dest is None and isinstance(action, Dictionary):
            action_type = text(action.get("/S"))
            if action.get("/S") == Name.GoTo:
                dest = action.get("/D")
            elif action.get("/S") == Name.URI:
                uri = text(action.get("/URI"))
        info = describe_destination(pdf, dest, pages, named) if dest is not None else \
            {"page": None, "fit": None, "left": None, "top": None, "zoom": None, "name": None}
        count = int(node.get("/Count", 0) or 0)
        flags = int(node.get("/F", 0) or 0)
        color = node.get("/C")
        items.append({
            "ref": oid(node),
            "title": text(node.get("/Title")) or "",
            "page": info["page"], "fit": info["fit"], "left": info["left"], "top": info["top"],
            "zoom": info["zoom"], "dest_name": info["name"], "uri": uri,
            "action": action_type[1:] if action_type else None,
            "open": count > 0,
            "italic": bool(flags & 1), "bold": bool(flags & 2),
            "color": [round(float(c) * 255) for c in color] if isinstance(color, Array) and len(color) == 3 else None,
            "children": _outline_nodes(pdf, node.get("/First"), pages, named, seen, budget) if "/First" in node else [],
        })
        node = node.get("/Next")
    return items


@query("outline")
def outline_query(ctx):
    pdf = ctx.pdf
    outlines = pdf.Root.get("/Outlines")
    if not isinstance(outlines, Dictionary):
        return {"items": [], "count": 0}
    budget = [MAX_OUTLINE_ITEMS]
    items = _outline_nodes(pdf, outlines.get("/First"), page_index_map(pdf), named_destinations(pdf), set(), budget)
    return {"items": items, "count": MAX_OUTLINE_ITEMS - budget[0], "truncated": budget[0] <= 0}


def _build_items(pdf, parent, specs, originals, depth=0):
    """Create linked outline dictionaries for `specs`; returns (first, last, visible_count)."""
    require(depth < 64, "INVALID_ARGUMENT", "Bookmarks are nested too deeply.")
    built = []
    for spec in specs:
        require(isinstance(spec, dict), "INVALID_ARGUMENT", "Invalid bookmark.")
        title = str(spec.get("title") or "").strip() or "Untitled"
        item = pdf.make_indirect(Dictionary(Title=String(title[:4000]), Parent=parent))
        original = originals.get(spec.get("ref")) if spec.get("ref") else None
        if spec.get("uri"):
            item.A = Dictionary(S=Name.URI, URI=String(str(spec["uri"])))
        elif spec.get("page") is not None:
            item.Dest = make_destination(pdf, int(spec["page"]), spec.get("left"), spec.get("top"),
                                         spec.get("zoom"), spec.get("fit"))
        elif spec.get("dest_name"):
            item.Dest = String(str(spec["dest_name"]))
        elif original is not None:
            # Keep an action the app does not model (JavaScript, Launch, GoToR...).
            for key in ("/Dest", "/A", "/SE"):
                if key in original:
                    item[key] = original[key]
        color = spec.get("color")
        if isinstance(color, list) and len(color) == 3:
            item.C = Array([max(0.0, min(1.0, float(c) / 255)) for c in color])
        flags = (1 if spec.get("italic") else 0) | (2 if spec.get("bold") else 0)
        if flags:
            item.F = flags
        children = spec.get("children") or []
        if children:
            first, last, count = _build_items(pdf, item, children, originals, depth + 1)
            item.First, item.Last = first, last
            item.Count = count if spec.get("open") else -count
        built.append((item, children, spec.get("open")))
    for index, (item, _, _) in enumerate(built):
        if index > 0:
            item.Prev = built[index - 1][0]
        if index + 1 < len(built):
            item.Next = built[index + 1][0]
    visible = 0
    for item, children, is_open in built:
        visible += 1
        if children and is_open:
            visible += int(item.Count)
    return (built[0][0] if built else None, built[-1][0] if built else None, visible)


def count_items(specs):
    return sum(1 + count_items(s.get("children") or []) for s in specs)


@op("set_outline")
def set_outline(ctx, items):
    """Replace the whole bookmark tree with `items` (the `outline` query shape)."""
    require(isinstance(items, list), "INVALID_ARGUMENT", "Invalid bookmarks.")
    require(count_items(items) <= MAX_OUTLINE_ITEMS, "INVALID_ARGUMENT", "Too many bookmarks.")
    pdf = ctx.pdf
    originals = {oid(node): node for node in _walk_outline_dicts(pdf)}
    if not items:
        if "/Outlines" in pdf.Root:
            del pdf.Root["/Outlines"]
        if pdf.Root.get("/PageMode") == Name.UseOutlines:
            del pdf.Root["/PageMode"]
        return {"count": 0}
    root = pdf.make_indirect(Dictionary(Type=Name.Outlines))
    first, last, visible = _build_items(pdf, root, items, originals)
    root.First, root.Last, root.Count = first, last, visible
    pdf.Root.Outlines = root
    return {"count": count_items(items)}


# ------------------------------------------------------- headings -> outline

def _page_lines(pdf_page, textpage):
    """Group characters into visual lines: [(text, size, bold, top, left)]."""
    import pypdfium2.raw as raw
    count = textpage.count_chars()
    lines = []
    import ctypes
    current = None
    buffer = ctypes.create_string_buffer(256)
    flags = ctypes.c_int(0)
    for index in range(count):
        char = raw.FPDFText_GetUnicode(textpage.raw, index)
        if char in (0xFFFE, 0xFFFF):
            continue
        ch = chr(char) if char else ""
        if ch in ("\r", "\n"):
            if current:
                lines.append(current)
            current = None
            continue
        size = raw.FPDFText_GetFontSize(textpage.raw, index)
        try:
            left, bottom, right, top = textpage.get_charbox(index)
        except Exception:
            continue
        name_len = raw.FPDFText_GetFontInfo(textpage.raw, index, buffer, 256, ctypes.byref(flags))
        font = buffer.value.decode("utf-8", "replace") if name_len else ""
        bold = "bold" in font.lower() or "black" in font.lower() or "heavy" in font.lower() or int(raw.FPDFText_GetFontWeight(textpage.raw, index)) >= 600
        if current is None or abs(current["baseline"] - bottom) > max(2.0, size * 0.5):
            if current:
                lines.append(current)
            current = {"text": "", "sizes": [], "bold": [], "top": top, "left": left, "baseline": bottom}
        current["text"] += ch
        if not ch.isspace():
            current["sizes"].append(size)
            current["bold"].append(bold)
        current["top"] = max(current["top"], top)
        current["left"] = min(current["left"], left)
    if current:
        lines.append(current)
    result = []
    for line in lines:
        value = re.sub(r"\s+", " ", line["text"]).strip()
        if not value or not line["sizes"]:
            continue
        sizes = sorted(line["sizes"])
        result.append((value, sizes[len(sizes) // 2], sum(line["bold"]) > len(line["bold"]) / 2, line["top"], line["left"]))
    return result


def detect_headings(ctx, ratio=1.15, max_levels=3, max_headings=400, pages=None):
    """Font-size heuristic: lines noticeably larger than body text are headings.

    Distinct heading sizes (rounded to 0.5pt), largest first, become levels
    1..max_levels; bold body-size lines are not used (too noisy). Returns
    [(page, level, title, top, left)] in reading order.
    """
    samples = []
    per_page = []
    with ctx.pdfium() as doc:
        indexes = range(len(doc)) if pages is None else pages
        for index in indexes:
            page = doc[index]
            textpage = page.get_textpage()
            try:
                lines = _page_lines(page, textpage)
            finally:
                textpage.close()
                page.close()
            per_page.append((index, lines))
            for value, size, _, _, _ in lines:
                samples.extend([round(size, 1)] * max(1, len(value)))
    if not samples:
        return []
    samples.sort()
    body = samples[len(samples) // 2]
    candidates = []
    for index, lines in per_page:
        for value, size, bold, top, left in lines:
            if size < body * ratio or len(value) < 2 or len(value) > 160:
                continue
            if re.fullmatch(r"[\d\W_]+", value):
                continue
            candidates.append((index, round(size * 2) / 2, value, top, left, bold))
    if not candidates:
        return []
    levels = sorted({c[1] for c in candidates}, reverse=True)[:max_levels]
    headings = []
    for index, size, value, top, left, _ in candidates:
        if size not in levels:
            # Smaller than the chosen levels: attach to the deepest level.
            if size < levels[-1]:
                continue
        level = levels.index(size) + 1 if size in levels else len(levels)
        # Merge consecutive lines of the same heading (wrapped titles).
        if headings and headings[-1][0] == index and headings[-1][1] == level and \
                0 < headings[-1][3] - top < size * 1.6:
            prev = headings[-1]
            headings[-1] = (prev[0], prev[1], prev[2] + " " + value, prev[3], prev[4])
            continue
        headings.append((index, level, value, top, left))
    return headings[:max_headings]


def headings_to_tree(headings, pad=6.0):
    root = []
    stack = []  # (level, children list)
    for page, level, title, top, left in headings:
        node = {"title": title, "page": page, "top": top + pad, "left": max(0.0, left - pad), "zoom": None,
                "open": level == 1, "children": []}
        while stack and stack[-1][0] >= level:
            stack.pop()
        (stack[-1][1] if stack else root).append(node)
        stack.append((level, node["children"]))
    return root


@query("detect_headings")
def detect_headings_query(ctx, ratio=1.15, max_levels=3):
    headings = detect_headings(ctx, ratio, max_levels)
    return {"items": [{"page": p, "level": lv, "title": t, "top": top, "left": left}
                      for p, lv, t, top, left in headings]}


@op("outline_from_headings")
def outline_from_headings(ctx, ratio=1.15, max_levels=3, replace=True):
    headings = detect_headings(ctx, float(ratio), int(max_levels))
    require(headings, "NO_HEADINGS", "No headings were found. Headings are detected from text that is larger than the body text.")
    tree = headings_to_tree(headings)
    if not replace:
        existing = outline_query(ctx)["items"]
        tree = existing + tree
    set_outline(ctx, tree)
    return {"added": len(headings)}


# ------------------------------------------------------------- attachments

def _filespec_info(name, spec):
    info = {"name": name, "filename": None, "description": None, "size": None, "mime": None,
            "created": None, "modified": None}
    if not isinstance(spec, Dictionary):
        return info
    info["filename"] = text(spec.get("/UF") or spec.get("/F")) or name
    info["description"] = text(spec.get("/Desc"))
    ef = spec.get("/EF")
    stream = ef.get("/UF") or ef.get("/F") if isinstance(ef, Dictionary) else None
    if isinstance(stream, pikepdf.Stream):
        params = stream.get("/Params", Dictionary())
        size = params.get("/Size")
        info["size"] = int(size) if size is not None else None
        info["created"] = pdf_date(params.get("/CreationDate"))
        info["modified"] = pdf_date(params.get("/ModDate"))
        subtype = stream.get("/Subtype")
        info["mime"] = text(subtype)[1:].replace("#2F", "/") if isinstance(subtype, Name) else None
    return info


def _embedded_stream(spec):
    ef = spec.get("/EF") if isinstance(spec, Dictionary) else None
    stream = (ef.get("/UF") or ef.get("/F")) if isinstance(ef, Dictionary) else None
    return stream if isinstance(stream, pikepdf.Stream) else None


def _annotation_attachments(pdf):
    for page_index, page in enumerate(pdf.pages):
        for annot_index, annot in enumerate(page.obj.get("/Annots", [])):
            if annot.get("/Subtype") == Name.FileAttachment and isinstance(annot.get("/FS"), Dictionary):
                yield page_index, annot_index, annot


@query("attachments")
def attachments_query(ctx):
    pdf = ctx.pdf
    items = []
    tree = pdf.Root.get("/Names", Dictionary()).get("/EmbeddedFiles")
    for key, spec in name_tree_items(tree):
        info = _filespec_info(key, spec)
        info.update({"id": "tree:" + (key or ""), "page": None})
        if info["size"] is None:
            stream = _embedded_stream(spec)
            if stream is not None:
                try:
                    info["size"] = len(stream.read_bytes())
                except pikepdf.PdfError:
                    pass
        items.append(info)
    for page_index, annot_index, annot in _annotation_attachments(pdf):
        info = _filespec_info(text(annot.FS.get("/UF") or annot.FS.get("/F")) or "attachment", annot.FS)
        info.update({"id": f"annot:{page_index}:{annot_index}", "page": page_index,
                     "description": info["description"] or text(annot.get("/Contents"))})
        items.append(info)
    return {"items": items}


def _find_attachment(pdf, ident):
    ident = str(ident)
    if ident.startswith("annot:"):
        _, page, index = ident.split(":")
        annots = pdf.pages[int(page)].obj.get("/Annots", [])
        require(int(index) < len(annots), "STALE_OBJECT", "That attachment no longer exists.")
        return annots[int(index)].FS
    key = ident[5:] if ident.startswith("tree:") else ident
    tree = pdf.Root.get("/Names", Dictionary()).get("/EmbeddedFiles")
    for name, spec in name_tree_items(tree):
        if name == key:
            return spec
    raise EngineError("STALE_OBJECT", "That attachment no longer exists.")


@query("attachment_data")
def attachment_data(ctx, id, max_bytes=512 * 1024 * 1024):
    spec = _find_attachment(ctx.pdf, id)
    stream = _embedded_stream(spec)
    require(stream is not None, "NO_DATA", "This attachment has no embedded data.")
    data = stream.read_bytes()
    require(len(data) <= int(max_bytes), "TOO_LARGE", "This attachment is too large to extract.")
    return {"filename": text(spec.get("/UF") or spec.get("/F")) or "attachment",
            "size": len(data), "data": base64.b64encode(data).decode("ascii")}


@op("add_attachment")
def add_attachment(ctx, path, name=None, description="", mime=None):
    source = Path(path)
    require(source.is_file(), "MISSING_INPUT", "The file to attach could not be read.")
    data = source.read_bytes()
    require(len(data) <= 512 * 1024 * 1024, "TOO_LARGE", "Files larger than 512 MB cannot be attached.")
    pdf = ctx.pdf
    filename = str(name or source.name).strip() or source.name
    existing = {k for k, _ in name_tree_items(pdf.Root.get("/Names", Dictionary()).get("/EmbeddedFiles"))}
    key = filename
    counter = 2
    while key in existing:
        stem, dot, ext = filename.rpartition(".")
        key = f"{stem or ext} ({counter}){dot}{ext if stem else ''}"
        counter += 1
    stat = source.stat()
    stream = pikepdf.Stream(pdf, data)
    stream.Type = Name.EmbeddedFile
    mime = mime or mimetypes.guess_type(filename)[0]
    if mime:
        stream.Subtype = Name("/" + mime.replace("/", "#2F"))
    stream.Params = Dictionary(Size=len(data), ModDate=datetime.fromtimestamp(stat.st_mtime, timezone.utc).strftime("D:%Y%m%d%H%M%SZ"),
                               CreationDate=now_pdf_date())
    spec = pdf.make_indirect(Dictionary(Type=Name.Filespec, F=String(key), UF=String(key),
                                        EF=Dictionary(F=stream, UF=stream)))
    if description:
        spec.Desc = String(str(description))
    tree = names_tree(pdf, "/EmbeddedFiles", create=True)
    tree[key] = spec
    return {"name": key, "size": len(data)}


@op("remove_attachments")
def remove_attachments(ctx, ids):
    require(isinstance(ids, list) and ids, "INVALID_ARGUMENT", "Choose attachments to delete.")
    pdf = ctx.pdf
    removed = 0
    annot_targets = {}
    for ident in ids:
        ident = str(ident)
        if ident.startswith("annot:"):
            _, page, index = ident.split(":")
            annot_targets.setdefault(int(page), set()).add(int(index))
            continue
        key = ident[5:] if ident.startswith("tree:") else ident
        tree = names_tree(pdf, "/EmbeddedFiles")
        require(tree is not None and key in tree, "STALE_OBJECT", "That attachment no longer exists.")
        del tree[key]
        removed += 1
    for page, indexes in annot_targets.items():
        annots = pdf.pages[page].obj.get("/Annots")
        require(annots is not None and max(indexes) < len(annots), "STALE_OBJECT", "That attachment no longer exists.")
        doomed = {annots[i].objgen for i in indexes if annots[i].is_indirect}
        kept = [a for i, a in enumerate(annots) if i not in indexes and not
                (a.get("/Subtype") == Name.Popup and a.get("/Parent") is not None and a.Parent.is_indirect and a.Parent.objgen in doomed)]
        removed += len(annots) - len(kept)
        pdf.pages[page].obj.Annots = Array(kept)
    return {"removed": removed}


@op("describe_attachment")
def describe_attachment(ctx, id, description):
    spec = _find_attachment(ctx.pdf, id)
    if description:
        spec.Desc = String(str(description))
    elif "/Desc" in spec:
        del spec["/Desc"]
    return {"id": id}


# ----------------------------------------------------------------- layers

def _oc_config(pdf):
    props = pdf.Root.get("/OCProperties")
    if not isinstance(props, Dictionary):
        return None, None
    return props, props.get("/D") if isinstance(props.get("/D"), Dictionary) else None


def layer_states(pdf):
    """{objgen: visible} for every OCG under the default configuration."""
    props, config = _oc_config(pdf)
    if props is None:
        return {}
    base_on = config is None or config.get("/BaseState", Name.ON) != Name.OFF
    states = {}
    for ocg in props.get("/OCGs", []):
        if isinstance(ocg, Dictionary) and ocg.is_indirect:
            states[ocg.objgen] = base_on
    if config is not None:
        for key, value in (("/ON", True), ("/OFF", False)):
            for ocg in config.get(key, []):
                if isinstance(ocg, Dictionary) and ocg.is_indirect:
                    states[ocg.objgen] = value
    return states


@query("layers")
def layers_query(ctx):
    pdf = ctx.pdf
    props, config = _oc_config(pdf)
    if props is None:
        return {"items": [], "has_layers": False}
    states = layer_states(pdf)
    locked = {o.objgen for o in (config.get("/Locked", []) if config is not None else []) if isinstance(o, Dictionary) and o.is_indirect}
    items = []
    listed = set()

    def entry(ocg, depth, parent_label=None):
        listed.add(ocg.objgen)
        usage = ocg.get("/Usage", Dictionary())
        printing = usage.get("/Print", Dictionary()).get("/PrintState") if isinstance(usage, Dictionary) else None
        items.append({"id": oid(ocg), "name": text(ocg.get("/Name")) or "Untitled layer",
                      "visible": states.get(ocg.objgen, True), "locked": ocg.objgen in locked, "depth": depth,
                      "group": parent_label, "prints": None if printing is None else printing == Name.ON,
                      "kind": "layer"})

    def walk(order, depth, label=None):
        if not isinstance(order, Array) or depth > 32:
            return
        for element in order:
            if isinstance(element, Array):
                if len(element) and isinstance(element[0], String):
                    items.append({"id": None, "name": text(element[0]), "visible": None, "locked": False,
                                  "depth": depth, "group": label, "prints": None, "kind": "label"})
                    walk(Array(list(element)[1:]), depth + 1, text(element[0]))
                else:
                    walk(element, depth + 1, label)
            elif isinstance(element, Dictionary) and element.is_indirect and element.objgen not in listed:
                entry(element, depth, label)

    if config is not None:
        walk(config.get("/Order"), 0)
    for ocg in props.get("/OCGs", []):
        if isinstance(ocg, Dictionary) and ocg.is_indirect and ocg.objgen not in listed:
            entry(ocg, 0)
    return {"items": items, "has_layers": True, "config_name": text(config.get("/Name")) if config is not None else None}


@op("set_layer_visibility")
def set_layer_visibility(ctx, states):
    """Change the default configuration's ON/OFF state (what viewers show on open)."""
    require(isinstance(states, dict) and states, "INVALID_ARGUMENT", "Choose layers to change.")
    pdf = ctx.pdf
    props, config = _oc_config(pdf)
    require(props is not None, "NO_LAYERS", "This document has no layers.")
    if config is None:
        config = props.D = Dictionary()
    current = layer_states(pdf)
    for ident, visible in states.items():
        ocg = resolve_oid(pdf, ident)
        require(ocg.objgen in current, "STALE_OBJECT", "That layer no longer exists.")
        current[ocg.objgen] = bool(visible)
    ocgs = [o for o in props.get("/OCGs", []) if isinstance(o, Dictionary) and o.is_indirect]
    config.BaseState = Name.ON
    config.ON = Array([o for o in ocgs if current.get(o.objgen, True)])
    config.OFF = Array([o for o in ocgs if not current.get(o.objgen, True)])
    return {"changed": len(states)}


def _ocmd_visible(ocmd, states, depth=0):
    if not isinstance(ocmd, Dictionary) or depth > 16:
        return True
    if ocmd.get("/Type") == Name.OCG or "/OCGs" not in ocmd:
        return states.get(ocmd.objgen, True) if ocmd.is_indirect else True
    groups = ocmd.OCGs
    groups = list(groups) if isinstance(groups, Array) else [groups]
    values = [states.get(g.objgen, True) for g in groups if isinstance(g, Dictionary) and g.is_indirect]
    if not values:
        return True
    policy = ocmd.get("/P", Name.AnyOn)
    if policy == Name.AllOn:
        return all(values)
    if policy == Name.AnyOff:
        return not all(values)
    if policy == Name.AllOff:
        return not any(values)
    return any(values)


_SHOW = {"Tj", "TJ"}
_PAINT = {"S", "s", "f", "F", "f*", "B", "B*", "b", "b*"}


def _flatten_stream(pdf, holder, states, visited):
    """Drop hidden optional content from one content stream; keep visible content untagged."""
    resources = holder.get("/Resources", Dictionary()) if isinstance(holder, Dictionary) else Dictionary()
    properties = resources.get("/Properties", Dictionary())
    xobjects = resources.get("/XObject", Dictionary())
    try:
        instructions = pikepdf.parse_content_stream(holder)
    except pikepdf.PdfError:
        return 0
    out = []
    stack = []  # (is_oc, hidden)
    dropped = 0
    changed = False

    def hidden():
        return any(h for _, h in stack)

    for instruction in instructions:
        if isinstance(instruction, pikepdf.ContentStreamInlineImage):
            if hidden():
                dropped += 1
                changed = True
            else:
                out.append(instruction)
            continue
        operands, operator = instruction.operands, str(instruction.operator)
        if operator in ("BDC", "BMC"):
            is_oc = operator == "BDC" and len(operands) >= 2 and operands[0] == Name.OC
            if is_oc:
                target = operands[1]
                if isinstance(target, Name):
                    target = properties.get(target)
                stack.append((True, not _ocmd_visible(target, states)))
                changed = True
                continue
            stack.append((False, False))
            if not hidden():
                out.append(instruction)
            continue
        if operator == "EMC":
            if stack:
                is_oc, _ = stack.pop()
                if is_oc:
                    continue
            if not hidden():
                out.append(instruction)
            continue
        if hidden():
            # Hidden content keeps its graphics-state effects but paints nothing.
            if operator in _SHOW or operator in ("Do", "sh"):
                dropped += 1
                changed = True
                continue
            if operator == "'":
                out.append(pikepdf.ContentStreamInstruction([], pikepdf.Operator("T*")))
                dropped += 1
                changed = True
                continue
            if operator == '"':
                out.append(pikepdf.ContentStreamInstruction([operands[0]], pikepdf.Operator("Tw")))
                out.append(pikepdf.ContentStreamInstruction([operands[1]], pikepdf.Operator("Tc")))
                out.append(pikepdf.ContentStreamInstruction([], pikepdf.Operator("T*")))
                dropped += 1
                changed = True
                continue
            if operator in _PAINT:
                out.append(pikepdf.ContentStreamInstruction([], pikepdf.Operator("n")))
                dropped += 1
                changed = True
                continue
        if operator == "Do" and operands and isinstance(xobjects, Dictionary):
            xobj = xobjects.get(operands[0])
            if isinstance(xobj, pikepdf.Stream):
                if "/OC" in xobj and not _ocmd_visible(xobj.OC, states):
                    dropped += 1
                    changed = True
                    continue
                if "/OC" in xobj:
                    del xobj["/OC"]
                if xobj.get("/Subtype") == Name.Form and xobj.objgen not in visited:
                    visited.add(xobj.objgen)
                    dropped += _flatten_stream(pdf, xobj, states, visited)
        out.append(instruction)
    if changed:
        data = pikepdf.unparse_content_stream(out)
        if isinstance(holder, pikepdf.Stream):
            holder.write(data)
        else:
            holder.Contents = pdf.make_stream(data)
    return dropped


@op("flatten_layers")
def flatten_layers(ctx):
    """Merge visible layers into page content, discard hidden ones, remove /OCProperties."""
    pdf = ctx.pdf
    props, _ = _oc_config(pdf)
    require(props is not None, "NO_LAYERS", "This document has no layers.")
    states = layer_states(pdf)
    visited = set()
    dropped = 0
    removed_annots = 0
    for page in pdf.pages:
        dropped += _flatten_stream(pdf, page.obj, states, visited)
        annots = page.obj.get("/Annots")
        if annots is not None:
            kept = []
            for annot in annots:
                if "/OC" in annot:
                    if not _ocmd_visible(annot.OC, states):
                        removed_annots += 1
                        continue
                    del annot["/OC"]
                kept.append(annot)
            page.obj.Annots = Array(kept)
            for annot in kept:
                ap = annot.get("/AP")
                if isinstance(ap, Dictionary):
                    for key in ap.keys():
                        stream = ap[key]
                        if isinstance(stream, pikepdf.Stream) and stream.objgen not in visited:
                            visited.add(stream.objgen)
                            dropped += _flatten_stream(pdf, stream, states, visited)
    del pdf.Root["/OCProperties"]
    return {"layers": len(states), "dropped": dropped, "removed_annotations": removed_annots}


# --------------------------------------------------------------- articles

@query("articles")
def articles_query(ctx):
    pdf = ctx.pdf
    pages = page_index_map(pdf)
    threads = []
    for index, thread in enumerate(pdf.Root.get("/Threads", [])):
        if not isinstance(thread, Dictionary):
            continue
        info = thread.get("/I", Dictionary())
        beads = []
        bead = thread.get("/F")
        seen = set()
        while isinstance(bead, Dictionary) and len(beads) < 5000:
            key = bead.objgen if bead.is_indirect else id(bead)
            if key in seen:
                break
            seen.add(key)
            page = bead.get("/P")
            rect = bead.get("/R")
            beads.append({"page": pages.get(page.objgen) if isinstance(page, Dictionary) and page.is_indirect else None,
                          "rect": [float(v) for v in rect] if isinstance(rect, Array) and len(rect) == 4 else None})
            bead = bead.get("/N")
        threads.append({"index": index, "title": text(info.get("/Title")) or f"Article {index + 1}",
                        "author": text(info.get("/Author")), "subject": text(info.get("/Subject")), "beads": beads})
    return {"threads": threads}


@query("models_3d")
def models_3d_query(ctx):
    items = []
    for page_index, page in enumerate(ctx.pdf.pages):
        for annot in page.obj.get("/Annots", []):
            subtype = annot.get("/Subtype")
            if subtype not in (Name("/3D"), Name.RichMedia):
                continue
            stream = annot.get("/3DD")
            fmt = None
            views = []
            if isinstance(stream, pikepdf.Stream):
                fmt = text(stream.get("/Subtype"))
                for view in stream.get("/VA", []):
                    if isinstance(view, Dictionary):
                        views.append(text(view.get("/XN") or view.get("/IN")) or "View")
            if subtype == Name.RichMedia:
                fmt = "RichMedia"
            rect = annot.get("/Rect")
            items.append({"page": page_index, "subtype": text(subtype)[1:],
                          "name": text(annot.get("/Contents") or annot.get("/T") or annot.get("/NM")) or "3D model",
                          "format": fmt[1:] if fmt and fmt.startswith("/") else fmt, "views": views,
                          "rect": [float(v) for v in rect] if isinstance(rect, Array) else None})
    return {"items": items}


@query("content_objects")
def content_objects_query(ctx, page, limit=600):
    """Top-level page objects in content order (the Content panel's tree)."""
    import pypdfium2.raw as raw
    kinds = {1: "text", 2: "path", 3: "image", 4: "shading", 5: "form"}
    objects = []
    total = 0
    with ctx.pdfium() as doc:
        require(0 <= int(page) < len(doc), "INVALID_PAGE", "Choose a page in this document.")
        pdf_page = doc[int(page)]
        textpage = pdf_page.get_textpage()
        try:
            for obj in pdf_page.get_objects(max_depth=1):
                total += 1
                if len(objects) >= int(limit):
                    continue
                kind = kinds.get(obj.type, "other")
                try:
                    left, bottom, right, top = obj.get_pos()
                except Exception:
                    left = bottom = right = top = 0.0
                entry = {"type": kind, "rect": [left, bottom, right, top], "text": None}
                if kind == "text":
                    size = raw.FPDFTextObj_GetText(obj.raw, textpage.raw, None, 0)
                    if size > 2:
                        import ctypes
                        buffer = ctypes.create_string_buffer(size)
                        raw.FPDFTextObj_GetText(obj.raw, textpage.raw, ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ushort)), size)
                        entry["text"] = buffer.raw[:size - 2].decode("utf-16-le", "replace")[:120]
                objects.append(entry)
        finally:
            textpage.close()
            pdf_page.close()
    return {"page": int(page), "objects": objects, "total": total}
