"""Unruled table bodies under a ruled header (data tables).

Statistical tables often rule only their header box: the body is rows of
values aligned in columns, with row labels (and dot leaders) left of the
grid, section headings centred between groups of rows, and footnotes below
(EIA Weekly Petroleum Status Report table 1, Census P60 Table A-4b). The ruled
detector finds the header alone and the body comes through as text lines.

This stage reads the body below such a header as a stream table: the body's
own whitespace defines the columns, the ruled header cells are mapped onto
them by position, header text outside the ruled box (the row-label header) is
added, and the result replaces the header-only table. It runs only when a
format asks for data tables (XLSX); the layout-preserving DOCX keeps the
verified behaviour. Nothing is invented: a row is a line of the page, a cell
is a run of its glyphs; dot leaders are dropped and footnote marks are kept as
superscript characters so "2017" with mark 1 never reads as 20171.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass, field

from .geometry import BBox
from .tables import Cell, Table
from .textlines import build_lines

_SUPERSCRIPT = str.maketrans("0123456789,*+-()abcdefghijklmnoprstuvwxyz",
                             "⁰¹²³⁴⁵⁶⁷⁸⁹,*⁺⁻⁽⁾"
                             "ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ")


_NUMERIC = set("0123456789.,-%$\u2212")


@dataclass
class _Seg:
    text: str
    x0: float
    x1: float
    y0: float
    y1: float
    chars: list = field(default_factory=list)


def _segments(line) -> list[_Seg]:
    """A line's glyph runs separated by column-sized gaps. Dot leaders (three
    or more periods) end a run and are dropped; small raised glyphs are
    footnote marks and stay with the run they follow."""
    chars = [c for c in line.chars if not c.generated and not c.text.isspace()]
    if not chars:
        return []
    spaced = {id(t.char) for t in getattr(line, "tokens", []) if t.space_before}   # the line's own word breaks
    sizes = sorted(c.font_size for c in chars)
    size = sizes[len(sizes) // 2]
    mid = statistics.median((c.lbox.y0 + c.lbox.y1) / 2 for c in chars)
    base = statistics.median(c.lbox.y1 for c in chars)          # the line's baseline (glyph bottoms)
    segs: list[_Seg] = []
    cur: list = []

    def close():
        if cur:
            text = ""
            prev = None
            for c in cur:
                # a footnote mark: small and raised, or set at full size but lifted off the baseline
                mark = ((c.font_size < 0.8 * size and (c.lbox.y0 + c.lbox.y1) / 2 < mid - 0.1 * size)
                        or (c.text.isdigit() and prev is not None and base - c.lbox.y1 > 0.2 * size))
                piece = c.text.translate(_SUPERSCRIPT) if mark else c.text
                numeric = prev is not None and prev.text in _NUMERIC and c.text in _NUMERIC
                if prev is not None and not mark and not numeric and (id(c) in spaced or c.lbox.x0 - prev.lbox.x1 > 0.3 * size):
                    text += " "
                text += piece
                prev = c
            segs.append(_Seg(text, min(c.lbox.x0 for c in cur), max(c.lbox.x1 for c in cur),
                             min(c.lbox.y0 for c in cur), max(c.lbox.y1 for c in cur), list(cur)))
            cur.clear()

    i = 0
    prev = None
    while i < len(chars):
        c = chars[i]
        if c.text in ".…":
            j = i
            while j < len(chars) and chars[j].text in ".…" and (j == i or chars[j].lbox.x0 - chars[j - 1].lbox.x1 < 0.6 * size):
                j += 1
            if j - i >= 3:                      # a dot leader: presentation, not content
                close(); prev = None; i = j
                continue
        if prev is not None and c.lbox.x0 - prev.lbox.x1 > max(0.6 * size, 3.0):
            close()
        cur.append(c); prev = c; i += 1
    close()
    return segs


def _columns(rows: list[list[_Seg]]) -> list[list[float]]:
    """Column intervals from the body's own alignment: segment extents of the
    multi-cell rows, merged where they overlap."""
    spans = sorted([s.x0, s.x1] for r in rows if len(r) >= 2 for s in r)
    cols: list[list[float]] = []
    for x0, x1 in spans:
        if cols and x0 <= cols[-1][1] + 0.5:
            cols[-1][1] = max(cols[-1][1], x1)
        else:
            cols.append([x0, x1])
    return cols


def _col_of(cols, x0: float, x1: float) -> int:
    best, best_ov = None, 0.0
    for k, (a, b) in enumerate(cols):
        ov = min(b, x1) - max(a, x0)
        if ov > best_ov:
            best, best_ov = k, ov
    if best is not None:
        return best
    cx = (x0 + x1) / 2
    return min(range(len(cols)), key=lambda k: min(abs(cols[k][0] - cx), abs(cols[k][1] - cx)))


def _cols_covered(cols, x0: float, x1: float) -> tuple[int, int]:
    inside = [k for k, (a, b) in enumerate(cols) if x0 - 2 <= (a + b) / 2 <= x1 + 2]
    if not inside:
        k = _col_of(cols, x0, x1)
        return k, k
    return inside[0], inside[-1]


def _body_rows(page, t: Table, stop_y: float):
    """Candidate body lines below the header, top to bottom, and where they end."""
    chars = [c for c in page.chars if not c.generated and not c.text.isspace()
             and t.lbox.y1 - 0.5 <= (c.lbox.y0 + c.lbox.y1) / 2 < stop_y]
    lines = build_lines(chars)
    width = t.lbox.width
    rows: list[list[_Seg]] = []
    last_y = None
    pitches: list[float] = []
    for ln in lines:
        segs = _segments(ln)
        if not segs:
            continue
        y = min(s.y0 for s in segs)
        if max(s.x1 - s.x0 for s in segs) > 0.45 * width:
            break                                # a running sentence: footnotes or text below the table
        if segs[-1].x1 < t.lbox.x0 - 2 and len(rows) == 0:
            continue                             # label-only lines above the first row
        if last_y is not None:
            gap = y - last_y
            pitch = statistics.median(pitches) if pitches else gap
            if pitches and gap > 3.5 * pitch:
                break                            # the table has ended
            pitches.append(gap)
        rows.append(segs)
        last_y = y
    # trailing single-cell rows (a note, a page footer) are not part of the table
    while rows and len(rows[-1]) == 1:
        rows.pop()
    return rows


def extend_table_bodies(page, tables: list[Table]) -> tuple[list[Table], list[dict]]:
    """Replace header-only ruled tables by header + stream body where a body
    of aligned rows follows. Returns the tables and the warnings."""
    if page.rotation % 360:
        return tables, []
    out: list[Table] = []
    warnings: list[dict] = []
    ordered = sorted(tables, key=lambda t: t.lbox.y0)
    for k, t in enumerate(ordered):
        body_rows = t.n_rows - len(t.header_rows)
        if body_rows > 2:
            out.append(t)
            continue
        stop_y = ordered[k + 1].lbox.y0 - 0.5 if k + 1 < len(ordered) else page.layout_height
        rows = _body_rows(page, t, stop_y)
        multi = [r for r in rows if len(r) >= 3]
        if len(multi) < 3:
            out.append(t)
            continue
        ext = _build(page, t, rows)
        if ext is None:
            out.append(t)
            continue
        out.append(ext)
        warnings.append({"code": "TABLE_BODY_RECOVERED", "page": page.index, "object_id": t.table_id,
                         "rows": ext.n_rows - len(ext.header_rows), "cols": ext.n_cols,
                         "detail": "an unruled body under a ruled header was read by its column alignment"})
    return out, warnings


def _rule_runs(boxes: list[BBox]) -> list[BBox]:
    """Collinear horizontal rule segments that touch, merged into one rule
    (tables often draw one segment per cell: Census A-4b)."""
    out: list[BBox] = []
    for b in sorted(boxes, key=lambda b: (round((b.y0 + b.y1) / 2), b.x0)):
        last = out[-1] if out else None
        if last is not None and abs((last.y0 + last.y1) / 2 - (b.y0 + b.y1) / 2) <= 0.8 and b.x0 <= last.x1 + 1.5:
            out[-1] = last.union(b)
        else:
            out.append(b)
    return out


def _header_extents(page, t: Table, used: set[int]) -> dict[int, tuple[BBox, str]]:
    """A header cell at the edge of the ruled box whose underline runs on past
    that edge: the box ended early (the next column has no vertical rule), and
    the group the underline marks covers the columns beyond it. EIA table 1:
    'Year Ago' is underlined from 395 to 585 but the box ends at 522, leaving
    'Percent Change' without its group. The cell takes the underline's extent
    and its text is re-read from the glyphs inside (text the box clipped,
    'Cumulative Daily Av…', is whole again)."""
    out: dict[int, tuple[BBox, str]] = {}
    rules = _rule_runs([r.lbox for r in page.rules if r.orientation == "h"])
    for c in t.cells:
        if c.colspan < 2:
            continue           # only a group header's underline marks the columns it heads
        b = c.lbox
        for rb in rules:
            if abs(rb.y0 - b.y1) > 1.5 and abs(rb.y1 - b.y1) > 1.5:
                continue
            x0, x1 = b.x0, b.x1
            covers = rb.x0 <= b.x0 + 2 and rb.x1 >= b.x1 - 2      # the rule underlines this cell
            if covers and abs(b.x1 - t.lbox.x1) <= 2 and rb.x1 > t.lbox.x1 + 3:
                x1 = rb.x1
            elif covers and abs(b.x0 - t.lbox.x0) <= 2 and rb.x0 < t.lbox.x0 - 3:
                x0 = rb.x0
            else:
                continue
            ext = BBox(x0, b.y0, x1, b.y1)
            chars = [ch for ch in page.chars if not ch.generated and not ch.text.isspace()
                     and ext.contains_point((ch.lbox.x0 + ch.lbox.x1) / 2, (ch.lbox.y0 + ch.lbox.y1) / 2)]
            text = "\n".join(" ".join(s.text for s in _segments(ln)) for ln in build_lines(chars)).strip()
            text = "\n".join(" ".join(part.split()) for part in text.split("\n"))
            if text:
                out[id(c)] = (ext, text)
                used.update(id(ch) for ch in chars)
            break
    return out


def _build(page, t: Table, rows: list[list[_Seg]]) -> Table | None:
    cols = _columns(rows)
    if len(cols) < 2:
        return None
    n_cols = len(cols)
    grid: dict[tuple[int, int], dict] = {}

    def put(r, c, text, box, rowspan=1, colspan=1, bold=False, chars=()):
        key = (r, c)
        if key in grid:
            grid[key]["text"] = (grid[key]["text"] + " " + text).strip()
            grid[key]["box"] = grid[key]["box"].union(box)
            return
        grid[key] = {"text": text, "box": box, "rowspan": rowspan, "colspan": colspan, "bold": bold,
                     "chars": list(chars)}

    # header: the ruled cells mapped onto the body's columns, then header text
    # outside the ruled box (the row-label column's header)
    h = t.n_rows      # the ruled box is the header (its body, if any, is at most two rows of sub-headings)
    covered: set[tuple[int, int]] = set()
    used_chars: set[int] = set()
    extents = _header_extents(page, t, used_chars)
    for c in sorted(t.cells, key=lambda c: (c.row, c.col)):
        if c.row >= h or not c.raw_text.strip():
            continue
        box, text = extents.get(id(c), (c.lbox, c.raw_text))
        if box is not c.lbox:
            c = Cell(c.row, c.col, c.rowspan, c.colspan, text, box, box, c.bold, c.chars)
        a, b = _cols_covered(cols, c.lbox.x0, c.lbox.x1)
        if any((rr, cc) in covered for rr in range(c.row, c.row + c.rowspan) for cc in range(a, b + 1)):
            a = b = _col_of(cols, c.lbox.x0, c.lbox.x1)
        put(c.row, a, c.raw_text, c.lbox, c.rowspan, b - a + 1, True, c.chars)
        covered.update((rr, cc) for rr in range(c.row, c.row + c.rowspan) for cc in range(a, b + 1))
    band = [ch for ch in page.chars if not ch.generated and not ch.text.isspace() and id(ch) not in used_chars
            and t.lbox.y0 - 1 <= (ch.lbox.y0 + ch.lbox.y1) / 2 <= t.lbox.y1 + 1
            and not t.lbox.contains_point((ch.lbox.x0 + ch.lbox.x1) / 2, (ch.lbox.y0 + ch.lbox.y1) / 2)
            and cols[0][0] - 2 <= (ch.lbox.x0 + ch.lbox.x1) / 2 <= cols[-1][1] + 2]
    outside: dict[int, list] = {}
    for ln in build_lines(band):
        for s in _segments(ln):
            outside.setdefault(_col_of(cols, s.x0, s.x1), []).append(s)
    for c, segs in sorted(outside.items()):
        free = [r for r in range(h) if not any((r, cc) in covered for cc in [c])]
        if not free:
            continue
        text = " ".join(s.text for s in sorted(segs, key=lambda s: (s.y0, s.x0)))
        box = segs[0].__dict__ and BBox(min(s.x0 for s in segs), min(s.y0 for s in segs),
                                        max(s.x1 for s in segs), max(s.y1 for s in segs))
        top = free[0]; span = 1
        while top + span < h and (top + span) in free:
            span += 1
        put(top, c, text, box, span, 1, True)
        covered.update((rr, c) for rr in range(top, top + span))
    # body rows
    r = h
    pending_label: dict[int, str] = {}
    label_cols = {k for k, (a, b) in enumerate(cols) if b <= t.lbox.x0 + 2}
    for segs in rows:
        placed = [(_col_of(cols, s.x0, s.x1), s) for s in segs]
        if len(segs) == 1 and placed[0][0] not in label_cols:
            s = segs[0]
            put(r, 0, s.text, BBox(s.x0, s.y0, s.x1, s.y1), 1, n_cols, True, s.chars)   # section heading
            r += 1
            continue
        if label_cols and all(k in label_cols for k, _s in placed):
            for k, s in placed:                   # a label that wraps onto the next line
                pending_label[k] = (pending_label.get(k, "") + " " + s.text).strip()
            continue
        for k, s in placed:
            text = s.text
            if k in pending_label:
                text = pending_label.pop(k) + " " + text
            put(r, k, text, BBox(s.x0, s.y0, s.x1, s.y1), chars=s.chars)
        for k, text in list(pending_label.items()):
            put(r, k, text, BBox(cols[k][0], segs[0].y0, cols[k][1], segs[0].y1))
            pending_label.pop(k)
        r += 1
    n_rows = r
    cells = [Cell(rr, cc, v["rowspan"], v["colspan"], v["text"], v["box"], v["box"], v["bold"], v["chars"])
             for (rr, cc), v in sorted(grid.items())]
    box = t.lbox
    for c in cells:
        box = box.union(c.lbox)
    return Table(t.table_id, t.page, n_rows, n_cols, cells, box, box, list(range(h)), "ruled_header_stream_body",
                 list(t.warnings), [], list(t.rules), list(t.fills))
