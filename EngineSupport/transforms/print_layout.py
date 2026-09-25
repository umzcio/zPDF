"""Print preparation and imposition.

These operations build a *print copy* of the document: the app runs them on a
private temporary revision and hands the result to the macOS print system, so
the user's file and the editing revision are never changed.

Typical chain (Swift side):

    [{"op": "print_prepare", "comments": true, "fields": true},
     {"op": "scale_pages", "percent": 90},          # optional
     {"op": "impose_nup", "cols": 2, "rows": 2}]    # or booklet / poster

Imposition draws each source page through a Form XObject built from the page's
content (CropBox, /Rotate honoured), so annotations are *not* carried onto the
imposed sheets. Run `print_prepare` first to flatten the annotations that
should print. Imposition also drops document-level navigation (outlines,
destinations, structure, forms) that would otherwise point at pages that no
longer exist.
"""
import math

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op
from transforms.content import (add_content, fmt, invert, multiply, page_box, resources,
                                stamp_appearances, transform_rect, visual_matrix, visual_size,
                                select_pages)

PRINT_FLAG = 4
HIDDEN_FLAG = 2
NON_COMMENTS = ("/Widget", "/Link", "/Popup")


# ---------------------------------------------------------------- helpers

def _number(value, name, low=None, high=None):
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = float("nan")
    ok = math.isfinite(number) and (low is None or number >= low) and (high is None or number <= high)
    require(ok, "INVALID_ARGUMENT", f"Invalid value for {name}.")
    return number


def _size(value, fallback, name):
    if value is None:
        return fallback
    require(isinstance(value, (list, tuple)) and len(value) == 2, "INVALID_ARGUMENT", f"Invalid {name}.")
    return (_number(value[0], name, 36, 14400), _number(value[1], name, 36, 14400))


def page_form(pdf, page):
    """A Form XObject drawing `page` in its own user space (BBox = CropBox)."""
    obj = page.obj
    contents = obj.get("/Contents")
    streams = [] if contents is None else (list(contents) if isinstance(contents, pikepdf.Array) else [contents])
    data = b"\n".join(s.read_bytes() for s in streams)
    form = pikepdf.Stream(pdf, data)
    form.Type = Name.XObject
    form.Subtype = Name.Form
    form.BBox = pikepdf.Array([float(v) for v in page_box(page)])
    form.Resources = resources(page)
    group = obj.get("/Group")
    if group is not None:
        form.Group = group
    return pdf.make_indirect(form)


def fit_matrix(page, cell):
    """Matrix drawing `page` (user space) upright, fitted and centred in cell (x, y, w, h)."""
    vw, vh = visual_size(page)
    x, y, w, h = cell
    user_to_visual = invert(visual_matrix(page))
    k = min(w / vw, h / vh)
    tx, ty = x + (w - vw * k) / 2, y + (h - vh * k) / 2
    return multiply(user_to_visual, (k, 0, 0, k, tx, ty)), (tx, ty, vw * k, vh * k)


class SheetBuilder:
    """Collects new sheets, then replaces the document's pages with them."""

    def __init__(self, pdf):
        self.pdf = pdf
        self.original = len(pdf.pages)
        self.forms = {}
        self.sheets = []

    def form(self, index):
        if index not in self.forms:
            self.forms[index] = page_form(self.pdf, self.pdf.pages[index])
        return self.forms[index]

    def sheet(self, width, height):
        page = self.pdf.add_blank_page(page_size=(float(width), float(height)))
        page.obj.Resources = pikepdf.Dictionary(XObject=pikepdf.Dictionary())
        self.sheets.append((page, []))
        return len(self.sheets) - 1

    def draw(self, sheet, source, matrix, clip=None):
        page, ops = self.sheets[sheet]
        xobjects = page.obj.Resources.XObject
        name = f"/P{source}"
        xobjects[Name(name)] = self.form(source)
        clip_ops = f"{fmt(*[float(v) for v in clip])} re W n " if clip else ""
        ops.append(f"q {clip_ops}{fmt(*[float(v) for v in matrix])} cm {name} Do Q")

    def raw(self, sheet, text):
        self.sheets[sheet][1].append(text)

    def finish(self):
        pdf = self.pdf
        for page, ops in self.sheets:
            page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, ("\n".join(ops) + "\n").encode("latin-1")))
        require(self.sheets, "EMPTY_DOCUMENT", "Nothing to print.")
        del pdf.pages[0:self.original]
        _drop_navigation(pdf)
        return len(self.sheets)


def _drop_navigation(pdf):
    """Imposed sheets no longer correspond to the original pages."""
    root = pdf.Root
    for key in ("/Outlines", "/OpenAction", "/PageLabels", "/StructTreeRoot", "/MarkInfo",
                "/AcroForm", "/Dests", "/Threads", "/PageMode"):
        if key in root:
            del root[key]
    names = root.get("/Names")
    if names is not None and "/Dests" in names:
        del names["/Dests"]


def _helvetica(pdf):
    return pdf.make_indirect(pikepdf.Dictionary(Type=Name.Font, Subtype=Name.Type1,
                                                BaseFont=Name.Helvetica, Encoding=Name.WinAnsiEncoding))


def _pdf_text(text):
    raw = str(text).encode("cp1252", errors="replace")
    return "(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)").decode("latin-1") + ")"


# ---------------------------------------------------------------- operations

@op("print_prepare")
def print_prepare(ctx, comments=True, fields=True):
    """Flatten what prints (per category), remove everything else."""
    pdf = ctx.pdf
    flattened = removed = 0
    had_widgets = False
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if not annots:
            continue
        stamp = []
        for annot in annots:
            subtype = str(annot.get("/Subtype", ""))
            if subtype == "/Widget":
                had_widgets = True
            try:
                flags = int(annot.get("/F", 0))
            except (TypeError, ValueError):
                flags = 0
            included = (fields if subtype == "/Widget" else comments) and subtype not in ("/Link", "/Popup")
            printable = bool(flags & PRINT_FLAG) and not flags & HIDDEN_FLAG
            has_ap = "/AP" in annot and "/N" in annot.AP
            if included and printable and has_ap:
                stamp.append(annot)
            else:
                removed += 1
        if stamp:
            stamp_appearances(pdf, page, stamp)
            flattened += len(stamp)
        del page.obj["/Annots"]
    if had_widgets and "/AcroForm" in pdf.Root:
        del pdf.Root["/AcroForm"]
    return {"flattened": flattened, "removed": removed}


@op("scale_pages")
def scale_pages(ctx, percent=100.0, center=True):
    """Scale page content (and annotation rectangles) inside unchanged page boxes."""
    pdf = ctx.pdf
    k = _number(percent, "percent", 1, 1000) / 100.0
    for page in pdf.pages:
        x0, y0, x1, y1 = page_box(page)
        if center:
            ox, oy = (x0 + x1) / 2, (y0 + y1) / 2
        else:
            vm = visual_matrix(page)
            ox, oy = vm[4], vm[5]  # visual bottom-left corner in user space
        m = (k, 0, 0, k, ox - k * ox, oy - k * oy)
        obj = page.obj
        contents = obj.get("/Contents")
        streams = [] if contents is None else (list(contents) if isinstance(contents, pikepdf.Array) else [contents])
        head = pdf.make_indirect(pikepdf.Stream(pdf, f"q {fmt(*m)} cm\n".encode()))
        tail = pdf.make_indirect(pikepdf.Stream(pdf, b"\nQ\n"))
        obj.Contents = pikepdf.Array([head] + streams + [tail])
        for annot in obj.get("/Annots", []):
            if "/Rect" in annot:
                annot.Rect = pikepdf.Array([float(v) for v in transform_rect(m, [float(v) for v in annot.Rect])])
    return {"pages": len(pdf.pages)}


ORDERS = ("horizontal", "horizontal_reversed", "vertical", "vertical_reversed")


@op("impose_nup")
def impose_nup(ctx, cols=2, rows=1, order="horizontal", borders=False, sheet=None, margin=18, gap=6,
               auto_rotate=True):
    """Several pages per sheet, in reading order `order`."""
    pdf = ctx.pdf
    require(isinstance(cols, int) and isinstance(rows, int) and 1 <= cols <= 16 and 1 <= rows <= 16,
            "INVALID_ARGUMENT", "Choose 1-16 columns and rows.")
    require(order in ORDERS, "INVALID_ARGUMENT", "Unknown page order.")
    margin = _number(margin, "margin", 0, 720)
    gap = _number(gap, "gap", 0, 720)
    first_w, first_h = visual_size(pdf.pages[0])
    width, height = _size(sheet, (first_w, first_h), "sheet size")
    if auto_rotate:
        grid_aspect = (cols * first_w) / (rows * first_h)
        if (grid_aspect > 1 and width < height) or (grid_aspect < 1 and width > height):
            width, height = height, width
    cell_w = (width - 2 * margin - (cols - 1) * gap) / cols
    cell_h = (height - 2 * margin - (rows - 1) * gap) / rows
    require(cell_w > 1 and cell_h > 1, "INVALID_ARGUMENT", "The margins leave no room for pages.")
    builder = SheetBuilder(pdf)
    per = cols * rows
    for start in range(0, builder.original, per):
        sheet_index = builder.sheet(width, height)
        for slot, source in enumerate(range(start, min(start + per, builder.original))):
            if order.startswith("horizontal"):
                row, col = slot // cols, slot % cols
            else:
                row, col = slot % rows, slot // rows
            if order.endswith("reversed"):
                col = cols - 1 - col
            x = margin + col * (cell_w + gap)
            y = height - margin - (row + 1) * cell_h - row * gap
            matrix, placed = fit_matrix(pdf.pages[source], (x, y, cell_w, cell_h))
            builder.draw(sheet_index, source, matrix)
            if borders:
                builder.raw(sheet_index, f"q 0 G 0.5 w {fmt(*[float(v) for v in placed])} re S Q")
    return {"sheets": builder.finish(), "per_sheet": per}


@op("impose_booklet")
def impose_booklet(ctx, binding="left", sheet=None, pages=None):
    """Saddle-stitch booklet: 2-up sides that fold into reading order."""
    pdf = ctx.pdf
    require(binding in ("left", "right"), "INVALID_ARGUMENT", "Binding must be left or right.")
    sources = select_pages(pdf, pages) if pages is not None else list(range(len(pdf.pages)))
    if pages is not None:
        sources = [p for p in pages if isinstance(p, int)]  # keep the requested order
    require(sources, "INVALID_ARGUMENT", "Choose pages for the booklet.")
    blanks = (-len(sources)) % 4
    padded = sources + [None] * blanks
    n = len(padded)
    first_w, first_h = visual_size(pdf.pages[sources[0]])
    width, height = _size(sheet, (2 * first_w, first_h), "sheet size")
    builder = SheetBuilder(pdf)
    for k in range(n // 2):
        left, right = (n - 1 - k, k) if k % 2 == 0 else (k, n - 1 - k)
        if binding == "right":
            left, right = right, left
        sheet_index = builder.sheet(width, height)
        for position, x in ((left, 0.0), (right, width / 2)):
            source = padded[position]
            if source is None:
                continue
            matrix, _ = fit_matrix(pdf.pages[source], (x, 0.0, width / 2, height))
            builder.draw(sheet_index, source, matrix, clip=(x, 0.0, width / 2, height))
    builder.finish()
    return {"sheets": n // 4, "sides": n // 2, "blank_pages_added": blanks}


@op("impose_poster")
def impose_poster(ctx, tile=None, scale=100.0, overlap=18, cut_marks=True, labels=True, pages=None):
    """Tile enlarged pages across several sheets with overlap, cut marks and labels."""
    pdf = ctx.pdf
    tw, th = _size(tile, (612.0, 792.0), "tile size")
    s = _number(scale, "scale", 1, 2000) / 100.0
    ov = _number(overlap, "overlap", 0, min(tw, th) / 3)
    sources = select_pages(pdf, pages)
    builder = SheetBuilder(pdf)
    font = _helvetica(pdf) if labels else None
    grids = []
    step_x, step_y = tw - ov, th - ov
    for source in sources:
        page = pdf.pages[source]
        vw, vh = visual_size(page)
        W, H = vw * s, vh * s
        cols = max(1, math.ceil((W - ov) / step_x - 1e-9))
        rows = max(1, math.ceil((H - ov) / step_y - 1e-9))
        require(cols * rows <= 400, "INVALID_ARGUMENT", "That poster needs too many tiles.")
        grids.append([rows, cols])
        base = multiply(invert(visual_matrix(page)), (s, 0, 0, s, 0, 0))
        for r in range(rows):
            for c in range(cols):
                sheet_index = builder.sheet(tw, th)
                bottom = H - r * step_y - th
                matrix = multiply(base, (1, 0, 0, 1, -c * step_x, -bottom))
                builder.draw(sheet_index, source, matrix)
                marks = []
                if cut_marks:
                    tick = min(12.0, ov if ov > 0 else 12.0)
                    xs = ([ov / 2] if c > 0 else []) + ([tw - ov / 2] if c < cols - 1 else [])
                    ys = ([th - ov / 2] if r > 0 else []) + ([ov / 2] if r < rows - 1 else [])
                    for x in xs:
                        marks.append(f"{fmt(x)} 0 m {fmt(x)} {fmt(tick)} l {fmt(x)} {fmt(th - tick)} m {fmt(x)} {fmt(th)} l")
                    for y in ys:
                        marks.append(f"0 {fmt(y)} m {fmt(tick)} {fmt(y)} l {fmt(tw - tick)} {fmt(y)} m {fmt(tw)} {fmt(y)} l")
                if marks:
                    builder.raw(sheet_index, "q 0 G 0.5 w " + " ".join(marks) + " S Q")
                if labels:
                    label = f"Row {r + 1}, Col {c + 1} — Page {source + 1}"
                    builder.raw(sheet_index, f"q 1 g {fmt(4.0)} {fmt(2.0)} {fmt(len(label) * 3.6 + 4)} 10 re f "
                                             f"0 g BT /ZPDFLabel 7 Tf 6 4 Td {_pdf_text(label)} Tj ET Q")
                    builder.sheets[sheet_index][0].obj.Resources.Font = pikepdf.Dictionary(ZPDFLabel=font)
    tiles = builder.finish()
    return {"tiles": tiles, "grid": grids}


@op("crop_area")
def crop_area(ctx, page, rect):
    """Keep one page, cropped to `rect` (user space), for printing a selection."""
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "INVALID_ARGUMENT", "The page is invalid.")
    require(isinstance(rect, (list, tuple)) and len(rect) == 4, "INVALID_ARGUMENT", "The area is invalid.")
    l, b, r, t = [_number(v, "area") for v in rect]
    l, r = min(l, r), max(l, r)
    b, t = min(b, t), max(b, t)
    target = pdf.pages[page]
    x0, y0, x1, y1 = page_box(target)
    m0, n0, m1, n1 = page_box(target, "/MediaBox")
    x0, y0, x1, y1 = max(x0, m0), max(y0, n0), min(x1, m1), min(y1, n1)
    l, b, r, t = max(l, x0), max(b, y0), min(r, x1), min(t, y1)
    require(r - l >= 1 and t - b >= 1, "INVALID_ARGUMENT", "The selected area is outside the page.")
    box = pikepdf.Array([l, b, r, t])
    target.obj.MediaBox = box
    target.obj.CropBox = pikepdf.Array([l, b, r, t])
    for key in ("/TrimBox", "/BleedBox", "/ArtBox"):
        if key in target.obj:
            del target.obj[key]
    count = len(pdf.pages)
    for index in reversed(range(count)):
        if index != page:
            del pdf.pages[index]
    _drop_navigation(pdf)
    return {"rect": [round(v, 4) for v in (l, b, r, t)]}
