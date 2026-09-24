"""Shared char -> line assembly in upright layout space.

PDFium's generated whitespace is used only as a word-separator hint; line
membership and order come from geometry.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from statistics import median

from .extract import Char
from .geometry import BBox


@dataclass
class Token:
    char: Char
    space_before: bool


@dataclass
class Line:
    tokens: list[Token] = field(default_factory=list)

    @property
    def chars(self) -> list[Char]:
        return [t.char for t in self.tokens]

    @property
    def lbox(self) -> BBox:
        b = self.tokens[0].char.lbox
        for t in self.tokens[1:]:
            b = b.union(t.char.lbox)
        return b

    @property
    def bbox(self) -> BBox:
        b = self.tokens[0].char.bbox
        for t in self.tokens[1:]:
            b = b.union(t.char.bbox)
        return b

    @property
    def size(self) -> float:
        return median(t.char.font_size for t in self.tokens)

    @property
    def cy(self) -> float:
        return self.lbox.cy

    @property
    def text(self) -> str:
        out = []
        for i, t in enumerate(self.tokens):
            if t.space_before and i > 0:
                out.append(" ")
            out.append(t.char.text)
        return "".join(out)


def _real_chars(chars: list[Char]) -> list[tuple[Char, bool]]:
    """Drop generated/zero-area chars, remembering whitespace as a separator
    hint: 2 for a real space glyph (always a word break), 1 for a space PDFium
    generated or a zero-area glyph (a break only where the gap allows one)."""
    out: list[tuple[Char, int]] = []
    pending = 0
    for c in chars:
        if c.generated or c.text.isspace() or c.loose.width <= 0 or c.loose.height <= 0:
            pending = max(pending, 1 if (c.generated or not c.text.isspace()) else 2)
            continue
        out.append((c, pending))
        pending = 0
    return out


def build_lines(chars: list[Char], overlap: float = 0.5) -> list[Line]:
    """Group chars into horizontal lines by vertical overlap, then order by x.

    Returns lines sorted top-to-bottom. Chars in the same line are sorted by x;
    a space is inserted where PDFium hinted one or where the gap exceeds a
    quarter of the font size.
    """
    items = _real_chars(chars)
    if not items:
        return []
    items.sort(key=lambda it: (it[0].loose.cy, it[0].loose.x0))
    groups: list[list[tuple[Char, bool]]] = []
    boxes: list[BBox] = []
    sizes: list[list[float]] = []
    cys: list[list[float]] = []
    hs: list[list[float]] = []

    def med(v: list[float]) -> float:
        return sorted(v)[len(v) // 2]

    for c, sp in items:
        cb = c.loose
        # try recent lines first; lines are created in cy order. A line with
        # glyphs horizontally near that accepts the glyph wins over a line that
        # accepts it only by its box: body text in another column at nearly the
        # same height must not take the small caps of a callout beside it.
        by_box = None
        target = None
        for gi in range(len(groups) - 1, max(-1, len(groups) - 6), -1):
            gb = boxes[gi]
            ov = min(cb.y1, gb.y1) - max(cb.y0, gb.y0)
            # same line: substantial vertical overlap AND centers close (tight
            # leading makes adjacent lines' font boxes overlap) AND a compatible
            # font size (an oversized icon glyph beside body text is not part of it).
            # The line's centre and height are its glyphs' (median), not its
            # union box's: text in another column on the same row stretches the
            # box and would push small caps beside larger initials off their line.
            ref = med(sizes[gi])
            if ref > 0 and c.font_size > 0 and not (0.55 <= c.font_size / ref <= 1.8):
                continue
            # glyphs of this line horizontally near the candidate decide its centre
            # (small caps beside larger initials); with none near, the line's box does
            reach = 3.0 * max(c.font_size, 1.0)
            near = [k for k, (g, _s) in enumerate(groups[gi])
                    if g.loose.x0 - reach <= cb.x1 and cb.x0 <= g.loose.x1 + reach]
            if near:
                gh = med([hs[gi][k] for k in near]); gcy = med([cys[gi][k] for k in near])
            else:
                gh = gb.height; gcy = gb.cy
            if (ov > 0 and ov >= overlap * min(cb.height, gh)
                    and abs(cb.cy - gcy) <= 0.4 * min(cb.height, gh)):
                if near:
                    target = gi
                    break
                if by_box is None:
                    by_box = gi
        if target is None:
            target = by_box
        if target is not None:
            groups[target].append((c, sp))
            boxes[target] = boxes[target].union(cb)
            sizes[target].append(c.font_size)
            cys[target].append(cb.cy)
            hs[target].append(cb.height)
        else:
            groups.append([(c, sp)])
            boxes.append(cb)
            sizes.append([c.font_size])
            cys.append([cb.cy])
            hs.append([cb.height])
    lines: list[Line] = []
    for g in groups:
        g.sort(key=lambda it: it[0].loose.x0)
        line = Line()
        prev: Char | None = None
        for c, hinted in g:
            space = False
            if prev is not None:
                gap = c.loose.x0 - prev.loose.x1
                size = max(prev.font_size, c.font_size, 1.0)
                # PDFium's space hint is trusted only where a word space could be:
                # letter-spaced display type has 0.1 em gaps between glyphs
                if gap > 0.2 * size or hinted == 2 or (hinted == 1 and gap > 0.14 * size):
                    space = True
            line.tokens.append(Token(c, space))
            prev = c
        lines.append(line)
    lines.sort(key=lambda ln: (ln.lbox.cy, ln.lbox.x0))
    return lines


def _gaps(line: Line, minimum: float) -> list[tuple[float, float]]:
    out = []
    prev: Char | None = None
    for t in line.tokens:
        if prev is not None:
            g0, g1 = prev.loose.x1, t.char.loose.x0
            if g1 - g0 >= minimum:
                out.append((g0, g1))
        prev = t.char
    return out


def split_line_at_gaps(line: Line, factor: float = 2.0, minimum: float = 8.0,
                       neighbors: list[Line] | None = None) -> list[Line]:
    """Split a line into segments at column gaps.

    A gap wider than ``factor`` × font size always splits. A moderate gap
    (≥ 1.2 × font size) splits only when the neighboring lines (above/below)
    also leave that x-interval empty, which distinguishes a column gutter from
    a wide word space in justified text.
    """
    neighbor_gaps = [_gaps(n, 3.0) for n in (neighbors or [])]

    def confirmed(g0: float, g1: float) -> bool:
        cx = (g0 + g1) / 2
        support = 0
        for ng in neighbor_gaps:
            if any(a <= cx <= b for a, b in ng):
                support += 1
        return support >= 2

    segs: list[Line] = []
    cur = Line()
    prev: Char | None = None
    for t in line.tokens:
        if prev is not None:
            gap = t.char.loose.x0 - prev.loose.x1
            size = max(prev.font_size, t.char.font_size)
            hard = gap > max(factor * size, minimum)
            soft = gap >= 1.2 * size and gap >= 5.0 and confirmed(prev.loose.x1, t.char.loose.x0)
            if hard or soft:
                segs.append(cur)
                cur = Line()
                t = Token(t.char, False)
        cur.tokens.append(t)
        prev = t.char
    if cur.tokens:
        segs.append(cur)
    return segs


def split_lines_with_neighbors(lines: list[Line], window: int = 3) -> list[Line]:
    """Split every line at column gaps, using nearby lines as evidence."""
    out: list[Line] = []
    for i, ln in enumerate(lines):
        nb = [lines[j] for j in range(max(0, i - window), min(len(lines), i + window + 1)) if j != i
              and abs(lines[j].cy - ln.cy) < 4 * max(ln.size, 1.0)]
        out.extend(split_line_at_gaps(ln, neighbors=nb))
    return out


def lines_text(lines: list[Line]) -> str:
    return "\n".join(ln.text for ln in lines)
