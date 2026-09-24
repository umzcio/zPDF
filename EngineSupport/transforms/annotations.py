"""Generic annotation edits carried from PDFKit.

PDFKit renders every annotation type the app edits and writes an appearance
stream for it. The app writes changed or new annotations into a scratch PDF
whose pages mirror the edited pages; this module grafts those dictionaries
into the document of record. Existing annotations are updated in place, so
references to them (popups, replies, structure) stay intact.

`annotations` runs before the v0 facade and never changes an existing
annotation's index: deletions are only marked. `finalize` runs last and
removes marked annotations together with their popups and reply threads.
"""
import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op

DELETE = Name("/ZPDFDelete")
# Keys PDFKit owns for an edited annotation. Anything else on the original
# dictionary (NM, IRT, Popup, structure parent, rich-text subject...) is kept.
OWNED = ("/Rect", "/AP", "/C", "/IC", "/BS", "/Border", "/BE", "/Contents", "/QuadPoints",
         "/InkList", "/L", "/LE", "/Vertices", "/DA", "/DS", "/Q", "/Name", "/CA", "/F",
         "/M", "/T", "/RD", "/CL", "/IT", "/Rotate", "/FS")
PRIVATE = ("/ZPDFDelete", "/ZPDFCommentID", "/ZPDFNewField", "/ZPDFScratchKey", "/ZPDFReplyTo", "/ZPDFRevision")


def _annots(page):
    annots = page.obj.get("/Annots")
    if annots is None:
        annots = pikepdf.Array()
        page.obj.Annots = annots
    return annots


def _foreign(ctx, scratch, page_index, key):
    require(isinstance(page_index, int) and 0 <= page_index < len(scratch.pages), "INVALID_ARGUMENT",
            "The annotation scratch file is incomplete.")
    matches = [a for a in scratch.pages[page_index].obj.get("/Annots", [])
               if str(a.get("/ZPDFScratchKey", "")) == key]
    require(len(matches) == 1, "INVALID_ARGUMENT", "The annotation scratch file is incomplete.")
    source = matches[0]
    for private in PRIVATE:
        if private in source:
            del source[private]
    # A PDFKit companion popup would be copied as an orphan; replies and popups
    # of the document of record are preserved from the original instead.
    for key in ("/Popup", "/P", "/Parent", "/IRT"):
        if key in source:
            del source[key]
    return ctx.pdf.copy_foreign(source)


@op("annotations")
def annotations(ctx, scratch, items):
    require(isinstance(items, list), "INVALID_ARGUMENT", "Annotation items are required.")
    counts = {"added": 0, "updated": 0, "deleted": 0}
    from contextlib import nullcontext
    needs_scratch = any(item.get("action") in ("add", "update") for item in items)
    with (pikepdf.open(scratch) if needs_scratch else nullcontext()) as foreign:
        # Resolve every target before the first mutation.
        planned = []
        for item in items:
            action = item.get("action")
            page_index = item.get("page")
            require(isinstance(page_index, int) and 0 <= page_index < len(ctx.pdf.pages),
                    "STALE_PAGE", "An annotation refers to a page that no longer exists.")
            page = ctx.pdf.pages[page_index]
            target = None
            if action in ("update", "delete"):
                index = item.get("index")
                annots = page.obj.get("/Annots", pikepdf.Array())
                require(isinstance(index, int) and 0 <= index < len(annots), "STALE_ANNOTATION",
                        "An annotation no longer matches the opened file.")
                target = annots[index]
                expected = item.get("subtype")
                if expected:
                    require(str(target.get("/Subtype", "")) == "/" + expected, "STALE_ANNOTATION",
                            "An annotation no longer matches the opened file.")
            else:
                require(action == "add", "INVALID_ARGUMENT", "Unknown annotation action.")
            planned.append((action, page, target, item))
        for action, page, target, item in planned:
            if action == "delete":
                target[DELETE] = True
                counts["deleted"] += 1
                continue
            copied = _foreign(ctx, foreign, item.get("scratch_page"), item.get("scratch_key"))
            if action == "update":
                for key in OWNED:
                    if key in copied:
                        target[key] = copied[key]
                    elif key in target and key not in ("/NM", "/F"):
                        del target[key]
                if "/Contents" in copied and "/RC" in target:
                    del target["/RC"]  # stale rich text would override edited contents
                counts["updated"] += 1
            else:
                copied.P = page.obj
                if item.get("reply_to") is not None:
                    parent_page, parent_index = item["reply_to"]
                    parents = ctx.pdf.pages[parent_page].obj.get("/Annots", [])
                    require(0 <= parent_index < len(parents), "STALE_ANNOTATION", "A reply's parent comment no longer exists.")
                    copied.IRT = parents[parent_index]
                    copied.RT = Name.R
                _annots(page).append(copied)
                counts["added"] += 1
    return counts


def _remove_marked(pdf):
    removed = set()
    for page in pdf.pages:
        for annot in page.obj.get("/Annots", []):
            if annot.get(DELETE) is True and annot.is_indirect:
                removed.add(annot.objgen)
    changed = True
    while changed:  # a removed parent removes its popup and its whole reply thread
        changed = False
        for page in pdf.pages:
            for annot in page.obj.get("/Annots", []):
                if not annot.is_indirect or annot.objgen in removed:
                    continue
                for key in ("/IRT", "/Parent"):
                    target = annot.get(key)
                    if target is not None and target.is_indirect and target.objgen in removed:
                        removed.add(annot.objgen)
                        changed = True
    count = 0
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if annots is None:
            continue
        kept = [a for a in annots if not (a.is_indirect and a.objgen in removed)]
        count += len(annots) - len(kept)
        page.obj.Annots = pikepdf.Array(kept)
    return count


@op("finalize")
def finalize(ctx):
    removed = _remove_marked(ctx.pdf)
    for page in ctx.pdf.pages:
        for annot in page.obj.get("/Annots", []):
            for key in PRIVATE:
                if key in annot:
                    del annot[key]
    return {"removed": removed}


@op("flatten_annotations")
def flatten_annotations(ctx, pages=None, include_widgets=False):
    """Draw annotation appearances into page content and remove them."""
    targets = range(len(ctx.pdf.pages)) if pages is None else pages
    count = 0
    for index in targets:
        page = ctx.pdf.pages[index]
        annots = page.obj.get("/Annots")
        if not annots:
            continue
        kept, flattened = [], []
        for annot in annots:
            subtype = str(annot.get("/Subtype", ""))
            if subtype in ("/Popup", "/Link") or (subtype == "/Widget" and not include_widgets):
                kept.append(annot)
                continue
            flags = int(annot.get("/F", 0))
            if flags & 2 or "/AP" not in annot or "/N" not in annot.AP:  # hidden or no appearance
                if subtype != "/Widget":
                    continue
                kept.append(annot)
                continue
            flattened.append(annot)
        if not flattened:
            continue
        page.obj.Annots = pikepdf.Array(kept)
        from transforms.content import stamp_appearances
        stamp_appearances(ctx.pdf, page, flattened)
        count += len(flattened)
    if include_widgets and "/AcroForm" in ctx.pdf.Root:
        from transforms.forms import prune_fields
        prune_fields(ctx.pdf)
    return {"flattened": count}
