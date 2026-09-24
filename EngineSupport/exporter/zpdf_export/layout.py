"""Text layout: lines -> blocks -> classified paragraphs in reading order."""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

from .extract import PageExtract
from .geometry import BBox
from .textlines import Line, Token, build_lines, split_line_at_gaps, split_lines_with_neighbors

_BULLET_RE = re.compile(r"^([•●◦▪■‣⁃\-–\*])\s+")
_ENUM_RE = re.compile(r"^(\(?\d{1,2}[.)]|[a-z][.)])\s+")


@dataclass
class Run:
    text: str
    bold: bool
    italic: bool
    uri: str | None = None
    dest_page: int | None = None


@dataclass
class Block:
    page: int
    kind: str  # paragraph | heading | list_item
    text: str
    runs: list[Run]
    lbox: BBox
    bbox: BBox
    lines: int
    level: int | None = None
    marker: str | None = None
    size: float = 0.0
    tokens: list = field(default_factory=list)  # Token list (chars + space flags) for label slicing
    marker_tokens: list = field(default_factory=list)  # glyphs of a stripped list marker (layout mode re-emits them)
    marker_next: object = None  # the Token the marker preceded (identity), wherever that token ends up


@dataclass
class _Proto:
    lines: list[Line] = field(default_factory=list)

    @property
    def lbox(self) -> BBox:
        b = self.lines[0].lbox
        for ln in self.lines[1:]:
            b = b.union(ln.lbox)
        return b

    @property
    def size(self) -> float:
        return sum(ln.size for ln in self.lines) / len(self.lines)

    @property
    def bold(self) -> bool:
        toks = [t for ln in self.lines for t in ln.tokens]
        return bool(toks) and all(t.char.bold for t in toks)


def analyze_layout(page: PageExtract, exclude: list[BBox]) -> list[Block]:
    chars = [c for c in page.chars
             if not any(e.contains_point(c.lbox.cx, c.lbox.cy) for e in exclude)]
    segments: list[Line] = split_lines_with_neighbors(build_lines(chars))
    if not segments:
        return []
    body_size = _body_size(segments)
    protos = _group_blocks(segments, _column_width(segments))
    protos = order_atoms(protos)
    blocks = [_classify(page, p, body_size) for p in protos]
    _pair_drop_caps(blocks)
    _assign_heading_levels([b for b in blocks if getattr(b, "drop_cap_of", None) is None])
    _attach_links(page, blocks)
    return blocks


def _pair_drop_caps(blocks: list[Block]) -> None:
    """A single capital much larger than the text beside it, whose top is that
    text's top, begins that text (a drop cap: 'F' + 'or Americans…'). The
    pair is marked, not merged: reading order joins them (the paragraph's
    ``drop_cap``), while page layout keeps the letter where it is drawn."""
    for cap in blocks:
        letter = cap.text.strip()
        if len(letter) != 1 or not letter.isalpha() or not letter.isupper() or cap.size <= 0:
            continue
        for b in blocks:
            if b is cap or getattr(b, "drop_cap", None) is not None or not b.text[:1].isalpha():
                continue
            if b.size <= 0 or cap.size < 1.6 * b.size:
                continue
            if abs(b.lbox.y0 - cap.lbox.y0) > 0.5 * b.size:
                continue
            first_x = min((t.char.lbox.x0 for t in b.tokens[:1]), default=b.lbox.x0)
            if not (cap.lbox.x1 - 1.0 <= first_x <= cap.lbox.x1 + 1.5 * b.size):
                continue
            b.drop_cap = cap            # type: ignore[attr-defined]
            cap.drop_cap_of = b         # type: ignore[attr-defined]
            break


def _body_size(segments: list[Line]) -> float:
    counter: Counter[float] = Counter()
    for ln in segments:
        for t in ln.tokens:
            counter[round(t.char.font_size * 2) / 2] += 1
    return counter.most_common(1)[0][0] if counter else 10.0


def _column_width(segments: list[Line]) -> float:
    widths = sorted(ln.lbox.width for ln in segments)
    return widths[int(0.9 * (len(widths) - 1))] if widths else 0.0


def _starts_list(line: Line) -> bool:
    t = line.text
    return bool(_BULLET_RE.match(t) or _ENUM_RE.match(t))


def _group_blocks(segments: list[Line], column_width: float) -> list[_Proto]:
    segments = sorted(segments, key=lambda ln: (ln.lbox.cy, ln.lbox.x0))
    protos: list[_Proto] = []
    for seg in segments:
        best: _Proto | None = None
        for p in protos[-12:]:
            last = p.lines[-1]
            lb, sb = last.lbox, seg.lbox
            if sb.cy <= last.cy:
                continue
            h_overlap = min(lb.x1, sb.x1) - max(lb.x0, sb.x0)
            if h_overlap < 0.5 * min(lb.width, sb.width):
                continue
            size = max(last.size, seg.size, 1.0)
            pitch = seg.cy - last.cy
            if pitch > 1.6 * size:
                continue
            if abs(last.size - seg.size) > 1.0:
                continue
            # bold run-in headings ("Reminders. The rate is…") continue into plain
            # text: allow a bold change when the previous line mixes weights or
            # the new line starts mid-sentence (lowercase)
            if last_bold(last) != last_bold(seg) and not (_mixed_bold(last) or seg.text[:1].islower()):
                continue
            if _starts_list(seg):
                continue
            # a ragged short previous line followed by a capitalized start ends a
            # paragraph; "short" is judged against the block's own lines when it
            # has several, otherwise against the page's dominant column width
            block_right = max(l.lbox.x1 for l in p.lines)
            width = max(block_right, sb.x1) - min(min(l.lbox.x0 for l in p.lines), sb.x0)
            ref_width = max(l.lbox.width for l in p.lines) if len(p.lines) >= 2 else column_width
            first = seg.text[:1]
            short_vs_block = lb.x1 < max(block_right, sb.x1) - 0.35 * width
            short_vs_ref = ref_width > 0 and lb.width < 0.6 * ref_width
            if (short_vs_block or short_vs_ref) and (first.isupper() or first.isdigit()):
                continue
            best = p
            break
        if best is None:
            protos.append(_Proto([seg]))
        else:
            best.lines.append(seg)
    return protos


def _mixed_bold(line: Line) -> bool:
    flags = {t.char.bold for t in line.tokens if not t.char.text.isspace()}
    return len(flags) > 1


def last_bold(line: Line) -> bool:
    toks = line.tokens
    return bool(toks) and sum(1 for t in toks if t.char.bold) > len(toks) / 2


def order_atoms(atoms: list, y_gap: float = 2.0, x_gap: float = 6.0) -> list:
    """Recursive XY-cut over objects exposing ``lbox``: one cut per level at the
    strongest whitespace. A column gutter wins over a horizontal gap unless the
    horizontal gap is clearly larger (forms read row by row; two-column text
    reads column by column)."""
    if len(atoms) <= 1:
        return list(atoms)
    yc = _best_cut(atoms, "y", y_gap)
    xc = _best_cut(atoms, "x", x_gap)
    if xc is not None and (yc is None or xc[0] >= 1.2 * yc[0]):
        a, b = xc[1], xc[2]
        return order_atoms(a, y_gap, x_gap) + order_atoms(b, y_gap, x_gap)
    if yc is not None:
        a, b = yc[1], yc[2]
        return order_atoms(a, y_gap, x_gap) + order_atoms(b, y_gap, x_gap)
    # no clean cut: a few atoms (a footer, a wide title) may straddle an otherwise
    # clear column gutter. Split around them and place the straddlers by height.
    split = _gutter_split(atoms, x_gap)
    if split is not None:
        left, right, crossers = split
        top_y = min(a.lbox.y0 for a in left + right)
        bottom_y = max(a.lbox.y1 for a in left + right)
        before = [a for a in crossers if a.lbox.cy <= top_y + 1]
        after = [a for a in crossers if a.lbox.cy >= bottom_y - 1]
        middle = [a for a in crossers if a not in before and a not in after]
        return (sorted(before, key=lambda a: a.lbox.y0) + order_atoms(left, y_gap, x_gap)
                + sorted(middle, key=lambda a: a.lbox.y0) + order_atoms(right, y_gap, x_gap)
                + sorted(after, key=lambda a: a.lbox.y0))
    # same band, no clean column gap: read row by row (centers bucketed by ~4pt), then left to right
    return sorted(atoms, key=lambda a: (round(a.lbox.cy / 4), a.lbox.x0))


def _best_cut(atoms: list, axis: str, min_gap: float):
    """Largest whitespace gap across all atoms along an axis: (gap, before, after)."""
    if axis == "y":
        key0, key1 = (lambda a: a.lbox.y0), (lambda a: a.lbox.y1)
    else:
        key0, key1 = (lambda a: a.lbox.x0), (lambda a: a.lbox.x1)
    ordered = sorted(atoms, key=key0)
    reach = key1(ordered[0])
    best = None
    for i in range(1, len(ordered)):
        gap = key0(ordered[i]) - reach
        if gap >= min_gap and (best is None or gap > best[0]):
            best = (gap, i)
        reach = max(reach, key1(ordered[i]))
    if best is None:
        return None
    gap, i = best
    return gap, ordered[:i], ordered[i:]


def _split_by_gaps(atoms: list, axis: str, min_gap: float) -> tuple[list[list], float]:
    """All gaps along an axis (kept for callers that need bands)."""
    if axis == "y":
        key0, key1 = (lambda a: a.lbox.y0), (lambda a: a.lbox.y1)
    else:
        key0, key1 = (lambda a: a.lbox.x0), (lambda a: a.lbox.x1)
    ordered = sorted(atoms, key=key0)
    groups: list[list] = [[ordered[0]]]
    reach = key1(ordered[0])
    best = 0.0
    for a in ordered[1:]:
        gap = key0(a) - reach
        if gap >= min_gap:
            groups.append([a])
            best = max(best, gap)
        else:
            groups[-1].append(a)
        reach = max(reach, key1(a))
    return groups, best


def _gutter_split(atoms: list, min_gap: float):
    """Find a vertical gutter crossed by at most a few atoms. Returns
    (left, right, crossers) or None."""
    n = len(atoms)
    if n < 4:
        return None
    max_cross = max(1, int(0.15 * n))
    edges = sorted({round(a.lbox.x1) for a in atoms} | {round(a.lbox.x0) for a in atoms})
    best = None
    for g0 in edges:
        g1 = g0 + min_gap
        left = [a for a in atoms if a.lbox.x1 <= g0 + 0.5]
        right = [a for a in atoms if a.lbox.x0 >= g1 - 0.5]
        crossers = [a for a in atoms if a not in left and a not in right]
        if len(left) < 2 or len(right) < 2 or len(crossers) > max_cross:
            continue
        # crossers must be small relative to the columns (not the body text itself)
        if any(a.lbox.height > 0.3 * (max(x.lbox.y1 for x in left + right) - min(x.lbox.y0 for x in left + right)) for a in crossers):
            continue
        score = (min(len(left), len(right)), -len(crossers))
        if best is None or score > best[0]:
            best = (score, left, right, crossers)
    if best is None:
        return None
    return best[1], best[2], best[3]


def _classify(page: PageExtract, p: _Proto, body_size: float) -> Block:
    tokens: list[Token] = []
    for i, ln in enumerate(p.lines):
        for j, t in enumerate(ln.tokens):
            tokens.append(Token(t.char, (t.space_before if j > 0 else i > 0)))
    text = "".join((" " if t.space_before else "") + t.char.text for t in tokens)
    kind = "paragraph"
    marker = None
    m = _BULLET_RE.match(text) or _ENUM_RE.match(text)
    if m:
        kind = "list_item"
        marker = m.group(1)
        # drop exactly the marker's glyphs, then the separating space
        taken = ""
        marker_tokens: list[Token] = []
        while tokens and taken != marker:
            marker_tokens.append(tokens.pop(0))
            taken += marker_tokens[-1].char.text
        if tokens:
            tokens[0] = Token(tokens[0].char, False)
        text = text[len(m.group(0)):]
    elif (len(p.lines) <= 2 and len(text) <= 120 and any(ch.isalpha() for ch in text)
          and (p.size >= 1.15 * body_size or (p.bold and p.size >= body_size - 0.5))
          and p.lbox.y0 < 0.93 * page.layout_height):  # bottom-of-page lines are footers, not headings
        kind = "heading"
    runs = _runs(tokens)
    lbox = p.lbox
    bbox = p.lines[0].bbox
    for ln in p.lines[1:]:
        bbox = bbox.union(ln.bbox)
    blk = Block(page.index, kind, text, runs, lbox, bbox, len(p.lines), None, marker, p.size, tokens)
    if marker and tokens:
        blk.marker_tokens = marker_tokens
        blk.marker_next = tokens[0]
    return blk


def _runs(tokens: list[Token]) -> list[Run]:
    runs: list[Run] = []
    for t in tokens:
        piece = (" " if t.space_before else "") + t.char.text
        if runs and runs[-1].bold == t.char.bold and runs[-1].italic == t.char.italic:
            runs[-1].text += piece
        else:
            runs.append(Run(piece, t.char.bold, t.char.italic))
    return runs


def _assign_heading_levels(blocks: list[Block]) -> None:
    sizes = sorted({round(b.size, 1) for b in blocks if b.kind == "heading"}, reverse=True)
    for b in blocks:
        if b.kind == "heading":
            b.level = min(sizes.index(round(b.size, 1)) + 1, 3)


def _attach_links(page: PageExtract, blocks: list[Block]) -> None:
    """Split runs so hyperlink text carries its target. Uses char geometry."""
    if not page.links:
        return
    # Re-derive per-char link membership by re-walking tokens is expensive; instead,
    # rebuild runs from chars for blocks that intersect a link box.
    for b in blocks:
        hits = [l for l in page.links if l.lbox.intersects(b.lbox)]
        if not hits:
            continue
        new_runs: list[Run] = []
        pos = 0
        # We need char-level geometry: rebuild from the block's lines is not stored,
        # so approximate by locating each link's text through chars within its lbox.
        chars_in_block = [c for c in page.chars if b.lbox.contains_point(c.lbox.cx, c.lbox.cy)
                          and not c.generated and not c.text.isspace()]
        for link in hits:
            linked = [c for c in chars_in_block if link.lbox.contains_point(c.lbox.cx, c.lbox.cy)]
            if not linked:
                continue
            ltext = "".join(c.text for c in linked)
            # find ltext inside block text ignoring spaces
            idx = _find_ignoring_spaces(b.text, ltext, pos)
            if idx is None:
                continue
            start, end = idx
            new_runs.extend(_slice_runs(b.runs, pos, start))
            seg = _slice_runs(b.runs, start, end)
            for r in seg:
                r.uri = link.uri
                r.dest_page = link.dest_page
            new_runs.extend(seg)
            pos = end
        new_runs.extend(_slice_runs(b.runs, pos, len(b.text)))
        if new_runs:
            b.runs = [r for r in new_runs if r.text]


def _find_ignoring_spaces(text: str, needle: str, start: int) -> tuple[int, int] | None:
    compact = []
    for i, ch in enumerate(text):
        if not ch.isspace():
            compact.append((ch, i))
    cstr = "".join(ch for ch, _ in compact)
    cneedle = "".join(ch for ch in needle if not ch.isspace())
    # map start to compact index
    cstart = sum(1 for ch, i in compact if i < start)
    j = cstr.find(cneedle, cstart)
    if j < 0 or not cneedle:
        return None
    return compact[j][1], compact[j + len(cneedle) - 1][1] + 1


def _slice_runs(runs: list[Run], start: int, end: int) -> list[Run]:
    out: list[Run] = []
    pos = 0
    for r in runs:
        r_start, r_end = pos, pos + len(r.text)
        pos = r_end
        s, e = max(start, r_start), min(end, r_end)
        if s < e:
            out.append(Run(r.text[s - r_start:e - r_start], r.bold, r.italic, r.uri, r.dest_page))
    return out


def cell_blocks_text(lines: list[Line]) -> str:
    """Text for a table cell: lines joined by newlines unless the cell holds
    several text columns, in which case blocks are grouped and XY-cut ordered."""
    segments = split_lines_with_neighbors(lines)
    multi = len(segments) > len(lines)
    if not multi:
        return "\n".join(ln.text for ln in lines)
    protos = order_atoms(_group_blocks(segments, _column_width(segments)))
    return "\n".join(" ".join(ln.text for ln in p.lines) for p in protos)
