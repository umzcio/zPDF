"""Page composition that PDFKit must never do on the display copy: insertion
(blank, other PDFs, images), replacement, duplication, relative rotation,
page labels, page boxes, resizing and transitions.

Inserted foreign pages keep their annotations, links (re-targeted when the
destination page came along, removed otherwise) and form fields. Field trees
are pruned to the imported pages and merged into this document's AcroForm;
a top-level name that already exists here is namespaced (``zpdfN_``) so two
forms never silently become one shared field.
"""
from pathlib import Path

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require
from transforms import op, query
from transforms.content import page_box, rotation, fmt

PAPER = {
    "letter": (612, 792), "legal": (612, 1008), "tabloid": (792, 1224), "executive": (522, 756),
    "a3": (841.89, 1190.55), "a4": (595.28, 841.89), "a5": (419.53, 595.28), "b5": (498.9, 708.66),
}
FIELD_KEYS = ("/FT", "/T", "/TU", "/TM", "/Ff", "/V", "/DV", "/Opt", "/DA", "/Q", "/MaxLen", "/TI", "/I", "/RV", "/DS")
FIELD_TRIGGERS = ("/K", "/F", "/V", "/C")
BOXES = ("/MediaBox", "/CropBox", "/BleedBox", "/TrimBox", "/ArtBox")


def _keep(ctx, pdf):
    """Foreign documents stay open until the transformed file is written."""
    if not hasattr(ctx, "foreign"):
        ctx.foreign = []
    ctx.foreign.append(pdf)
    return pdf


def _open_foreign(ctx, path, password=None):
    require(isinstance(path, str) and Path(path).is_file(), "INVALID_ARGUMENT", "The file to insert could not be found.")
    try:
        return _keep(ctx, pikepdf.open(path, password=password or ""))
    except pikepdf.PasswordError as exc:
        raise EngineError("PASSWORD_REQUIRED", "The PDF to insert needs its password.") from exc
    except pikepdf.PdfError as exc:
        raise EngineError("INVALID_PDF", "The file to insert could not be read as a PDF.") from exc


CONTAINERS = (pikepdf.Dictionary, pikepdf.Array, pikepdf.Stream)


def copy_from(pdf, src, value):
    """Copy a (possibly direct) object of foreign `src` into `pdf`."""
    if not isinstance(value, CONTAINERS):
        return value
    if not value.is_indirect:
        value = src.make_indirect(value)
    return pdf.copy_foreign(value)


def _position(pdf, at):
    count = len(pdf.pages)
    if at is None:
        return count
    require(isinstance(at, int) and 0 <= at <= count, "INVALID_ARGUMENT", "The insertion position is invalid.")
    return at


def _indexes(pdf, pages, allow_empty=False):
    count = len(pdf.pages)
    if pages is None:
        return list(range(count))
    require(isinstance(pages, list) and (pages or allow_empty) and
            all(isinstance(p, int) and 0 <= p < count for p in pages), "INVALID_ARGUMENT", "The page range is invalid.")
    return list(pages)


def _size(size, like=None):
    if isinstance(size, str):
        key = size.lower()
        require(key in PAPER, "INVALID_ARGUMENT", "Unknown paper size.")
        return PAPER[key]
    if size is None and like is not None:
        x0, y0, x1, y1 = page_box(like, "/MediaBox")
        w, h = x1 - x0, y1 - y0
        return (h, w) if rotation(like) in (90, 270) else (w, h)
    require(isinstance(size, (list, tuple)) and len(size) == 2, "INVALID_ARGUMENT", "A page size is required.")
    w, h = float(size[0]), float(size[1])
    require(3 <= w <= 14400 and 3 <= h <= 14400, "INVALID_ARGUMENT", "Page sizes must be between 3 and 14,400 points.")
    return w, h


def _new_page(pdf, width, height):
    return pikepdf.Page(pdf.make_indirect(pikepdf.Dictionary(
        Type=Name.Page, MediaBox=pikepdf.Array([0, 0, float(width), float(height)]),
        Resources=pikepdf.Dictionary(), Contents=pdf.make_indirect(pikepdf.Stream(pdf, b"")))))


# ---------------------------------------------------------------- destinations

def _named_dests(pdf):
    names = {}
    root = pdf.Root
    try:
        if "/Names" in root and "/Dests" in root.Names:
            for key, value in pikepdf.NameTree(root.Names.Dests).items():
                names[str(key)] = value
    except (pikepdf.PdfError, ValueError, TypeError):
        pass
    if "/Dests" in root:
        for key, value in root.Dests.items():
            names[str(key)[1:] if str(key).startswith("/") else str(key)] = value
    return names


def _explicit(dest, named):
    if isinstance(dest, (pikepdf.String, pikepdf.Name)):
        key = str(dest)
        dest = named.get(key[1:] if key.startswith("/") else key)
    if isinstance(dest, pikepdf.Dictionary) and "/D" in dest:
        dest = dest.D
    if isinstance(dest, pikepdf.Array) and len(dest) and isinstance(dest[0], pikepdf.Dictionary):
        return dest
    return None


def _detach_links(src, indexes):
    """Strip GoTo targets from imported link annotations before copying so no
    unrelated foreign page is dragged along. Returns re-targeting instructions."""
    named = None
    wanted = {src.pages[i].obj.objgen: n for n, i in enumerate(indexes)}
    plan = []
    for n, index in enumerate(indexes):
        annots = src.pages[index].obj.get("/Annots")
        if annots is None:
            continue
        for a, annot in enumerate(annots):
            if not isinstance(annot, pikepdf.Dictionary):
                continue
            target = None
            action = annot.get("/A")
            carrier = None
            if "/Dest" in annot:
                carrier = ("dest", annot.Dest)
            elif isinstance(action, pikepdf.Dictionary) and action.get("/S") == Name.GoTo and "/D" in action:
                carrier = ("action", action.D)
            if carrier is None:
                continue
            if named is None:
                named = _named_dests(src)
            explicit = _explicit(carrier[1], named)
            if explicit is not None and explicit[0].objgen in wanted:
                target = (wanted[explicit[0].objgen], [explicit[i] for i in range(1, len(explicit))])
            plan.append((n, a, target))
            if "/Dest" in annot:
                del annot["/Dest"]
            if isinstance(action, pikepdf.Dictionary) and action.get("/S") == Name.GoTo:
                del annot["/A"]
    return plan


def _retarget(pdf, new_pages, plan):
    removals = {}
    for n, a, target in plan:
        annot = new_pages[n].obj.Annots[a]
        if target is None:
            removals.setdefault(n, set()).add(a)
            continue
        dest_page, rest = target
        annot.Dest = pikepdf.Array([new_pages[dest_page].obj] + rest)
    for n, drop in removals.items():
        annots = new_pages[n].obj.Annots
        new_pages[n].obj.Annots = pikepdf.Array([x for i, x in enumerate(annots) if i not in drop])
    return sum(len(v) for v in removals.values())


# ---------------------------------------------------------------- forms

def _root_field(node):
    seen = set()
    while "/Parent" in node and node.objgen not in seen:
        seen.add(node.objgen)
        node = node.Parent
    return node


def _prune_fields(src, indexes):
    """Limit foreign field trees to widgets on the imported pages."""
    widgets = set()
    for index in indexes:
        for annot in src.pages[index].obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary) and annot.get("/Subtype") == Name.Widget:
                widgets.add(annot.objgen)

    def prune(node, depth=0):
        if depth > 32:
            return False
        if node.objgen in widgets:
            keep_kids = True
        else:
            keep_kids = False
        kids = node.get("/Kids")
        if isinstance(kids, pikepdf.Array):
            kept = pikepdf.Array([k for k in kids if isinstance(k, pikepdf.Dictionary) and prune(k, depth + 1)])
            node.Kids = kept
            return keep_kids or len(kept) > 0
        return keep_kids

    roots = {}
    for index in indexes:
        for annot in src.pages[index].obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary) and annot.get("/Subtype") == Name.Widget:
                root = _root_field(annot)
                roots[root.objgen] = root
    for root in roots.values():
        prune(root)
    # Page objects of other pages must not be reachable through /P of pruned kids.
    return len(roots)


def _existing_names(pdf):
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return set()
    return {str(f.T) for f in acro.get("/Fields", []) if isinstance(f, pikepdf.Dictionary) and "/T" in f}


def _merge_fields(pdf, src, new_pages, used_names):
    """Register imported widgets' root fields in this document's AcroForm."""
    roots = []
    seen = set()
    for page in new_pages:
        for annot in page.obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary) and annot.get("/Subtype") == Name.Widget:
                root = _root_field(annot)
                if root.objgen not in seen:
                    seen.add(root.objgen)
                    roots.append(root)
    if not roots:
        return {"fields": 0, "renamed": 0}
    if "/AcroForm" not in pdf.Root:
        pdf.Root.AcroForm = pdf.make_indirect(pikepdf.Dictionary(Fields=pikepdf.Array()))
    acro = pdf.Root.AcroForm
    if "/Fields" not in acro:
        acro.Fields = pikepdf.Array()
    foreign = src.Root.get("/AcroForm")
    if foreign is not None:
        if "/DA" not in acro and "/DA" in foreign:
            acro.DA = pikepdf.String(bytes(foreign.DA))
        if "/DR" in foreign:
            dr = copy_from(pdf, src, foreign.DR)
            if "/DR" not in acro:
                acro.DR = dr
            else:
                for category in ("/Font", "/XObject", "/ColorSpace", "/Encoding"):
                    if category in dr:
                        if category not in acro.DR:
                            acro.DR[category] = pikepdf.Dictionary()
                        for key, value in dr[category].items():
                            if key not in acro.DR[category]:
                                acro.DR[category][key] = value
        if foreign.get("/NeedAppearances") is True:
            acro.NeedAppearances = True
    renamed = 0
    names = set(used_names)
    for root in roots:
        if "/T" in root:
            name = str(root.T)
            if name in names:
                n = 1
                while f"zpdf{n}_{name}" in names:
                    n += 1
                root.T = pikepdf.String(f"zpdf{n}_{name}")
                renamed += 1
            names.add(str(root.T))
        if "/Parent" in root:
            del root["/Parent"]
        acro.Fields.append(root)
    return {"fields": len(roots), "renamed": renamed}


def _scrub_structure(page):
    obj = page.obj
    for key in ("/StructParents", "/B", "/PieceInfo", "/Thumb", "/ZPDFWrapped"):
        if key in obj:
            del obj[key]
    for annot in obj.get("/Annots", []):
        if isinstance(annot, pikepdf.Dictionary) and "/StructParent" in annot:
            del annot["/StructParent"]


def import_pages(ctx, src, indexes, at):
    """Copy `indexes` of `src` into ctx.pdf at `at`. Returns stats."""
    pdf = ctx.pdf
    used = _existing_names(pdf)
    plan = _detach_links(src, indexes)
    _prune_fields(src, indexes)
    for index in indexes:
        obj = src.pages[index].obj
        for key in ("/B", "/StructParents"):
            if key in obj:
                del obj[key]
        # Inheritable attributes live on the foreign page tree, which is not copied.
        for key in ("/Resources", "/MediaBox", "/CropBox", "/Rotate"):
            if key not in obj:
                node = obj
                while "/Parent" in node and key not in node:
                    node = node.Parent
                if key in node:
                    obj[key] = node[key]
    new_pages = []
    for n, index in enumerate(indexes):
        pdf.pages.insert(at + n, src.pages[index])
        new_pages.append(pdf.pages[at + n])
    for page in new_pages:
        _scrub_structure(page)
        for annot in page.obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary) and "/P" in annot:
                annot.P = page.obj
    removed_links = _retarget(pdf, new_pages, plan)
    forms = _merge_fields(pdf, src, new_pages, used)
    return {"inserted": len(new_pages), "links_removed": removed_links, **forms}


# ---------------------------------------------------------------- operations

@op("insert_blank_pages")
def insert_blank_pages(ctx, at=None, count=1, size=None, like=None, orientation=None):
    """size: [w, h] points, a paper name, or None to match page `like`."""
    pdf = ctx.pdf
    require(isinstance(count, int) and 1 <= count <= 1000, "INVALID_ARGUMENT", "Insert between 1 and 1,000 pages.")
    at = _position(pdf, at)
    reference = None
    if size is None:
        like = at - 1 if like is None and at > 0 else (0 if like is None else like)
        require(isinstance(like, int) and 0 <= like < len(pdf.pages), "INVALID_ARGUMENT", "Invalid reference page.")
        reference = pdf.pages[like]
    w, h = _size(size, reference)
    if orientation == "landscape" and h > w or orientation == "portrait" and w > h:
        w, h = h, w
    for n in range(count):
        pdf.pages.insert(at + n, _new_page(pdf, w, h))
    return {"inserted": count, "at": at, "size": [w, h]}


@op("insert_pages")
def insert_pages(ctx, path, at=None, pages=None, password=None):
    """Insert pages of another PDF (all, or zero-based `pages`) before index `at`."""
    src = _open_foreign(ctx, path, password)
    indexes = list(range(len(src.pages))) if pages is None else pages
    require(isinstance(indexes, list) and indexes and len(set(indexes)) == len(indexes) and
            all(isinstance(i, int) and 0 <= i < len(src.pages) for i in indexes),
            "INVALID_ARGUMENT", "The pages to insert are invalid.")
    at = _position(ctx.pdf, at)
    return {"at": at, **import_pages(ctx, src, indexes, at)}


@op("insert_images")
def insert_images(ctx, images, at=None, page_size=None, fit="fit", margin=0, dpi=None):
    """One page per image. page_size None sizes each page to its image (at its
    resolution, 72 dpi when unknown); otherwise images are fitted in the page:
    fit = "fit" (contain), "fill" (cover, cropped) or "actual" (centered)."""
    from PIL import Image
    from transforms.content import image_xobject
    pdf = ctx.pdf
    require(isinstance(images, list) and images, "INVALID_ARGUMENT", "Choose at least one image.")
    require(fit in ("fit", "fill", "actual"), "INVALID_ARGUMENT", "Unknown image fit.")
    at = _position(pdf, at)
    margin = float(margin)
    for n, item in enumerate(images):
        spec = item if isinstance(item, dict) else {"path": item}
        path = spec.get("path")
        require(isinstance(path, str) and Path(path).is_file(), "INVALID_ARGUMENT", "An image could not be found.")
        try:
            with Image.open(path) as probe:
                info_dpi = probe.info.get("dpi")
        except OSError as exc:
            raise EngineError("INVALID_IMAGE", f"{Path(path).name} is not a supported image.") from exc
        xobj, pw, ph = image_xobject(pdf, path)
        resolution = spec.get("dpi") or dpi
        if not resolution and info_dpi and float(info_dpi[0]) >= 36:
            resolution = float(info_dpi[0])
        resolution = float(resolution or 72)
        iw, ih = pw * 72 / resolution, ph * 72 / resolution
        if page_size is None:
            scale = min(1.0, 14400 / max(iw + 2 * margin, ih + 2 * margin))
            iw, ih = iw * scale, ih * scale
            w, h = iw + 2 * margin, ih + 2 * margin
        else:
            w, h = _size(page_size)
            if spec.get("auto_orient", True) and (iw > ih) != (w > h):
                w, h = h, w
        aw, ah = w - 2 * margin, h - 2 * margin
        require(aw > 0 and ah > 0, "INVALID_ARGUMENT", "The margin is larger than the page.")
        if page_size is None or fit == "actual":
            dw, dh = min(iw, aw) if fit != "actual" else iw, min(ih, ah) if fit != "actual" else ih
            if page_size is None:
                dw, dh = iw, ih
        else:
            s = min(aw / iw, ah / ih) if fit == "fit" else max(aw / iw, ah / ih)
            dw, dh = iw * s, ih * s
        x, y = (w - dw) / 2, (h - dh) / 2
        page = _new_page(pdf, w, h)
        page.obj.Resources = pikepdf.Dictionary(XObject=pikepdf.Dictionary(Im1=xobj))
        clip = f"{fmt(margin, margin, aw, ah)} re W n " if fit in ("fill", "actual") and page_size is not None else ""
        page.obj.Contents = pdf.make_indirect(pikepdf.Stream(
            pdf, f"q {clip}{fmt(dw)} 0 0 {fmt(dh)} {fmt(x)} {fmt(y)} cm /Im1 Do Q\n".encode()))
        pdf.pages.insert(at + n, page)
    return {"inserted": len(images), "at": at}


def prune_for_removal(pdf, removed):
    """Before `removed` pages (page indexes) are deleted: drop what points at them —
    form fields and widgets, bookmarks, named destinations, links, the open action
    and tagged-structure elements — so the removed pages (and everything they
    reference) are not written into the file."""
    gone = {pdf.pages[i].obj.objgen for i in removed}
    if not gone:
        return
    stays = [p for i, p in enumerate(pdf.pages) if i not in set(removed)]
    on_kept = {a.objgen for p in stays for a in (p.obj.get("/Annots") or []) if isinstance(a, pikepdf.Dictionary) and a.is_indirect}

    def page_of(dest):
        if isinstance(dest, pikepdf.Dictionary) and dest.get("/S") == Name.GoTo:
            dest = dest.get("/D")
        if isinstance(dest, pikepdf.Dictionary) and "/D" in dest:  # a named-destination value
            dest = dest.D
        if isinstance(dest, pikepdf.Array) and len(dest) and isinstance(dest[0], pikepdf.Dictionary) and dest[0].is_indirect:
            return dest[0].objgen
        return None

    def targets_gone(value):
        return page_of(value) in gone

    # Form fields: keep widgets that are on kept pages; drop fields left without widgets.
    acro = pdf.Root.get("/AcroForm")
    if isinstance(acro, pikepdf.Dictionary) and isinstance(acro.get("/Fields"), pikepdf.Array):
        def keep(node):
            kids = node.get("/Kids")
            if isinstance(kids, pikepdf.Array) and len(kids):
                kept = [k for k in kids if isinstance(k, pikepdf.Dictionary) and keep(k)]
                if len(kept) != len(kids):
                    node.Kids = pikepdf.Array(kept)
                return bool(kept)
            if node.get("/Subtype") == Name.Widget or "/Rect" in node:
                return node.is_indirect and node.objgen in on_kept
            return True
        acro.Fields = pikepdf.Array([f for f in acro.Fields if isinstance(f, pikepdf.Dictionary) and keep(f)])
        if isinstance(acro.get("/CO"), pikepdf.Array):
            reachable = set()

            def collect(node):
                if isinstance(node, pikepdf.Dictionary) and node.is_indirect and node.objgen not in reachable:
                    reachable.add(node.objgen)
                    for kid in node.get("/Kids") or []:
                        collect(kid)
            for field in acro.Fields:
                collect(field)
            acro.CO = pikepdf.Array([f for f in acro.CO if f.is_indirect and f.objgen in reachable])

    # Bookmarks: drop items that jump to removed pages (items with children keep, minus the jump).
    if "/Outlines" in pdf.Root:
        with pdf.open_outline() as outline:
            def prune(items):
                for item in list(items):
                    prune(item.children)
                    if targets_gone(item.destination) or targets_gone(item.action):
                        if item.children:
                            item.destination = None
                            item.action = None
                        else:
                            items.remove(item)
            prune(outline.root)

    # Named destinations (name tree and the old /Dests dictionary).
    names = pdf.Root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and isinstance(names.get("/Dests"), pikepdf.Dictionary):
        tree = pikepdf.NameTree(names.Dests)
        for key in [k for k, v in tree.items() if targets_gone(v)]:
            del tree[key]
    old = pdf.Root.get("/Dests")
    if isinstance(old, pikepdf.Dictionary):
        for key in [k for k, v in old.items() if targets_gone(v)]:
            del old[key]
    if targets_gone(pdf.Root.get("/OpenAction")):
        del pdf.Root["/OpenAction"]

    # Links on kept pages that jump to removed pages.
    for page in stays:
        annots = page.obj.get("/Annots")
        if isinstance(annots, pikepdf.Array):
            kept = [a for a in annots if not (isinstance(a, pikepdf.Dictionary) and a.get("/Subtype") == Name.Link
                                              and (targets_gone(a.get("/Dest")) or targets_gone(a.get("/A"))))]
            if len(kept) != len(annots):
                page.obj.Annots = pikepdf.Array(kept)

    # Tagged structure: elements and marked-content references on removed pages.
    root = pdf.Root.get("/StructTreeRoot")
    if isinstance(root, pikepdf.Dictionary):
        def on_gone_page(node):
            pg = node.get("/Pg") if isinstance(node, pikepdf.Dictionary) else None
            return isinstance(pg, pikepdf.Dictionary) and pg.is_indirect and pg.objgen in gone

        seen = set()

        def prune_struct(node, inherited_gone=False):
            """False when nothing of `node` remains on kept pages. Marked-content and
            object references without their own /Pg belong to their element's page."""
            if not isinstance(node, pikepdf.Dictionary):
                return True
            if node.is_indirect:
                if node.objgen in seen:
                    return True
                seen.add(node.objgen)
            page_gone = on_gone_page(node) if "/Pg" in node else inherited_gone
            if node.get("/Type") == Name.OBJR:
                obj = node.get("/Obj")
                if isinstance(obj, pikepdf.Dictionary) and obj.is_indirect and obj.get("/Subtype") is not None:
                    return obj.objgen in on_kept or not page_gone
                return not page_gone
            kids = node.get("/K")
            if kids is None:
                return not page_gone
            items = list(kids) if isinstance(kids, pikepdf.Array) else [kids]
            kept = [k for k in items if (prune_struct(k, page_gone) if isinstance(k, pikepdf.Dictionary) else not page_gone)]
            if len(kept) != len(items):
                if not kept:
                    del node["/K"]
                else:
                    node.K = pikepdf.Array(kept) if len(kept) > 1 or isinstance(kids, pikepdf.Array) else kept[0]
            if kept and "/Pg" in node and on_gone_page(node):
                del node["/Pg"]  # it survives only for children on kept pages
            return bool(kept) or node.get("/Type") == Name.StructTreeRoot

        prune_struct(root)

        # ParentTree: entries pointing only at elements no longer in the tree go
        # (whatever owned their key: a removed page, its annotations or forms).
        live = set()

        def collect(node):
            if isinstance(node, pikepdf.Dictionary) and node.is_indirect and node.objgen not in live:
                live.add(node.objgen)
                kids = node.get("/K")
                for kid in (list(kids) if isinstance(kids, pikepdf.Array) else [kids]) if kids is not None else []:
                    collect(kid)
        collect(root)
        for kid in (list(root.K) if isinstance(root.get("/K"), pikepdf.Array) else [root.get("/K")]):
            collect(kid)

        def alive(value):
            return isinstance(value, pikepdf.Dictionary) and value.is_indirect and value.objgen in live

        def prune_numbers(tree):
            if not isinstance(tree, pikepdf.Dictionary):
                return
            nums = tree.get("/Nums")
            if isinstance(nums, pikepdf.Array):
                kept = []
                for i in range(0, len(nums) - 1, 2):
                    key, value = nums[i], nums[i + 1]
                    if isinstance(value, pikepdf.Array):
                        cleaned = [v if alive(v) else None for v in value]
                        if any(v is not None for v in cleaned):
                            kept += [key, pikepdf.Array(cleaned)]
                    elif alive(value):
                        kept += [key, value]
                tree.Nums = pikepdf.Array(kept)
                if "/Limits" in tree and kept:
                    tree.Limits = pikepdf.Array([kept[0], kept[-2]])
            for kid in tree.get("/Kids") or []:
                prune_numbers(kid)
        prune_numbers(root.get("/ParentTree"))

        def prune_names(tree):  # the IDTree maps element IDs to elements
            if not isinstance(tree, pikepdf.Dictionary):
                return
            names = tree.get("/Names")
            if isinstance(names, pikepdf.Array):
                kept = [v for i in range(0, len(names) - 1, 2) if alive(names[i + 1]) for v in (names[i], names[i + 1])]
                tree.Names = pikepdf.Array(kept)
                if "/Limits" in tree and kept:
                    tree.Limits = pikepdf.Array([kept[0], kept[-2]])
            for kid in tree.get("/Kids") or []:
                prune_names(kid)
        prune_names(root.get("/IDTree"))


@op("delete_pages")
def delete_pages(ctx, pages):
    pdf = ctx.pdf
    indexes = sorted(set(_indexes(pdf, pages)), reverse=True)
    require(len(indexes) < len(pdf.pages), "EMPTY_DOCUMENT", "A PDF must keep at least one page.")
    prune_for_removal(pdf, indexes)
    for index in indexes:
        del pdf.pages[index]
    return {"deleted": len(indexes)}


@op("reorder_pages")
def reorder_pages(ctx, order):
    """Puts the pages in `order` (a permutation of all page indexes). The page
    objects themselves move, so links, bookmarks and form widgets that point at
    them stay correct (assigning a page list would copy them)."""
    pdf = ctx.pdf
    count = len(pdf.pages)
    require(isinstance(order, list) and all(isinstance(i, int) for i in order)
            and sorted(order) == list(range(count)), "INVALID_ARGUMENT",
            "The new page order must list every page exactly once.")
    moved = sum(1 for position, index in enumerate(order) if position != index)
    if moved:
        objects = [pdf.pages[i].obj for i in order]
        keep = pdf.pages[0]  # a page tree can't be emptied, so one page stays while the rest move
        for page in list(pdf.pages)[1:]:
            pdf.pages.remove(page)
        for obj in objects:
            if obj.objgen != keep.obj.objgen:
                pdf.pages.append(pikepdf.Page(obj))
        pdf.pages.remove(keep)
        pdf.pages.insert(order.index(0), pikepdf.Page(keep.obj))
    return {"moved": moved, "page_count": count}


@op("replace_pages")
def replace_pages(ctx, path, targets, source_pages=None, password=None):
    """Replace the content of `targets` with pages of another PDF, one to one.
    Like Acrobat, the replaced pages keep their own annotations, form fields,
    links and bookmarks; only page content, resources and boxes change."""
    pdf = ctx.pdf
    targets = _indexes(pdf, targets)
    src = _open_foreign(ctx, path, password)
    sources = list(range(len(targets))) if source_pages is None else source_pages
    require(isinstance(sources, list) and len(sources) == len(targets) and
            all(isinstance(i, int) and 0 <= i < len(src.pages) for i in sources),
            "INVALID_ARGUMENT", "Choose as many replacement pages as pages to replace.")
    for target, source in zip(targets, sources):
        foreign = src.pages[source].obj
        values = {}
        for key in ("/Contents", "/Resources", "/MediaBox", "/CropBox", "/BleedBox", "/TrimBox", "/ArtBox",
                    "/Rotate", "/Group", "/UserUnit"):
            node = foreign
            while key not in node and "/Parent" in node and key in ("/Resources", "/MediaBox", "/CropBox", "/Rotate"):
                node = node.Parent
            if key in node:
                values[key] = node[key]
        page = pdf.pages[target].obj
        for key in ("/Contents", "/Resources", "/CropBox", "/BleedBox", "/TrimBox", "/ArtBox",
                    "/Rotate", "/Group", "/UserUnit", "/ZPDFWrapped", "/Thumb", "/PieceInfo"):
            if key in page:
                del page[key]
        for key, value in values.items():
            if key in BOXES:
                page[key] = pikepdf.Array(_rect(value))
            else:
                page[key] = copy_from(pdf, src, value)
        if "/Contents" not in page:
            page.Contents = pdf.make_indirect(pikepdf.Stream(pdf, b""))
    return {"replaced": len(targets)}


def _split_merged_field(pdf, widget):
    """Turn a merged field/widget into a parent field with one widget kid."""
    parent = pikepdf.Dictionary()
    for key in FIELD_KEYS:
        if key in widget:
            parent[key] = widget[key]
            del widget[key]
    if isinstance(widget.get("/AA"), pikepdf.Dictionary):
        field_aa = pikepdf.Dictionary()
        widget_aa = pikepdf.Dictionary()
        for key, value in widget.AA.items():
            (field_aa if key in FIELD_TRIGGERS else widget_aa)[key] = value
        if len(field_aa):
            parent.AA = field_aa
        if len(widget_aa):
            widget.AA = widget_aa
        else:
            del widget["/AA"]
    parent = pdf.make_indirect(parent)
    parent.Kids = pikepdf.Array([widget])
    widget.Parent = parent
    acro = pdf.Root.get("/AcroForm")
    if acro is not None and "/Fields" in acro:
        acro.Fields = pikepdf.Array([parent if f.objgen == widget.objgen else f for f in acro.Fields])
    return parent


def _duplicate(pdf, page):
    source = page.obj
    copy = pikepdf.Dictionary()
    for key, value in source.items():
        if key in ("/Annots", "/StructParents", "/B", "/Parent", "/Thumb"):
            continue
        copy[key] = value
    node = source
    for key in ("/Resources", "/MediaBox", "/CropBox", "/Rotate"):
        if key not in copy:
            node = source
            while key not in node and "/Parent" in node:
                node = node.Parent
            if key in node:
                copy[key] = node[key]
    new = pdf.make_indirect(copy)
    annots = source.get("/Annots")
    if annots is not None:
        mapping = {}
        copies = []
        for annot in annots:
            if not isinstance(annot, pikepdf.Dictionary):
                continue
            dup = pdf.make_indirect(pikepdf.Dictionary(annot))
            for key in ("/StructParent", "/NM"):
                if key in dup:
                    del dup[key]
            dup.P = new
            mapping[annot.objgen] = dup
            copies.append((annot, dup))
        for original, dup in copies:
            for key in ("/Popup", "/Parent", "/IRT"):
                target = dup.get(key)
                if isinstance(target, pikepdf.Dictionary) and target.objgen in mapping and \
                        not (key == "/Parent" and original.get("/Subtype") == Name.Widget):
                    dup[key] = mapping[target.objgen]
            if original.get("/Subtype") == Name.Widget:
                if "/Parent" not in original:
                    parent = _split_merged_field(pdf, original)
                    for key in FIELD_KEYS:
                        if key in dup:
                            del dup[key]
                    if isinstance(dup.get("/AA"), pikepdf.Dictionary):
                        widget_aa = pikepdf.Dictionary({k: v for k, v in dup.AA.items() if k not in FIELD_TRIGGERS})
                        if len(widget_aa):
                            dup.AA = widget_aa
                        else:
                            del dup["/AA"]
                else:
                    parent = original.Parent
                if not isinstance(parent.get("/Kids"), pikepdf.Array):
                    # Malformed field tree: the widget names a parent that doesn't list it.
                    parent.Kids = pikepdf.Array([original])
                dup.Parent = parent
                parent.Kids.append(dup)
        new.Annots = pikepdf.Array([dup for _, dup in copies])
    return pikepdf.Page(new)


@op("duplicate_pages")
def duplicate_pages(ctx, pages, at=None, copies=1):
    """Duplicate `pages` (in the given order). at None: after the last page
    of the selection. Duplicated form widgets stay linked to their field."""
    pdf = ctx.pdf
    indexes = _indexes(pdf, pages)
    require(isinstance(copies, int) and 1 <= copies <= 100, "INVALID_ARGUMENT", "Make between 1 and 100 copies.")
    at = _position(pdf, max(indexes) + 1 if at is None else at)
    originals = [pdf.pages[i] for i in indexes]
    made = 0
    for _ in range(copies):
        for page in originals:
            pdf.pages.insert(at + made, _duplicate(pdf, page))
            made += 1
    return {"inserted": made, "at": at}


@op("rotate_pages")
def rotate_pages(ctx, pages=None, angle=90, absolute=False):
    pdf = ctx.pdf
    require(isinstance(angle, int) and angle % 90 == 0, "INVALID_ARGUMENT", "Rotate by a multiple of 90°.")
    indexes = _indexes(pdf, pages)
    for index in indexes:
        page = pdf.pages[index]
        current = 0 if absolute else rotation(page)
        page.obj.Rotate = (current + angle) % 360
    return {"rotated": len(indexes)}


# ---------------------------------------------------------------- labels

STYLES = {"D": "/D", "R": "/R", "r": "/r", "A": "/A", "a": "/a", None: None, "": None}


def _roman(n):
    values = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
              (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
    out = ""
    for v, s in values:
        while n >= v:
            out += s
            n -= v
    return out


def _letters(n):
    return chr(ord("a") + (n - 1) % 26) * ((n - 1) // 26 + 1)


def format_label(style, prefix, number):
    body = ""
    if style == "D":
        body = str(number)
    elif style in ("R", "r"):
        body = _roman(number)
        body = body.upper() if style == "R" else body
    elif style in ("A", "a"):
        body = _letters(number)
        body = body.upper() if style == "A" else body
    return (prefix or "") + body


def read_label_ranges(pdf):
    labels = pdf.Root.get("/PageLabels")
    if labels is None:
        return []
    entries = []
    try:
        tree = pikepdf.NumberTree(labels)
        items = list(tree.items())
    except (AttributeError, pikepdf.PdfError, TypeError):
        nums = labels.get("/Nums", [])
        items = [(int(nums[i]), nums[i + 1]) for i in range(0, len(nums) - 1, 2)]
    for start, value in sorted(items, key=lambda kv: int(kv[0])):
        style = str(value.get("/S", ""))[1:] or None
        entries.append({"start": int(start), "style": style,
                        "prefix": str(value.get("/P", "")) if "/P" in value else "",
                        "first": int(value.get("/St", 1))})
    return entries


def labels_for(pdf, ranges=None):
    ranges = read_label_ranges(pdf) if ranges is None else ranges
    count = len(pdf.pages)
    if not ranges:
        return [str(i + 1) for i in range(count)]
    out = []
    ordered = sorted(ranges, key=lambda r: r["start"])
    for index in range(count):
        current = None
        for entry in ordered:
            if entry["start"] <= index:
                current = entry
        if current is None:
            out.append(str(index + 1))
        else:
            out.append(format_label(current.get("style"), current.get("prefix"),
                                    int(current.get("first", 1)) + index - current["start"]))
    return out


@op("set_page_labels")
def set_page_labels(ctx, ranges):
    """ranges: [{"start": zero-based page, "style": D|R|r|A|a|None, "prefix": str, "first": int}].
    An empty list removes custom labels."""
    pdf = ctx.pdf
    require(isinstance(ranges, list), "INVALID_ARGUMENT", "Page label ranges are required.")
    if not ranges:
        if "/PageLabels" in pdf.Root:
            del pdf.Root["/PageLabels"]
        return {"ranges": 0}
    starts = set()
    nums = pikepdf.Array()
    for entry in sorted(ranges, key=lambda r: r.get("start", -1)):
        start = entry.get("start")
        require(isinstance(start, int) and 0 <= start < len(pdf.pages) and start not in starts,
                "INVALID_ARGUMENT", "Each label range needs a distinct starting page.")
        starts.add(start)
        style = entry.get("style")
        require(style in STYLES, "INVALID_ARGUMENT", "Unknown numbering style.")
        first = entry.get("first", 1)
        require(isinstance(first, int) and first >= 1, "INVALID_ARGUMENT", "Numbering starts at 1 or more.")
        label = pikepdf.Dictionary(Type=Name.PageLabel)
        if STYLES[style]:
            label.S = Name(STYLES[style])
        if entry.get("prefix"):
            label.P = pikepdf.String(str(entry["prefix"]))
        if first != 1:
            label.St = first
        nums.append(start)
        nums.append(label)
    if 0 not in starts:
        nums.insert(0, pikepdf.Dictionary(Type=Name.PageLabel, S=Name.D))
        nums.insert(0, 0)
    pdf.Root.PageLabels = pdf.make_indirect(pikepdf.Dictionary(Nums=nums))
    return {"ranges": len(ranges), "labels": labels_for(pdf)[:2000]}


@query("page_labels")
def page_labels(ctx):
    return {"ranges": read_label_ranges(ctx.pdf), "labels": labels_for(ctx.pdf)}


# ---------------------------------------------------------------- boxes & size

def _rect(value):
    x0, y0, x1, y1 = [float(v) for v in value]
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


@op("set_page_boxes")
def set_page_boxes(ctx, boxes, pages=None, remove=None):
    """boxes: {"CropBox": {"margins": [l, b, r, t]} | {"rect": [x0, y0, x1, y1]}, ...}
    Margins are measured inward from the MediaBox (Acrobat's Set Page Boxes).
    A MediaBox change keeps other boxes inside it. `remove`: box names to delete."""
    pdf = ctx.pdf
    indexes = _indexes(pdf, pages)
    require(isinstance(boxes, dict), "INVALID_ARGUMENT", "Choose page boxes to set.")
    for name in list(boxes) + list(remove or []):
        require("/" + name in BOXES, "INVALID_ARGUMENT", f"Unknown page box {name}.")
    require("MediaBox" not in (remove or []), "INVALID_ARGUMENT", "The MediaBox cannot be removed.")
    order = sorted(boxes, key=lambda n: 0 if n == "MediaBox" else 1)
    for index in indexes:
        page = pdf.pages[index]
        obj = page.obj
        media = _rect(page_box(page, "/MediaBox"))
        for name in order:
            spec = boxes[name]
            if "rect" in spec:
                rect = _rect(spec["rect"])
            else:
                margins = spec.get("margins")
                require(isinstance(margins, list) and len(margins) == 4, "INVALID_ARGUMENT", "Margins need four values.")
                l, b, r, t = [float(m) for m in margins]
                base = media
                rect = [base[0] + l, base[1] + b, base[2] - r, base[3] - t]
            require(rect[2] - rect[0] >= 3 and rect[3] - rect[1] >= 3, "INVALID_ARGUMENT",
                    f"The {name} would be smaller than 3 points.")
            if name == "MediaBox":
                media = rect
                obj.MediaBox = pikepdf.Array(rect)
                for other in ("/CropBox", "/BleedBox", "/TrimBox", "/ArtBox"):
                    if other in obj:
                        o = _rect(obj[other])
                        clipped = [max(o[0], rect[0]), max(o[1], rect[1]), min(o[2], rect[2]), min(o[3], rect[3])]
                        if clipped[2] - clipped[0] < 3 or clipped[3] - clipped[1] < 3:
                            del obj[other]
                        else:
                            obj[other] = pikepdf.Array(clipped)
                continue
            rect = [max(rect[0], media[0]), max(rect[1], media[1]), min(rect[2], media[2]), min(rect[3], media[3])]
            require(rect[2] - rect[0] >= 3 and rect[3] - rect[1] >= 3, "INVALID_ARGUMENT",
                    f"The {name} must lie inside the MediaBox.")
            obj["/" + name] = pikepdf.Array(rect)
        for name in remove or []:
            if "/" + name in obj:
                del obj["/" + name]
    return {"pages": len(indexes)}


def _transform_annotation(annot, m):
    from transforms.content import apply, transform_rect
    if "/Rect" in annot:
        annot.Rect = pikepdf.Array(list(transform_rect(m, _rect(annot.Rect))))
    for key in ("/QuadPoints", "/Vertices", "/L", "/CL"):
        if key in annot and isinstance(annot[key], pikepdf.Array):
            values = [float(v) for v in annot[key]]
            out = []
            for i in range(0, len(values) - 1, 2):
                out.extend(apply(m, values[i], values[i + 1]))
            annot[key] = pikepdf.Array(out)
    if "/InkList" in annot:
        paths = pikepdf.Array()
        for path in annot.InkList:
            values = [float(v) for v in path]
            out = []
            for i in range(0, len(values) - 1, 2):
                out.extend(apply(m, values[i], values[i + 1]))
            paths.append(pikepdf.Array(out))
        annot.InkList = paths


@op("resize_pages")
def resize_pages(ctx, size, pages=None, mode="scale", anchor="center"):
    """Change the page size to `size` (visual width x height, points or paper name).
    mode "scale" scales content (and annotations) to fit, preserving aspect;
    mode "canvas" keeps content at 100% and changes only the page area."""
    pdf = ctx.pdf
    indexes = _indexes(pdf, pages)
    require(mode in ("scale", "canvas", "stretch"), "INVALID_ARGUMENT", "Unknown resize mode.")
    tw, th = _size(size)
    for index in indexes:
        page = pdf.pages[index]
        obj = page.obj
        x0, y0, x1, y1 = page_box(page, "/CropBox")
        w, h = x1 - x0, y1 - y0
        W, H = (th, tw) if rotation(page) in (90, 270) else (tw, th)
        if mode == "scale":
            s = min(W / w, H / h)
            sx = sy = s
        elif mode == "stretch":
            sx, sy = W / w, H / h
        else:
            sx = sy = 1.0
        ax, ay = {"center": (0.5, 0.5), "top-left": (0, 1), "bottom-left": (0, 0)}.get(anchor, (0.5, 0.5))
        tx = (W - w * sx) * ax - x0 * sx
        ty = (H - h * sy) * ay - y0 * sy
        m = (sx, 0, 0, sy, tx, ty)
        contents = obj.get("/Contents")
        streams = [] if contents is None else (list(contents) if isinstance(contents, pikepdf.Array) else [contents])
        pre = pdf.make_indirect(pikepdf.Stream(pdf, f"q {fmt(*m)} cm\n".encode()))
        post = pdf.make_indirect(pikepdf.Stream(pdf, b"\nQ\n"))
        obj.Contents = pikepdf.Array([pre] + streams + [post])
        if "/ZPDFWrapped" in obj:
            del obj["/ZPDFWrapped"]
        for box in ("/CropBox", "/BleedBox", "/TrimBox", "/ArtBox"):
            if box in obj:
                del obj[box]
        obj.MediaBox = pikepdf.Array([0, 0, W, H])
        for annot in obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary):
                _transform_annotation(annot, m)
    return {"pages": len(indexes), "size": [tw, th]}


# ---------------------------------------------------------------- transitions

TRANSITIONS = ("Split", "Blinds", "Box", "Wipe", "Dissolve", "Glitter", "R", "Fly", "Push", "Cover", "Uncover", "Fade")


@op("set_transitions")
def set_transitions(ctx, style=None, pages=None, duration=1.0, direction=None, dimension=None,
                    motion=None, advance=None):
    """style None removes transitions. advance: seconds before auto-advance (/Dur)."""
    pdf = ctx.pdf
    indexes = _indexes(pdf, pages)
    require(style is None or style in TRANSITIONS, "INVALID_ARGUMENT", "Unknown transition.")
    for index in indexes:
        obj = pdf.pages[index].obj
        for key in ("/Trans", "/Dur"):
            if key in obj:
                del obj[key]
        if style is None:
            continue
        trans = pikepdf.Dictionary(Type=Name.Trans, S=Name("/" + style), D=float(duration))
        if direction is not None and style in ("Wipe", "Glitter", "Fly", "Cover", "Uncover", "Push"):
            trans.Di = int(direction)
        if dimension in ("H", "V") and style in ("Split", "Blinds"):
            trans.Dm = Name("/" + dimension)
        if motion in ("I", "O") and style in ("Split", "Box", "Fly"):
            trans.M = Name("/" + motion)
        obj.Trans = trans
        if advance is not None:
            require(float(advance) > 0, "INVALID_ARGUMENT", "Auto-advance needs a positive duration.")
            obj.Dur = float(advance)
    return {"pages": len(indexes)}


@query("page_transitions")
def page_transitions(ctx):
    out = []
    for page in ctx.pdf.pages:
        trans = page.obj.get("/Trans")
        out.append({"style": str(trans.get("/S", "/R"))[1:] if trans is not None else None,
                    "duration": float(trans.get("/D", 1)) if trans is not None else None,
                    "advance": float(page.obj.Dur) if "/Dur" in page.obj else None})
    return {"pages": out}


# ---------------------------------------------------------------- inspection

def _reachable_size(obj, seen, depth=0):
    """Approximate serialized bytes of the indirect objects reachable from obj."""
    total = 0
    stack = [obj]
    while stack:
        node = stack.pop()
        if isinstance(node, pikepdf.Object) and node.is_indirect:
            key = node.objgen
            if key in seen:
                continue
            seen.add(key)
            total += 40
            if isinstance(node, pikepdf.Stream):
                try:
                    total += len(node.read_raw_bytes())
                except pikepdf.PdfError:
                    pass
        if isinstance(node, (pikepdf.Dictionary, pikepdf.Stream)):
            if node.get("/Type") == Name.Page and node is not obj and depth > 0:
                continue
            for key, value in node.items():
                if key in ("/Parent", "/P", "/Dest", "/A", "/IRT") and node is not obj:
                    continue
                if key in ("/Parent",):
                    continue
                if isinstance(value, CONTAINERS):
                    if isinstance(value, pikepdf.Dictionary) and value.get("/Type") == Name.Page:
                        continue
                    stack.append(value)
                else:
                    total += 8
        elif isinstance(node, pikepdf.Array):
            for value in node:
                if isinstance(value, CONTAINERS):
                    if isinstance(value, pikepdf.Dictionary) and value.get("/Type") == Name.Page:
                        continue
                    stack.append(value)
                else:
                    total += 8
        depth += 1
    return total


@query("split_by_size")
def split_by_size(ctx, max_bytes):
    """Greedy page groups whose estimated standalone size stays under max_bytes
    (a single oversized page forms its own group). Shared resources count once
    per group, as they would in each split file."""
    require(isinstance(max_bytes, (int, float)) and max_bytes >= 10_000, "INVALID_ARGUMENT",
            "Choose a maximum size of at least 10 KB.")
    pdf = ctx.pdf
    # Every part keeps the document-level objects (form, tags, metadata, output intents,
    # names…): count them once per part, and never again for its pages.
    shared = set()
    base = 2000 + sum(_reachable_size(value, shared) for key, value in pdf.Root.items()
                      if key not in ("/Pages", "/Type") and isinstance(value, CONTAINERS))
    # Raw object sizes overstate the saved file (object streams, shared dictionaries):
    # scale by how the whole estimate compares with the document's real size.
    total_seen = set(shared)
    estimate = base + sum(_reachable_size(page.obj, total_seen) for page in pdf.pages)
    try:
        factor = min(1.25, max(0.5, ctx.source.stat().st_size / estimate))
    except (OSError, ZeroDivisionError, AttributeError):
        factor = 1.0
    limit = max_bytes / factor
    groups, current, seen, size = [], [], set(shared), base
    for index, page in enumerate(pdf.pages):
        trial = set(seen)
        added = _reachable_size(page.obj, trial)
        if current and size + added > limit:
            groups.append(current)
            current, seen, size = [], set(shared), base
            trial = set(shared)
            added = _reachable_size(page.obj, trial)
        current.append(index)
        seen = trial
        size += added
    if current:
        groups.append(current)
    return {"groups": groups}


@query("page_info")
def page_info(ctx):
    out = []
    for page in ctx.pdf.pages:
        obj = page.obj
        boxes = {}
        for name in BOXES:
            if name in obj:
                boxes[name[1:]] = _rect(obj[name])
        boxes.setdefault("MediaBox", _rect(page_box(page, "/MediaBox")))
        out.append({"rotation": rotation(page), "boxes": boxes})
    return {"pages": out, "labels": labels_for(ctx.pdf)}
