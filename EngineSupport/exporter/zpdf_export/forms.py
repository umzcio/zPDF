"""Pair form widgets with their visible labels (spec §7 FormValue, §9 DOCX).

Geometry is in upright layout space, so rotated pages behave like upright ones.
Labels are taken from visible text only: inside the field box, directly above,
to the left (text fields), or to the right (check boxes / radios). Widgets that
sit inside a table cell take the cell as their label. Anything ambiguous is
left unpaired; the field's tooltip (/TU) is reported but never treated as a
visible label.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from statistics import median

from .extract import PageExtract, Widget
from .geometry import BBox
from .layout import Block, Run
from .tables import Table
from .textlines import Token

_MAX_LABEL_CHARS = 90
_MAX_LABEL_LINES = 2


@dataclass
class FormPair:
    widget: Widget
    label: str | None
    label_source: str            # visible_inside | visible_above | visible_left | visible_right | table_cell | field_tooltip | none
    paired: bool
    placement: str               # inline | inline_sentence | table_cell | fallback
    anchor_lbox: BBox            # where the paired paragraph sits in reading order
    anchor_bbox: BBox
    group_id: str | None = None
    table_id: str | None = None
    cell_index: int | None = None
    ambiguity: list[str] = field(default_factory=list)
    sentence: "ChoiceSentence | None" = None


@dataclass
class ChoiceSentence:
    """A paragraph with check-box glyphs placed where the boxes sit in the text."""
    text: str
    runs: list[Run]
    lbox: BBox
    bbox: BBox
    widgets: list[Widget]
    lines: int
    rows: list = field(default_factory=list)   # [(row lbox, [Run], segments)] per source row, for layout mode;
    # segments: (x0, x1, kind, payload) sorted by x — kind text (tokens) | box (Widget) | value (Widget)


def _glyph(w: Widget) -> str:
    return "\u2612" if w.checked else "\u2610"


def build_choice_sentences(pairs: list[FormPair], blocks: list[Block], consumed_blocks: dict[int, list[Token]],
                           s: float) -> list[Block]:
    """Merge check boxes into the sentence they interrupt or prefix.

    A box belongs to a sentence when its label segment is part of a text block
    (the label is the block's first line, or the block continues after it) or
    when other text sits directly left of the box on the same line. All blocks
    touched by the boxes of one row, plus their remaining lines, become one
    paragraph with ☒/☐ glyphs at the box positions. Returns the blocks left over.
    """
    boxes = [fp for fp in pairs if fp.widget.field_type in ("checkbox", "radio") and fp.paired
             and fp.placement == "inline" and fp.label_source in ("visible_right", "visible_left")]
    if not boxes:
        return blocks
    # tokens -> block index for quick membership
    tok_block: dict[int, int] = {}
    for bi, b in enumerate(blocks):
        for t in b.tokens:
            tok_block[id(t)] = bi
    # a block whose tokens were (partly) consumed as a box label still exists in
    # ``blocks`` only if text remained; consumed tokens live in consumed_blocks
    label_tokens: dict[str, list[Token]] = {}
    for fp in boxes:
        label_tokens[fp.widget.widget_id] = fp.sentence_tokens if hasattr(fp, "sentence_tokens") else []
    # Group boxes by text row (same line band) together with the blocks on that row.
    groups: list[dict] = []
    for fp in boxes:
        wb = fp.widget.lbox
        row_blocks = [bi for bi, b in enumerate(blocks)
                      if any(abs(ln_cy - wb.cy) <= 0.6 * max(wb.height, s) for ln_cy in _line_centers(b))]
        placed = False
        for g in groups:
            if any(bi in g["blocks"] for bi in row_blocks) or any(abs(o.widget.lbox.cy - wb.cy) <= 0.6 * max(wb.height, s) for o in g["boxes"]):
                g["boxes"].append(fp); g["blocks"].update(row_blocks); placed = True; break
        if not placed:
            groups.append({"boxes": [fp], "blocks": set(row_blocks)})
    # A group is a sentence only if some text sits LEFT of a box on its row, or a
    # box label is the first line of a multi-line block (box prefixes a paragraph).
    used_blocks: set[int] = set()
    for g in groups:
        blks = [blocks[bi] for bi in sorted(g["blocks"])]
        # text segments on the rows of this group: remaining block lines plus the
        # label tokens already consumed by the boxes themselves
        text_items: list[tuple[float, float, float, list[Token]]] = []  # (cy, x0, x1, tokens)
        for b in blks:
            for ln_tokens in _block_lines(b):
                lb = _tokens_lbox(ln_tokens)
                text_items.append((lb.cy, lb.x0, lb.x1, ln_tokens))
        for fp in g["boxes"]:
            lt = getattr(fp, "sentence_tokens", None) or []
            if lt:
                lb = _tokens_lbox(lt)
                text_items.append((lb.cy, lb.x0, lb.x1, lt))
        def same_row(cy: float, wb: BBox) -> bool:
            return abs(cy - wb.cy) <= 0.6 * max(wb.height, s)
        left_text = any(x1 <= fp.widget.lbox.x0 + 2 and same_row(cy, fp.widget.lbox)
                        for fp in g["boxes"] for (cy, x0, x1, _t) in text_items)
        prefixes_paragraph = any(fp.label_block_lines > 1 for fp in g["boxes"] if hasattr(fp, "label_block_lines"))
        if not (left_text or prefixes_paragraph):
            continue
        folded_fields: list[FormPair] = _extend_sentence(g, text_items, blocks, pairs, used_blocks, s)
        # cluster text segments into rows (centers within half a font size)
        rows: list[list[float]] = []
        for cy in sorted(cy for cy, _x0, _x1, _t in text_items):
            if rows and cy - rows[-1][-1] <= 0.5 * s:
                rows[-1].append(cy)
            else:
                rows.append([cy])
        row_centers = [sum(r) / len(r) for r in rows]

        def row_of(cy: float) -> int:
            return min(range(len(row_centers)), key=lambda i: abs(row_centers[i] - cy)) if row_centers else 0

        items: list[tuple[int, float, str, object]] = []  # (row index, x, kind, payload)
        for cy, x0, _x1, toks in text_items:
            items.append((row_of(cy), x0, "text", toks))
        min_text_x0 = min((x0 for _cy, x0, _x1, _t in text_items), default=0.0)
        for fp in g["boxes"]:
            wb = fp.widget.lbox
            ri = row_of(wb.cy)
            if row_centers and abs(row_centers[ri] - wb.cy) > 0.8 * max(wb.height, s):
                ri = len(row_centers)  # no row nearby: after all text
            if wb.x1 <= min_text_x0 + 1 and row_centers and abs(row_centers[0] - wb.cy) <= 1.2 * max(wb.height, s):
                ri = 0  # a box left of all text prefixes the paragraph
            items.append((ri, wb.x0, "box", fp))
        for fp in folded_fields:
            wb = fp.widget.lbox
            ri = row_of(wb.cy)
            if not row_centers or abs(row_centers[ri] - wb.cy) > 0.6 * max(wb.height, s):
                ri = len(row_centers)  # a field on a row with no text follows all text
                items.append((ri, wb.cy * 1000 + wb.x0, "value", fp))
            else:
                items.append((ri, wb.x0, "value", fp))
        items.sort(key=lambda it: (it[0], it[1]))
        runs: list[Run] = []
        text_parts: list[str] = []
        widgets: list[Widget] = []
        all_tokens: list[Token] = []
        row_runs: dict[int, list[Run]] = {}
        row_boxes: dict[int, BBox] = {}
        row_segs: dict[int, list[tuple[float, float, str, object]]] = {}
        # a list marker stripped from a block is re-attached to the token it preceded
        markers = {id(b.marker_next): b.marker_tokens for b in blks if b.marker_tokens and b.marker_next is not None}

        def _row_add(ri: int, run: Run, box: BBox, kind: str, payload) -> None:
            row_runs.setdefault(ri, []).append(run)
            row_boxes[ri] = box if ri not in row_boxes else row_boxes[ri].union(box)
            row_segs.setdefault(ri, []).append((box.x0, box.x1, kind, payload))

        for ri, _x, kind, payload in items:
            if kind == "box":
                fp = payload
                piece = _glyph(fp.widget)
                widgets.append(fp.widget)
                if text_parts and not text_parts[-1].endswith((" ", "(")):
                    piece = " " + piece
                runs.append(Run(piece, False, False)); text_parts.append(piece)
                _row_add(ri, Run(piece, False, False), fp.widget.lbox, "box", fp.widget)
            elif kind == "value":
                fp = payload
                widgets.append(fp.widget)
                piece = fp.widget.value.strip() or "____"
                if text_parts and not text_parts[-1].endswith((" ", "(")):
                    piece = " " + piece
                runs.append(Run(piece, False, False)); text_parts.append(piece)
                _row_add(ri, Run(piece, False, False), fp.widget.lbox, "value", fp.widget)
            else:
                if payload and id(payload[0]) in markers:
                    payload = list(markers[id(payload[0])]) + [Token(payload[0].char, True)] + list(payload[1:])
                t = tokens_text(payload)
                if not t:
                    continue
                if text_parts and not text_parts[-1].endswith(" "):
                    t = " " + t
                seg_runs = tokens_runs(payload)
                for r in seg_runs:
                    runs.append(Run(r.text, r.bold, r.italic))
                if text_parts and not text_parts[-1].endswith(" ") and runs:
                    # prepend the separating space to the first run of this segment
                    idx = len(runs) - len(seg_runs)
                    runs[idx].text = " " + runs[idx].text
                text_parts.append(t)
                all_tokens.extend(payload)
                seg_box = _tokens_lbox(payload)
                for k, r in enumerate(seg_runs):
                    row_runs.setdefault(ri, []).append(Run((" " if k == 0 and row_runs.get(ri) else "") + r.text, r.bold, r.italic))
                row_boxes[ri] = seg_box if ri not in row_boxes else row_boxes[ri].union(seg_box)
                row_segs.setdefault(ri, []).append((seg_box.x0, seg_box.x1, "text", list(payload)))
        text = "".join(text_parts).strip()
        if runs:
            runs[0].text = runs[0].text.lstrip()
        lbox = _tokens_lbox(all_tokens) if all_tokens else g["boxes"][0].widget.lbox
        bbox = _tokens_bbox(all_tokens) if all_tokens else g["boxes"][0].widget.bbox
        for fp in g["boxes"]:
            lbox = lbox.union(fp.widget.lbox); bbox = bbox.union(fp.widget.bbox)
        sentence = ChoiceSentence(text, runs, lbox, bbox, widgets, max(1, len(row_centers)),
                                  [(row_boxes[ri], row_runs[ri], sorted(row_segs.get(ri, []), key=lambda sg: sg[0]))
                                   for ri in sorted(row_runs)])
        for fp in g["boxes"] + folded_fields:
            fp.sentence = sentence
            fp.placement = "inline_sentence"
        used_blocks.update(g["blocks"])
    return [b for bi, b in enumerate(blocks) if bi not in used_blocks]


_TERMINAL = (".", "!", "?")


def _ends_open(text: str) -> bool:
    t = text.rstrip().rstrip(")").rstrip()
    return bool(t) and not t.endswith(_TERMINAL)


def _extend_sentence(g: dict, text_items: list, blocks: list[Block], pairs: list[FormPair],
                     used_blocks: set[int], s: float) -> list[FormPair]:
    """Grow a box-sentence group upward through a box-prefixed lead line and
    downward through continuation rows: plain lines starting lowercase, and
    labels of text fields on those rows (whose values are folded in).
    Mutates ``g`` (blocks, boxes) and ``text_items``; returns folded field pairs."""
    folded: list[FormPair] = []
    if not text_items:
        return folded

    def rows():
        cys = sorted(cy for cy, _x0, _x1, _t in text_items)
        return cys[0], cys[-1], min(x0 for _cy, x0, _x1, _t in text_items)

    def row_text(cy: float) -> str:
        parts = sorted([(x0, tokens_text(t)) for c, x0, _x1, t in text_items if abs(c - cy) <= 0.5 * s])
        return " ".join(p for _x, p in parts)

    def add_field(fp: FormPair) -> None:
        lt = getattr(fp, "sentence_tokens", None) or []
        if lt:
            lb = _tokens_lbox(lt)
            text_items.append((lb.cy, lb.x0, lb.x1, lt))
        subt = getattr(fp, "sub_tokens", []) or []
        if subt:
            sb = _tokens_lbox(subt)
            text_items.append((sb.cy, sb.x0, sb.x1, subt))
        folded.append(fp)

    # upward: a box-prefixed single-line label pair directly above
    first_cy, last_cy, left = rows()
    for fp in pairs:
        if (fp.widget.field_type in ("checkbox", "radio") and fp.placement == "inline" and fp not in g["boxes"]
                and getattr(fp, "label_block_lines", 1) == 1 and fp.label_source == "visible_right"):
            lt = getattr(fp, "sentence_tokens", None) or []
            if not lt:
                continue
            lb = _tokens_lbox(lt)
            lead = tokens_text(lt)
            # a lead line ending in ":" is completed by a field, not by the next paragraph
            if (0.6 * s <= first_cy - lb.cy <= 2.3 * s and fp.widget.lbox.x0 <= left + 3 * s
                    and _ends_open(lead) and not lead.rstrip().endswith(":")):
                g["boxes"].append(fp)
                text_items.append((lb.cy, lb.x0, lb.x1, lt))
                break
    # downward
    for _ in range(8):
        first_cy, last_cy, left = rows()
        if not _ends_open(row_text(last_cy)):
            break
        lo, hi = last_cy + 0.6 * s, last_cy + 1.8 * s
        grew = False
        for bi, b in enumerate(blocks):
            if bi in g["blocks"] or bi in used_blocks:
                continue
            fl = _first_line(b)
            if not fl:
                continue
            flb = _tokens_lbox(fl)
            if lo <= flb.cy <= hi and abs(flb.x0 - left) <= 3 * s and b.text[:1].islower():
                for ln in _block_lines(b):
                    lb = _tokens_lbox(ln)
                    text_items.append((lb.cy, lb.x0, lb.x1, ln))
                g["blocks"].add(bi)
                grew = True
        for fp in pairs:
            if fp.widget.field_type in ("checkbox", "radio") or fp.placement != "inline" or fp in folded:
                continue
            lt = getattr(fp, "sentence_tokens", None) or []
            if not lt or fp.label_source not in ("visible_left", "visible_caption"):
                continue
            lb = _tokens_lbox(lt)
            if lo <= lb.cy <= hi and abs(lb.x0 - left) <= 3 * s and tokens_text(lt)[:1].islower():
                add_field(fp)
                grew = True
        if not grew:
            # an unlabelled text field that sits right after the sentence's last
            # row (same row, to the right) or starts the next row completes it
            first_cy, last_cy, left = rows()
            row_x1 = max((x1 for cy, _x0, x1, _t in text_items if abs(cy - last_cy) <= 0.5 * s), default=left)
            for fp in pairs:
                if fp.widget.field_type in ("checkbox", "radio") or fp.paired or fp in folded:
                    continue
                wb = fp.widget.lbox
                same_row = abs(wb.cy - last_cy) <= 0.6 * max(wb.height, s) and wb.x0 >= row_x1 - 2
                next_row = lo <= wb.cy <= hi and abs(wb.x0 - left) <= 3 * s
                if same_row or next_row:
                    fp.paired = True
                    fp.label = row_text(last_cy)
                    fp.label_source = "sentence_continuation"
                    fp.sentence_tokens = []  # type: ignore[attr-defined]
                    folded.append(fp)
                    grew = True
                    break
            if not grew:
                break
            continue
        # further fields on the same new row ("(mm/dd/yyyy) to" + field)
        first_cy, last_cy, left = rows()
        for fp in pairs:
            if fp.widget.field_type in ("checkbox", "radio") or fp.placement != "inline" or fp in folded:
                continue
            if fp.label_source not in ("visible_left", "visible_caption"):
                continue  # an "above" label belongs to a field on the next row
            lt = getattr(fp, "sentence_tokens", None) or []
            if lt and abs(_tokens_lbox(lt).cy - last_cy) <= 0.5 * s and _tokens_lbox(lt).x0 > left:
                add_field(fp)
    return folded


def _line_centers(b: Block) -> list[float]:
    return [_tokens_lbox(ln).cy for ln in _block_lines(b)]


def _first_cy(b: Block) -> float:
    fl = _first_line(b)
    return _tokens_lbox(fl).cy if fl else b.lbox.cy


def _block_lines(b: Block) -> list[list[Token]]:
    return _token_lines(b.tokens)


def _token_lines(tokens: list[Token]) -> list[list[Token]]:
    """Tokens per visual line. A token joins the current line when its centre is
    near the line's mean centre (not the previous glyph's: a comma followed by an
    opening quote differ by most of the font size while sharing the line)."""
    lines: list[list[Token]] = []
    cy_sum = 0.0
    for t in tokens:
        if lines and abs(cy_sum / len(lines[-1]) - t.char.lbox.cy) <= 0.5 * t.char.font_size:
            lines[-1].append(t); cy_sum += t.char.lbox.cy
        else:
            lines.append([t]); cy_sum = t.char.lbox.cy
    return lines


def _neighbour_cell_label(t, cell, w) -> tuple[str | None, str]:
    """Label for a widget in an empty grid cell from an adjacent cell."""
    def text(c):
        return c.raw_text.replace("\n", " ").strip()

    def overlap_y(a, b):
        return min(a.lbox.y1, b.lbox.y1) - max(a.lbox.y0, b.lbox.y0) > 0.5 * min(a.lbox.height, b.lbox.height)

    def overlap_x(a, b):
        return min(a.lbox.x1, b.lbox.x1) - max(a.lbox.x0, b.lbox.x0) > 0.5 * min(a.lbox.width, b.lbox.width)

    if w.field_type in ("checkbox", "radio"):
        right = sorted([c for c in t.cells if text(c) and overlap_y(c, cell) and c.lbox.x0 >= cell.lbox.x1 - 1],
                       key=lambda c: c.lbox.x0)
        parts: list[str] = []
        edge = cell.lbox.x1
        for c in right:  # chain adjacent cells ("2." | "A noncitizen national …")
            if c.lbox.x0 - edge > 6:
                break
            parts.append(text(c)); edge = c.lbox.x1
        if parts:
            return " ".join(parts), "table_cell_right"
        return None, "none"
    left = [c for c in t.cells if text(c) and overlap_y(c, cell) and c.lbox.x1 <= cell.lbox.x0 + 1]
    if left:
        c = max(left, key=lambda c: c.lbox.x1)
        if cell.lbox.x0 - c.lbox.x1 <= 6:
            return text(c), "table_cell_left"
    above = [c for c in t.cells if text(c) and overlap_x(c, cell) and c.lbox.y1 <= cell.lbox.y0 + 1]
    if above:
        c = max(above, key=lambda c: c.lbox.y1)
        if cell.lbox.y0 - c.lbox.y1 <= 6:
            return text(c), "table_cell_above"
    return None, "none"


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def _v_overlap(a: BBox, b: BBox) -> float:
    return max(0.0, min(a.y1, b.y1) - max(a.y0, b.y0))


def _h_overlap(a: BBox, b: BBox) -> float:
    return max(0.0, min(a.x1, b.x1) - max(a.x0, b.x0))


def _label_block(b: Block, max_lines: int = _MAX_LABEL_LINES, max_chars: int = _MAX_LABEL_CHARS) -> bool:
    return b.kind in ("paragraph", "heading", "list_item") and b.lines <= max_lines and len(b.text) <= max_chars and bool(b.text.strip())


def _left_of_field(b: Block, widgets: list[Widget], s: float) -> bool:
    """True if the block's first line ends just before a widget on the same row:
    such text is that widget's (or group's) lead-in label, not a label for a
    field above or below."""
    first = _first_line(b)
    if not first:
        return False
    fl = _tokens_lbox(first)
    for w in widgets:
        wb = w.lbox
        if fl.x1 <= wb.x0 + 2 and wb.x0 - fl.x1 <= _GAP_LIMIT["visible_left"] * s:
            if _v_overlap(fl, wb) >= 0.3 * min(fl.height, wb.height) or abs(fl.cy - wb.cy) <= 0.6 * wb.height:
                return True
    return False


def _slice_tokens(block: Block, x0: float, x1: float, y0: float | None = None, y1: float | None = None) -> tuple[list[Token], list[Token]]:
    """Split a block's tokens into (inside the x-range [and y-range], the rest).

    The inside part is trimmed to label-segment boundaries: it must start after
    a line start or a gap of at least 0.8 × font size and end likewise, so a
    slice never begins or ends mid-phrase (e.g. ".)" left over from a longer
    label that belongs to a different widget).
    """
    toks = block.tokens
    flags = []
    for t in toks:
        cx, cy = t.char.lbox.cx, t.char.lbox.cy
        flags.append(x0 - 1.0 <= cx <= x1 + 1.0 and (y0 is None or (y0 - 1.0 <= cy <= y1 + 1.0)))
    if all(flags):
        return list(toks), []
    if not any(flags):
        return [], list(toks)

    def boundary_before(i: int) -> bool:
        if i == 0:
            return True
        a, b = toks[i - 1].char, toks[i].char
        if abs(a.lbox.cy - b.lbox.cy) > 0.5 * b.font_size:
            return True  # new line
        return b.loose.x0 - a.loose.x1 >= 0.8 * b.font_size

    def boundary_after(i: int) -> bool:
        return i == len(toks) - 1 or boundary_before(i + 1)

    # keep only maximal runs of flagged tokens that start and end on boundaries
    inside_idx: set[int] = set()
    i = 0
    while i < len(toks):
        if not flags[i]:
            i += 1
            continue
        j = i
        while j + 1 < len(toks) and flags[j + 1]:
            j += 1
        # trim to boundaries
        a, b = i, j
        while a <= b and not boundary_before(a):
            a += 1
        while b >= a and not boundary_after(b):
            b -= 1
        if a <= b:
            inside_idx.update(range(a, b + 1))
        i = j + 1
    inside = [t for k, t in enumerate(toks) if k in inside_idx]
    rest = [t for k, t in enumerate(toks) if k not in inside_idx]
    return inside, rest


def tokens_text(tokens: list[Token]) -> str:
    out = []
    for i, t in enumerate(tokens):
        if i > 0 and (t.space_before or t.char.lbox.x0 - tokens[i - 1].char.lbox.x1 > 0.25 * t.char.font_size
                      or abs(t.char.lbox.cy - tokens[i - 1].char.lbox.cy) > 0.5 * t.char.font_size):
            out.append(" ")
        out.append(t.char.text)
    return "".join(out).strip()


def tokens_runs(tokens: list[Token]) -> list[Run]:
    runs: list[Run] = []
    text = tokens_text(tokens)
    # rebuild runs by attribute changes; spaces attached to following char
    pieces: list[tuple[str, bool, bool]] = []
    for i, t in enumerate(tokens):
        piece = t.char.text
        if i > 0 and (t.space_before or t.char.lbox.x0 - tokens[i - 1].char.lbox.x1 > 0.25 * t.char.font_size
                      or abs(t.char.lbox.cy - tokens[i - 1].char.lbox.cy) > 0.5 * t.char.font_size):
            piece = " " + piece
        pieces.append((piece, t.char.bold, t.char.italic))
    for piece, bold, italic in pieces:
        if runs and runs[-1].bold == bold and runs[-1].italic == italic:
            runs[-1].text += piece
        else:
            runs.append(Run(piece, bold, italic))
    if runs:
        runs[0].text = runs[0].text.lstrip()
        runs[-1].text = runs[-1].text.rstrip()
    assert "".join(r.text for r in runs) == text
    return [r for r in runs if r.text]


def _tokens_lbox(tokens: list[Token]) -> BBox:
    b = tokens[0].char.lbox
    for t in tokens[1:]:
        b = b.union(t.char.lbox)
    return b


def _tokens_bbox(tokens: list[Token]) -> BBox:
    b = tokens[0].char.bbox
    for t in tokens[1:]:
        b = b.union(t.char.bbox)
    return b



_PENALTY = {"visible_inside": 0.0, "visible_right": 0.0, "visible_left": 0.5, "visible_above": 0.5,
            "visible_below": 0.6, "visible_caption": 0.7, "visible_right_hint": 0.8}
_SUB_SOURCES = ("visible_below", "visible_right_hint")
_GAP_LIMIT = {"visible_above": 1.5, "visible_below": 1.2, "visible_left": 6.0, "visible_right": 3.0}


@dataclass
class _Cand:
    score: float
    widget: Widget
    block: Block
    tokens: list[Token]
    source: str


def _first_line(block: Block) -> list[Token]:
    if not block.tokens:
        return []
    cy = block.tokens[0].char.lbox.cy
    size = block.tokens[0].char.font_size
    return [t for t in block.tokens if abs(t.char.lbox.cy - cy) <= 0.5 * size]


def _clean_checkbox_label(text: str) -> str:
    text = text.strip()
    text = re.sub(r"^[)\]]\s*", "", text)
    text = re.sub(r"\s*[/(\[]\s*$", "", text)
    return text.strip() or text


def _checkbox_owned(tokens: list[Token], boxes: list[BBox], s: float) -> bool:
    """True if the segment starts just right of a check box on the same line:
    that text is the box's label, never a text field's."""
    if not tokens:
        return False
    first = tokens[0].char.lbox
    for cb in boxes:
        if 0 <= first.x0 - cb.x1 <= 3 * s and _v_overlap(first, cb) >= 0.3 * min(first.height, cb.height):
            return True
    return False


def _candidates(w: Widget, blocks: list[Block], s: float, boxes: list[BBox] | None = None,
                left_blocks: set[int] | None = None) -> list[_Cand]:
    out: list[_Cand] = []
    if w.field_type == "signature":
        return out      # no text value to place: visible text near a signature box is never its label
    wb = w.lbox
    boxes = boxes or []
    left_blocks = left_blocks or set()
    for b in blocks:
        lb = b.lbox
        if w.field_type in ("checkbox", "radio"):
            for source, cond, dist in (
                ("visible_right", lb.x0 >= wb.x1 - 2 and lb.x0 - wb.x1 <= _GAP_LIMIT["visible_right"] * s, lb.x0 - wb.x1),
                ("visible_left", lb.x1 <= wb.x0 + 2 and wb.x0 - lb.x1 <= _GAP_LIMIT["visible_right"] * s, wb.x0 - lb.x1),
            ):
                first = _first_line(b)
                if not first:
                    continue
                fl = _tokens_lbox(first)
                if cond and (_v_overlap(fl, wb) >= 0.3 * min(fl.height, wb.height) or abs(fl.cy - wb.cy) <= 0.6 * wb.height):
                    penalty = _PENALTY[source] + (0.3 if source == "visible_left" else 0.0)
                    out.append(_Cand(max(dist, 0) / s + penalty, w, b, first, source))
            continue
        if not _label_block(b, 3, 220):
            continue
        # inside the field box
        inside, rest = _slice_tokens(b, wb.x0, wb.x1, wb.y0, wb.y1)
        if inside and _tokens_lbox(inside).height <= wb.height + 2 and not _checkbox_owned(inside, boxes, s):
            out.append(_Cand(_PENALTY["visible_inside"], w, b, inside, "visible_inside"))
            continue
        # above / below: tokens within the field's x-range (never from a block
        # that is itself the lead-in label of a field on its own row)
        col, _ = _slice_tokens(b, wb.x0, wb.x1)
        if col and not _checkbox_owned(col, boxes, s) and id(b) not in left_blocks and _label_block(b):
            cb = _tokens_lbox(col)
            if _h_overlap(cb, wb) >= 0.5 * cb.width:
                # a "Label: …" block only labels a field below it from its start;
                # its trailing lines are not free-standing labels
                starts_at_block = col[0] is b.tokens[0]
                if (cb.y1 <= wb.y0 + 2 and wb.y0 - cb.y1 <= _GAP_LIMIT["visible_above"] * s
                        and (":" not in b.text or starts_at_block)):
                    # a label above a field starts at (or near) the field's left edge; text that
                    # begins far to the right is more likely the tail of the row above
                    offset = max(0.0, cb.x0 - wb.x0) / max(wb.width, 1.0)
                    out.append(_Cand((wb.y0 - cb.y1) / s + _PENALTY["visible_above"] + offset, w, b, col, "visible_above"))
                elif (cb.y0 >= wb.y1 - 2 and cb.y0 - wb.y1 <= _GAP_LIMIT["visible_below"] * s
                      and len(tokens_text(col).split()) <= 4 and not tokens_text(col).rstrip().endswith(":")):
                    out.append(_Cand((cb.y0 - wb.y1) / s + _PENALTY["visible_below"], w, b, col, "visible_below"))
        # format hint right of a text field, e.g. "(mm/dd/yyyy)": a sub-label
        first_r = _first_line(b)
        if first_r and b.lines == 1 and len(b.text.split()) <= 3 and (b.text.startswith("(") or len(b.text) <= 14):
            fr = _tokens_lbox(first_r)
            if (fr.x0 >= wb.x1 - 2 and fr.x0 - wb.x1 <= _GAP_LIMIT["visible_right"] * s
                    and (_v_overlap(fr, wb) >= 0.3 * min(fr.height, wb.height) or abs(fr.cy - wb.cy) <= 0.6 * wb.height)
                    and not _checkbox_owned(first_r, boxes, s)):
                # a parenthesized format hint right after a field belongs to it
                penalty = 0.4 if b.text.startswith("(") else _PENALTY["visible_right_hint"]
                out.append(_Cand((fr.x0 - wb.x1) / s + penalty, w, b, list(b.tokens), "visible_right_hint"))
        # caption: a label-like line ("Date: …") starting just left of or inside the
        # field's x-range whose first line sits over the field's lower half or just below it
        first = _first_line(b)
        if first and _label_block(b) and ":" in tokens_text(first) and not _checkbox_owned(first, boxes, s):
            fl = _tokens_lbox(first)
            if (wb.x0 - 3 * s <= fl.x0 <= wb.x1 and _h_overlap(fl, wb) >= 0.3 * fl.width
                    and wb.cy <= fl.cy <= wb.y1 + _GAP_LIMIT["visible_below"] * s):
                out.append(_Cand(max(fl.cy - wb.y1, 0) / s + _PENALTY["visible_caption"], w, b, list(b.tokens), "visible_caption"))
                continue
        # left, on the same row: judged by the block's first line (a wrapped
        # continuation may run under the field), labelled with the whole block
        if first and _label_block(b, 3, 220) and not _checkbox_owned(list(b.tokens), boxes, s):
            fl = _tokens_lbox(first)
            if fl.x1 <= wb.x0 + 2 and wb.x0 - fl.x1 <= _GAP_LIMIT["visible_left"] * s:
                if _v_overlap(fl, wb) >= 0.3 * min(fl.height, wb.height) or abs(fl.cy - wb.cy) <= 0.6 * wb.height:
                    out.append(_Cand((wb.x0 - fl.x1) / s + _PENALTY["visible_left"], w, b, list(b.tokens), "visible_left"))
    return out


def pair_widgets(page: PageExtract, blocks: list[Block], tables: list[Table]) -> tuple[list[FormPair], list[Block]]:
    """Return (pairs, remaining blocks). Consumed label text is removed from the
    returned blocks; partially consumed blocks keep their remaining text."""
    sizes = [c.font_size for c in page.chars if not c.generated and c.font_size > 0]
    s = median(sizes) if sizes else 9.0
    widgets = [w for w in page.widgets if w.field_type != "pushbutton"]

    # radio / shared-name groups on this page
    names: dict[tuple[str, str], list[Widget]] = {}
    for w in widgets:
        names.setdefault((w.field_name, w.field_type), []).append(w)

    def group_of(w: Widget) -> str | None:
        if w.field_type == "radio" or len(names[(w.field_name, w.field_type)]) > 1:
            return f"p{page.index}-group-{_norm(w.field_name).replace(' ', '-') or 'unnamed'}"
        return None

    pairs: dict[str, FormPair] = {}

    # 1) widgets inside table cells
    remaining_widgets: list[Widget] = []
    for w in widgets:
        hit = None
        for t in tables:
            if t.lbox.contains_point(w.lbox.cx, w.lbox.cy):
                for i, c in enumerate(t.cells):
                    if c.lbox.contains_point(w.lbox.cx, w.lbox.cy):
                        hit = (t, i)
                        break
                break
        if hit:
            t, ci = hit
            cell = t.cells[ci]
            label = cell.raw_text.replace("\n", " ").strip() or None
            source = "table_cell"
            if label is None:
                # an empty cell: a check box is labelled by the next cell to its right,
                # a text field by the cell to its left or the one above (grid forms)
                label, source = _neighbour_cell_label(t, cell, w)
            pairs[w.widget_id] = FormPair(w, label, source if label else "none", label is not None, "table_cell",
                                          cell.lbox, cell.bbox, group_of(w), t.table_id, ci)
        else:
            remaining_widgets.append(w)

    # 2) global greedy assignment of visible label segments
    boxes = [w.lbox for w in widgets if w.field_type in ("checkbox", "radio")]
    left_blocks = {id(b) for b in blocks if _left_of_field(b, widgets, s)}
    cands: list[_Cand] = []
    for w in remaining_widgets:
        cands.extend(_candidates(w, blocks, s, boxes, left_blocks))
    cands.sort(key=lambda c: c.score)
    consumed_tokens: set[int] = set()
    primary: dict[str, _Cand] = {}
    sub: dict[str, _Cand] = {}
    ambiguous: dict[str, list[str]] = {}
    for c in cands:
        wid = c.widget.widget_id
        if c.source in _SUB_SOURCES:
            if wid in sub:
                continue
        elif wid in primary or wid in ambiguous:
            continue
        if any(id(t) in consumed_tokens for t in c.tokens):
            continue
        if c.source not in _SUB_SOURCES:
            rivals = [o for o in cands if o.widget is c.widget and o is not c and o.source not in _SUB_SOURCES
                      and o.score - c.score <= 0.15 and tokens_text(o.tokens) != tokens_text(c.tokens)
                      and not any(id(t) in consumed_tokens for t in o.tokens)]
            if rivals:
                tip = _norm(c.widget.label or "")
                match = [o for o in [c] + rivals if tip and (tip in _norm(tokens_text(o.tokens)) or _norm(tokens_text(o.tokens)) in tip)]
                if len(match) == 1:
                    c = match[0]
                else:
                    ambiguous[wid] = [tokens_text(o.tokens) for o in [c] + rivals]
                    continue
        consumed_tokens.update(id(t) for t in c.tokens)
        (sub if c.source in _SUB_SOURCES else primary)[wid] = c

    # 3) row-shared labels: an unlabeled text field takes the primary label of the
    #    nearest labeled field to its left on the same row when no text intervenes
    for w in remaining_widgets:
        wid = w.widget_id
        if wid in primary or wid in ambiguous or w.field_type in ("checkbox", "radio"):
            continue
        row_mates = [o for o in remaining_widgets if o is not w and o.widget_id in primary and o.lbox.x1 <= w.lbox.x0 + 2
                     and _v_overlap(o.lbox, w.lbox) >= 0.5 * min(o.lbox.height, w.lbox.height)
                     and primary[o.widget_id].source in ("visible_left", "visible_inside", "visible_above", "visible_caption")]
        if not row_mates:
            continue
        leader = max(row_mates, key=lambda o: o.lbox.x1)
        between = BBox(leader.lbox.x1, min(leader.lbox.y0, w.lbox.y0), w.lbox.x0, max(leader.lbox.y1, w.lbox.y1))
        if any(b.lbox.intersects(between) and _h_overlap(b.lbox, between) > 2 for b in blocks
               if not all(id(t) in consumed_tokens for t in b.tokens)):
            continue
        lc = primary[leader.widget_id]
        primary[wid] = _Cand(lc.score + 2.0, w, lc.block, [], lc.source + "_shared")

    # 4) build pairs
    for w in remaining_widgets:
        wid = w.widget_id
        gid = group_of(w)
        if wid in primary:
            pc = primary[wid]
            if pc.tokens:
                label = tokens_text(pc.tokens)
            else:  # shared row label
                label = tokens_text(primary[[o for o in remaining_widgets if o.widget_id in primary and primary[o.widget_id].block is pc.block and primary[o.widget_id].tokens][0].widget_id].tokens)
            if w.field_type in ("checkbox", "radio"):
                label = _clean_checkbox_label(label)
            if wid in sub:
                label = f"{label} {tokens_text(sub[wid].tokens)}".strip()
            if pc.tokens:
                anchor_l = _tokens_lbox(pc.tokens) if pc.source != "visible_inside" else w.lbox
                anchor_b = _tokens_bbox(pc.tokens) if pc.source != "visible_inside" else w.bbox
            else:
                anchor_l, anchor_b = w.lbox, w.bbox
            if w.field_type in ("checkbox", "radio"):
                anchor_l, anchor_b = w.lbox.union(anchor_l), w.bbox.union(anchor_b)
            fp = FormPair(w, label, pc.source, True, "inline", anchor_l, anchor_b, gid)
            fp.sentence_tokens = list(pc.tokens)  # type: ignore[attr-defined]
            fp.label_block_lines = pc.block.lines if pc.block is not None else 1  # type: ignore[attr-defined]
            fp.sub_tokens = list(sub[wid].tokens) if wid in sub else []  # type: ignore[attr-defined]
            # a label that opens a list item keeps the item's marker for layout mode
            blk = pc.block
            fp.marker_tokens = (list(blk.marker_tokens) if blk is not None and blk.marker_tokens  # type: ignore[attr-defined]
                                and pc.tokens and pc.tokens[0] is blk.marker_next else [])
            pairs[wid] = fp
        elif wid in sub and sub[wid].source == "visible_below":
            sc = sub[wid]
            label = tokens_text(sc.tokens)
            pairs[wid] = FormPair(w, label, "visible_below", True, "inline", w.lbox, w.bbox, gid)
        else:
            pairs[wid] = FormPair(w, w.label, "field_tooltip" if w.label else "none", False, "fallback",
                                  w.lbox, w.bbox, gid, ambiguity=ambiguous.get(wid, []))

    for wid, sc in list(sub.items()):
        if sc.source == "visible_right_hint" and wid not in primary:
            for t in sc.tokens:
                consumed_tokens.discard(id(t))
            del sub[wid]

    # 5) remove consumed tokens from blocks
    remaining: list[Block] = []
    for b in blocks:
        left = [t for t in b.tokens if id(t) not in consumed_tokens]
        if len(left) == len(b.tokens):
            remaining.append(b)
            continue
        if not left:
            continue
        text = tokens_text(left)
        if not text:
            continue
        b.tokens = left
        b.text = text
        b.runs = tokens_runs(left)
        b.lbox = _tokens_lbox(left)
        b.bbox = _tokens_bbox(left)
        remaining.append(b)
    ordered = [pairs[w.widget_id] for w in widgets if w.widget_id in pairs]
    remaining = build_choice_sentences(ordered, remaining, {}, s)
    return ordered, remaining
