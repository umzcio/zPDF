"""Sanitize: remove hidden information, scripts and other active content.

Categories (each a keyword of the `sanitize` op; the same names are counted by
the read-only `sanitize_scan` query):

* metadata       - the document Info dictionary, XMP /Metadata streams on any
                   object, /PieceInfo, page /Thumb thumbnails, /SpiderInfo.
* embedded_files - the /EmbeddedFiles name tree, FileAttachment annotations,
                   /AF associated-file arrays, portfolio /Collection.
* javascript     - the /JavaScript name tree, /AA additional actions on every
                   object, JavaScript/Launch/ImportData/SubmitForm/ResetForm/
                   Rendition/Sound/Movie actions (also inside /Next chains) on
                   the open action, annotations and bookmarks, and /XFA.
                   A link left without any action is removed.
* hidden_layers  - content of optional-content groups that are OFF by default
                   (page and form content, XObjects and annotations); then the
                   layer structure itself, so what remains always shows.
* hidden_text    - delegated to transforms.interpret (0 when unavailable).
* private_data   - leftover /PieceInfo and /LastModified keys on any object.
* bookmarks      - the outline tree.
* comments       - every annotation except widgets and links (popups too).
* form_fields    - widget appearances are drawn into the page, widgets and
                   the /AcroForm dictionary are removed.
* links          - Link annotations.
"""
import pikepdf
from pikepdf import Name

from transforms import op, query

DANGEROUS = {"/JavaScript", "/Launch", "/ImportData", "/SubmitForm", "/ResetForm", "/Rendition",
             "/Sound", "/Movie"}
PAINT_PATH = {"S", "s", "f", "F", "f*", "B", "B*", "b", "b*"}
KEEPS = ("/Widget", "/Link")


# ---------------------------------------------------------------- helpers

def _is_dict(obj):
    return isinstance(obj, (pikepdf.Dictionary, pikepdf.Stream))


def _walk(pdf):
    """Every dictionary and stream reachable from the trailer (each once)."""
    seen, found = set(), []
    stack = [pdf.trailer]
    while stack:
        obj = stack.pop()
        if isinstance(obj, pikepdf.Array):
            stack.extend(item for item in obj if isinstance(item, (pikepdf.Array, pikepdf.Dictionary, pikepdf.Stream)))
            continue
        if not _is_dict(obj):
            continue
        if obj.is_indirect:
            if obj.objgen in seen:
                continue
            seen.add(obj.objgen)
        found.append(obj)
        for key in list(obj.keys()):
            if key == "/Encrypt":
                continue
            try:
                value = obj[key]
            except (KeyError, pikepdf.PdfError):
                continue
            if isinstance(value, (pikepdf.Array, pikepdf.Dictionary, pikepdf.Stream)):
                stack.append(value)
    return found


def _strip_keys(pdf, keys, apply):
    count = 0
    for obj in _walk(pdf):
        for key in keys:
            if key in obj:
                count += 1
                if apply:
                    del obj[key]
    return count


def _annots(pdf):
    """(page number, index, annot) for every annotation dictionary."""
    for number, page in enumerate(pdf.pages):
        for index, annot in enumerate(page.obj.get("/Annots", [])):
            if isinstance(annot, pikepdf.Dictionary):
                yield number, index, annot


def _remove_annots(pdf, predicate, apply):
    """Remove annotations matching `predicate` (and their popups)."""
    count = 0
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if not isinstance(annots, pikepdf.Array):
            continue
        doomed = set()
        for i, annot in enumerate(annots):
            if isinstance(annot, pikepdf.Dictionary) and predicate(annot):
                doomed.add(i)
                if str(annot.get("/Subtype", "")) != "/Popup":
                    count += 1
        if not doomed:
            continue
        gone = {annots[i].objgen for i in doomed if annots[i].is_indirect}
        for i, annot in enumerate(annots):
            if not isinstance(annot, pikepdf.Dictionary):
                continue
            parent = annot.get("/Parent")
            if str(annot.get("/Subtype", "")) == "/Popup" and parent is not None and parent.is_indirect \
                    and parent.objgen in gone:
                doomed.add(i)
        if apply:
            page.obj.Annots = pikepdf.Array([a for i, a in enumerate(annots) if i not in doomed])
    return count


def _name_tree_count(node):
    try:
        return len(pikepdf.NameTree(node))
    except Exception:  # malformed tree still counts as present
        return 1


def _drop_name_tree(pdf, key, apply):
    names = pdf.Root.get("/Names")
    if not isinstance(names, pikepdf.Dictionary) or key not in names:
        return 0
    count = _name_tree_count(names[key])
    if apply:
        del names[key]
        if not list(names.keys()):
            del pdf.Root["/Names"]
    return count


# ---------------------------------------------------------------- metadata / private

def _metadata(pdf, apply):
    count = 0
    info = pdf.trailer.get("/Info")
    if isinstance(info, pikepdf.Dictionary):
        count += len(list(info.keys()))
        if apply:
            del pdf.trailer["/Info"]
    count += _strip_keys(pdf, ("/Metadata",), apply)
    for key in ("/SpiderInfo",):
        if key in pdf.Root:
            count += 1
            if apply:
                del pdf.Root[key]
    for page in pdf.pages:
        if "/Thumb" in page.obj:
            count += 1
            if apply:
                del page.obj["/Thumb"]
    count += _strip_keys(pdf, ("/PieceInfo",), apply)
    return count


def _metadata_scan(pdf):
    info = pdf.trailer.get("/Info")
    count = len(list(info.keys())) if isinstance(info, pikepdf.Dictionary) else 0
    return count + (1 if "/Metadata" in pdf.Root else 0)


def _private_data(pdf, apply):
    return _strip_keys(pdf, ("/PieceInfo", "/LastModified"), apply)


# ---------------------------------------------------------------- embedded files

def _embedded_files(pdf, apply):
    count = _drop_name_tree(pdf, "/EmbeddedFiles", apply)
    count += _remove_annots(pdf, lambda a: str(a.get("/Subtype", "")) == "/FileAttachment", apply)
    count += _strip_keys(pdf, ("/AF",), apply)
    if "/Collection" in pdf.Root:
        count += 1
        if apply:
            del pdf.Root["/Collection"]
    return count


# ---------------------------------------------------------------- javascript

def _flatten_chain(action, out, seen):
    if not isinstance(action, pikepdf.Dictionary):
        return
    if action.is_indirect:
        if action.objgen in seen:
            return
        seen.add(action.objgen)
    out.append(action)
    nxt = action.get("/Next")
    if nxt is None:
        return
    for item in (list(nxt) if isinstance(nxt, pikepdf.Array) else [nxt]):
        _flatten_chain(item, out, seen)


def _clean_action(action, apply):
    """Returns (replacement action or None, dangerous actions removed)."""
    chain = []
    _flatten_chain(action, chain, set())
    bad = [a for a in chain if str(a.get("/S", "")) in DANGEROUS]
    if not bad:
        return action, 0
    safe = [a for a in chain if str(a.get("/S", "")) not in DANGEROUS]
    if apply:
        # Rebuild a linear chain back to front so direct copies are final.
        for i in range(len(safe) - 1, -1, -1):
            if i + 1 < len(safe):
                safe[i].Next = safe[i + 1]
            elif "/Next" in safe[i]:
                del safe[i]["/Next"]
    return (safe[0] if safe else None), len(bad)


def _outline_items(pdf):
    outlines = pdf.Root.get("/Outlines")
    items, seen = [], set()
    stack = [outlines.get("/First")] if isinstance(outlines, pikepdf.Dictionary) else []
    while stack:
        item = stack.pop()
        while isinstance(item, pikepdf.Dictionary):
            key = item.objgen if item.is_indirect else id(item)
            if key in seen:
                break
            seen.add(key)
            items.append(item)
            if "/First" in item:
                stack.append(item.First)
            item = item.get("/Next")
    return items


def _javascript(pdf, apply):
    count = _drop_name_tree(pdf, "/JavaScript", apply)
    opener = pdf.Root.get("/OpenAction")
    if isinstance(opener, pikepdf.Dictionary):
        new, n = _clean_action(opener, apply)
        count += n
        if apply and n:
            if new is None:
                del pdf.Root["/OpenAction"]
            else:
                pdf.Root.OpenAction = new
    for obj in _walk(pdf):
        aa = obj.get("/AA")
        if isinstance(aa, pikepdf.Dictionary):
            count += max(1, len(list(aa.keys())))
            if apply:
                del obj["/AA"]
    for item in _outline_items(pdf):
        if isinstance(item.get("/A"), pikepdf.Dictionary):
            new, n = _clean_action(item.A, apply)
            count += n
            if apply and n:
                if new is None:
                    del item["/A"]
                else:
                    item.A = new
    dead_links = set()
    for page, index, annot in _annots(pdf):
        if not isinstance(annot.get("/A"), pikepdf.Dictionary):
            continue
        new, n = _clean_action(annot.A, apply)
        count += n
        if n and new is None and str(annot.get("/Subtype", "")) == "/Link" and "/Dest" not in annot:
            dead_links.add((page, index))
        if apply and n:
            if new is None:
                del annot["/A"]
            else:
                annot.A = new
    if dead_links and apply:
        for key, page in enumerate(pdf.pages):
            annots = page.obj.get("/Annots")
            if not isinstance(annots, pikepdf.Array):
                continue
            kept = [a for i, a in enumerate(annots) if (key, i) not in dead_links]
            if len(kept) != len(annots):
                page.obj.Annots = pikepdf.Array(kept)
    form = pdf.Root.get("/AcroForm")
    if isinstance(form, pikepdf.Dictionary) and "/XFA" in form:
        count += 1
        if apply:
            del form["/XFA"]
    return count


# ---------------------------------------------------------------- hidden layers

def _key(obj):
    return obj.objgen if obj.is_indirect else None


def _off_groups(pdf):
    props = pdf.Root.get("/OCProperties")
    if not isinstance(props, pikepdf.Dictionary):
        return None
    config = props.get("/D")
    if not isinstance(config, pikepdf.Dictionary):
        return set()
    groups = {_key(g) for g in props.get("/OCGs", []) if isinstance(g, pikepdf.Dictionary) and g.is_indirect}
    on = {_key(g) for g in config.get("/ON", []) if isinstance(g, pikepdf.Dictionary) and g.is_indirect}
    off = {_key(g) for g in config.get("/OFF", []) if isinstance(g, pikepdf.Dictionary) and g.is_indirect}
    if str(config.get("/BaseState", "/ON")) == "/OFF":
        return (groups | off) - on
    return off


def _hidden(oc, off):
    if not isinstance(oc, pikepdf.Dictionary) or not off:
        return False
    if str(oc.get("/Type", "")) == "/OCMD" or "/OCGs" in oc:
        ocgs = oc.get("/OCGs")
        members = list(ocgs) if isinstance(ocgs, pikepdf.Array) else [ocgs]
        states = [_key(g) not in off for g in members if isinstance(g, pikepdf.Dictionary)]
        if not states:
            return False
        policy = str(oc.get("/P", "/AnyOn"))
        visible = {"/AllOn": all(states), "/AnyOff": not all(states),
                   "/AllOff": not any(states)}.get(policy, any(states))
        return not visible
    return _key(oc) in off


def _inherited_resources(page):
    node = page.obj
    while isinstance(node, pikepdf.Dictionary):
        if "/Resources" in node:
            return node.Resources
        node = node.get("/Parent")
    return pikepdf.Dictionary()


def _instruction(operands, operator):
    return pikepdf.ContentStreamInstruction(operands, pikepdf.Operator(operator))


class _LayerFilter:
    def __init__(self, pdf, off):
        self.pdf, self.off = pdf, off
        self.done = set()
        self.removed = 0

    def lookup(self, res, category, name):
        group = res.get(category) if isinstance(res, pikepdf.Dictionary) else None
        if not isinstance(group, pikepdf.Dictionary) or not isinstance(name, pikepdf.Name):
            return None
        return group.get(name)

    def form(self, xobj, parent_res):
        if not isinstance(xobj, pikepdf.Stream) or str(xobj.get("/Subtype", "/Form")) != "/Form":
            return
        if xobj.is_indirect:
            if xobj.objgen in self.done:
                return
            self.done.add(xobj.objgen)
        res = xobj.get("/Resources", parent_res)
        self.streams([xobj], res)

    def streams(self, streams, res):
        state = {"depth": 0}
        for stream in streams:
            if not isinstance(stream, pikepdf.Stream):
                continue
            try:
                raw = stream.read_bytes()
            except pikepdf.PdfError:
                continue
            if b"OC" not in raw and b"Do" not in raw and state["depth"] == 0:
                continue
            try:
                instructions = pikepdf.parse_content_stream(stream)
            except pikepdf.PdfError:
                continue
            out, changed = self.filter(instructions, res, state)
            if changed:
                stream.write(pikepdf.unparse_content_stream(out))

    def filter(self, instructions, res, state):
        out, changed = [], False
        for inst in instructions:
            operator = str(inst.operator)
            operands = list(inst.operands)
            if state["depth"]:
                changed = True
                if operator in ("BDC", "BMC"):
                    state["depth"] += 1
                elif operator == "EMC":
                    state["depth"] -= 1
                elif operator == "'":
                    out.append(_instruction([], "T*"))
                elif operator == '"':
                    out += [_instruction(operands[:1], "Tw"), _instruction(operands[1:2], "Tc"),
                            _instruction([], "T*")]
                elif operator in PAINT_PATH:
                    out.append(_instruction([], "n"))
                elif operator in ("Tj", "TJ", "Do", "sh", "INLINE IMAGE", "BI", "ID", "EI"):
                    pass
                else:
                    out.append(inst)
                continue
            if operator == "BDC" and len(operands) == 2 and operands[0] == Name.OC:
                prop = operands[1]
                if isinstance(prop, pikepdf.Name):
                    prop = self.lookup(res, "/Properties", prop)
                if _hidden(prop, self.off):
                    state["depth"] = 1
                    self.removed += 1
                else:
                    out.append(_instruction([Name.OC], "BMC"))
                changed = True
                continue
            if operator == "Do" and operands:
                xobj = self.lookup(res, "/XObject", operands[0])
                if xobj is not None and _hidden(xobj.get("/OC"), self.off):
                    changed = True
                    self.removed += 1
                    continue
                if xobj is not None:
                    self.form(xobj, res)
            out.append(inst)
        return out, changed


def _appearance_streams(annot):
    ap = annot.get("/AP")
    if not isinstance(ap, pikepdf.Dictionary):
        return []
    found = []
    for key in ("/N", "/R", "/D"):
        value = ap.get(key)
        if isinstance(value, pikepdf.Stream):
            found.append(value)
        elif isinstance(value, pikepdf.Dictionary):
            found += [v for v in value.values() if isinstance(v, pikepdf.Stream)]
    return found


def _hidden_layers(pdf, apply):
    off = _off_groups(pdf)
    if off is None:
        return 0
    if not apply:
        return len(off)
    layer = _LayerFilter(pdf, off)
    for page in pdf.pages:
        res = _inherited_resources(page)
        contents = page.obj.get("/Contents")
        streams = list(contents) if isinstance(contents, pikepdf.Array) else [contents]
        layer.streams(streams, res)
    _remove_annots(pdf, lambda a: _hidden(a.get("/OC"), off), True)
    for _, _, annot in _annots(pdf):
        for stream in _appearance_streams(annot):
            layer.form(stream, stream.get("/Resources", pikepdf.Dictionary()))
    del pdf.Root["/OCProperties"]
    _strip_keys(pdf, ("/OC",), True)
    return len(off)


# ---------------------------------------------------------------- hidden text hooks

def _remove_hidden_text(ctx):
    try:
        from transforms.interpret import remove_hidden_text
    except (ImportError, AttributeError):
        return 0
    return int(remove_hidden_text(ctx) or 0)


def _count_hidden_text(ctx):
    try:
        from transforms.interpret import count_hidden_text
    except (ImportError, AttributeError):
        return 0
    return int(count_hidden_text(ctx) or 0)


# ---------------------------------------------------------------- annotations / structure

def _bookmarks(pdf, apply):
    if "/Outlines" not in pdf.Root:
        return 0
    count = len(_outline_items(pdf))
    if apply:
        del pdf.Root["/Outlines"]
        if str(pdf.Root.get("/PageMode", "")) == "/UseOutlines":
            pdf.Root.PageMode = Name.UseNone
    return count


def _comments(pdf, apply):
    return _remove_annots(pdf, lambda a: str(a.get("/Subtype", "")) not in KEEPS, apply)


def _links(pdf, apply):
    return _remove_annots(pdf, lambda a: str(a.get("/Subtype", "")) == "/Link", apply)


def _form_fields(pdf, apply):
    count = 0
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if not isinstance(annots, pikepdf.Array):
            continue
        widgets = [a for a in annots if isinstance(a, pikepdf.Dictionary) and str(a.get("/Subtype", "")) == "/Widget"]
        if not widgets:
            continue
        count += len(widgets)
        if not apply:
            continue
        visible = [w for w in widgets if not int(w.get("/F", 0)) & 2 and isinstance(w.get("/AP"), pikepdf.Dictionary)
                   and "/N" in w.AP and "/Rect" in w]
        page.obj.Annots = pikepdf.Array([a for a in annots if not (isinstance(a, pikepdf.Dictionary)
                                                                    and str(a.get("/Subtype", "")) == "/Widget")])
        if visible:
            from transforms.content import stamp_appearances
            stamp_appearances(pdf, page, visible)
    if "/AcroForm" in pdf.Root:
        if apply:
            del pdf.Root["/AcroForm"]
        if not count:
            count = 1
    return count


# ---------------------------------------------------------------- op / query

@op("sanitize")
def sanitize(ctx, metadata=True, embedded_files=True, javascript=True, hidden_layers=True, hidden_text=True,
             private_data=True, bookmarks=False, comments=False, form_fields=False, links=False):
    pdf = ctx.pdf
    counts = {}
    # Hidden layers first: a hidden annotation or widget must not be flattened.
    if hidden_layers:
        counts["hidden_layers"] = _hidden_layers(pdf, True)
    if hidden_text:
        counts["hidden_text"] = _remove_hidden_text(ctx)
        pdf = ctx.pdf  # the hook may have reloaded the document
    if javascript:
        counts["javascript"] = _javascript(pdf, True)
    if embedded_files:
        counts["embedded_files"] = _embedded_files(pdf, True)
    if comments:
        counts["comments"] = _comments(pdf, True)
    if links:
        counts["links"] = _links(pdf, True)
    if form_fields:
        counts["form_fields"] = _form_fields(pdf, True)
    if bookmarks:
        counts["bookmarks"] = _bookmarks(pdf, True)
    if metadata:
        counts["metadata"] = _metadata(pdf, True)
    if private_data:
        counts["private_data"] = _private_data(pdf, True)
    return {"removed": counts}


@query("sanitize_scan")
def sanitize_scan(ctx):
    pdf = ctx.pdf
    return {
        "metadata": _metadata_scan(pdf),
        "embedded_files": _embedded_files(pdf, False),
        "javascript": _javascript(pdf, False),
        "hidden_layers": _hidden_layers(pdf, False),
        "hidden_text": _count_hidden_text(ctx),
        "private_data": _private_data(pdf, False),
        "bookmarks": _bookmarks(pdf, False),
        "comments": _comments(pdf, False),
        "form_fields": _form_fields(pdf, False),
        "links": _links(pdf, False),
    }
