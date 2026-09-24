"""Document assembly: snapshot -> per-page extraction -> tables -> layout ->
ordered IR with figures, form values, and comments (spec section 8)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import BACKEND_ID
from .errors import ExportError
from .extract import PageExtract, extract_page, sample_fill_colours
from .forms import pair_widgets
from .geometry import BBox
from .ir import (SCHEMA_VERSION, CommentNode, Document, FigureNode, FormValueNode, PageInfo,
                 TableNode, TextNode, make_asset)
from .layout import analyze_layout, order_atoms
from .snapshot import open_snapshot
from .tables import detect_tables

_LINK_SCHEMES = {"http", "https", "mailto"}

ProgressFn = Callable[[str, int, int], None]
CancelFn = Callable[[], bool]


@dataclass
class ExportOptions:
    include_images: bool = True
    include_hyperlinks: bool = True
    include_form_values: bool = True
    include_comments: bool = True
    running_headers: str = "preserve"
    layout_mode: str = "preserve"   # preserve (layout-preserving DOCX, primary) | reflow (explicit fallback)
    ocr: str = "off"
    locale: str | None = None
    allow_partial: bool = False
    # internal, set by the worker for XLSX (not a request option): recover the
    # unruled bodies of tables whose ruled header alone was detected
    data_tables: bool = False

    def validate(self) -> None:
        if self.ocr != "off":
            raise ExportError("UNSUPPORTED_OPTION", "ocr_unavailable", option="ocr", value=str(self.ocr))
        if self.running_headers != "preserve":
            raise ExportError("UNSUPPORTED_OPTION", "running_header_removal_unavailable",
                              option="running_headers", value=str(self.running_headers))
        if self.locale is not None:
            raise ExportError("UNSUPPORTED_OPTION", "locale_rules_unavailable", option="locale")
        if self.layout_mode not in ("preserve", "reflow"):
            raise ExportError("UNSUPPORTED_OPTION", "layout_mode_unknown", option="layout_mode", value=str(self.layout_mode))
        for name in ("include_images", "include_hyperlinks", "include_form_values",
                     "include_comments", "allow_partial"):
            if not isinstance(getattr(self, name), bool):
                raise ExportError("INVALID_REQUEST", "option_not_boolean", option=name)


def validate_pages(pages, page_count: int) -> list[int]:
    if not isinstance(pages, list) or not pages:
        raise ExportError("INVALID_REQUEST", "pages_empty")
    for p in pages:
        if isinstance(p, bool) or not isinstance(p, int):
            raise ExportError("INVALID_REQUEST", "page_not_integer")
        if p < 1 or p > page_count:
            raise ExportError("INVALID_REQUEST", "page_out_of_range", page=p)
    if any(b <= a for a, b in zip(pages, pages[1:])):
        raise ExportError("INVALID_REQUEST", "pages_not_ascending_unique")
    return list(pages)


class _Atom:
    """Ordering wrapper so blocks, tables, and figures share one XY-cut."""

    def __init__(self, kind: str, lbox: BBox, payload) -> None:
        self.kind = kind
        self.lbox = lbox
        self.payload = payload


def _region(page: int, bbox: BBox) -> dict:
    return {"page": page, "bbox": bbox.rounded()}


def _run_dicts(runs, include_hyperlinks: bool) -> list[dict]:
    out = []
    for r in runs:
        d = {"text": r.text, "bold": r.bold, "italic": r.italic}
        if include_hyperlinks and r.uri:
            d["uri"] = r.uri
        if include_hyperlinks and r.dest_page:
            d["dest_page"] = r.dest_page
        out.append(d)
    return out


def build_document(path: Path, sha256: str, pages, options: ExportOptions,
                   progress: ProgressFn | None = None, cancelled: CancelFn | None = None) -> Document:
    options.validate()
    snap = open_snapshot(Path(path), sha256)
    try:
        selected = validate_pages(pages, snap.page_count)
        doc = Document(SCHEMA_VERSION, snap.sha256, BACKEND_ID, [], [], {}, {}, [], {})
        doc.layouts = []  # type: ignore[attr-defined]  # PageLayout per page (layout_mode = preserve)
        stats = {"pages_requested": len(selected), "pages_processed": 0, "paragraphs": 0,
                 "tables": 0, "images": 0, "form_values": 0, "comments": 0}
        for i, pno in enumerate(selected):
            if cancelled and cancelled():
                raise ExportError("CANCELLED", "cancelled_during_extraction", page=pno)
            if progress:
                progress("extract", i, len(selected))
            page = extract_page(snap, pno)
            sample_fill_colours(snap, page)   # bars behind text take the colour the page shows
            _process_page(doc, page, options, stats)
            _render_blended_backdrops(snap, page, doc)
            stats["pages_processed"] += 1
            if progress:
                progress("extract", i + 1, len(selected))
        image_only = stats.get("image_only_pages", [])
        if image_only and len(image_only) == len(selected) and not options.allow_partial:
            raise ExportError("OCR_REQUIRED", "image_only_page", page=image_only[0])
        stats["warnings"] = len(doc.warnings)
        doc.stats = stats
        return doc
    finally:
        snap.close()


def _render_blended_backdrops(snap, page: PageExtract, doc: Document) -> None:
    """A backdrop fill that renders with the pictures under it showing through
    (a blend mode, a soft mask, a translucent bar over a photograph) cannot be
    a flat colour picture: it is carried as a render of its region from the
    page without its text, so what shows through is what the reader shows."""
    layouts = getattr(doc, "layouts", None)
    if not layouts or layouts[-1] is None:
        return
    lay = layouts[-1]
    blended = [f for f in getattr(lay, "backdrops", []) if getattr(f, "blended", False)]
    if not blended:
        return
    from .artwork import _render_region, clean_page
    src = clean_page(snap, page.index, drop_images=False)   # the words go, the pictures under the fill stay
    if src is None:
        return
    for f in blended:
        png, _w, _h = _render_region(src, page, f.bbox, min_ink=0.0)
        if png is not None:
            f.png = png  # type: ignore[attr-defined]


def _process_page(doc: Document, page: PageExtract, options: ExportOptions, stats: dict) -> None:
    pno = page.index
    doc.pages.append(PageInfo(pno, page.width, page.height, page.rotation, page.user_unit,
                              list(page.media_box), list(page.crop_box)))
    doc.warnings.extend(page.warnings)

    real_chars = [c for c in page.chars if not c.generated and not c.text.isspace()]
    if page.links and options.include_hyperlinks:
        from urllib.parse import urlsplit
        unsafe = 0
        for link in page.links:
            if not link.uri:
                continue  # internal destinations stay plain text in every writer
            if urlsplit(link.uri).scheme.lower() not in _LINK_SCHEMES:
                unsafe += 1
                continue
            for c in real_chars:
                if link.lbox.contains_point(c.lbox.cx, c.lbox.cy):
                    c.uri = link.uri
        if unsafe:
            doc.warnings.append({"code": "LINK_DROPPED_UNSAFE_SCHEME", "page": pno, "count": unsafe})
    missing = sum(1 for c in real_chars if c.missing_map)
    if missing:
        doc.warnings.append({"code": "MISSING_UNICODE_MAP", "page": pno, "count": missing})

    tables = detect_tables(page)
    if options.data_tables:
        from .stream_tables import extend_table_bodies
        tables, extra = extend_table_bodies(page, tables)
        doc.warnings.extend(extra)
    for t in tables:
        doc.warnings.extend(t.warnings)
    if page.artwork:
        # artwork drawn over a table (arrows, circled cells) is reported, not rendered
        kept = []
        for im in page.artwork:
            if not getattr(im, "behind", False) and any(t.lbox.intersects(im.lbox) for t in tables):
                doc.warnings.append({"code": "VECTOR_ARTWORK_OVERLAPS_TEXT", "page": pno, "object_id": im.image_id,
                                     "objects": im.objects, "bbox": im.bbox.rounded(), "reason": "inside_table"})
                doc.warnings[:] = [w for w in doc.warnings if not (w.get("code") == "VECTOR_ARTWORK_RENDERED"
                                                                   and w.get("object_id") == im.image_id)]
            else:
                kept.append(im)
        page.artwork = kept
    if page.absorbed_chars and options.include_images:
        # rendered artwork, and pictures that keep the labels drawn over them (a map)
        holders = list(page.artwork) + [im for im in page.images if im.absorbed_text]
        absorbed_kept = {id(c) for im in holders for c in page.chars
                         if id(c) in page.absorbed_chars and im.lbox.contains_point(c.lbox.cx, c.lbox.cy)}
        page.chars = [c for c in page.chars if id(c) not in absorbed_kept]
    exclude = [t.lbox for t in tables]
    blocks = analyze_layout(page, exclude)

    pairs = []
    if page.widgets and options.include_form_values:
        pairs, blocks = pair_widgets(page, blocks, tables)
        for fp in pairs:
            if fp.placement == "table_cell" and fp.table_id is not None:
                cell = next(t for t in tables if t.table_id == fp.table_id).cells[fp.cell_index]
                shown = _display_value(fp.widget)
                cell.raw_text = (cell.raw_text + "\n" + shown).strip("\n") if shown else cell.raw_text
                if shown:
                    w = fp.widget
                    is_box = w.field_type in ("checkbox", "radio")
                    # in its own grid cell a check box is just the glyph; the export
                    # value would wrap inside the box and inflate the row
                    cell.values.append({"text": ("\u2612" if w.checked else "\u2610") if is_box else shown,
                                        "lbox": w.lbox,
                                        "size": min(_value_size(w), max(4.0, min(cell.lbox.width, cell.lbox.height) * 0.9)) if is_box else _value_size(w),
                                        "bold": not is_box, "font": ""})

    figures = []
    if page.images or page.artwork:
        if options.include_images:
            # raster pictures are content wherever they sit, ruled figure grids
            # included; artwork over a table stays reported (see above)
            figures = list(page.images) + list(page.artwork)
        else:
            doc.warnings.append({"code": "CONTENT_EXCLUDED_BY_OPTION", "page": pno,
                                 "option": "include_images", "count": len(page.images) + len(page.artwork)})

    # scan / blank detection (a scan carrying an OCR layer has text: it is hidden
    # text in the output, not a page that needs OCR)
    if not real_chars and not tables and not getattr(page, "hidden_chars", None):
        page_area = page.layout_width * page.layout_height
        img_area = sum(im.lbox.width * im.lbox.height for im in page.images)
        if page.images and img_area > 0.5 * page_area:
            # one bare page in a document with readable pages is placed as its
            # picture and reported; a document with no text at all is refused
            # after the pass (OCR_REQUIRED) unless partial output was allowed
            stats.setdefault("image_only_pages", []).append(pno)
            doc.warnings.append({"code": "IMAGE_ONLY_PAGE", "page": pno})
            nid = f"p{pno}-unsupported-1"
            doc.nodes[nid] = TextNode(nid, "unsupported", [_region(pno, BBox(0, 0, page.width, page.height))],
                                      text=f"[Page {pno}: image-only content was not converted to text]")
            doc.flow.append(nid)
        elif not page.images:
            doc.warnings.append({"code": "BLANK_PAGE", "page": pno})

    sentences = []
    seen_sentences: set[int] = set()
    for fp in pairs:
        if fp.placement == "inline_sentence" and fp.sentence is not None and id(fp.sentence) not in seen_sentences:
            seen_sentences.add(id(fp.sentence))
            sentences.append(fp.sentence)
    atoms = ([_Atom("block", b.lbox, b) for b in blocks]
             + [_Atom("table", t.lbox, t) for t in tables]
             + [_Atom("figure", im.lbox, im) for im in figures]
             + [_Atom("field", fp.anchor_lbox, fp) for fp in pairs if fp.placement == "inline"]
             + [_Atom("sentence", sn.lbox, sn) for sn in sentences])
    sentence_ids: dict[int, str] = {}
    k = 0
    for atom in order_atoms(atoms):
        if atom.kind == "block":
            b = atom.payload
            if getattr(b, "drop_cap_of", None) is not None:
                continue                       # read as the first letter of its paragraph
            k += 1
            nid = f"p{pno}-block-{k}"
            text, runs = b.text, _run_dicts(b.runs, options.include_hyperlinks)
            cap = getattr(b, "drop_cap", None)
            if cap is not None:
                letter = cap.text.strip()
                text = letter + text
                if runs:
                    runs = [dict(runs[0], text=letter + runs[0]["text"])] + runs[1:]
                else:
                    runs = [{"text": letter, "bold": False, "italic": False}]
            doc.nodes[nid] = TextNode(nid, b.kind, [_region(pno, b.bbox if cap is None else b.bbox.union(cap.bbox))],
                                      text=text, runs=runs, level=b.level, marker=b.marker, line_count=b.lines)
            stats["paragraphs"] += 1
        elif atom.kind == "table":
            t = atom.payload
            cells = [{"row": c.row, "col": c.col, "rowspan": c.rowspan, "colspan": c.colspan,
                      "raw_text": c.raw_text, "bbox": c.bbox.rounded(), "bold": c.bold} for c in t.cells]
            doc.nodes[t.table_id] = TableNode(t.table_id, "table", [_region(pno, t.bbox)], n_rows=t.n_rows,
                                              n_cols=t.n_cols, cells=cells, header_rows=list(t.header_rows),
                                              header_inference=t.header_inference,
                                              row_inference=list(t.row_inference))
            stats["tables"] += 1
        elif atom.kind == "figure":
            im = atom.payload
            asset = make_asset(im.image_id, im.png_bytes, im.width_px, im.height_px)
            doc.assets[asset.asset_id] = asset
            doc.nodes[im.image_id] = FigureNode(im.image_id, "figure", [_region(pno, im.bbox)],
                                                asset_id=asset.asset_id, width_px=im.width_px,
                                                height_px=im.height_px, origin=im.origin, objects=im.objects,
                                                absorbed_text=im.absorbed_text)
            stats["images"] += 1
            nid = im.image_id
        elif atom.kind == "sentence":
            sn = atom.payload
            k += 1
            nid = f"p{pno}-block-{k}"
            doc.nodes[nid] = TextNode(nid, "paragraph", [_region(pno, sn.bbox)], text=sn.text,
                                      runs=_run_dicts(sn.runs, options.include_hyperlinks), line_count=sn.lines,
                                      choices=[w.widget_id for w in sn.widgets])
            sentence_ids[id(sn)] = nid
            stats["paragraphs"] += 1
        else:
            nid = _add_form_node(doc, pno, atom.payload, stats)
        doc.flow.append(atom.payload.table_id if atom.kind == "table" else nid)
    # boxes embedded in sentences, widgets paired to table cells (value already in
    # the cell), and unpaired widgets
    for fp in pairs:
        if fp.placement == "inline_sentence":
            nid = _add_form_node(doc, pno, fp, stats)
            doc.nodes[nid].sentence_id = sentence_ids.get(id(fp.sentence))
            doc.flow.append(nid)
        elif fp.placement != "inline":
            doc.flow.append(_add_form_node(doc, pno, fp, stats))

    # text drawn invisibly (a scan's OCR layer, the text layer of a graphic) is
    # content too: one node per page, which reading-order writers carry in a
    # collapsed or hidden form and layout writers place from the page layout
    hidden = getattr(page, "hidden_chars", None)
    if hidden:
        from .layout_preserve import lines_from_chars
        lines = ["".join(r["text"] for r in ln.runs).strip() for ln in lines_from_chars(hidden)]
        text = "\n".join(t for t in lines if t)
        if text:
            nid = f"p{pno}-invisible-text"
            doc.nodes[nid] = TextNode(nid, "invisible", [_region(pno, BBox(0, 0, page.width, page.height))],
                                      text=text, runs=[{"text": text, "bold": False, "italic": False}],
                                      line_count=text.count("\n") + 1)
            doc.flow.append(nid)

    if options.layout_mode == "preserve":
        from .layout_preserve import decompose_page
        layout = decompose_page(page, blocks, tables, figures, pairs, sentences,
                                page.comments if options.include_comments else [])
        doc.layouts.append(layout)  # type: ignore[attr-defined]
        doc.warnings.extend(layout.warnings)

    if page.widgets and not options.include_form_values:
        doc.warnings.append({"code": "CONTENT_EXCLUDED_BY_OPTION", "page": pno,
                             "option": "include_form_values", "count": len(page.widgets)})
    unpaired = [fp for fp in pairs if not fp.paired]
    if unpaired:
        doc.warnings.append({"code": "FORM_VALUE_UNPAIRED", "page": pno, "count": len(unpaired),
                             "object_ids": [fp.widget.widget_id for fp in unpaired]})
    if page.comments:
        if options.include_comments:
            for c in page.comments:
                nid = f"{c.comment_id}-comment"
                doc.nodes[nid] = CommentNode(nid, "comment", [_region(pno, c.bbox)], comment_kind=c.kind,
                                             text=c.text, author=c.author, modified=c.modified)
                doc.flow.append(nid)
                stats["comments"] += 1
        else:
            doc.warnings.append({"code": "CONTENT_EXCLUDED_BY_OPTION", "page": pno,
                                 "option": "include_comments", "count": len(page.comments)})


def _value_size(w) -> float:
    if w.field_type in ("checkbox", "radio"):
        return max(6.0, min(w.lbox.height * 0.8, 10.0))
    return max(7.0, min(w.lbox.height * 0.55, 11.0))


def _display_value(w) -> str:
    if w.field_type in ("checkbox", "radio"):
        return ("\u2612 " if w.checked else "\u2610 ") + (w.export_value or "")
    return w.value


def _add_form_node(doc: Document, pno: int, fp, stats: dict) -> str:
    w = fp.widget
    nid = f"{w.widget_id}-value"
    doc.nodes[nid] = FormValueNode(
        nid, "form_value", [_region(pno, fp.anchor_bbox), _region(pno, w.bbox)],
        field_name=w.field_name, label=fp.label, field_type=w.field_type, raw_value=w.value,
        checked=w.checked, export_value=w.export_value, widget_ids=[w.widget_id],
        paired=fp.paired, label_source=fp.label_source, placement=fp.placement, group_id=fp.group_id,
        table_id=fp.table_id, tooltip=w.label, ambiguity=list(fp.ambiguity),
    )
    stats["form_values"] += 1
    stats["form_values_paired"] = stats.get("form_values_paired", 0) + (1 if fp.paired else 0)
    return nid
