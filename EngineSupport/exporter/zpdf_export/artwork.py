"""Vector artwork: logos, lettering and diagrams drawn as paths.

Path objects that are neither rules nor large rectangular shading are clustered
by proximity. A cluster with real drawing (a curve, or several shapes) becomes a
figure rendered by PDFium from the page region, so the DOCX carries it as an
image next to the editable text. Clusters that share their region with body
text are not rendered over that text; they are reported as
``VECTOR_ARTWORK_OVERLAPS_TEXT`` instead, and members that do not touch text
themselves (a mark inside a shaded text banner) are tried on their own.
Nothing is dropped silently.
"""
from __future__ import annotations

from pathlib import Path

from .geometry import BBox
from .pngenc import bitmap_to_png

_GAP = 3.0            # pt: paths closer than this belong to one artwork cluster
_MIN_AREA = 36.0      # pt²
_MAX_PAGE_FRACTION = 0.6
_RENDER_SCALE = 3.0   # 216 dpi
_MARGIN = 2.0


def _expanded(b: BBox, m: float) -> BBox:
    return BBox(b.x0 - m, b.y0 - m, b.x1 + m, b.y1 + m)


def _clusters(objs):
    """Proximity clusters (union-find on boxes expanded by _GAP)."""
    parent = list(range(len(objs)))

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    boxes = [_expanded(o.lbox, _GAP) for o in objs]
    for i in range(len(objs)):
        for j in range(i + 1, len(objs)):
            if boxes[i].intersects(boxes[j]):
                ra, rb = find(i), find(j)
                if ra != rb:
                    parent[rb] = ra
    groups: dict[int, list] = {}
    for i in range(len(objs)):
        groups.setdefault(find(i), []).append(objs[i])
    return sorted(groups.values(), key=lambda g: (min(o.lbox.y0 for o in g), min(o.lbox.x0 for o in g)))


def _cluster_boxes(objs):
    lbox = objs[0].lbox
    bbox = objs[0].bbox
    for o in objs[1:]:
        lbox = lbox.union(o.lbox)
        bbox = bbox.union(o.bbox)
    return lbox, bbox


def detect_artwork(page_handle, out, snapshot=None) -> None:
    """Populate ``out.artwork`` (rendered regions), ``out.absorbed_chars`` and warnings.
    ``snapshot`` lets a drawing under the text be rendered from a copy of the
    document with the text removed (see _render_region_clean)."""
    if not out.art:
        return
    page_area = out.layout_width * out.layout_height
    real_chars = [c for c in out.chars if not c.generated and not c.text.isspace()]
    counter = [0]
    for members in _clusters(list(out.art)):
        _emit_cluster(page_handle, out, members, real_chars, page_area, counter, allow_split=True, snapshot=snapshot)


def _emit_backdrop(snapshot, out, objs, bbox, lbox, art_id) -> bool:
    """A drawing that lies under the page's text (a shading illustration, a
    gradient background): rendered from the document without its text and
    pictures, placed behind everything; the text stays editable text."""
    from .extract import ImageRegion
    png, wpx, hpx = _render_region_clean(snapshot, out, bbox)
    if png is None:
        return False
    out.artwork.append(ImageRegion(art_id, bbox, lbox, png, wpx, hpx, "vector", len(objs), "", behind=True))
    out.warnings.append({"code": "VECTOR_ARTWORK_BACKDROP", "page": out.index, "object_id": art_id,
                         "objects": len(objs), "bbox": bbox.rounded(),
                         "detail": "a drawing under the text (shading), rendered without the text and placed behind it"})
    return True


def _emit_cluster(page_handle, out, objs, real_chars, page_area, counter, allow_split: bool, snapshot=None) -> None:
    from .extract import ImageRegion  # local import to avoid a cycle

    nonwhite = [o for o in objs if not o.white]
    has_shading = any(getattr(o, "shading", False) for o in nonwhite)
    curved = [o for o in nonwhite if o.curved]
    lbox, bbox = _cluster_boxes(objs)
    if not nonwhite:
        # white shapes are knock-outs, unless they lie on a dark fill: then they
        # are the drawing (a reversed-out logo on a banner)
        dark = [f for f in getattr(out, "fills", []) if not getattr(f, "white", False) and sum(f.rgb) < 450
                and _covers_box(f.lbox, lbox) >= 0.8]
        if dark and len(objs) >= 3:
            nonwhite = objs; curved = [o for o in objs if o.curved]
    if not nonwhite or not (curved or len(nonwhite) >= 3):
        return
    area = lbox.width * lbox.height
    if area < _MIN_AREA:
        return
    counter[0] += 1
    art_id = f"p{out.index}-art-{counter[0]}"
    if area > _MAX_PAGE_FRACTION * page_area:
        if has_shading and _emit_backdrop(snapshot, out, objs, bbox, lbox, art_id):
            return
        out.warnings.append({"code": "VECTOR_ARTWORK_PAGE_DECORATION", "page": out.index, "object_id": art_id,
                             "objects": len(objs), "bbox": bbox.rounded()})
        return
    region = _expanded(lbox, 1.0)
    inside = [c for c in real_chars if region.contains_point(c.lbox.cx, c.lbox.cy)]
    absorbed = ""
    partial = bool(inside) and _splits_a_word(inside, real_chars)
    if inside:
        text_area = sum(c.lbox.width * c.lbox.height for c in inside)
        # lettering inside real drawing (several shapes, or a curved shape plus
        # another) is part of a logo; a lone shape around text is a markup
        # circle/box, never artwork that may absorb the text
        drawing = len(nonwhite) >= 3 or (bool(curved) and len(nonwhite) >= 2)
        logo_text = len(inside) <= 12 and text_area <= 0.35 * area
        # a labelled diagram: a few short labels spread over a drawing (little
        # text area, no label wider than half the drawing, no paragraph of it)
        labels = _label_lines(inside)
        diagram = (labels is not None and len(labels) <= 16 and text_area <= 0.15 * area
                   and max(ln.lbox.width for ln in labels) <= 0.5 * lbox.width)
        if drawing and (logo_text or diagram) and not partial:
            if labels:
                absorbed = " ".join(ln.text.strip() for ln in sorted(labels, key=lambda ln: (round(ln.lbox.y0), ln.lbox.x0)))
            else:
                absorbed = "".join(c.text for c in sorted(inside, key=lambda c: (round(c.lbox.cy), c.lbox.x0)))
        else:
            if has_shading and _emit_backdrop(snapshot, out, objs, bbox, lbox, art_id):
                return
            out.warnings.append({"code": "VECTOR_ARTWORK_OVERLAPS_TEXT", "page": out.index, "object_id": art_id,
                                 "objects": len(objs), "bbox": bbox.rounded(), "chars": len(inside)})
            if allow_split:
                # a mark inside a text banner: members that touch no text may still
                # form artwork of their own; the text-bearing members stay reported
                clean = [o for o in objs if not any(_expanded(o.lbox, 1.0).contains_point(c.lbox.cx, c.lbox.cy)
                                                     for c in inside)]
                if clean and len(clean) < len(objs):
                    for sub in _clusters(clean):
                        _emit_cluster(page_handle, out, sub, real_chars, page_area, counter, allow_split=False, snapshot=snapshot)
            return
    png, wpx, hpx = _render_region(page_handle, out, bbox)
    if png is None:
        out.warnings.append({"code": "VECTOR_ARTWORK_BLANK", "page": out.index, "object_id": art_id,
                             "objects": len(objs), "bbox": bbox.rounded()})
        return
    for c in inside:
        out.absorbed_chars.add(id(c))
    out.artwork.append(ImageRegion(art_id, bbox, lbox, png, wpx, hpx, "vector", len(objs), absorbed))
    warn = {"code": "VECTOR_ARTWORK_RENDERED", "page": out.index, "object_id": art_id, "objects": len(objs),
            "bbox": bbox.rounded()}
    if absorbed:
        warn["absorbed_text"] = absorbed
    out.warnings.append(warn)


def _covers_box(outer: BBox, inner: BBox) -> float:
    ix = max(0.0, min(outer.x1, inner.x1) - max(outer.x0, inner.x0))
    iy = max(0.0, min(outer.y1, inner.y1) - max(outer.y0, inner.y0))
    return ix * iy / max(inner.width * inner.height, 1e-6)


def _splits_a_word(inside, real_chars) -> bool:
    """True when the region takes some glyphs of a word and leaves others: a
    word is absorbed whole or not at all ('NOVEMBER 11' must not become a
    picture of 'NO 11' beside the text 'VEMBER')."""
    ids = {id(c) for c in inside}
    for c in inside:
        size = max(c.font_size, 1.0)
        for d in real_chars:
            if id(d) in ids or d is c:
                continue
            if abs(d.lbox.cy - c.lbox.cy) > 0.5 * size:
                continue
            gap = d.lbox.x0 - c.lbox.x1 if d.lbox.x0 >= c.lbox.x0 else c.lbox.x0 - d.lbox.x1
            if -0.5 <= gap <= 0.25 * size:
                return True
    return False


def _label_lines(chars):
    """Text lines inside a drawing, or None when they read as a paragraph (three
    or more lines stacked at one x with a regular pitch: body text over a box)."""
    from .textlines import build_lines
    lines = build_lines(list(chars))
    if len(lines) >= 3:
        stacked = sorted(lines, key=lambda ln: ln.lbox.y0)
        run = 1
        for a, b in zip(stacked, stacked[1:]):
            same_x = abs(a.lbox.x0 - b.lbox.x0) <= 3.0
            pitch = b.lbox.y0 - a.lbox.y0
            if same_x and 0 < pitch <= 1.6 * max(a.lbox.height, b.lbox.height):
                run += 1
                if run >= 3:
                    return None
            else:
                run = 1
    return lines


def clean_page(snapshot, index: int, drop_images: bool = True):
    """A page of an in-memory copy of the document with its top-level text
    objects (and, by default, raster images) removed. The source file is never
    touched; the copy lives only as long as the returned handle. Text inside
    Form XObjects cannot be removed this way. None when the copy fails."""
    import pypdfium2 as pdfium
    import pypdfium2.raw as raw
    if snapshot is None:
        return None
    try:
        doc = pdfium.PdfDocument(Path(snapshot.path).read_bytes())
        page = doc[index - 1]
        kinds = (raw.FPDF_PAGEOBJ_TEXT, raw.FPDF_PAGEOBJ_IMAGE) if drop_images else (raw.FPDF_PAGEOBJ_TEXT,)
        for k in range(raw.FPDFPage_CountObjects(page) - 1, -1, -1):
            o = raw.FPDFPage_GetObject(page, k)
            if raw.FPDFPageObj_GetType(o) in kinds:
                raw.FPDFPage_RemoveObject(page, o)
                raw.FPDFPageObj_Destroy(o)
        raw.FPDFPage_GenerateContent(page)
        page._zpdf_doc = doc   # keep the copy alive with the page handle
        return page
    except Exception:  # noqa: BLE001
        return None


def _render_region_clean(snapshot, out, bbox: BBox):
    """Render a region of the page without its words (those stay editable text)
    and without the pictures placed on their own: the drawing alone."""
    page = clean_page(snapshot, out.index)
    if page is None:
        return None, 0, 0
    return _render_region(page, out, bbox)


def _render_region(page_handle, out, bbox: BBox, min_ink: float = 0.002, margin: float = _MARGIN):
    """Render a normalized-space region of the page with PDFium; None if blank
    (less than ``min_ink`` of the sampled pixels are dark)."""
    import pypdfium2.raw as raw
    W, H = out.width, out.height
    x0 = max(0.0, bbox.x0 - margin); y0 = max(0.0, bbox.y0 - margin)
    x1 = min(W, bbox.x1 + margin); y1 = min(H, bbox.y1 + margin)
    if x1 - x0 < 1 or y1 - y0 < 1:
        return None, 0, 0
    crop = (x0, H - y1, W - x1, y0)  # left, bottom, right, top (points cut away)
    try:
        bmp = page_handle.render(scale=_RENDER_SCALE, crop=crop, may_draw_forms=False)
    except Exception:  # noqa: BLE001
        return None, 0, 0
    fmt = {raw.FPDFBitmap_Gray: "Gray", raw.FPDFBitmap_BGR: "BGR", raw.FPDFBitmap_BGRx: "BGRx",
           raw.FPDFBitmap_BGRA: "BGRA"}[bmp.format]
    mv = memoryview(bmp.buffer).cast("B")
    nch = {"Gray": 1, "BGR": 3, "BGRx": 4, "BGRA": 4}[fmt]
    dark = 0
    step = max(1, (bmp.width * bmp.height) // 20000)
    total = 0
    for idx in range(0, bmp.width * bmp.height, step):
        y, x = divmod(idx, bmp.width)
        p = y * bmp.stride + x * nch
        total += 1
        if nch == 1:
            if mv[p] < 200:
                dark += 1
        elif mv[p] < 200 or mv[p + 1] < 200 or mv[p + 2] < 200:
            dark += 1
    if total == 0 or dark / total < min_ink:
        return None, 0, 0
    png = bitmap_to_png(bmp.buffer, bmp.width, bmp.height, bmp.stride, fmt, bmp.rev_byteorder)
    return png, bmp.width, bmp.height


_LABELLED_MIN_LABELS = 3      # a photo with a title over it is not a labelled picture
_LABELLED_MAX_LABELS = 40


def keep_picture_labels(page_handle, out) -> None:
    """Labels drawn over a raster picture (a map's place names, scale bar and
    north arrow; curved river names set glyph by glyph) belong to the picture.
    Left as page text they scatter through the reading order and the turned
    ones become fragment pictures ('ineral', 'ee Ceme'). A picture whose text
    reads as a few short labels (no paragraph, no label wider than half the
    picture, no word cut by its edge) is rendered from the page with its labels
    and the marks drawn over it; the labels become its alt text
    (``PICTURE_LABELS_KEPT``). Runs after artwork detection and before turned
    text is rendered, so neither takes these glyphs."""
    page_area = out.layout_width * out.layout_height
    real = [c for c in out.chars if not c.generated and not c.text.isspace() and not c.invisible]
    order = {id(c): k for k, c in enumerate(out.chars)}
    for im in sorted(out.images, key=lambda im: im.lbox.width * im.lbox.height):
        box = im.lbox
        area = box.width * box.height
        if area < 40 * 40 or area > _MAX_PAGE_FRACTION * page_area:
            continue
        inside = [c for c in real if id(c) not in out.absorbed_chars and box.contains_point(c.lbox.cx, c.lbox.cy)]
        if not inside or _splits_a_word(inside, real) or _crosses_edge(inside, out.chars, order):
            continue
        upright = [c for c in inside if not c.sideways]
        lines = _label_lines(upright) if upright else []
        if lines is None:
            continue                                   # a paragraph over a backdrop: page text
        from .textlines import split_line_at_gaps
        lines = [seg for ln in lines for seg in split_line_at_gaps(ln)]   # labels far apart at one height
        if any(ln.lbox.width > 0.5 * box.width for ln in lines):
            continue
        labels = _picture_labels(inside, out.chars, order)
        text_area = sum(c.lbox.width * c.lbox.height for c in inside)
        if not (_LABELLED_MIN_LABELS <= len(labels) <= _LABELLED_MAX_LABELS) or text_area > 0.15 * area:
            continue
        png, wpx, hpx = _render_region(page_handle, out, im.bbox, margin=0.0)
        if png is None:
            continue
        marks = [a for a in out.artwork if not a.behind and _covers_box(box, a.lbox) >= 0.9]
        for a in marks:
            out.artwork.remove(a)
        mark_ids = {a.image_id for a in marks}
        out.warnings[:] = [w for w in out.warnings
                           if not (w.get("code") == "VECTOR_ARTWORK_RENDERED" and w.get("object_id") in mark_ids)]
        for c in inside:
            out.absorbed_chars.add(id(c))
        text = "; ".join(t for _pos, t in sorted(labels))
        im.png_bytes, im.width_px, im.height_px = png, wpx, hpx
        im.absorbed_text = text
        im.objects = 1 + len(marks)
        out.warnings.append({"code": "PICTURE_LABELS_KEPT", "page": out.index, "object_id": im.image_id,
                             "labels": len(labels), "bbox": im.bbox.rounded(), "absorbed_text": text,
                             "detail": "labels drawn over a picture (a map) are kept in the picture and its alt text, "
                                       "not as editable text"})


def _crosses_edge(inside, chars, order) -> bool:
    """A word the picture's edge cuts, in any direction: a glyph inside whose
    neighbour in page order is beside it but outside (turned 'Fixed' with only
    its 'd' on the picture). _splits_a_word looks along upright lines only."""
    ids = {id(c) for c in inside}
    for c in inside:
        k = order.get(id(c))
        if k is None:
            continue
        for j in (k - 1, k + 1):
            if not 0 <= j < len(chars):
                continue
            d = chars[j]
            if id(d) in ids or d.generated or d.text.isspace() or d.invisible:
                continue
            reach = 1.5 * max(c.font_size, d.font_size, 1.0)
            if abs(d.lbox.cx - c.lbox.cx) <= reach and abs(d.lbox.cy - c.lbox.cy) <= reach:
                return True
    return False


def _picture_labels(inside, chars, order) -> list[tuple[tuple[float, float], str]]:
    """The labels drawn over a picture, as text: glyphs in page order (their
    reading order, whether set upright, tilted along a road or turned along a
    river), a label ending where the next glyph is not beside the last; a space
    glyph between two glyphs is a word space. A label set directly under the
    one before it continues it ('Storm' over 'Peak'). Each keeps its top-left."""
    ids = {id(c) for c in inside}
    seq = sorted(inside, key=lambda c: order.get(id(c), 0))
    spaced = set()
    prev = None
    for c in chars:
        if id(c) in ids:
            prev = c
        elif prev is not None and c.text.isspace():
            spaced.add(id(prev))
    runs: list[list] = [[seq[0]]]
    for a, b in zip(seq, seq[1:]):
        size = max(a.font_size, b.font_size, 1.0)
        reach = 1.5 * size
        # upright text continues rightward on its line; a step back or down is the next label
        # (tilted text descends a little per glyph; turned text runs along y)
        wrapped = not a.sideways and not b.sideways and (b.lbox.x0 < a.lbox.x0 - 0.3 * size
                                                         or abs(b.lbox.cy - a.lbox.cy) > 0.6 * size)
        if wrapped or abs(b.lbox.cx - a.lbox.cx) > reach or abs(b.lbox.cy - a.lbox.cy) > reach:
            runs.append([b])
        else:
            runs[-1].append(b)

    def box(run):
        lb = run[0].lbox
        for c in run[1:]:
            lb = lb.union(c.lbox)
        return lb

    def text(run):
        t = run[0].text
        for a, b in zip(run, run[1:]):
            t += (" " if id(a) in spaced else "") + b.text
        return t

    labels: list[list] = []
    for run in runs:
        if labels and not run[0].sideways and not labels[-1][-1][0].sideways:
            above, below = box(labels[-1][-1]), box(run)
            h = max(above.height, below.height)
            if (0 <= below.y0 - above.y1 <= 0.8 * h
                    and min(above.x1, below.x1) - max(above.x0, below.x0) > 0):
                labels[-1].append(run)
                continue
        labels.append([run])
    out = []
    for group in labels:
        lb = box(group[0])
        out.append(((round(lb.y0), lb.x0), " ".join(text(r) for r in group)))
    return out
