"""Ruled-table reconstruction from line geometry and token placement.

Grid lines come from connected components of thin path objects. Cells that
lack an internal separator are merged (rectangular spans only). Grid rows whose
cells all contain the same number of aligned text lines are split into
sub-rows, which handles tables that rule only every few body rows.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .extract import Char, PageExtract, Rule
from .geometry import BBox
from .textlines import Line, build_lines, split_line_at_gaps

TOL = 2.0


@dataclass
class Cell:
    row: int
    col: int
    rowspan: int
    colspan: int
    raw_text: str
    lbox: BBox
    bbox: BBox
    bold: bool = False
    chars: list[Char] = field(default_factory=list, repr=False)
    values: list[dict] = field(default_factory=list, repr=False)  # field values placed in this cell (layout mode)


@dataclass
class Table:
    table_id: str
    page: int
    n_rows: int
    n_cols: int
    cells: list[Cell]
    lbox: BBox
    bbox: BBox
    header_rows: list[int]
    header_inference: str
    warnings: list[dict] = field(default_factory=list)
    row_inference: list[dict] = field(default_factory=list)  # grid rows split into aligned sub-rows
    rules: list[Rule] = field(default_factory=list, repr=False)   # the grid's own rules (borders)
    fills: list = field(default_factory=list, repr=False)          # filled rectangles inside the grid (shading)


class _UF:
    def __init__(self, n: int) -> None:
        self.p = list(range(n))

    def find(self, a: int) -> int:
        while self.p[a] != a:
            self.p[a] = self.p[self.p[a]]
            a = self.p[a]
        return a

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[rb] = ra


def _cluster(values: list[float], tol: float) -> list[float]:
    values = sorted(values)
    out: list[list[float]] = []
    for v in values:
        if out and v - out[-1][-1] <= tol:
            out[-1].append(v)
        else:
            out.append([v])
    return [sum(g) / len(g) for g in out]


def _merge_close(values: list[float], min_gap: float) -> list[float]:
    out: list[list[float]] = []
    for v in values:
        if out and v - out[-1][-1] < min_gap:
            out[-1].append(v)
        else:
            out.append([v])
    return [sum(g) / len(g) for g in out]


def _components(rules: list[Rule]) -> list[list[Rule]]:
    h = [r for r in rules if r.orientation == "h"]
    v = [r for r in rules if r.orientation == "v"]
    allr = h + v
    uf = _UF(len(allr))
    nh = len(h)
    for i, hr in enumerate(h):
        hy = hr.lbox.cy
        for j, vr in enumerate(v):
            vx = vr.lbox.cx
            if (hr.lbox.x0 - TOL <= vx <= hr.lbox.x1 + TOL
                    and vr.lbox.y0 - TOL <= hy <= vr.lbox.y1 + TOL):
                uf.union(i, nh + j)
    # collinear touching segments of the same orientation also connect
    for group, offset, axis in ((h, 0, "h"), (v, nh, "v")):
        for i in range(len(group)):
            for j in range(i + 1, len(group)):
                a, b = group[i].lbox, group[j].lbox
                if axis == "h":
                    if abs(a.cy - b.cy) <= TOL and (a.x0 - TOL <= b.x1 and b.x0 - TOL <= a.x1):
                        uf.union(offset + i, offset + j)
                else:
                    if abs(a.cx - b.cx) <= TOL and (a.y0 - TOL <= b.y1 and b.y0 - TOL <= a.y1):
                        uf.union(offset + i, offset + j)
    comps: dict[int, list[Rule]] = {}
    for i, r in enumerate(allr):
        comps.setdefault(uf.find(i), []).append(r)
    return list(comps.values())


def _structural(h: list[Rule], v: list[Rule]) -> tuple[list[Rule], list[Rule]]:
    """Keep rules that define the grid: long ones, or ones whose end meets a
    perpendicular rule. Ticks and underlines that merely cross or float near a
    border (no endpoint on the grid) are decoration, not cell boundaries."""
    x_ext = (min(r.lbox.x0 for r in h + v), max(r.lbox.x1 for r in h + v))
    y_ext = (min(r.lbox.y0 for r in h + v), max(r.lbox.y1 for r in h + v))
    tol = 2 * TOL

    def touches_v(x: float, y: float) -> bool:
        return any(abs(r.lbox.cx - x) <= tol and r.lbox.y0 - tol <= y <= r.lbox.y1 + tol for r in v)

    def touches_h(x: float, y: float) -> bool:
        return any(abs(r.lbox.cy - y) <= tol and r.lbox.x0 - tol <= x <= r.lbox.x1 + tol for r in h)

    # collinear touching segments form one line; judge the chain, keep its parts
    h2: list[Rule] = []
    for chain in _chains(h, "h"):
        x0 = min(r.lbox.x0 for r in chain); x1 = max(r.lbox.x1 for r in chain)
        cy = sum(r.lbox.cy for r in chain) / len(chain)
        if x1 - x0 >= 0.5 * (x_ext[1] - x_ext[0]) or touches_v(x0, cy) or touches_v(x1, cy):
            h2.extend(chain)
    v2: list[Rule] = []
    for chain in _chains(v, "v"):
        y0 = min(r.lbox.y0 for r in chain); y1 = max(r.lbox.y1 for r in chain)
        cx = sum(r.lbox.cx for r in chain) / len(chain)
        if y1 - y0 >= 0.5 * (y_ext[1] - y_ext[0]) or touches_h(cx, y0) or touches_h(cx, y1):
            v2.extend(chain)
    return h2, v2


def _chains(rules: list[Rule], axis: str) -> list[list[Rule]]:
    """Group collinear rules whose extents touch (within TOL) into chains."""
    if axis == "h":
        pos = lambda r: r.lbox.cy; lo = lambda r: r.lbox.x0; hi = lambda r: r.lbox.x1  # noqa: E731
    else:
        pos = lambda r: r.lbox.cx; lo = lambda r: r.lbox.y0; hi = lambda r: r.lbox.y1  # noqa: E731
    ordered = sorted(rules, key=lambda r: (round(pos(r) / TOL), lo(r)))
    chains: list[list[Rule]] = []
    for r in ordered:
        placed = False
        for ch in chains:
            if abs(pos(ch[-1]) - pos(r)) <= TOL and lo(r) <= max(hi(x) for x in ch) + TOL and hi(r) >= min(lo(x) for x in ch) - TOL:
                ch.append(r); placed = True; break
        if not placed:
            chains.append([r])
    return chains


def _has_v_separator(v: list[Rule], x: float, y0: float, y1: float) -> bool:
    need = 0.6 * (y1 - y0)
    for r in v:
        if abs(r.lbox.cx - x) <= TOL:
            cover = min(r.lbox.y1, y1) - max(r.lbox.y0, y0)
            if cover >= need:
                return True
    return False


def _fill_edge(fills, x: float, y0: float, y1: float) -> bool:
    """A shaded rectangle's side at x spanning this row separates cells."""
    for f in fills:
        b = f.lbox
        if (abs(b.x0 - x) <= 2 * TOL or abs(b.x1 - x) <= 2 * TOL) and b.y0 <= y0 + 2 * TOL and b.y1 >= y1 - 2 * TOL:
            return True
    return False


def _border_ends_at(h: list[Rule], x: float, y0: float, y1: float, span: float) -> bool:
    """The row's top or bottom border stops at x and does not resume right
    away: an unruled gap cell (the "AND" between two lists) begins or ends here.
    A line running the table's full width (the outer frame drawn over the cell
    segments) does not mask such an end."""
    tol = 2 * TOL
    for y in (y0, y1):
        on_row = [r for r in h if abs(r.lbox.cy - y) <= tol and r.lbox.width < 0.9 * span]
        ends = [r for r in on_row if abs(r.lbox.x0 - x) <= tol or abs(r.lbox.x1 - x) <= tol]
        if ends and not any(r.lbox.x0 < x - tol and r.lbox.x1 > x + tol for r in on_row):
            left = any(r.lbox.x1 >= x - tol and r.lbox.x0 < x - tol for r in on_row)
            right = any(r.lbox.x0 <= x + tol and r.lbox.x1 > x + tol for r in on_row)
            if left != right:
                return True
    return False


def _has_h_separator(h: list[Rule], y: float, x0: float, x1: float) -> bool:
    need = 0.6 * (x1 - x0)
    for r in h:
        if abs(r.lbox.cy - y) <= TOL:
            cover = min(r.lbox.x1, x1) - max(r.lbox.x0, x0)
            if cover >= need:
                return True
    return False


def _to_bbox(page: PageExtract, lbox: BBox) -> BBox:
    """Map a layout-space box back to normalized displayed space."""
    rot = page.rotation % 360
    W, H = page.width, page.height
    if rot == 0:
        return lbox
    if rot == 90:
        return BBox(W - lbox.y1, lbox.x0, W - lbox.y0, lbox.x1)
    if rot == 180:
        return BBox(W - lbox.x1, H - lbox.y1, W - lbox.x0, H - lbox.y0)
    return BBox(lbox.y0, H - lbox.x1, lbox.y1, H - lbox.x0)


def detect_tables(page: PageExtract) -> list[Table]:
    tables: list[Table] = []
    k = 0
    page_spaces = None
    order: dict[int, int] = {}
    real_chars = [c for c in page.chars if not c.generated and not c.text.isspace()
                  and c.lbox.width > 0 and c.lbox.height > 0]
    for comp in sorted(_components(page.rules), key=lambda c: (min(r.lbox.y0 for r in c), min(r.lbox.x0 for r in c))):
        h = [r for r in comp if r.orientation == "h"]
        v = [r for r in comp if r.orientation == "v"]
        if len(h) < 2 or len(v) < 2:
            continue
        h, v = _structural(h, v)
        if len(h) < 2 or len(v) < 2:
            continue
        # double-drawn box edges produce grid lines 2–3 pt apart: merge them
        ys = _merge_close(_cluster([r.lbox.cy for r in h], TOL), 3.0)
        xs = _merge_close(_cluster([r.lbox.cx for r in v], TOL), 3.0)
        if len(ys) < 2 or len(xs) < 2:
            continue
        if len(ys) - 1 < 2 or len(xs) - 1 < 2:
            continue  # a single boxed row/column is boxed text, not a table
        # soft column edges inside a real grid: a shaded cell's sides and the
        # ends of horizontal border segments mark cell boundaries drawn without
        # a vertical rule (header cells such as "OR"/"AND" between two lists)
        region0 = BBox(xs[0], ys[0], xs[-1], ys[-1])
        soft_fills = [f for f in getattr(page, "fills", []) if region0.intersects(f.lbox)
                      and f.lbox.width >= 4 and f.lbox.height >= 4 and not getattr(f, "white", False)]
        soft_x: list[float] = []
        for f in soft_fills:
            soft_x.extend((f.lbox.x0, f.lbox.x1))
        for r in h:
            soft_x.extend((r.lbox.x0, r.lbox.x1))
        soft_all = [x for x in _cluster(soft_x, TOL) if xs[0] + 3 < x < xs[-1] - 3]
        soft_x = [x for x in soft_all if all(abs(x - e) > 3 for e in xs)]
        xs = _merge_close(sorted(xs + soft_x), 3.0)
        n_rows, n_cols = len(ys) - 1, len(xs) - 1
        if n_rows < 2 or n_cols < 2:
            continue  # a single boxed row/column is boxed text, not a table
        region = BBox(xs[0], ys[0], xs[-1], ys[-1])
        warnings: list[dict] = []
        split_rows: list[dict] = []
        k += 1
        table_id = f"p{page.index}-table-{k}"

        in_region = [c for c in real_chars if region.contains_point(c.lbox.cx, c.lbox.cy)]

        # merge cells lacking separators, unless token placement respects the
        # grid boundary (partially ruled tables: header rules define columns)
        uf = _UF(n_rows * n_cols)
        idx = lambda r, c: r * n_cols + c  # noqa: E731
        for r in range(n_rows):
            row_chars = [ch for ch in in_region if ys[r] <= ch.lbox.cy < ys[r + 1]]
            row_lines = build_lines(row_chars)
            for c in range(n_cols):
                if c + 1 < n_cols and not _has_v_separator(v, xs[c + 1], ys[r], ys[r + 1]):
                    xb = xs[c + 1]
                    # strong evidence of a boundary drawn without a vertical rule:
                    # a shaded cell's side, or a border that genuinely ends here
                    hard = _fill_edge(soft_fills, xb, ys[r], ys[r + 1]) or \
                        _border_ends_at(h, xb, ys[r], ys[r + 1], xs[-1] - xs[0])
                    left = _present(row_chars, xs[c], xb)
                    right = _present(row_chars, xb, xs[c + 2])
                    if hard and (not left or not right):
                        merge = False   # a shaded or gap cell keeps its empty sliver out
                    elif hard:
                        # the end may belong to the row on the other side of this
                        # border: running text across it still is one cell
                        merge = _text_crosses_x(row_lines, xb, tight=True, factor=1.0)
                    elif not left or not right:
                        merge = True   # an empty side joins its neighbour
                    elif any(abs(xb - sx) <= TOL for sx in soft_all):
                        # a border-segment junction between two text clusters: one
                        # cell only if the text runs on across it (a glyph over the
                        # edge or the next glyph within a word space)
                        merge = _text_crosses_x(row_lines, xb, tight=True, factor=0.5)
                    else:
                        merge = _text_crosses_x(row_lines, xb)
                    if merge:
                        uf.union(idx(r, c), idx(r, c + 1))
                if r + 1 < n_rows and not _has_h_separator(h, ys[r + 1], xs[c], xs[c + 1]):
                    # a missing horizontal rule always merges: another column's
                    # internal boxes must not slice this cell. Aligned unruled
                    # rows are recovered by the sub-row split below.
                    uf.union(idx(r, c), idx(r + 1, c))
        groups: dict[int, list[tuple[int, int]]] = {}
        for r in range(n_rows):
            for c in range(n_cols):
                groups.setdefault(uf.find(idx(r, c)), []).append((r, c))
        spans: dict[tuple[int, int], tuple[int, int]] = {}  # anchor -> (rowspan, colspan)
        covered: set[tuple[int, int]] = set()
        for members in groups.values():
            rows_ = sorted({m[0] for m in members}); cols_ = sorted({m[1] for m in members})
            r0, r1, c0, c1 = rows_[0], rows_[-1], cols_[0], cols_[-1]
            if len(members) == (r1 - r0 + 1) * (c1 - c0 + 1):
                spans[(r0, c0)] = (r1 - r0 + 1, c1 - c0 + 1)
                covered.update(m for m in members if m != (r0, c0))
            else:
                # an L-shaped merge group: split it into maximal rectangles
                # (consecutive rows sharing the same contiguous column run)
                warnings.append({"code": "TABLE_SPAN_IRREGULAR", "page": page.index, "object_id": table_id,
                                 "detail": "split into rectangles"})
                for (rr0, cc0), (rs_, cs_) in _rectangles(members).items():
                    spans[(rr0, cc0)] = (rs_, cs_)
                    covered.update((rr, cc) for rr in range(rr0, rr0 + rs_) for cc in range(cc0, cc0 + cs_)
                                   if (rr, cc) != (rr0, cc0))

        # assign chars to anchored cells
        cell_chars: dict[tuple[int, int], list[Char]] = {a: [] for a in spans}
        anchor_of: dict[tuple[int, int], tuple[int, int]] = {}
        for (r0, c0), (rs, cs) in spans.items():
            for r in range(r0, r0 + rs):
                for c in range(c0, c0 + cs):
                    anchor_of[(r, c)] = (r0, c0)
        # the source's own space glyphs go with their cell too: they are the
        # word breaks the line builder honours (a 1.4 pt space at 7 pt is below
        # its gap threshold: '(if applicable)' read '(ifapplicable)')
        if page_spaces is None:
            page_spaces = [c for c in page.chars if c.text == " " and not c.generated and c.lbox.width > 0]
            order = {id(ch): k for k, ch in enumerate(page.chars)}  # a space marks the glyph after it
        spaces = [c for c in page_spaces if region.contains_point(c.lbox.cx, c.lbox.cy)]
        for ch in sorted(in_region + spaces, key=lambda ch: order.get(id(ch), 0)):
            r = _bucket(ys, ch.lbox.cy); c = _bucket(xs, ch.lbox.cx)
            if r is None or c is None:
                continue
            cell_chars[anchor_of[(r, c)]].append(ch)

        # split grid rows into aligned sub-rows where no rules separate body rows
        row_lines: list[list[dict[tuple[int, int], list[Line]]]] = []
        out_rows: list[list[tuple[tuple[int, int], list[Line]]]] = []
        row_map: list[int] = []  # grid row -> first output row index
        extra_anchor_rows: dict[int, int] = {}  # grid rows split into span row + child row
        n_out = 0
        for r in range(n_rows):
            anchors = [(r, c) for c in range(n_cols) if (r, c) in spans]
            lines_by_anchor = {a: build_lines(cell_chars[a]) for a in anchors}
            single_row_anchors = [a for a in anchors if spans[a][0] == 1]
            counts = {len(lines_by_anchor[a]) for a in single_row_anchors if lines_by_anchor[a]}
            k_split = counts.pop() if len(counts) == 1 else 1
            if k_split > 1 and _aligned(lines_by_anchor, single_row_anchors, k_split):
                # every populated single-row cell has k aligned lines -> k sub-rows
                row_map.append(n_out)
                for sub in range(k_split):
                    out_rows.append([(a, [lines_by_anchor[a][sub]] if lines_by_anchor[a] else []) for a in anchors])
                n_out += k_split
                split_rows.append({"grid_row": r, "sub_rows": k_split})
            else:
                split = _split_child_header_row(anchors, lines_by_anchor, spans, xs)
                if split is not None:
                    upper, lower = split
                    row_map.append(n_out)
                    out_rows.append(upper)
                    out_rows.append(lower)
                    n_out += 2
                    split_rows.append({"grid_row": r, "sub_rows": 2, "reason": "aligned_child_columns"})
                    extra_anchor_rows[r] = 1
                else:
                    row_map.append(n_out)
                    out_rows.append([(a, lines_by_anchor[a]) for a in anchors])
                    n_out += 1
        row_map.append(n_out)

        cells: list[Cell] = []
        for r in range(n_rows):
            for (a, lines) in out_rows[row_map[r]] if row_map[r + 1] - row_map[r] == 1 else []:
                pass
        # build cells from out_rows; anchors with rowspan>1 keep their grid rowspan mapped to output rows
        for out_r_index, row in enumerate(out_rows):
            for a, lines in row:
                if len(a) == 3:
                    # child cell produced by a header split: (row, col, "child")
                    r0, c0, _ = a
                    x0, x1 = xs[c0], xs[c0 + 1]
                    lb = lines[0].lbox if lines else BBox(x0, ys[r0], x1, ys[r0 + 1])
                    lbox = BBox(x0, lb.y0, x1, lb.y1)
                    chars_here = [t.char for ln in lines for t in ln.tokens]
                    bold = bool(chars_here) and all(c.bold for c in chars_here)
                    cells.append(Cell(out_r_index, c0, 1, 1, _cell_text(lines), lbox, _to_bbox(page, lbox), bold, chars_here))
                    continue
                r0, c0 = a
                rs, cs = spans[a]
                grid_first_out = row_map[r0]
                if r0 in extra_anchor_rows:
                    if out_r_index != grid_first_out:
                        continue
                    x0, x1 = xs[c0], xs[c0 + cs]
                    y0, y1 = ys[r0], ys[r0 + rs]
                    lbox = BBox(x0, y0, x1, y1)
                    chars_here = [t.char for ln in lines for t in ln.tokens]
                    bold = bool(chars_here) and all(c.bold for c in chars_here)
                    rowspan = (row_map[r0 + rs] - row_map[r0]) if rs > 1 else 1
                    cells.append(Cell(out_r_index, c0, rowspan, cs, _cell_text(lines), lbox, _to_bbox(page, lbox), bold, chars_here))
                    continue
                if out_r_index != grid_first_out and not (row_map[r0 + 1] - row_map[r0] > 1):
                    continue
                if rs > 1 and out_r_index != grid_first_out:
                    continue
                rowspan = (row_map[r0 + rs] - row_map[r0]) if rs > 1 else 1
                x0, x1 = xs[c0], xs[c0 + cs]
                if row_map[r0 + 1] - row_map[r0] > 1:
                    # sub-row: use the text line box for geometry, bounded by the grid cell
                    if lines:
                        lb = lines[0].lbox
                        y0, y1 = lb.y0, lb.y1
                    else:
                        y0, y1 = ys[r0], ys[r0 + 1]
                    out_row = out_r_index
                else:
                    y0, y1 = ys[r0], ys[r0 + rs]
                    out_row = grid_first_out
                lbox = BBox(x0, y0, x1, y1)
                chars_here = [t.char for ln in lines for t in ln.tokens]
                bold = bool(chars_here) and all(c.bold for c in chars_here)
                cells.append(Cell(out_row, c0, rowspan, cs, _cell_text(lines),
                                  lbox, _to_bbox(page, lbox), bold, chars_here))
        cells.sort(key=lambda c: (c.row, c.col))
        header_rows, inference = _header_rows(cells, n_out)
        header_rows = _extend_header_rows(header_rows, cells, n_out)
        tables.append(Table(table_id, page.index, n_out, n_cols, cells, region, _to_bbox(page, region),
                            header_rows, inference, warnings, split_rows, list(h) + list(v),
                            [f for f in getattr(page, "fills", []) if region.intersects(f.lbox)
                             and not getattr(f, "white", False)]))
    return tables


def _present(chars, x0: float, x1: float):
    """Glyphs that lie in [x0, x1) by at least 40 % of their width (a glyph
    reaching into a sliver makes that sliver part of its cell)."""
    return [ch for ch in chars if min(ch.lbox.x1, x1) - max(ch.lbox.x0, x0) >= 0.4 * ch.lbox.width]


def _glyph_straddles(lines: list[Line], xb: float) -> bool:
    for ln in lines:
        for tok in ln.tokens:
            c = tok.char
            if c.lbox.x0 < xb < c.lbox.x1 and min(xb - c.lbox.x0, c.lbox.x1 - xb) > 0.15 * c.lbox.width:
                return True
    return False


def _text_crosses_x(lines: list[Line], xb: float, tight: bool = False, factor: float = 0.5) -> bool:
    """True if a glyph straddles the boundary or a line continues across it with
    a normal word gap (a real column boundary shows a wider gap than a space).
    ``tight`` measures the gap between glyph boxes instead of advance boxes
    (advance boxes absorb wide word spacing in centred or justified text)."""
    for ln in lines:
        prev = None
        for tok in ln.tokens:
            c = tok.char
            if c.lbox.x0 < xb < c.lbox.x1 and min(xb - c.lbox.x0, c.lbox.x1 - xb) > 0.15 * c.lbox.width:
                return True
            if prev is not None and prev.lbox.cx < xb < c.lbox.cx:
                gap = (c.lbox.x0 - prev.lbox.x1) if tight else (c.loose.x0 - prev.loose.x1)
                if gap <= factor * max(prev.font_size, c.font_size):
                    return True
            prev = c
    return False


def _cell_text(lines: list[Line]) -> str:
    """Cell text in reading order. Cells holding several text columns are laid
    out with the same block grouping and XY-cut as body text."""
    from .layout import cell_blocks_text
    return cell_blocks_text(lines)


def _split_child_header_row(anchors, lines_by_anchor, spans, xs):
    """If every populated spanning cell in this grid row ends with a line whose
    tokens fall one per sub-column (each in a distinct existing grid column),
    return (upper_row, lower_row) where the last lines become single cells.
    Uses only the grid's own columns; never invents new ones."""
    spanning = [a for a in anchors if spans[a][1] > 1 and lines_by_anchor[a]]
    if not spanning:
        return None
    lower: list = []
    upper: list = []
    for a in anchors:
        lines = lines_by_anchor[a]
        if a in spanning:
            r0, c0 = a
            cs = spans[a][1]
            last = lines[-1]
            words = split_line_at_gaps(last)
            if len(words) < 2 or len(lines) < 2:
                return None
            cols = []
            for seg in words:
                cx = seg.lbox.cx
                k = _bucket(xs, cx)
                if k is None or not (c0 <= k < c0 + cs) or k in cols:
                    return None
                cols.append(k)
            upper.append((a, lines[:-1]))
            for seg, k in zip(words, cols):
                lower.append(((r0, k, "child"), [seg]))
        else:
            upper.append((a, lines))
    return upper, lower


def _rectangles(members) -> dict[tuple[int, int], tuple[int, int]]:
    """Decompose a set of grid cells into rectangles: per row, contiguous column
    runs; consecutive rows with an identical run merge vertically."""
    by_row: dict[int, list[int]] = {}
    for r, c in members:
        by_row.setdefault(r, []).append(c)
    runs: dict[int, list[tuple[int, int]]] = {}
    for r, cols in by_row.items():
        cols.sort()
        out = []
        start = prev = cols[0]
        for c in cols[1:]:
            if c == prev + 1:
                prev = c
            else:
                out.append((start, prev)); start = prev = c
        out.append((start, prev))
        runs[r] = out
    rects: dict[tuple[int, int], tuple[int, int]] = {}
    used: set[tuple[int, tuple[int, int]]] = set()
    for r in sorted(runs):
        for run in runs[r]:
            if (r, run) in used:
                continue
            rs = 1
            while (r + rs) in runs and run in runs[r + rs] and (r + rs, run) not in used:
                used.add((r + rs, run)); rs += 1
            used.add((r, run))
            rects[(r, run[0])] = (rs, run[1] - run[0] + 1)
    return rects


def _bucket(edges: list[float], v: float) -> int | None:
    for i in range(len(edges) - 1):
        if edges[i] <= v < edges[i + 1]:
            return i
    return None


def _aligned(lines_by_anchor, anchors, k: int) -> bool:
    populated = [lines_by_anchor[a] for a in anchors if lines_by_anchor[a]]
    if len(populated) < 2:
        return False
    for i in range(k):
        cys = [ls[i].cy for ls in populated]
        if max(cys) - min(cys) > 3.0:
            return False
    return True


def _header_rows(cells: list[Cell], n_rows: int) -> tuple[list[int], str]:
    by_row: dict[int, list[Cell]] = {}
    for c in cells:
        by_row.setdefault(c.row, []).append(c)
    # rule 1: leading rows whose populated cells are all bold, followed by a non-bold row
    hdr: list[int] = []
    for r in range(n_rows):
        row = [c for c in by_row.get(r, []) if c.raw_text.strip()]
        if row and all(c.bold for c in row):
            hdr.append(r)
        else:
            break
    if hdr and len(hdr) < n_rows:
        return hdr, "bold_leading_rows"
    # rule 2: leading rows containing column spans
    hdr = []
    for r in range(n_rows):
        row = by_row.get(r, [])
        if any(c.colspan > 1 for c in row):
            hdr.append(r)
        else:
            break
    if hdr and len(hdr) < n_rows:
        return hdr, "leading_spanning_rows"
    return [], "none"


def _extend_header_rows(header_rows: list[int], cells: list[Cell], n_rows: int) -> list[int]:
    """Rows of child cells split from a spanning header row are header rows too."""
    if not header_rows:
        return header_rows
    by_row: dict[int, list[Cell]] = {}
    for c in cells:
        by_row.setdefault(c.row, []).append(c)
    out = list(header_rows)
    r = max(header_rows) + 1
    while r < n_rows:
        row = by_row.get(r, [])
        if row and all(len(c.raw_text.strip()) <= 3 and c.rowspan == 1 for c in row if c.raw_text.strip()) \
                and any(c.raw_text.strip() for c in row) and any(c.colspan > 1 for c in by_row.get(r - 1, [])):
            out.append(r)
            r += 1
        else:
            break
    return out
