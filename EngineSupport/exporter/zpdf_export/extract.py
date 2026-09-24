"""Per-page extraction from PDFium into geometry-bearing primitives.

Everything here is read-only. Coordinates are normalized with PDFium's own
page-to-device mapping so CropBox origin and /Rotate are resolved identically
to rendering. IDs are positional and stable within a snapshot (page number +
annotation/object index), never field names.
"""
from __future__ import annotations

import ctypes
import math
from dataclasses import dataclass, field

import pypdfium2 as pdfium
import pypdfium2.raw as raw

from .errors import ExportError
from .geometry import BBox
from .fontmap import GlyphRecovery
from .pngenc import bitmap_to_png
from .snapshot import Snapshot

_SCALE = 100  # device units per point for the integer PageToDevice mapping

_FIELD_TYPES = {
    raw.FPDF_FORMFIELD_PUSHBUTTON: "pushbutton",
    raw.FPDF_FORMFIELD_CHECKBOX: "checkbox",
    raw.FPDF_FORMFIELD_RADIOBUTTON: "radio",
    raw.FPDF_FORMFIELD_COMBOBOX: "combobox",
    raw.FPDF_FORMFIELD_LISTBOX: "listbox",
    raw.FPDF_FORMFIELD_TEXTFIELD: "text",
    raw.FPDF_FORMFIELD_SIGNATURE: "signature",
}

_COMMENT_KINDS = {
    raw.FPDF_ANNOT_TEXT: "text",
    raw.FPDF_ANNOT_FREETEXT: "freetext",
    raw.FPDF_ANNOT_HIGHLIGHT: "highlight",
    raw.FPDF_ANNOT_UNDERLINE: "underline",
    raw.FPDF_ANNOT_SQUIGGLY: "squiggly",
    raw.FPDF_ANNOT_STRIKEOUT: "strikeout",
    raw.FPDF_ANNOT_INK: "ink",
    raw.FPDF_ANNOT_SQUARE: "square",
    raw.FPDF_ANNOT_CIRCLE: "circle",
    raw.FPDF_ANNOT_LINE: "line",
    raw.FPDF_ANNOT_POLYGON: "polygon",
    raw.FPDF_ANNOT_POLYLINE: "polyline",
    raw.FPDF_ANNOT_STAMP: "stamp",
    raw.FPDF_ANNOT_CARET: "caret",
    raw.FPDF_ANNOT_FILEATTACHMENT: "fileattachment",
}

_FXFONT_ITALIC = 0x40
_FXFONT_FORCE_BOLD = 0x40000


@dataclass
class Char:
    text: str
    bbox: BBox        # tight glyph box, normalized displayed space
    lbox: BBox        # tight glyph box, upright layout space
    loose: BBox       # font-height/advance box, upright layout space (line grouping)
    font_name: str
    font_size: float
    bold: bool
    italic: bool
    generated: bool
    missing_map: bool
    recovered: bool = False
    color: tuple[int, int, int] = (0, 0, 0)   # text fill colour
    uri: str | None = None                   # hyperlink target covering this glyph (set by reconstruct)
    underline: bool = False                  # a stroked rule runs under this glyph (set by layout mode)
    inferred: bool = False                   # text read from the glyph's shape, not from a Unicode mapping
    invisible: bool = False                  # drawn with an invisible render mode (OCR layer under a scan)
    sideways: int = 0                        # glyph drawn turned (text matrix): +1 reads upward, -1 downward

    @property
    def x0(self): return self.bbox.x0
    @property
    def y0(self): return self.bbox.y0
    @property
    def x1(self): return self.bbox.x1
    @property
    def y1(self): return self.bbox.y1


@dataclass
class Rule:
    bbox: BBox
    lbox: BBox
    orientation: str  # 'h' or 'v' in layout space
    rgb: tuple[int, int, int] = (0, 0, 0)   # stroke (or bar fill) colour
    z: int = -1                              # drawing order on the page

    @property
    def x0(self): return self.bbox.x0
    @property
    def y0(self): return self.bbox.y0
    @property
    def x1(self): return self.bbox.x1
    @property
    def y1(self): return self.bbox.y1


@dataclass
class ImageRegion:
    image_id: str
    bbox: BBox
    lbox: BBox
    png_bytes: bytes
    width_px: int
    height_px: int
    origin: str = "image"      # image (raster XObject) | vector (rendered path artwork)
    objects: int = 1           # number of source objects
    absorbed_text: str = ""    # logo lettering that is part of the rendered artwork
    z: int = -1                # drawing order on the page
    behind: bool = False       # a render of the page's drawing under the text (shading illustration): placed behind everything


@dataclass
class FillRect:
    """A filled axis-aligned rectangle (shading band, section bar, cell background)."""
    bbox: BBox
    lbox: BBox
    rgb: tuple[int, int, int]
    white: bool = False   # a white knockout (frames, highlights); never shading
    z: int = -1            # drawing order on the page
    alpha: int = 255
    blended: bool = False  # renders with what lies under it showing through (blend mode, soft mask)


@dataclass
class ArtPath:
    """A path object that may be part of vector artwork (not a rule)."""
    bbox: BBox
    lbox: BBox
    curved: bool
    filled: bool
    white: bool
    shading: bool = False   # a PDF shading (gradient) object: appearance that only a render can carry


@dataclass
class Link:
    link_id: str
    bbox: BBox
    lbox: BBox
    uri: str | None
    dest_page: int | None  # 1-based


@dataclass
class Widget:
    widget_id: str
    bbox: BBox
    lbox: BBox
    field_name: str
    field_type: str
    value: str
    label: str | None
    checked: bool | None
    export_value: str | None


@dataclass
class Comment:
    comment_id: str
    bbox: BBox
    lbox: BBox
    kind: str
    text: str
    author: str | None
    modified: str | None


@dataclass
class PageExtract:
    index: int
    width: float
    height: float
    layout_width: float
    layout_height: float
    rotation: int
    user_unit: float
    media_box: tuple[float, float, float, float]
    crop_box: tuple[float, float, float, float]
    chars: list[Char] = field(default_factory=list)
    hidden_chars: list = field(default_factory=list)  # invisible text (render mode 3/7): kept hidden, never laid out
    rules: list[Rule] = field(default_factory=list)
    images: list[ImageRegion] = field(default_factory=list)
    links: list[Link] = field(default_factory=list)
    widgets: list[Widget] = field(default_factory=list)
    comments: list[Comment] = field(default_factory=list)
    warnings: list[dict] = field(default_factory=list)
    art: list[ArtPath] = field(default_factory=list)        # artwork candidates (paths)
    fills: list[FillRect] = field(default_factory=list)     # non-white filled rectangles (shading)
    artwork: list[ImageRegion] = field(default_factory=list)  # rendered vector artwork regions
    absorbed_chars: set = field(default_factory=set)          # ids of chars rendered inside artwork
    markups: list = field(default_factory=list)               # (kind, lbox, rgb) of text-markup annotations


class _Mapper:
    """Page space -> (normalized displayed space, upright layout space).

    Both use FPDF_PageToDevice so CropBox origin and /Rotate are resolved the
    same way PDFium renders. Layout space cancels /Rotate so text lines are
    horizontal for analysis; normalized space is what the IR records.
    """

    def __init__(self, page: pdfium.PdfPage, width: float, height: float, rotation: int) -> None:
        self.page = page
        self.sx = int(round(width * _SCALE))
        self.sy = int(round(height * _SCALE))
        self.unrotate = (4 - (rotation // 90)) % 4
        if self.unrotate in (1, 3):
            self.lsx, self.lsy = self.sy, self.sx
        else:
            self.lsx, self.lsy = self.sx, self.sy
        self.layout_width = self.lsx / _SCALE
        self.layout_height = self.lsy / _SCALE
        self._dx = ctypes.c_int()
        self._dy = ctypes.c_int()

    def point(self, x: float, y: float) -> tuple[float, float]:
        raw.FPDF_PageToDevice(self.page, 0, 0, self.sx, self.sy, 0, x, y, self._dx, self._dy)
        return self._dx.value / _SCALE, self._dy.value / _SCALE

    def lpoint(self, x: float, y: float) -> tuple[float, float]:
        raw.FPDF_PageToDevice(self.page, 0, 0, self.lsx, self.lsy, self.unrotate, x, y, self._dx, self._dy)
        return self._dx.value / _SCALE, self._dy.value / _SCALE

    def box(self, left: float, bottom: float, right: float, top: float) -> BBox:
        pts = [self.point(left, bottom), self.point(right, bottom),
               self.point(left, top), self.point(right, top)]
        return BBox.from_points(pts)

    def lbox(self, left: float, bottom: float, right: float, top: float) -> BBox:
        pts = [self.lpoint(left, bottom), self.lpoint(right, bottom),
               self.lpoint(left, top), self.lpoint(right, top)]
        return BBox.from_points(pts)

    def both(self, left: float, bottom: float, right: float, top: float) -> tuple[BBox, BBox]:
        return self.box(left, bottom, right, top), self.lbox(left, bottom, right, top)


def _utf16(fn, *args) -> str:
    n = fn(*args, None, 0)
    if n <= 2:
        return ""
    buf = ctypes.create_string_buffer(n)
    fn(*args, ctypes.cast(buf, ctypes.POINTER(ctypes.c_ushort)), n)
    return buf.raw[:n].decode("utf-16-le", "replace").rstrip("\x00")


def _utf16_annot_string(annot, key: bytes) -> str:
    n = raw.FPDFAnnot_GetStringValue(annot, key, None, 0)
    if n <= 2:
        return ""
    buf = ctypes.create_string_buffer(n)
    raw.FPDFAnnot_GetStringValue(annot, key, ctypes.cast(buf, ctypes.POINTER(ctypes.c_ushort)), n)
    return buf.raw[:n].decode("utf-16-le", "replace").rstrip("\x00")


def _page_or_raise(snapshot: Snapshot, index: int) -> pdfium.PdfPage:
    if not isinstance(index, int) or index < 1 or index > snapshot.page_count:
        raise ExportError("INVALID_REQUEST", "page_out_of_range", page=index)
    return snapshot.pdf[index - 1]


def extract_page(snapshot: Snapshot, index: int) -> PageExtract:
    page = _page_or_raise(snapshot, index)
    width, height = page.get_size()
    rotation = page.get_rotation()
    mapper = _Mapper(page, width, height, rotation)
    out = PageExtract(
        index=index, width=width, height=height,
        layout_width=mapper.layout_width, layout_height=mapper.layout_height, rotation=rotation,
        user_unit=_user_unit(page),
        media_box=tuple(page.get_mediabox()), crop_box=tuple(page.get_cropbox()),
    )
    _extract_chars(page, mapper, out)
    _extract_objects(page, mapper, out)
    _extract_links(snapshot, page, mapper, out)
    _extract_annotations(snapshot, page, mapper, out)
    _drop_outside_cropbox(out, page, snapshot)
    from .artwork import detect_artwork
    detect_artwork(page, out, snapshot)
    from .artwork import keep_picture_labels
    keep_picture_labels(page, out)
    _render_sideways_text(page, out)
    _apply_markups(out)
    return out


def _render_sideways_text(page, out: PageExtract) -> None:
    """Glyphs drawn turned by their text matrix (a print job stamp up the margin
    of a Federal Register page) cannot be placed as Word text on the flow; a
    thin strip of them is rendered as a picture at its position and the glyphs
    leave the text. Applies only to a small minority of the page's glyphs, so
    a page typeset sideways as a whole is untouched."""
    from .artwork import _render_region
    from .extract import ImageRegion  # noqa: PLW0406 - same module; explicit for clarity
    real = [c for c in out.chars if not c.generated and not c.text.isspace()]
    side = [c for c in real if getattr(c, "sideways", False) and id(c) not in out.absorbed_chars]
    if not side or len(side) > 0.1 * len(real):
        return
    runs: list[list] = []
    for c in sorted(side, key=lambda c: (round(c.lbox.cx / 4), c.lbox.y0)):
        cur = runs[-1] if runs else None
        if cur and abs(cur[-1].lbox.cx - c.lbox.cx) <= 4 and c.lbox.y0 - cur[-1].lbox.y1 <= 2 * max(c.font_size, 1.0):
            cur.append(c)
        else:
            runs.append([c])
    n = 0
    for k, run in enumerate(runs, start=1):
        if len(run) < 3:
            continue
        lb = run[0].lbox; bb = run[0].bbox
        for c in run[1:]:
            lb = lb.union(c.lbox); bb = bb.union(c.bbox)
        png, wpx, hpx = _render_region(page, out, bb, min_ink=0.0)   # tiny glyphs on a thin strip: little ink
        if png is None:
            continue
        upward = getattr(run[0], "sideways", 0) > 0
        ordered = sorted(run, key=lambda c: -c.lbox.y0 if upward else c.lbox.y0)
        text = ordered[0].text
        for a, b in zip(ordered, ordered[1:]):
            gap = (a.lbox.y0 - b.lbox.y1) if upward else (b.lbox.y0 - a.lbox.y1)
            text += (" " if gap > 0.3 * max(a.font_size, 1.0) else "") + b.text
        out.artwork.append(ImageRegion(f"p{out.index}-sideways-{k}", bb, lb, png, wpx, hpx, "vector", len(run), text))
        for c in run:
            out.absorbed_chars.add(id(c))
        n += len(run)
    if n:
        out.warnings.append({"code": "TEXT_SIDEWAYS_RENDERED", "page": out.index, "count": n,
                             "absorbed_text": " ".join(a.absorbed_text for a in out.artwork if a.image_id.startswith(f"p{out.index}-sideways-")),
                             "detail": "text drawn turned in the margin is placed as a picture of itself, not as editable text"})


def _drop_outside_cropbox(out: PageExtract, page=None, snapshot=None) -> None:
    """Content whose center lies outside the displayed page box is invisible in
    every viewer (print slugs, crop marks). Exclude it and say so."""
    W, H = out.layout_width, out.layout_height

    def inside(box: BBox) -> bool:
        return -0.5 <= box.cx <= W + 0.5 and -0.5 <= box.cy <= H + 0.5

    dropped = 0
    kept = []
    for c in out.chars:
        if c.generated or inside(c.lbox):
            kept.append(c)
        else:
            dropped += 1
    out.chars = kept
    _drop_hidden_images(out, page, snapshot)
    for name in ("rules", "images", "links", "widgets", "comments", "art", "fills"):
        items = getattr(out, name)
        keep = [it for it in items if inside(it.lbox)]
        dropped += len(items) - len(keep)
        setattr(out, name, keep)
    if dropped:
        out.warnings.append({"code": "CONTENT_OUTSIDE_CROPBOX", "page": out.index, "count": dropped})


def _user_unit(page) -> float:
    # pypdfium2 has no helper; PDFium exposes no direct getter in the public API.
    # /UserUnit is rare; we record 1.0 and flag if the page dictionary differs later.
    return 1.0


def _extract_chars(page, mapper: _Mapper, out: PageExtract) -> None:
    tp = page.get_textpage()
    n = tp.count_chars()
    left = ctypes.c_double(); right = ctypes.c_double()
    bottom = ctypes.c_double(); top = ctypes.c_double()
    matrix = raw.FS_MATRIX()
    loose_rect = raw.FS_RECTF()
    col_r = ctypes.c_uint(); col_g = ctypes.c_uint(); col_b = ctypes.c_uint(); col_a = ctypes.c_uint()
    fbuf = ctypes.create_string_buffer(256)
    fflags = ctypes.c_int()
    is_generated = getattr(raw, "FPDFText_IsGenerated", None)
    recovery = GlyphRecovery()
    n_recovered = 0
    n_inferred = 0
    n_hidden = 0
    render_modes: dict[int, int] = {}
    trust = _matrix_size_votes(tp, n, mapper, matrix, left, right, bottom, top)
    last_trust: bool | None = None
    for i in range(n):
        cp = raw.FPDFText_GetUnicode(tp, i)
        generated = bool(is_generated(tp, i)) if is_generated else False
        obj = raw.FPDFText_GetTextObject(tp, i)
        key = ctypes.cast(obj, ctypes.c_void_p).value if obj else 0
        if key and key not in render_modes:
            render_modes[key] = raw.FPDFTextObj_GetTextRenderMode(obj)
        invisible = render_modes.get(key, 0) in (3, 7)   # invisible, or clip-only
        # PDFium reports glyphs without a Unicode mapping as control codepoints
        # (e.g. 0x1F for an unmapped "fi" ligature). Keep them visible and flagged.
        missing = (cp == 0 or cp == 0xFFFD or (cp < 32 and chr(cp) not in "\t\r\n")
                   or 0xD800 <= cp <= 0xDFFF or cp in (0xFFFE, 0xFFFF))
        text = "\ufffd" if missing else chr(cp)
        recovered = False
        if missing and cp != 0xFFFD:
            fixed = _recover_glyph(tp, i, cp, recovery)
            if fixed:
                text, missing, recovered = fixed, False, True
                n_recovered += 1
        if generated and text in ("\r", "\n"):
            continue  # PDFium's synthetic line breaks; layout rebuilds lines from geometry
        ok = raw.FPDFText_GetCharBox(tp, i, left, right, bottom, top)
        if ok:
            bbox, lbox = mapper.both(left.value, bottom.value, right.value, top.value)
        else:
            bbox = lbox = BBox(0, 0, 0, 0)
        if raw.FPDFText_GetLooseCharBox(tp, i, loose_rect):
            loose = mapper.lbox(loose_rect.left, loose_rect.bottom, loose_rect.right, loose_rect.top)
        else:
            loose = lbox
        fs = raw.FPDFText_GetFontSize(tp, i)
        sideways = 0
        if raw.FPDFText_GetMatrix(tp, i, matrix):
            det = abs(matrix.a * matrix.d - matrix.b * matrix.c)
            size = fs * math.sqrt(det) if det > 0 else fs
            # glyphs drawn turned: +1 reads upward (bottom to top on the page), -1 downward
            sideways = (1 if matrix.b > 0 else -1) if abs(matrix.b) > abs(matrix.a) else 0
        else:
            size = fs
        if size < 0.5:
            size = lbox.height
        # The text matrix does not include an enclosing Form XObject's scale, but
        # glyph boxes do. The object's letters voted on whether the matrix size
        # agrees with their boxes (see _matrix_size_votes); without a vote the
        # loose box height decides (its 1.2× ratio is only approximate).
        if loose.height > 0:
            est = loose.height / 1.2
            if key in trust:
                trusted = trust[key]
            elif last_trust is not None:
                # an object without letters to vote (a lone decimal point): its
                # neighbours' decision, not its own tiny glyph box (Census 'e=0.25')
                trusted = last_trust
            else:
                trusted = abs(size - est) / est <= 0.3 if size > 0 else False
            if key in trust:
                last_trust = trust[key]
            if size <= 0 or not trusted:
                size = est
        if size > 0 and 0 < loose.height < 0.5 * size and not sideways:
            # PDFium gave a glyph-tight "loose" box (a lone decimal point in its own
            # text object): line grouping needs the font-height box, so rebuild it
            # from the glyph's baseline (its tight bottom) and the size
            loose = BBox(loose.x0, lbox.y1 - 0.9 * size, loose.x1, lbox.y1 + 0.25 * size)
        fn_len = raw.FPDFText_GetFontInfo(tp, i, fbuf, 256, fflags)
        font_name = fbuf.raw[:max(fn_len - 1, 0)].decode("latin-1", "replace") if fn_len else ""
        if 0xF000 <= cp <= 0xF0FF and not recovered:
            sym = _symbol_pua(font_name, cp)
            if sym:
                text = sym
        flags = fflags.value
        weight = raw.FPDFText_GetFontWeight(tp, i)
        bold = bool(flags & _FXFONT_FORCE_BOLD) or weight >= 600 or "bold" in font_name.lower()
        italic = bool(flags & _FXFONT_ITALIC) or "italic" in font_name.lower() or "oblique" in font_name.lower()
        color = (0, 0, 0)
        if raw.FPDFText_GetFillColor(tp, i, col_r, col_g, col_b, col_a):
            color = (col_r.value, col_g.value, col_b.value)
        inferred = False
        if missing and not generated:
            prev = out.chars[-1] if out.chars and not out.chars[-1].generated else None
            guess = _infer_glyph(lbox, size, prev)
            if guess:
                text, missing, inferred = guess, False, True
                n_inferred += 1
        ch = Char(text, bbox, lbox, loose, font_name, size, bold, italic, generated, missing, recovered, color)
        ch.sideways = sideways
        ch.inferred = inferred
        if invisible and not generated:
            ch.invisible = True
            out.hidden_chars.append(ch)
            n_hidden += 1
            continue
        out.chars.append(ch)
    if n_recovered:
        out.warnings.append({"code": "GLYPH_RECOVERED", "page": out.index, "count": n_recovered,
                             "detail": "unmapped glyphs resolved through embedded font glyph names"})
    if n_hidden:
        out.warnings.append({"code": "TEXT_INVISIBLE_KEPT_HIDDEN", "page": out.index, "count": n_hidden,
                             "detail": "text drawn with an invisible render mode (an OCR layer under a scanned page) "
                                       "is written as hidden text, not as visible paragraphs"})
    if n_inferred:
        out.warnings.append({"code": "GLYPH_INFERRED", "page": out.index, "count": n_inferred,
                             "detail": "unmapped glyphs read from their shape: a short thin bar at mid x-height "
                                       "after a letter is a hyphen"})


_XHEIGHT_LETTERS = set("acemnorsuvwxz")


def _matrix_size_votes(tp, n: int, mapper: "_Mapper", matrix, left, right, bottom, top) -> dict[int, bool]:
    """Per text object: does the size from the text matrix agree with the glyph
    boxes? The matrix omits an enclosing Form XObject's scale (boxes include
    it), but a font with tight metrics (TimesNewRomanPSMT: loose box 0.9× the
    size) must not be shrunk either. Letters vote: capitals, digits and
    ascender/descender letters stand ≈ 0.7× the size, x-height letters ≈ 0.48×
    (or 0.7× as small capitals);
    the object's matrix size is trusted when at least half its voters agree
    within 30 %."""
    votes: dict[int, list[bool]] = {}
    for i in range(n):
        cp = raw.FPDFText_GetUnicode(tp, i)
        ch = chr(cp) if 32 <= cp < 0xD800 else ""
        if not (ch.isascii() and ch.isalnum()):
            continue
        obj = raw.FPDFText_GetTextObject(tp, i)
        key = ctypes.cast(obj, ctypes.c_void_p).value if obj else 0
        if not key or not raw.FPDFText_GetCharBox(tp, i, left, right, bottom, top):
            continue
        fs = raw.FPDFText_GetFontSize(tp, i)
        sideways = False
        if raw.FPDFText_GetMatrix(tp, i, matrix):
            det = abs(matrix.a * matrix.d - matrix.b * matrix.c)
            size = fs * math.sqrt(det) if det > 0 else fs
            sideways = abs(matrix.b) > abs(matrix.a)   # glyphs drawn turned: their height runs along x
        else:
            size = fs
        h = (right.value - left.value) if sideways else (top.value - bottom.value)
        if size <= 0 or h <= 0:
            continue
        # an x-height letter set as a small capital stands at cap height (NWS
        # 'what' in Arial-BoldMT-SC700: 'w' 6.5 pt tall at size 9.1)
        ests = (h / 0.48, h / 0.7) if ch in _XHEIGHT_LETTERS else (h / 0.7,)
        votes.setdefault(key, []).append(any(abs(size - est) / est <= 0.3 for est in ests))
    return {k: sum(v) * 2 >= len(v) for k, v in votes.items()}


def _page_space_corners(obj, l: float, b: float, r: float, t: float) -> list[tuple[float, float]]:
    """PDFium reports bounds of objects nested in Form XObjects in the form's
    local space; apply each ancestor form matrix to reach page space."""
    pts = [(l, b), (r, b), (l, t), (r, t)]
    container = getattr(obj, "container", None)
    while isinstance(container, pdfium.PdfObject):
        m = container.get_matrix()
        pts = [(m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f) for x, y in pts]
        container = getattr(container, "container", None)
    return pts


def _bounds_both(mapper: _Mapper, obj, l: float, b: float, r: float, t: float) -> tuple[BBox, BBox]:
    pts = _page_space_corners(obj, l, b, r, t)
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return mapper.both(min(xs), min(ys), max(xs), max(ys))


def _infer_glyph(lbox: BBox, size: float, prev) -> str | None:
    """Read an unmapped glyph from its geometry when the shape is unambiguous.
    A hyphen is a short (0.15–0.6 em), thin (≤ 0.15 em) bar whose centre sits in
    the middle of the preceding letter's x-height. Anything else stays U+FFFD."""
    if size <= 0 or lbox.width <= 0 or lbox.height <= 0 or prev is None:
        return None
    if not prev.text.isalpha():
        return None
    w, h = lbox.width / size, lbox.height / size
    if not (0.15 <= w <= 0.6 and h <= 0.15):
        return None
    pb = prev.lbox
    if pb.height <= 0 or abs(lbox.cx - pb.x1) > 0.6 * size:
        return None
    rel = (pb.y1 - lbox.cy) / pb.height   # 0 = the letter's bottom, 1 = its top
    if 0.25 <= rel <= 0.75:
        return "-"
    return None


def _recover_glyph(tp, index: int, code: int, recovery: GlyphRecovery) -> str | None:
    """Map an unmapped char code through the embedded font program's glyph names."""
    try:
        obj = raw.FPDFText_GetTextObject(tp, index)
        if not obj:
            return None
        font = raw.FPDFTextObj_GetFont(obj)
        if not font or not raw.FPDFFont_GetIsEmbedded(font):
            return None
        size = ctypes.c_size_t()
        if not raw.FPDFFont_GetFontData(font, None, 0, size) or not size.value:
            return None
        buf = ctypes.create_string_buffer(size.value)
        raw.FPDFFont_GetFontData(font, ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8)), size.value, size)
        return recovery.lookup_bytes(buf.raw, code)
    except Exception:  # noqa: BLE001
        return None


def _extract_objects(page, mapper: _Mapper, out: PageExtract) -> None:
    l = ctypes.c_float(); b = ctypes.c_float(); r = ctypes.c_float(); t = ctypes.c_float()
    img_k = 0
    fill_mode = ctypes.c_int(); stroked = ctypes.c_int(); stroke_w = ctypes.c_float()
    px = ctypes.c_float(); py = ctypes.c_float()
    cr = ctypes.c_uint(); cg = ctypes.c_uint(); cb = ctypes.c_uint(); ca = ctypes.c_uint()
    for z_index, obj in enumerate(page.get_objects(max_depth=8)):
        _PAINT_Z[0] = z_index
        if obj.type == raw.FPDF_PAGEOBJ_PATH:
            if not raw.FPDFPageObj_GetBounds(obj, l, b, r, t):
                continue
            raw.FPDFPath_GetDrawMode(obj, fill_mode, stroked)
            nseg = raw.FPDFPath_CountSegments(obj)
            curved = any(raw.FPDFPathSegment_GetType(raw.FPDFPath_GetPathSegment(obj, k)) == raw.FPDF_SEGMENT_BEZIERTO
                         for k in range(nseg))
            if stroked.value and not curved:
                # stroked paths: every straight axis-aligned segment is a rule
                # (table borders are often one path with many subpaths)
                width = stroke_w.value if raw.FPDFPageObj_GetStrokeWidth(obj, stroke_w) else 1.0
                _segments_to_rules(obj, mapper, out, max(width, 0.5), px, py)
            bbox, lbox = _bounds_both(mapper, obj, l.value, b.value, r.value, t.value)
            w, h = lbox.width, lbox.height
            if fill_mode.value and not stroked.value and not curved:
                # filled thin rectangles are rules too
                if h <= 2.5 and w > 4:
                    out.rules.append(Rule(bbox, lbox, "h", *_paint(obj, stroke=False)))
                    continue
                if w <= 2.5 and h > 4:
                    out.rules.append(Rule(bbox, lbox, "v", *_paint(obj, stroke=False)))
                    continue
            rect_like = (not curved) and nseg <= 6
            if fill_mode.value and rect_like and (w > 2.5 and h > 2.5) and raw.FPDFPageObj_GetFillColor(obj, cr, cg, cb, ca):
                if ca.value > 0:
                    is_white = cr.value >= 250 and cg.value >= 250 and cb.value >= 250
                    out.fills.append(FillRect(bbox, lbox, (cr.value, cg.value, cb.value), is_white, z_index, ca.value))
            # artwork candidates: curves, or filled shapes that are not large
            # axis-aligned rectangles (those are shading/backgrounds)
            if curved or (fill_mode.value and not (rect_like and max(w, h) > 30)):
                if w >= 1 or h >= 1:
                    white = False
                    if fill_mode.value and raw.FPDFPageObj_GetFillColor(obj, cr, cg, cb, ca):
                        white = cr.value >= 250 and cg.value >= 250 and cb.value >= 250
                    out.art.append(ArtPath(bbox, lbox, curved, bool(fill_mode.value), white))
        elif obj.type == raw.FPDF_PAGEOBJ_SHADING:
            # a gradient: no colour or path to reproduce; artwork rendering carries it
            if raw.FPDFPageObj_GetBounds(obj, l, b, r, t):
                bbox, lbox = _bounds_both(mapper, obj, l.value, b.value, r.value, t.value)
                if lbox.width >= 1 and lbox.height >= 1:
                    out.art.append(ArtPath(bbox, lbox, True, True, False, shading=True))
        elif obj.type == raw.FPDF_PAGEOBJ_IMAGE:
            img_k += 1
            image_id = f"p{out.index}-img-{img_k}"
            if not raw.FPDFPageObj_GetBounds(obj, l, b, r, t):
                continue
            bbox, lbox = _bounds_both(mapper, obj, l.value, b.value, r.value, t.value)
            try:
                bmp = obj.get_bitmap(render=True)
                png = bitmap_to_png(bmp.buffer, bmp.width, bmp.height, bmp.stride,
                                    _fmt_name(bmp), bmp.rev_byteorder)
                out.images.append(ImageRegion(image_id, bbox, lbox, png, bmp.width, bmp.height, z=z_index))
            except Exception as exc:  # noqa: BLE001 - report, never drop silently
                out.warnings.append({"code": "IMAGE_NOT_EXTRACTED", "page": out.index,
                                     "object_id": image_id, "detail": type(exc).__name__})


def _segments_to_rules(obj, mapper: _Mapper, out: PageExtract, width: float, px, py) -> None:
    n = raw.FPDFPath_CountSegments(obj)
    if n <= 1:
        return
    m = obj.get_matrix()
    start = None  # subpath start for closepath
    prev = None
    for i in range(n):
        seg = raw.FPDFPath_GetPathSegment(obj, i)
        if not seg or not raw.FPDFPathSegment_GetPoint(seg, px, py):
            prev = None
            continue
        kind = raw.FPDFPathSegment_GetType(seg)
        x, y = px.value, py.value
        pt = (m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f)
        if kind == raw.FPDF_SEGMENT_MOVETO:
            start = pt
        elif kind == raw.FPDF_SEGMENT_LINETO and prev is not None:
            _emit_rule(obj, mapper, out, prev, pt, width)
        if kind == raw.FPDF_SEGMENT_LINETO and raw.FPDFPathSegment_GetClose(seg) and start is not None:
            _emit_rule(obj, mapper, out, pt, start, width)
        prev = pt if kind != raw.FPDF_SEGMENT_BEZIERTO else None


def _emit_rule(obj, mapper: _Mapper, out: PageExtract, p0, p1, width: float) -> None:
    (x0, y0), (x1, y1) = p0, p1
    half = width / 2
    if abs(y1 - y0) <= 0.5 and abs(x1 - x0) > 4:
        l, r = min(x0, x1), max(x0, x1)
        bbox, lbox = _bounds_both(mapper, obj, l, y0 - half, r, y0 + half)
    elif abs(x1 - x0) <= 0.5 and abs(y1 - y0) > 4:
        b, t = min(y0, y1), max(y0, y1)
        bbox, lbox = _bounds_both(mapper, obj, x0 - half, b, x0 + half, t)
    else:
        return
    orientation = "h" if lbox.width >= lbox.height else "v"
    rgb, z = _paint(obj, stroke=True)
    out.rules.append(Rule(bbox, lbox, orientation, rgb, z))


def _paint(obj, stroke: bool) -> tuple[tuple[int, int, int], int]:
    """The object's stroke or fill colour and its paint order (set while extracting)."""
    cr = ctypes.c_uint(); cg = ctypes.c_uint(); cb = ctypes.c_uint(); ca = ctypes.c_uint()
    fn = raw.FPDFPageObj_GetStrokeColor if stroke else raw.FPDFPageObj_GetFillColor
    rgb = (cr.value, cg.value, cb.value) if fn(obj, cr, cg, cb, ca) else (0, 0, 0)
    return rgb, _PAINT_Z[0]


_PAINT_Z = [-1]


def _fmt_name(bmp) -> str:
    return {raw.FPDFBitmap_Gray: "Gray", raw.FPDFBitmap_BGR: "BGR",
            raw.FPDFBitmap_BGRx: "BGRx", raw.FPDFBitmap_BGRA: "BGRA"}[bmp.format]


def _extract_links(snapshot: Snapshot, page, mapper: _Mapper, out: PageExtract) -> None:
    pos = ctypes.c_int(0)
    link = raw.FPDF_LINK()
    rect = raw.FS_RECTF()
    k = 0
    while raw.FPDFLink_Enumerate(page, pos, link):
        k += 1
        if not raw.FPDFLink_GetAnnotRect(link, rect):
            continue
        bbox, lbox = mapper.both(rect.left, rect.bottom, rect.right, rect.top)
        uri = None
        dest_page = None
        action = raw.FPDFLink_GetAction(link)
        if action:
            atype = raw.FPDFAction_GetType(action)
            if atype == raw.PDFACTION_URI:
                n = raw.FPDFAction_GetURIPath(snapshot.pdf, action, None, 0)
                if n > 1:
                    buf = ctypes.create_string_buffer(n)
                    raw.FPDFAction_GetURIPath(snapshot.pdf, action, buf, n)
                    uri = buf.raw[:n - 1].decode("utf-8", "replace")
            elif atype == raw.PDFACTION_GOTO:
                dest = raw.FPDFAction_GetDest(snapshot.pdf, action)
                if dest:
                    dest_page = raw.FPDFDest_GetDestPageIndex(snapshot.pdf, dest) + 1
        else:
            dest = raw.FPDFLink_GetDest(snapshot.pdf, link)
            if dest:
                dest_page = raw.FPDFDest_GetDestPageIndex(snapshot.pdf, dest) + 1
        out.links.append(Link(f"p{out.index}-link-{k}", bbox, lbox, uri, dest_page))


def _extract_annotations(snapshot: Snapshot, page, mapper: _Mapper, out: PageExtract) -> None:
    formenv = snapshot.pdf.formenv
    rect = raw.FS_RECTF()
    count = raw.FPDFPage_GetAnnotCount(page)
    for a in range(count):
        annot = raw.FPDFPage_GetAnnot(page, a)
        if not annot:
            continue
        try:
            subtype = raw.FPDFAnnot_GetSubtype(annot)
            aid = f"p{out.index}-annot-{a}"
            has_rect = raw.FPDFAnnot_GetRect(annot, rect)
            if has_rect:
                bbox, lbox = mapper.both(rect.left, rect.bottom, rect.right, rect.top)
            else:
                bbox = lbox = BBox(0, 0, 0, 0)
            if subtype == raw.FPDF_ANNOT_WIDGET:
                if formenv is None:
                    out.warnings.append({"code": "WIDGET_WITHOUT_FORM", "page": out.index, "object_id": aid})
                    continue
                ftype = raw.FPDFAnnot_GetFormFieldType(formenv, annot)
                name = _utf16(raw.FPDFAnnot_GetFormFieldName, formenv, annot)
                value = _utf16(raw.FPDFAnnot_GetFormFieldValue, formenv, annot)
                label = _utf16(raw.FPDFAnnot_GetFormFieldAlternateName, formenv, annot) or None
                checked = None
                export_value = None
                if ftype in (raw.FPDF_FORMFIELD_CHECKBOX, raw.FPDF_FORMFIELD_RADIOBUTTON):
                    checked = bool(raw.FPDFAnnot_IsChecked(formenv, annot))
                    export_value = _utf16(raw.FPDFAnnot_GetFormFieldExportValue, formenv, annot) or None
                out.widgets.append(Widget(aid, bbox, lbox, name, _FIELD_TYPES.get(ftype, f"unknown-{ftype}"),
                                          value, label, checked, export_value))
            elif subtype in _MARKUP_KINDS:
                # text markup (highlight, underline, squiggly, strike-out): the glyphs
                # under its quads carry it as typography; a note on it is a comment too
                _collect_markup(annot, subtype, mapper, out)
                text = _utf16_annot_string(annot, b"Contents")
                if text.strip() and subtype in _COMMENT_KINDS:
                    author = _utf16_annot_string(annot, b"T") or None
                    modified = _utf16_annot_string(annot, b"M") or None
                    out.comments.append(Comment(aid, bbox, lbox, _COMMENT_KINDS[subtype], text, author, modified))
            elif subtype in _COMMENT_KINDS:
                text = _utf16_annot_string(annot, b"Contents")
                author = _utf16_annot_string(annot, b"T") or None
                modified = _utf16_annot_string(annot, b"M") or None
                out.comments.append(Comment(aid, bbox, lbox, _COMMENT_KINDS[subtype], text, author, modified))
            # Link and Popup annotations are handled elsewhere / intentionally skipped.
        finally:
            raw.FPDFPage_CloseAnnot(annot)


_MARKUP_KINDS = {raw.FPDF_ANNOT_HIGHLIGHT: "highlight", raw.FPDF_ANNOT_UNDERLINE: "underline",
                 raw.FPDF_ANNOT_SQUIGGLY: "underline", raw.FPDF_ANNOT_STRIKEOUT: "strike"}


def _collect_markup(annot, subtype: int, mapper: "_Mapper", out: PageExtract) -> None:
    kind = _MARKUP_KINDS[subtype]
    cr = ctypes.c_uint(); cg = ctypes.c_uint(); cb = ctypes.c_uint(); ca = ctypes.c_uint()
    rgb = (255, 255, 0)   # a highlight's colour when the annotation carries none PDFium can read
    if raw.FPDFAnnot_GetColor(annot, raw.FPDFANNOT_COLORTYPE_Color, cr, cg, cb, ca):
        rgb = (cr.value, cg.value, cb.value)
    quad = raw.FS_QUADPOINTSF()
    boxes = []
    for q in range(raw.FPDFAnnot_CountAttachmentPoints(annot)):
        if raw.FPDFAnnot_GetAttachmentPoints(annot, q, quad):
            xs = (quad.x1, quad.x2, quad.x3, quad.x4); ys = (quad.y1, quad.y2, quad.y3, quad.y4)
            boxes.append(mapper.lbox(min(xs), min(ys), max(xs), max(ys)))
    if not boxes:
        rect = raw.FS_RECTF()
        if raw.FPDFAnnot_GetRect(annot, rect):
            boxes.append(mapper.lbox(rect.left, rect.bottom, rect.right, rect.top))
    for b in boxes:
        out.markups.append((kind, b, rgb))


def _apply_markups(out: PageExtract) -> None:
    """Glyphs whose centre lies in a text-markup annotation's quad take its
    typography: highlight colour, underline or strike-through."""
    if not out.markups:
        return
    for c in out.chars:
        cx, cy = c.lbox.cx, c.lbox.cy
        for kind, b, rgb in out.markups:
            if b.x0 - 0.5 <= cx <= b.x1 + 0.5 and b.y0 - 0.5 <= cy <= b.y1 + 0.5:
                if kind == "highlight":
                    c.highlight = rgb  # type: ignore[attr-defined]
                elif kind == "strike":
                    c.strike = True  # type: ignore[attr-defined]
                else:
                    c.underline = True


def sample_fill_colours(snapshot: Snapshot, page: PageExtract, scale: float = 1.0) -> int:
    """Give each shading fill the colour the page actually shows inside it (the
    dominant rendered colour): a translucent overlay, a blend mode or a soft
    mask changes what the reader sees, and a bar behind text is reproduced as
    seen, not as the object's own colour (a dark box rendered light blue would
    otherwise hide its dark text). Page backgrounds, fills under pictures and
    rotated pages are left alone. Returns the number of fills recoloured."""
    if page.rotation % 360 or not page.fills:
        return 0
    W, H = page.layout_width, page.layout_height
    cands = [f for f in page.fills if not f.white and f.alpha >= 200 and f.lbox.width >= 4 and f.lbox.height >= 2.5]

    def covered(outer: BBox, inner: BBox) -> float:
        ix = max(0.0, min(outer.x1, inner.x1) - max(outer.x0, inner.x0))
        iy = max(0.0, min(outer.y1, inner.y1) - max(outer.y0, inner.y0))
        return ix * iy / max(outer.width * outer.height, 1e-6)

    if not cands:
        return 0
    pil = _page_or_raise(snapshot, page.index).render(scale=scale, may_draw_forms=True).to_pil().convert("RGB")
    changed = 0
    for f in cands:
        x0 = int(max(0.0, (f.lbox.x0 + 1) * scale)); y0 = int(max(0.0, (f.lbox.y0 + 1) * scale))
        x1 = int(min(pil.width, (f.lbox.x1 - 1) * scale)); y1 = int(min(pil.height, (f.lbox.y1 - 1) * scale))
        if x1 - x0 < 2 or y1 - y0 < 2:
            continue
        crop = pil.crop((x0, y0, x1, y1))
        colours = crop.getcolors(crop.width * crop.height) or []
        if not colours:
            continue
        count, mode = max(colours, key=lambda c: c[0])
        # pixels near the dominant colour count with it (anti-aliasing, dithering)
        near = sum(c for c, col in colours if all(abs(a - b) <= 12 for a, b in zip(col, mode)))
        if near < 0.5 * crop.width * crop.height:
            # no dominant colour: what lies under the fill shows through (a blend
            # mode or soft mask over a photograph) or it is a gradient; keep the
            # object's colour and remember that it is not an opaque cover
            f.blended = True
            continue
        if f.lbox.width * f.lbox.height > 0.5 * W * H:
            continue   # a page background keeps its object colour (its render is mostly text and pictures)
        if any(covered(f.lbox, im.lbox) >= 0.6 for im in page.images):
            continue   # under a picture: the render shows the picture, not the fill
        if sum(abs(a - b) for a, b in zip(mode, f.rgb)) > 40:
            f.rgb = tuple(int(v) for v in mode); changed += 1
    return changed


def render_page_gray(snapshot: Snapshot, index: int, scale: float = 1.0):
    """Render a page with PDFium (rotation applied) and return (gray bytes, w, h)."""
    page = _page_or_raise(snapshot, index)
    bmp = page.render(scale=scale, may_draw_forms=True)
    w, h, stride = bmp.width, bmp.height, bmp.stride
    fmt = _fmt_name(bmp)
    mv = memoryview(bmp.buffer).cast("B")
    gray = bytearray(w * h)
    nch = {"Gray": 1, "BGR": 3, "BGRx": 4, "BGRA": 4}[fmt]
    for y in range(h):
        row = mv[y * stride:y * stride + w * nch]
        if nch == 1:
            gray[y * w:(y + 1) * w] = row
        else:
            b, g, r = row[0::nch], row[1::nch], row[2::nch]
            if bmp.rev_byteorder:
                r, b = b, r
            for x in range(w):
                gray[y * w + x] = (r[x] * 299 + g[x] * 587 + b[x] * 114) // 1000
    return bytes(gray), w, h


def _renders_flat(pil, box: BBox, rgb, scale: float) -> bool:
    """True when at least 90 % of the rendered pixels in ``box`` lie within 40
    per channel of ``rgb`` (the fill really covers what is under it)."""
    x0 = int(max(0.0, box.x0 * scale)); y0 = int(max(0.0, box.y0 * scale))
    x1 = int(min(pil.width, box.x1 * scale)); y1 = int(min(pil.height, box.y1 * scale))
    if x1 - x0 < 2 or y1 - y0 < 2:
        return True
    crop = pil.crop((x0, y0, x1, y1))
    px = crop.tobytes(); n = (x1 - x0) * (y1 - y0)
    near = 0
    for i in range(0, len(px), 3):
        if abs(px[i] - rgb[0]) <= 40 and abs(px[i + 1] - rgb[1]) <= 40 and abs(px[i + 2] - rgb[2]) <= 40:
            near += 1
    return near >= 0.9 * n


_SYMBOL_PUA = {
    # Wingdings and Symbol glyphs arrive as private-use code points (U+F0xx)
    # from PDFs made by Office: the characters they stand for
    "wingdings": {0xA7: "\u25aa", 0xA8: "\u25a1", 0xB7: "\u2022", 0x6C: "\u25cf", 0x6E: "\u25a0", 0x75: "\u25c6",
                  0x76: "\u2756", 0x77: "\u25c7", 0xD8: "\u27a2", 0xE0: "\u21e8", 0xFC: "\u2713", 0xFE: "\u2612",
                  0xFD: "\u2717", 0xA1: "\u25cb", 0x9F: "\u2022", 0x6F: "\u25a1", 0x71: "\u2751", 0x72: "\u2752"},
    "symbol": {0xB7: "\u2022", 0xD8: "\u00b7", 0xB4: "\u00d7", 0xB1: "\u00b1", 0xA3: "\u2264", 0xB3: "\u2265",
               0xB9: "\u2260", 0xAE: "\u2192", 0xAC: "\u2190", 0xD6: "\u221a", 0xA5: "\u221e", 0xB0: "\u00b0"},
}


def _symbol_pua(font_name: str, cp: int) -> str | None:
    low = font_name.lower()
    table = None
    if "wingding" in low:
        table = _SYMBOL_PUA["wingdings"]
    elif "symbol" in low:
        table = _SYMBOL_PUA["symbol"]
    return table.get(cp & 0xFF) if table else None


def _drop_hidden_images(out, page=None, snapshot=None) -> None:
    """An image painted over completely by a later opaque rectangle is invisible
    in the PDF (a background repainted over a placeholder photo); it is not
    placed, and the decision is reported. A fill painted with a blend mode or a
    soft mask lets the picture show through, so the render has the last word:
    the page is rendered without its text and the picture is hidden only if its
    region comes out as the flat fill colour."""
    pil = None
    keep = []
    for im in out.images:
        ib = im.lbox
        area = max(ib.width * ib.height, 1e-6)
        hidden = False
        for f in out.fills:
            if f.z <= im.z or f.alpha < 250:
                continue
            fb = f.lbox
            ix = max(0.0, min(fb.x1, ib.x1) - max(fb.x0, ib.x0)); iy = max(0.0, min(fb.y1, ib.y1) - max(fb.y0, ib.y0))
            if ix * iy >= 0.9 * area:
                hidden = True
                if page is not None:
                    if pil is None:
                        try:
                            from .artwork import clean_page
                            src = clean_page(snapshot, out.index, drop_images=False) or page
                            pil = src.render(scale=0.5, may_draw_forms=True).to_pil().convert("RGB")
                        except Exception:  # noqa: BLE001
                            pil = False
                    if pil:
                        hidden = _renders_flat(pil, im.bbox, f.rgb, 0.5)
                break
        if hidden:
            out.warnings.append({"code": "IMAGE_HIDDEN", "page": out.index, "object_id": im.image_id,
                                 "detail": "covered by a later opaque fill; not visible in the source"})
        else:
            keep.append(im)
    out.images[:] = keep
