"""Document assembly: snapshot -> per-page extraction -> tables -> layout ->
ordered IR with figures, form values, and comments (spec section 8)."""
from __future__ import annotations

import re
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
    # internal, set by the worker for PPTX page_image mode: render each page's
    # drawing (without its text and pictures) as one picture for the slide background
    page_drawings: bool = False
    # internal, set by the worker for XML: keep every text node's lines and words
    # with their boxes and fonts (doc.geometry, node id → lines)
    keep_geometry: bool = False

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


def _dominant_font(block) -> tuple[str | None, float | None]:
    """The font name and size most of a block's glyphs are set in."""
    from collections import Counter
    count: Counter = Counter()
    for t in getattr(block, "tokens", []) or []:
        c = t.char
        if not c.text.isspace() and not c.generated:
            count[(c.font_name, round(c.font_size * 2) / 2)] += 1
    if not count:
        return None, None
    (font, size), _n = count.most_common(1)[0]
    return font or None, size or None


def _word_lines(token_lines, include_hyperlinks: bool) -> list[dict]:
    """Lines of words from lines of glyph tokens: a word ends at a space (a space
    glyph or the line builder's space mark). Boxes are in normalized displayed
    space (points, top-left origin), as the IR's regions."""
    from collections import Counter
    out = []
    for toks in token_lines:
        words: list[list] = []
        for t in toks:
            c = t.char
            if c.text.isspace() or c.generated:
                if words and words[-1]:
                    words.append([])
                continue
            if t.space_before and words and words[-1]:
                words.append([])
            if not words:
                words.append([])
            words[-1].append(c)
        line_words = []
        for w in (w for w in words if w):
            box = w[0].bbox
            for c in w[1:]:
                box = box.union(c.bbox)
            fonts = Counter((c.font_name, round(c.font_size, 2)) for c in w)
            (font, size), _n = fonts.most_common(1)[0]
            d = {"text": "".join(c.text for c in w), "bbox": box.rounded(), "font": font or "", "size": size,
                 "bold": sum(c.bold for c in w) * 2 > len(w), "italic": sum(c.italic for c in w) * 2 > len(w)}
            uri = next((c.uri for c in w if getattr(c, "uri", None)), None)
            if include_hyperlinks and uri:
                d["uri"] = uri
            line_words.append(d)
        if line_words:
            box = None
            for d in line_words:
                b = d["bbox"]
                box = list(b) if box is None else [min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3])]
            out.append({"bbox": box, "words": line_words})
    return out


def _fill_missing_geometry(doc, page, node_ids, include_hyperlinks: bool) -> None:
    """Text that reached the IR without its own glyph list (a check-box
    sentence, a table body recovered by column alignment) takes the page's
    visible glyphs inside its box, in line order."""
    from .textlines import build_lines
    visible = [c for c in page.chars if not c.generated and not c.invisible and not c.text.isspace()
               and id(c) not in page.absorbed_chars]

    def inside(bbox):
        x0, y0, x1, y1 = bbox
        return [c for c in visible if x0 - 0.5 <= c.bbox.cx <= x1 + 0.5 and y0 - 0.5 <= c.bbox.cy <= y1 + 0.5]

    def lines(chars):
        return _word_lines([ln.tokens for ln in build_lines(chars)], include_hyperlinks) if chars else []

    import unicodedata
    from collections import Counter

    def missing(text, geo) -> int:
        """Letters and digits of the text that the geometry's words do not hold."""
        want = Counter(ch for ch in unicodedata.normalize("NFKC", text) if ch.isalnum())
        have = Counter(ch for ln in geo for w in ln["words"] for ch in unicodedata.normalize("NFKC", w["text"])
                       if ch.isalnum())
        return sum((want - have).values())

    def settle(key, text, bbox):
        """The node's own glyphs, unless the glyphs inside its box account for
        its text better (a header cell widened to its rule, a row label joined
        from pieces, a check-box sentence)."""
        own = doc.geometry.get(key) or []
        if not text.strip() or (own and missing(text, own) == 0):
            return
        boxed = lines(inside(bbox))
        if missing(text, boxed) < missing(text, own) or not own:
            doc.geometry[key] = boxed

    for nid in node_ids:
        node = doc.nodes.get(nid)
        if isinstance(node, TextNode) and node.kind != "invisible":
            settle(nid, node.text, node.source_regions[0]["bbox"])
        elif isinstance(node, TableNode):
            for c in node.cells:
                settle(f"{nid}:{c['row']}:{c['col']}", c.get("raw_text", ""), c["bbox"])


def _token_lines_of_block(block):
    from .layout_preserve import _token_lines_of
    return _token_lines_of(block)


def _block_geometry(block, include_hyperlinks: bool) -> list[dict]:
    from .layout_preserve import _token_lines_of
    return _word_lines(_token_lines_of(block), include_hyperlinks)


def _cell_geometry(cell, include_hyperlinks: bool, page=None) -> list[dict]:
    """A cell's lines of words. A cell's glyph list holds no space glyphs; the
    page's spaces inside the cell mark its word breaks ('if applicable', set
    tight, is two words)."""
    from .textlines import build_lines
    chars = list(cell.chars)
    if page is not None and chars:
        box = cell.lbox
        order = {id(c): k for k, c in enumerate(page.chars)}
        spaces = [c for c in page.chars if c.text == " " and not c.generated and c.lbox.width > 0
                  and box.contains_point(c.lbox.cx, c.lbox.cy)]
        chars = sorted(chars + spaces, key=lambda c: order.get(id(c), 0))
    return _word_lines([ln.tokens for ln in build_lines(chars)], include_hyperlinks)


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
        doc.geometry = {}  # type: ignore[attr-defined]  # node id → lines of words (keep_geometry)
        doc.keep_geometry = options.keep_geometry  # type: ignore[attr-defined]
        doc.outline = _outline(snap)  # type: ignore[attr-defined]  # the PDF's bookmarks (EPUB navigation)
        try:
            meta = snap.pdf.get_metadata_dict()
        except Exception:  # noqa: BLE001
            meta = {}
        doc.title = (meta.get("Title") or "").strip() or None  # type: ignore[attr-defined]
        doc.author = (meta.get("Author") or "").strip() or None  # type: ignore[attr-defined]
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
            if options.page_drawings:
                _render_page_drawing(snap, page, doc)
            stats["pages_processed"] += 1
            if progress:
                progress("extract", i + 1, len(selected))
        _join_line_break_hyphens(doc)
        image_only = stats.get("image_only_pages", [])
        if image_only and len(image_only) == len(selected) and not options.allow_partial:
            raise ExportError("OCR_REQUIRED", "image_only_page", page=image_only[0])
        stats["warnings"] = len(doc.warnings)
        doc.stats = stats
        return doc
    finally:
        snap.close()


_BREAK = re.compile(r"([A-Za-z\u00c0-\u024f]+)[-\u00ad]\s+([a-z\u00df-\u024f][A-Za-z\u00c0-\u024f]*)")
# fragments a hyphenation break leaves after the hyphen (a compound's second part is a word)
_SUFFIX = re.compile(r"(?i)^(tions?|sions?|ments?|ings?|ity|ities|als?|ates?|ated|ed|ers?|ters?|ous|ibl[ey]|abl[ey]|"
                     r"ences?|ances?|ive|iz(e|ed|es|ing)|is(m|ts?)|ful(ly)?|ly|cy|ry|ty|ties|ures?|ians?|ic(al)?|"
                     r"ogy|ness|ship|ward|ish|ery|ory|age|ages|ance|ant|ent|ents|ents)$")
_WORDS = re.compile(r"[A-Za-z\u00c0-\u024f]+(?:-[A-Za-z\u00c0-\u024f]+)*")


def _join_line_break_hyphens(doc) -> None:
    """A hyphen that ended a source line, read in reading order as 'under-
    standing'. The space always goes. The hyphen goes too unless the document
    itself says it belongs: the joined word appears elsewhere → join; the
    hyphenated form appears elsewhere → keep ('three-dimensional'); the first
    part is a word of the document and the second a word-like part, not a
    suffix fragment → keep ('Mining-related', 'ground-based'); else it was a
    hyphenation point ('knowl- edge' → 'knowledge', 'contrast- ing'). Reading-order text
    only; layout modes keep each line as drawn."""
    from collections import Counter
    nodes = [n for n in doc.nodes.values() if isinstance(n, TextNode) and n.kind != "invisible"]
    if not any(_BREAK.search(n.text) for n in nodes):
        return
    vocab: Counter = Counter()
    for n in nodes:
        for w in _WORDS.findall(_BREAK.sub(" ", n.text)):      # words not at a break
            vocab[w.lower()] += 1
            for part in w.split("-"):
                vocab[part.lower()] += 1 if "-" in w else 0

    def keep_hyphen(a: str, b: str) -> bool:
        joined, hyph = (a + b).lower(), f"{a}-{b}".lower()
        if vocab[joined]:
            return False                   # the word appears whole: a hyphenation point
        if vocab[hyph]:
            return True                    # the hyphenated form appears mid-line: a compound
        # a word of the document, then a word-like part (not a suffix fragment):
        # most likely a compound ('ground-based', 'time-consuming'); when unsure,
        # the printed hyphen stays
        return len(a) >= 3 and vocab[a.lower()] > 0 and len(b) >= 4 and not _SUFFIX.match(b)

    def fix(text: str) -> str:
        return _BREAK.sub(lambda m: m.group(1) + ("-" if keep_hyphen(m.group(1), m.group(2)) else "") + m.group(2), text)

    for n in nodes:
        if not _BREAK.search(n.text):
            continue
        n.text = fix(n.text)
        if n.runs:
            n.runs = _fix_runs(n.runs, fix)


def _fix_runs(runs: list[dict], fix) -> list[dict]:
    """Apply a text fix that only deletes characters (a space, a hyphen) across
    run boundaries, keeping each surviving character in its run."""
    import difflib
    joined = "".join(r.get("text", "") for r in runs)
    fixed = fix(joined)
    owner = [k for k, r in enumerate(runs) for _ch in r.get("text", "")]
    keep_idx: list[int] = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, joined, fixed, autojunk=False).get_opcodes():
        if tag == "equal":
            keep_idx.extend(range(i1, i2))
        elif tag != "delete":
            return runs                                  # not a pure deletion: leave the runs as they are
    texts = [""] * len(runs)
    for i in keep_idx:
        texts[owner[i]] += joined[i]
    return [dict(r, text=t) for r, t in zip(runs, texts) if t]


def _outline(snap, limit: int = 5000) -> list[dict]:
    """The PDF's bookmarks: title, nesting level and destination page (1-based),
    in outline order; bookmarks without a page destination are left out."""
    out: list[dict] = []
    try:
        for bm in snap.pdf.get_toc(max_depth=16):
            if len(out) >= limit:
                break
            dest = bm.get_dest()
            idx = dest.get_index() if dest is not None else None
            title = (bm.get_title() or "").strip()
            if idx is None or idx < 0 or not title:
                continue
            out.append({"title": title, "level": int(bm.level), "page": int(idx) + 1})
    except Exception:  # noqa: BLE001  - a broken outline is not a conversion failure
        return out
    return out


def _render_page_drawing(snap, page: PageExtract, doc: Document) -> None:
    """The page's drawing alone (fills, rules, paths, shading), upright, from a
    copy without its text and pictures: the background of a PPTX slide in
    page_image mode, under pictures and editable text placed as usual. Text
    inside Form XObjects cannot be removed and would show twice
    (PPTX_BACKGROUND_TEXT_POSSIBLE is reported by the writer when the page has any)."""
    layouts = getattr(doc, "layouts", None)
    if not layouts or layouts[-1] is None:
        return
    from .artwork import clean_page
    from .pngenc import bitmap_to_png
    import pypdfium2.raw as raw
    src = clean_page(snap, page.index)
    if src is None:
        return
    try:
        src.set_rotation(0)
        bmp = src.render(scale=200 / 72, may_draw_forms=False)
    except Exception:  # noqa: BLE001
        return
    fmt = {raw.FPDFBitmap_Gray: "Gray", raw.FPDFBitmap_BGR: "BGR", raw.FPDFBitmap_BGRx: "BGRx",
           raw.FPDFBitmap_BGRA: "BGRA"}[bmp.format]
    layouts[-1].drawing_png = bitmap_to_png(bmp.buffer, bmp.width, bmp.height, bmp.stride, fmt,  # type: ignore[attr-defined]
                                            bmp.rev_byteorder)


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
    flow_start = len(doc.flow)
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
    last_block = None                            # (block, node id) emitted just before, for continuations
    for atom in order_atoms(atoms):
        if atom.kind == "block":
            b = atom.payload
            if getattr(b, "drop_cap_of", None) is not None:
                continue                       # read as the first letter of its paragraph
            prev = getattr(b, "continues", None)
            if prev is not None and last_block is not None and last_block[0] is prev:
                # the next line of a paragraph split by wide line spacing: one reading-order paragraph
                node = doc.nodes[last_block[1]]
                more = _run_dicts(b.runs, options.include_hyperlinks)
                sep = "" if node.text.endswith(" ") else " "     # a trailing hyphen: _join_line_break_hyphens decides
                node.text = node.text + sep + b.text
                if sep and node.runs:
                    node.runs[-1] = dict(node.runs[-1], text=node.runs[-1]["text"] + sep)
                node.runs = node.runs + more
                node.source_regions.append(_region(pno, b.bbox))
                node.line_count = (node.line_count or 1) + (b.lines or 1)
                if options.keep_geometry:
                    doc.geometry.setdefault(last_block[1], []).extend(_block_geometry(b, options.include_hyperlinks))
                last_block = (b, last_block[1])
                continue
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
            font, size = _dominant_font(b)
            doc.nodes[nid] = TextNode(nid, b.kind, [_region(pno, b.bbox if cap is None else b.bbox.union(cap.bbox))],
                                      text=text, runs=runs, level=b.level, marker=b.marker, line_count=b.lines,
                                      font=font, size=size)
            stats["paragraphs"] += 1
            if options.keep_geometry:
                lines = _block_geometry(b, options.include_hyperlinks)
                if cap is not None and lines and lines[0]["words"]:
                    # the drop cap is the first word's first letter: one word, both boxes
                    first = lines[0]["words"][0]
                    cb = cap.bbox.rounded()
                    first["text"] = cap.text.strip() + first["text"]
                    first["bbox"] = [min(cb[0], first["bbox"][0]), min(cb[1], first["bbox"][1]),
                                     max(cb[2], first["bbox"][2]), max(cb[3], first["bbox"][3])]
                    lb = lines[0]["bbox"]
                    lines[0]["bbox"] = [min(lb[0], cb[0]), min(lb[1], cb[1]), max(lb[2], cb[2]), max(lb[3], cb[3])]
                doc.geometry[nid] = lines
            last_block = (b, nid)
        elif atom.kind == "table":
            t = atom.payload
            cells = [{"row": c.row, "col": c.col, "rowspan": c.rowspan, "colspan": c.colspan,
                      "raw_text": c.raw_text, "bbox": c.bbox.rounded(), "bold": c.bold} for c in t.cells]
            if options.keep_geometry:
                for c in t.cells:
                    doc.geometry[f"{t.table_id}:{c.row}:{c.col}"] = _cell_geometry(c, options.include_hyperlinks, page)
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
        if atom.kind not in ("block", "figure"):
            last_block = None       # a picture between two columns does not end the paragraph
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
            if options.keep_geometry:
                from .textlines import build_lines
                doc.geometry[nid] = _word_lines([ln.tokens for ln in build_lines(list(hidden))], False)
            doc.flow.append(nid)

    if options.keep_geometry:
        _fill_missing_geometry(doc, page, doc.flow[flow_start:], options.include_hyperlinks)

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
    toks = list(getattr(fp, "label_tokens", None) or [])
    if getattr(doc, "keep_geometry", False) and toks:
        from .textlines import build_lines
        doc.geometry[f"{nid}:label"] = _word_lines([ln.tokens for ln in build_lines([t.char for t in toks])], False)
    return nid
