"""Layout-preserving page decomposition (spec §9, DOCX layout mode).

A page becomes an ordered list of vertical *bands* derived only from measured
geometry: tables (ruled grids with their cells), rows of side-by-side items
(header blocks, an image beside text), and single-block paragraphs. Every band
carries its layout-space box so the writer can reproduce vertical position
with exact spacing and horizontal position with fixed-width table columns.
Nothing here knows about a particular form.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .extract import FillRect, PageExtract, Rule
from .geometry import BBox
from .textlines import Token


@dataclass
class TextLine:
    """One visual line inside a cell or paragraph: runs with font info."""
    runs: list[dict]            # {text, font, size, bold, italic}
    lbox: BBox
    align: str = "left"         # left | center | right (within its container)
    anchor: bool = True         # lbox is measured text (a field widget's row is only an estimate)


@dataclass
class Item:
    """An atom placed in a band: paragraph block, table, figure or field."""
    kind: str                   # block | table | figure | sentence | field
    lbox: BBox
    payload: object
    lines: list[TextLine] = field(default_factory=list)


@dataclass
class Band:
    kind: str                   # table | row | flow | rule
    lbox: BBox
    items: list[Item] = field(default_factory=list)   # row: columns left→right; flow: one item
    columns: list[list[Item]] = field(default_factory=list)  # row bands: stacked items per column
    fill: FillRect | None = None   # rule band drawn from a filled bar
    rules: list[Rule] = field(default_factory=list)  # stroked horizontal line segments sharing one row


@dataclass
class PageLayout:
    width: float
    height: float
    margin_left: float
    margin_top: float
    margin_right: float
    margin_bottom: float
    bands: list[Band]
    warnings: list[dict] = field(default_factory=list)
    figures: list[Item] = field(default_factory=list)   # anchored at absolute page positions
    rotation: int = 0                                   # displayed rotation reproduced by the writer
    comments: list = field(default_factory=list)        # extract.Comment objects (layout-space boxes)
    hidden: list = field(default_factory=list)          # TextLines of invisible text (OCR layer), written hidden
    backdrops: list = field(default_factory=list)       # FillRects drawn as flat pictures behind the text
    page_rules: list = field(default_factory=list)      # every stroked line and thin bar (HTML draws them all)
    page_fills: list = field(default_factory=list)      # every filled rectangle, in paint order


def char_run(c) -> dict:
    """A run dict for one glyph: font, size, weight, colour, link target, underline."""
    return {"text": c.text, "font": c.font_name, "size": c.font_size, "bold": c.bold, "italic": c.italic,
            "color": getattr(c, "color", (0, 0, 0)), "uri": getattr(c, "uri", None),
            "underline": bool(getattr(c, "underline", False)),
            "strike": bool(getattr(c, "strike", False)), "highlight": getattr(c, "highlight", None)}


def same_style(run: dict, c) -> bool:
    return (run["font"] == c.font_name and abs(run["size"] - c.font_size) < 0.3 and run["bold"] == c.bold
            and run["italic"] == c.italic and run.get("color", (0, 0, 0)) == getattr(c, "color", (0, 0, 0))
            and run.get("uri") == getattr(c, "uri", None) and run.get("underline", False) == bool(getattr(c, "underline", False))
            and run.get("strike", False) == bool(getattr(c, "strike", False))
            and run.get("highlight") == getattr(c, "highlight", None))


CLUSTER_GAP = 12.0  # pt: a wider gap inside one text row is a positioned segment (tab stop), not a space


def token_runs(tokens, keep_positions: bool = False) -> list[dict]:
    """Runs for a token sequence. With ``keep_positions`` a gap wider than
    CLUSTER_GAP starts a new segment at its measured x (a tab stop), so several
    text clusters sharing a row keep their places."""
    runs: list[dict] = []
    cursor = None   # right edge of the glyphs written so far (glyphs without a box do not count)
    for i, t in enumerate(tokens):
        c = t.char
        boxed = c.lbox.width > 0
        gap = (c.lbox.x0 - cursor) if (boxed and cursor is not None) else 0.0
        # a new positioned segment needs the following glyph to sit beyond the gap
        # as well: a lone glyph with a stray box (a bad font metric) is not a cluster
        nxt = tokens[i + 1].char if i + 1 < len(tokens) else None
        # display type is letter-spaced in proportion to its size: the gap that
        # means a positioned segment grows with the glyphs
        cgap = max(CLUSTER_GAP, 0.2 * max(c.font_size, runs[-1]["size"] if runs else 0.0))
        cluster = keep_positions and gap > cgap and (nxt is None or nxt.lbox.x0 > cursor + 0.5 * cgap)
        if cluster:
            runs.append({"text": "\t", "font": "", "size": 8.0, "bold": False, "italic": False, "tab_to": c.lbox.x0})
            piece = c.text
        else:
            piece = (" " if t.space_before and i > 0 else "") + c.text
        if runs and "tab_to" not in runs[-1] and same_style(runs[-1], c):
            runs[-1]["text"] += piece
        else:
            r = char_run(c); r["text"] = piece; runs.append(r)
        if boxed and (cursor is None or gap <= cgap or cluster):
            cursor = c.lbox.x1 if cursor is None else max(cursor, c.lbox.x1)
    return runs


GUTTER_GAP = 9.0   # pt: a gap this wide at the same x on most lines of a block is a column gutter


def _token_lines_of(block) -> list[list]:
    from .forms import _block_lines
    marker = list(getattr(block, "marker_tokens", None) or [])
    lines = []
    for i, toks in enumerate(_block_lines(block)):
        if i == 0 and marker and toks and toks[0] is getattr(block, "marker_next", None):
            # the list marker stripped for reflow numbering is part of the visual line
            toks = marker + [Token(toks[0].char, True)] + toks[1:]
        lines.append(toks)
    return lines


def _lines_to_textlines(lines: list[list]) -> list[TextLine]:
    out: list[TextLine] = []
    for toks in lines:
        if not toks:
            continue
        runs = token_runs(toks)
        lb = toks[0].char.lbox
        for t in toks[1:]:
            lb = lb.union(t.char.lbox)
        if runs:
            runs[0]["text"] = runs[0]["text"].lstrip()
        out.append(TextLine(runs, lb))
    return out


def _lines_from_block(block) -> list[TextLine]:
    """Split a layout block's tokens into visual lines carrying font runs."""
    return _lines_to_textlines(_token_lines_of(block))


def block_items(block) -> list[Item]:
    """Items for a text block. A block whose lines run across a column gutter
    (two newspaper columns glued together by the line builder, or one column's
    lines stacked under the next column's) is split at the gutter into one item
    per column, so the columns stay side by side."""
    lines = _token_lines_of(block)
    pieces: list[list] = []
    for toks in lines:
        cur: list = []
        prev = None
        for t in toks:
            c = t.char
            if prev is not None and c.lbox.width > 0 and \
                    c.lbox.x0 - prev.lbox.x1 > max(GUTTER_GAP, 0.35 * max(prev.font_size, c.font_size)):
                pieces.append(cur); cur = []
            cur.append(t)
            if c.lbox.width > 0:
                prev = c
        if cur:
            pieces.append(cur)
    out: list[Item] = []
    for part in _x_clusters(pieces):
        tls = _lines_to_textlines(part)
        if not tls:
            continue
        lb = tls[0].lbox
        for ln in tls[1:]:
            lb = lb.union(ln.lbox)
        out.append(Item("block", lb, block, tls))
    return out


def _x_clusters(lines: list[list]) -> list[list[list]]:
    """Group a block's lines by horizontal extent; groups separated by more
    than GUTTER_GAP are separate columns (each needs at least two lines)."""
    boxes = []
    for toks in lines:
        bx = [t.char.lbox for t in toks if t.char.lbox.width > 0]
        if not bx:
            continue
        boxes.append((min(b.x0 for b in bx), max(b.x1 for b in bx), toks))
    if len(boxes) < 4:
        return [lines]
    boxes.sort(key=lambda b: b[0])
    groups: list[list] = [[boxes[0]]]
    for b in boxes[1:]:
        g = groups[-1]
        gx1 = max(e[1] for e in g)
        if b[0] > gx1 + GUTTER_GAP:
            groups.append([b])
        else:
            g.append(b)
    # at least one real column (two or more lines); a single fragment that ended
    # up beyond the gutter (the tail of a row glued across it) is still its own piece
    if len(groups) < 2 or not any(len(g) >= 2 for g in groups):
        return [lines]
    order = {id(toks): i for i, toks in enumerate(lines)}
    return [[e[2] for e in sorted(g, key=lambda e: order[id(e[2])])] for g in groups]


def lines_from_chars(chars) -> list[TextLine]:
    """Visual lines for a set of chars (table cells); clusters far apart on one
    row keep their measured positions."""
    from .textlines import build_lines
    return [TextLine(token_runs(ln.tokens, keep_positions=True), ln.lbox) for ln in build_lines(list(chars))]


def _field_extent(fp) -> BBox:
    """Everything the field's line(s) carry: label, widget, trailing hint, marker."""
    from .forms import _tokens_lbox
    box = fp.anchor_lbox.union(fp.widget.lbox)
    for attr in ("sub_tokens", "marker_tokens"):
        toks = getattr(fp, attr, None) or []
        if toks:
            box = box.union(_tokens_lbox(toks))
    return box


def decompose_page(page: PageExtract, blocks, tables, figures, pairs, sentences, comments=()) -> PageLayout:
    """Build bands for one page from already-reconstructed elements."""
    W, H = page.layout_width, page.layout_height
    warnings: list[dict] = []
    table_boxes = [t.lbox for t in tables]
    highlights = _mark_highlights(page, table_boxes)          # glyph highlights: run shading, not bars
    rule_bands, dropped = _classify_rules(page, table_boxes)   # marks underlined / struck glyphs first
    items: list[Item] = []
    for b in blocks:
        items.extend(block_items(b))
    for t in tables:
        items.append(Item("table", t.lbox, t))
    anchored = [Item("figure", im.lbox, im) for im in figures if im.lbox.width > 0 and im.lbox.height > 0]
    for sn in sentences:
        box = sn.lbox
        for row in getattr(sn, "rows", None) or []:   # rows include folded fields' widgets
            box = box.union(row[0])
        items.append(Item("sentence", box, sn))
    for fp in pairs:
        if fp.placement == "inline":
            items.append(Item("field", _field_extent(fp), fp))
    for fp in pairs:
        if fp.placement == "fallback":
            # no visible label was found: the value (or the field's own rule)
            # still belongs at its position
            w = fp.widget
            if (w.value.strip() and w.value.strip() != "Off") or w.checked or getattr(w, "underlined", False):
                items.append(Item("field", w.lbox, fp))
    items = [it for it in items if it.lbox.width > 0 and it.lbox.height > 0]
    rotation = page.rotation % 360
    if rotation in (90, 270):
        # reproduced with the section's text direction (Word rotates the whole
        # text flow); reported because that is a compatibility-sensitive feature
        warnings.append({"code": "LAYOUT_PAGE_ROTATED", "page": page.index, "source_rotation": rotation,
                         "detail": "displayed rotation reproduced with section text direction"})
    elif rotation:
        warnings.append({"code": "LAYOUT_PAGE_UPRIGHT", "page": page.index, "source_rotation": rotation,
                         "detail": "page emitted in content orientation; a 180° display rotation is not reproduced"})
        rotation = 0

    # margins from content extents (tables' own boxes, anchored figures and
    # stand-alone rules count: a rule above the first text line is on the budget)
    extent_boxes = [it.lbox for it in items + anchored] + [rb.lbox for rb in rule_bands]
    if extent_boxes:
        left = min(b.x0 for b in extent_boxes)
        right = max(b.x1 for b in extent_boxes)
        top = min(b.y0 for b in extent_boxes)
        bottom = max(b.y1 for b in extent_boxes)
    else:
        left, right, top, bottom = 36.0, W - 36.0, 36.0, H - 36.0
    margin_left = max(0.0, min(left, 72.0))
    margin_right = max(0.0, min(W - right, 72.0))
    margin_top = max(0.0, min(top, 72.0))
    # leave slack below the last band so Word's small overruns (borders, minimum
    # spacers, the paragraph carrying the section break) never push it to a new page
    margin_bottom = max(0.0, min(H - bottom - 16.0, 72.0))

    # vertical bands: items whose vertical extents overlap share a band
    ordered = sorted(items, key=lambda it: (it.lbox.y0, it.lbox.x0))
    bands: list[Band] = []
    cur: list[Item] = []
    cur_y1 = -1.0
    for it in ordered:
        if cur and it.lbox.y0 >= cur_y1 - 1.0:
            bands.append(_make_band(cur, W))
            cur = []
        cur.append(it)
        cur_y1 = max(cur_y1, it.lbox.y1) if cur_y1 >= 0 and len(cur) > 1 else it.lbox.y1
    if cur:
        bands.append(_make_band(cur, W))

    # filled rectangles outside tables: a bar holding text shades that text's
    # band (a banner); an empty bar is drawn as a filled block; a fill covering
    # more than half the page is a background and is reported, not reproduced
    fills_dropped = 0
    backdrops: list = []   # opaque fills that are not cell shading: drawn behind the text as flat pictures
    coloured = [f for f in page.fills if not getattr(f, "white", False) and getattr(f, "alpha", 255) >= 200
                and id(f) not in highlights]
    image_boxes = [im.lbox for im in getattr(page, "images", [])]

    def covered(outer: BBox, inner: BBox) -> float:
        ix = max(0.0, min(outer.x1, inner.x1) - max(outer.x0, inner.x0))
        iy = max(0.0, min(outer.y1, inner.y1) - max(outer.y0, inner.y0))
        return ix * iy / max(outer.width * outer.height, 1e-6)

    # smallest first: an inner box claims its text before the frame around it
    for f in sorted(coloured, key=lambda f: f.lbox.width * f.lbox.height):
        fb = f.lbox
        if any(tb.intersects(fb) for tb in table_boxes) or fb.width < 4 or fb.height < 2.5:
            continue
        if fb.width * fb.height > 0.5 * W * H:
            backdrops.append(f)   # a page background: painted behind everything
            continue
        # a rectangle mostly hidden under a picture, or holding a lighter/white
        # rectangle inside it, is a backdrop or a frame, not a bar behind text
        area = fb.width * fb.height
        bleed = fb.x0 < -5 or fb.y0 < -5 or fb.x1 > W + 5 or fb.y1 > H + 5   # runs off the sheet: a backdrop
        if bleed or any(covered(fb, ib) >= 0.6 for ib in image_boxes) or \
                any(g is not f and g.lbox.width * g.lbox.height < 0.95 * area and covered(fb, g.lbox) >= 0.6
                    and (getattr(g, "white", False) or sum(g.rgb) > sum(f.rgb)) for g in page.fills):
            backdrops.append(f)   # a frame or an image backdrop: appearance only, behind the text
            continue
        # a text block running from inside the bar to outside it (a title box
        # above a dark stripe holding its own line) is split at the bar's edge,
        # so each part keeps the background it was printed on
        for b in list(bands):
            if b.kind not in ("flow", "row") or b.fill is not None or not b.items \
                    or any(it.kind != "block" for it in b.items):
                continue
            if not (b.lbox.y0 < fb.y0 - 2 < b.lbox.y1 or b.lbox.y0 < fb.y1 + 2 < b.lbox.y1):
                continue
            # every block must sit on the bar: a block beside it (body text next
            # to a title box) keeps the band together, and the bar is a backdrop
            if any(min(it.lbox.x1, fb.x1) - max(it.lbox.x0, fb.x0) <= 0.5 * it.lbox.width for it in b.items):
                continue
            parts: dict[bool, list[Item]] = {True: [], False: []}
            for it in b.items:
                on_bar = [ln for ln in it.lines if fb.y0 - 1 <= (ln.lbox.y0 + ln.lbox.y1) / 2 <= fb.y1 + 1]
                off_bar = [ln for ln in it.lines if ln not in on_bar]
                for key, lns in ((True, on_bar), (False, off_bar)):
                    if lns:
                        lb = lns[0].lbox
                        for ln in lns[1:]:
                            lb = lb.union(ln.lbox)
                        parts[key].append(Item("block", lb, it.payload, lns))
            if parts[True] and parts[False]:
                bands.remove(b)
                for key in (True, False):
                    for it in parts[key]:
                        bands.append(_make_band([it], W))
        inside = [b for b in bands if b.kind in ("flow", "row") and b.fill is None
                  and b.lbox.y0 >= fb.y0 - 2 and b.lbox.y1 <= fb.y1 + 2
                  and min(b.lbox.x1, fb.x1) - max(b.lbox.x0, fb.x0) > 0.5 * b.lbox.width]
        if inside:
            # every band on the bar becomes one banner band of the bar's size
            items_in = [it for b in inside for it in b.items]
            for b in inside:
                bands.remove(b)
            bands.append(Band("row", BBox(fb.x0, fb.y0, fb.x1, fb.y1), items_in, [items_in], fill=f))
            continue
        if not any(b.lbox.y0 < fb.y1 and b.lbox.y1 > fb.y0 for b in bands):
            bands.append(Band("rule", fb, fill=f))
        else:
            backdrops.append(f)   # crosses several bands (a title box beside body text): behind the text
    # a bar that runs to the page edge (a full-bleed footer) is a band of its
    # own size: the text area must reach it, or the band cannot fit the page
    if bands:
        lowest = max(b.lbox.y1 for b in bands)
        margin_bottom = max(0.0, min(margin_bottom, H - lowest))
    if fills_dropped:
        warnings.append({"code": "LAYOUT_FILLS_DROPPED", "page": page.index, "count": fills_dropped,
                         "detail": "fills that could be neither shading nor a backdrop are not reproduced"})
    if backdrops:
        warnings.append({"code": "LAYOUT_FILLS_AS_BACKDROP", "page": page.index, "count": len(backdrops),
                         "detail": "fills that are not cell shading are drawn as flat pictures behind the text"})
    # a rule crossing a text band's rows cannot be placed between paragraphs
    for rb in rule_bands:
        if any(b.lbox.y0 < rb.lbox.y1 and b.lbox.y1 > rb.lbox.y0 for b in bands):
            dropped += 1
        else:
            bands.append(rb)
    if dropped:
        warnings.append({"code": "LAYOUT_RULES_DROPPED", "page": page.index, "count": dropped,
                         "detail": "stroked lines crossing text or standing vertically are not reproduced"})
    bands.sort(key=lambda b: b.lbox.y0)
    hidden = lines_from_chars(page.hidden_chars) if getattr(page, "hidden_chars", None) else []
    return PageLayout(W, H, margin_left, margin_top, margin_right, margin_bottom, bands, warnings, anchored,
                      rotation, list(comments), hidden, backdrops, list(page.rules), list(page.fills))


def _classify_rules(page: PageExtract, table_boxes: list[BBox]) -> tuple[list[Band], int]:
    """Stroked lines outside tables: a line along a text widget's bottom edge marks
    that widget ``underlined`` (drawn with the field), lines of check-box squares
    are covered by the box glyph, a horizontal line crossing no text becomes a
    rule band; the rest is counted as dropped."""
    boxes = [w for w in page.widgets if w.field_type in ("checkbox", "radio")]
    texts = [w for w in page.widgets if w.field_type not in ("checkbox", "radio")]
    chars = [c for c in page.chars if not c.generated and not c.text.isspace()]
    out: list[Band] = []
    dropped = 0
    for r in page.rules:
        b = r.lbox
        if any(tb.x0 - 1 <= b.x0 and b.x1 <= tb.x1 + 1 and tb.y0 - 1 <= b.y0 and b.y1 <= tb.y1 + 1 for tb in table_boxes):
            continue
        if any(w.lbox.x0 - 1.5 <= b.x0 and b.x1 <= w.lbox.x1 + 1.5 and w.lbox.y0 - 1.5 <= b.y0 and b.y1 <= w.lbox.y1 + 1.5
               for w in boxes):
            continue
        if r.orientation != "h":
            dropped += 1
            continue
        owner = [w for w in texts if abs(b.y0 - w.lbox.y1) <= 2.5
                 and min(b.x1, w.lbox.x1) - max(b.x0, w.lbox.x0) >= 0.6 * w.lbox.width]
        if owner:
            for w in owner:
                w.underlined = True  # type: ignore[attr-defined]
            continue
        # a line just under a row of glyphs is their underline (links, headings)
        under = [c for c in chars if c.lbox.x1 > b.x0 - 1 and c.lbox.x0 < b.x1 + 1
                 and -1.5 <= b.y0 - c.lbox.y1 <= 3.0 and b.height <= 2.5]
        if under and sum(c.lbox.width for c in under) >= 0.5 * b.width:
            for c in under:
                c.underline = True  # type: ignore[attr-defined]
            continue
        # a thin line through the middle of a row of glyphs is their strikethrough
        mid = b.y0 + b.height / 2
        through = [c for c in chars if c.lbox.x1 > b.x0 - 1 and c.lbox.x0 < b.x1 + 1 and b.height <= 2.5
                   and c.lbox.y0 + 0.25 * c.lbox.height <= mid <= c.lbox.y0 + 0.75 * c.lbox.height]
        if through and sum(c.lbox.width for c in through) >= 0.5 * b.width:
            for c in through:
                c.strike = True  # type: ignore[attr-defined]
            continue
        crossing = any(c.lbox.x1 > b.x0 and c.lbox.x0 < b.x1 and c.lbox.y1 > b.y0 - 1.5 and c.lbox.y0 < b.y1 + 1.5
                       for c in chars)
        if crossing:
            dropped += 1
            continue
        # segments on one row share a band (one exact 1 pt table row, a bordered cell each)
        for band in out:
            if abs(band.lbox.y0 - b.y0) <= 1.0:
                band.rules.append(r); band.lbox = band.lbox.union(BBox(b.x0, band.lbox.y0, b.x1, band.lbox.y1))
                break
        else:
            # thin lines occupy a 1 pt row (a border); thicker bars fill a row of their own height
            out.append(Band("rule", BBox(b.x0, b.y0, b.x1, b.y0 + max(1.0, b.height)), rules=[r]))
    return out, dropped


def _mark_highlights(page: PageExtract, table_boxes: list[BBox]) -> set[int]:
    """A filled rectangle hugging a run of glyphs on one line (no taller than
    the line, no wider than the words plus a letter each side) is a text
    highlight: the glyphs carry its colour as run shading, and the fill is
    neither a bar nor a backdrop. Returns the ids of the fills consumed."""
    chars = [c for c in page.chars if not c.generated and not c.text.isspace()]
    used: set[int] = set()
    for f in page.fills:
        if getattr(f, "white", False) or getattr(f, "alpha", 255) < 200:
            continue
        fb = f.lbox
        if any(tb.intersects(fb) for tb in table_boxes):
            continue
        inside = [c for c in chars if fb.x0 - 1 <= c.lbox.cx <= fb.x1 + 1 and fb.y0 - 1 <= c.lbox.cy <= fb.y1 + 1]
        if not inside:
            continue
        size = max(c.font_size for c in inside)
        # a highlight hugs the glyphs (a font-height box); a bar has padding
        if fb.height > 1.35 * size:
            continue
        x0 = min(c.lbox.x0 for c in inside); x1 = max(c.lbox.x1 for c in inside)
        if fb.x0 < x0 - 0.5 * size or fb.x1 > x1 + 0.5 * size:
            continue
        for c in inside:
            c.highlight = f.rgb  # type: ignore[attr-defined]
        used.add(id(f))
    return used


def _make_band(items: list[Item], page_width: float) -> Band:
    lbox = items[0].lbox
    for it in items[1:]:
        lbox = lbox.union(it.lbox)
    if len(items) == 1:
        it = items[0]
        if it.kind == "table":
            return Band("table", lbox, [it])
        b = Band("flow", lbox, [it])
        return b
    # side-by-side: cluster items into columns by horizontal overlap
    cols: list[list[Item]] = []
    for it in sorted(items, key=lambda i: i.lbox.x0):
        placed = False
        for col in cols:
            cb = col[0].lbox
            for c in col[1:]:
                cb = cb.union(c.lbox)
            ov = min(cb.x1, it.lbox.x1) - max(cb.x0, it.lbox.x0)
            if ov > 0.3 * min(cb.width, it.lbox.width):
                col.append(it)
                placed = True
                break
        if not placed:
            cols.append([it])
    for col in cols:
        col.sort(key=lambda i: i.lbox.y0)
    if len(cols) == 1:
        # vertically overlapping but same column: treat as stacked flow
        return Band("row", lbox, items, cols)
    return Band("row", lbox, items, cols)
