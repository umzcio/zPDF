"""Widget appearance streams (so saved forms render without /NeedAppearances).

Text uses the AcroForm standard fonts from /DR (/Helv, /TiRo, /Cour and bold
variants, WinAnsi). Values with characters outside WinAnsi get a subset of
a Unicode system font embedded in that appearance only. Metrics come from
the metric-compatible macOS fonts (Arial = Helvetica, Times New Roman =
Times, Courier New = Courier).
"""
from functools import lru_cache
from pathlib import Path

import pikepdf
from pikepdf import Name

from transforms.content import fmt

STANDARD_FONTS = {
    "Helv": ("Helvetica", "/System/Library/Fonts/Supplemental/Arial.ttf"),
    "HeBo": ("Helvetica-Bold", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    "TiRo": ("Times-Roman", "/System/Library/Fonts/Supplemental/Times New Roman.ttf"),
    "TiBo": ("Times-Bold", "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf"),
    "Cour": ("Courier", "/System/Library/Fonts/Supplemental/Courier New.ttf"),
    "CoBo": ("Courier-Bold", "/System/Library/Fonts/Supplemental/Courier New Bold.ttf"),
}
ZAPF = {"check": "4", "circle": "l", "cross": "8", "diamond": "u", "square": "n", "star": "H"}
SELECTION = (0.6, 0.75, 0.86)


@lru_cache(maxsize=8)
def _metrics(path):
    try:
        from fontTools.ttLib import TTFont
        if not Path(path).exists():
            return None
        font = TTFont(path, lazy=False)
        try:
            cmap = font.getBestCmap() or {}
            hmtx = font["hmtx"].metrics
            units = font["head"].unitsPerEm
            return {code: hmtx[name][0] / units for code, name in cmap.items() if name in hmtx}
        finally:
            font.close()
    except Exception:
        return None


def text_width(text, font="Helv", size=12):
    widths = _metrics(STANDARD_FONTS.get(font, STANDARD_FONTS["Helv"])[1])
    if not widths:
        return len(text) * size * (0.6 if font.startswith("Co") else 0.5)
    return sum(widths.get(ord(c), 0.5) for c in text) * size


def winansi(text):
    try:
        text.encode("cp1252")
        return True
    except UnicodeEncodeError:
        return False


def literal(text):
    raw = text.encode("cp1252", errors="replace")
    return "(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)").replace(b"\r", b"\\r").decode("latin-1") + ")"


def ensure_resources(pdf, acro):
    """/DR with the standard form fonts; returns the /Font dictionary."""
    dr = acro.get("/DR")
    if dr is None:
        dr = pikepdf.Dictionary()
        acro.DR = dr
    fonts = dr.get("/Font")
    if fonts is None:
        fonts = pikepdf.Dictionary()
        dr.Font = fonts
    for key, (base, _) in STANDARD_FONTS.items():
        if "/" + key not in fonts:
            fonts[Name("/" + key)] = pdf.make_indirect(pikepdf.Dictionary(
                Type=Name.Font, Subtype=Name.Type1, BaseFont=Name("/" + base), Encoding=Name.WinAnsiEncoding))
    if "/ZaDb" not in fonts:
        fonts.ZaDb = pdf.make_indirect(pikepdf.Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.ZapfDingbats))
    if "/DA" not in acro:
        acro.DA = pikepdf.String("/Helv 0 Tf 0 g")
    return fonts


def parse_da(da):
    """(font key, size, color ops) from a /DA string."""
    text = str(da or "/Helv 0 Tf 0 g")
    font, size = "Helv", 0.0
    tokens = text.split()
    color = "0 g"
    for i, token in enumerate(tokens):
        if token == "Tf" and i >= 2:
            font = tokens[i - 2].lstrip("/")
            try:
                size = float(tokens[i - 1])
            except ValueError:
                size = 0.0
        if token in ("g", "rg", "k"):
            count = {"g": 1, "rg": 3, "k": 4}[token]
            color = " ".join(tokens[i - count:i + 1])
    return font, size, color


def color_components(values):
    if values is None:
        return None
    values = [float(v) for v in values]
    return values


def color_op(values, stroke=False):
    if not values:
        return ""
    if len(values) == 1:
        return f"{fmt(values[0])} {'G' if stroke else 'g'}"
    if len(values) == 4:
        return f"{fmt(*values)} {'K' if stroke else 'k'}"
    return f"{fmt(*values[:3])} {'RG' if stroke else 'rg'}"


def _frame(width, height, mk, border_width, style):
    """Background and border operators (Acrobat conventions)."""
    ops = []
    bg = color_components(mk.get("/BG")) if mk is not None else None
    bc = color_components(mk.get("/BC")) if mk is not None else None
    if bg:
        ops.append(f"{color_op(bg)} 0 0 {fmt(width, height)} re f")
    if bc and border_width > 0:
        w = border_width
        if style == "/U":
            ops.append(f"{color_op(bc, True)} {fmt(w)} w 0 {fmt(w / 2)} m {fmt(width, w / 2)} l S")
        else:
            dash = "[3] 0 d " if style == "/D" else ""
            ops.append(f"{color_op(bc, True)} {dash}{fmt(w)} w {fmt(w / 2, w / 2, width - w, height - w)} re S")
            if style in ("/B", "/I"):
                light, dark = ("1 g", "0.5 g") if style == "/B" else ("0.5 g", "0.75 g")
                ops.append(f"{light} {fmt(w, w)} m {fmt(w, height - w)} l {fmt(width - w, height - w)} l "
                           f"{fmt(width - 2 * w, height - 2 * w)} l {fmt(2 * w, height - 2 * w)} l {fmt(2 * w, 2 * w)} l f")
                ops.append(f"{dark} {fmt(width - w, height - w)} m {fmt(width - w, w)} l {fmt(w, w)} l "
                           f"{fmt(2 * w, 2 * w)} l {fmt(width - 2 * w, 2 * w)} l {fmt(width - 2 * w, height - 2 * w)} l f")
    return ops


def _stream(pdf, content, width, height, resources, matrix=None):
    stream = pikepdf.Stream(pdf, content.encode("latin-1"))
    stream.Type, stream.Subtype = Name.XObject, Name.Form
    stream.BBox = pikepdf.Array([0, 0, width, height])
    stream.Resources = resources
    if matrix:
        stream.Matrix = pikepdf.Array(matrix)
    return pdf.make_indirect(stream)


def _rotation(mk):
    rotate = int(mk.get("/R", 0)) % 360 if mk is not None else 0
    return rotate


def widget_geometry(widget):
    r = [float(v) for v in widget.Rect]
    width, height = abs(r[2] - r[0]), abs(r[3] - r[1])
    mk = widget.get("/MK")
    rotate = _rotation(mk)
    matrix = None
    if rotate == 90:
        matrix = [0, 1, -1, 0, height, 0]
        width, height = height, width
    elif rotate == 180:
        matrix = [-1, 0, 0, -1, width, height]
    elif rotate == 270:
        matrix = [0, -1, 1, 0, 0, width]
        width, height = height, width
    return width, height, matrix


def _border(widget):
    bs = widget.get("/BS")
    width, style = 1.0, "/S"
    if bs is not None:
        width = float(bs.get("/W", 1))
        style = str(bs.get("/S", "/S"))
    elif "/Border" in widget:
        border = widget.Border
        width = float(border[2]) if len(border) >= 3 else 1.0
    return width, style


class TextFont:
    """Chooses /DR font or an embedded Unicode subset for one appearance."""

    def __init__(self, pdf, dr_fonts, key, text):
        self.key = key if key in STANDARD_FONTS else "Helv"
        self.embedded = None
        self.pdf = pdf
        if not winansi(text):
            from transforms.fonts import EmbeddedFont
            family = {"TiRo": "serif", "TiBo": "serif", "Cour": "mono", "CoBo": "mono"}.get(self.key, "sans")
            try:
                self.embedded = EmbeddedFont(pdf, None if family == "sans" else {"family": family})
            except Exception:
                self.embedded = None
        self.resource = self.embedded.ref if self.embedded else dr_fonts.get("/" + self.key)
        self.name = "/ZPDFU" if self.embedded else "/" + self.key

    def width(self, text, size):
        if self.embedded:
            return self.embedded.width(text, size)
        return text_width(text, self.key, size)

    def show(self, text):
        return (self.embedded.encode(text) if self.embedded else literal(text)) + " Tj"

    def finish(self):
        if self.embedded:
            self.embedded.finish()


def _wrap(text, font, size, width):
    lines = []
    for paragraph in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        words = paragraph.split(" ")
        line = ""
        for word in words:
            candidate = word if not line else line + " " + word
            if font.width(candidate, size) <= width or not line:
                line = candidate
                while font.width(line, size) > width and len(line) > 1:
                    # hard-break words longer than the field
                    cut = len(line)
                    while cut > 1 and font.width(line[:cut], size) > width:
                        cut -= 1
                    lines.append(line[:cut])
                    line = line[cut:]
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def text_appearance(pdf, widget, field_flags, text, da, quadding, dr_fonts, max_len=None, color=None):
    width, height, matrix = widget_geometry(widget)
    mk = widget.get("/MK")
    border_width, style = _border(widget)
    if mk is None or "/BC" not in mk:
        border_width = 0 if mk is None or "/BC" not in mk else border_width
    ops = _frame(width, height, mk if mk is not None else {}, border_width, style)
    font_key, size, text_color = parse_da(da)
    if color:
        text_color = color_op(color)
    multiline = bool(field_flags & (1 << 12))
    comb = bool(field_flags & (1 << 24)) and max_len and not multiline
    password = bool(field_flags & (1 << 13))
    shown = "*" * len(text) if password else text
    font = TextFont(pdf, dr_fonts, font_key, shown)
    inset = 2 + (2 * border_width if style in ("/B", "/I") else border_width)
    avail_w = max(width - 2 * inset, 1)
    avail_h = max(height - 2 * inset, 1)
    if size <= 0:
        if multiline:
            size = 12.0
            while size > 4 and len(_wrap(shown, font, size, avail_w)) * size * 1.15 > avail_h:
                size -= 0.5
        else:
            size = min(12.0, max(4.0, avail_h * 0.75 if avail_h < 16 else 12.0))
            if shown and font.width(shown, size) > avail_w:
                size = max(4.0, size * avail_w / font.width(shown, size))
    body = [f"/Tx BMC q {fmt(inset - 1 if inset > 1 else 0, inset - 1 if inset > 1 else 0, width - 2 * (inset - 1), height - 2 * (inset - 1))} re W n",
            "BT", f"{font.name} {fmt(size)} Tf", text_color]
    ascent = size * 0.8
    if comb:
        cell = width / int(max_len)
        for index, char in enumerate(shown[:int(max_len)]):
            cw = font.width(char, size)
            x = index * cell + (cell - cw) / 2
            y = (height - size) / 2 + size * 0.22
            body.append(f"1 0 0 1 {fmt(x, y)} Tm {font.show(char)}")
    elif multiline:
        leading = size * 1.15
        y = height - inset - ascent
        for line in _wrap(shown, font, size, avail_w):
            w = font.width(line, size)
            x = inset + {0: 0, 1: (avail_w - w) / 2, 2: avail_w - w}.get(quadding, 0)
            body.append(f"1 0 0 1 {fmt(x, y)} Tm {font.show(line)}")
            y -= leading
    elif shown:
        w = font.width(shown, size)
        x = inset + {0: 0, 1: (avail_w - w) / 2, 2: avail_w - w}.get(quadding, 0)
        y = (height - size) / 2 + size * 0.22
        body.append(f"1 0 0 1 {fmt(x, y)} Tm {font.show(shown)}")
    body.append("ET Q EMC")
    if comb and mk is not None and "/BC" in mk and border_width > 0:
        cell = width / int(max_len)
        dividers = " ".join(f"{fmt(cell * i, 0)} m {fmt(cell * i, height)} l" for i in range(1, int(max_len)))
        ops.append(f"{color_op(color_components(mk.BC), True)} {fmt(border_width)} w {dividers} S")
    font.finish()
    resources = pikepdf.Dictionary(Font=pikepdf.Dictionary({font.name: font.resource}))
    return _stream(pdf, "\n".join(ops + body), width, height, resources, matrix)


def choice_list_appearance(pdf, widget, options, selected, da, quadding, dr_fonts, top_index=0):
    width, height, matrix = widget_geometry(widget)
    mk = widget.get("/MK")
    border_width, style = _border(widget)
    ops = _frame(width, height, mk if mk is not None else {}, border_width if mk is not None and "/BC" in mk else 0, style)
    font_key, size, text_color = parse_da(da)
    size = size or 10.0
    font = TextFont(pdf, dr_fonts, font_key, "".join(label for label, _ in options))
    leading = size * 1.15
    inset = 2 + border_width
    y = height - inset
    body = [f"/Tx BMC q {fmt(border_width, border_width, width - 2 * border_width, height - 2 * border_width)} re W n"]
    for index, (label, export) in enumerate(options[top_index:], top_index):
        top = y
        y -= leading
        if y < -leading:
            break
        if export in selected or label in selected:
            body.append(f"{fmt(*SELECTION)} rg {fmt(border_width, y, width - 2 * border_width, leading)} re f")
        w = font.width(label, size)
        x = inset + {0: 0, 1: (width - 2 * inset - w) / 2, 2: width - 2 * inset - w}.get(quadding, 0)
        body.append(f"BT {font.name} {fmt(size)} Tf {text_color} 1 0 0 1 {fmt(x, y + size * 0.25)} Tm {font.show(label)} ET")
    body.append("Q EMC")
    font.finish()
    resources = pikepdf.Dictionary(Font=pikepdf.Dictionary({font.name: font.resource}))
    return _stream(pdf, "\n".join(ops + body), width, height, resources, matrix)


def check_appearances(pdf, widget, on_state, style, dr_fonts, color=None, radio=False):
    width, height, matrix = widget_geometry(widget)
    mk = widget.get("/MK")
    border_width, border_style = _border(widget)
    has_border = mk is not None and "/BC" in mk
    frame = []
    if radio and has_border:
        # Circular frame for radio buttons (Acrobat default look).
        r = min(width, height) / 2 - border_width / 2
        cx, cy = width / 2, height / 2
        k = 0.5523 * r
        circle = (f"{fmt(cx + r, cy)} m {fmt(cx + r, cy + k, cx + k, cy + r, cx, cy + r)} c "
                  f"{fmt(cx - k, cy + r, cx - r, cy + k, cx - r, cy)} c {fmt(cx - r, cy - k, cx - k, cy - r, cx, cy - r)} c "
                  f"{fmt(cx + k, cy - r, cx + r, cy - k, cx + r, cy)} c")
        bg = color_components(mk.get("/BG"))
        if bg:
            frame.append(f"{color_op(bg)} {circle} f")
        frame.append(f"{color_op(color_components(mk.BC), True)} {fmt(border_width)} w {circle} S")
    else:
        frame = _frame(width, height, mk if mk is not None else {}, border_width if has_border else 0, border_style)
    char = ZAPF.get(style, "4" if not radio else "l")
    if mk is not None and "/CA" in mk and str(mk.CA):
        char = str(mk.CA)[0]
    size = min(width, height) * (0.6 if char in ("l", "n", "u", "H") else 0.8)
    text_color = color_op(color) if color else "0 g"
    glyph_width = size * {"4": 0.846, "l": 0.791, "8": 0.759, "u": 0.788, "n": 0.761, "H": 0.816}.get(char, 0.8)
    x = (width - glyph_width) / 2
    y = (height - size * 0.705) / 2
    on = frame + [f"q BT /ZaDb {fmt(size)} Tf {text_color} 1 0 0 1 {fmt(x, y)} Tm ({char}) Tj ET Q"]
    resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(ZaDb=dr_fonts.ZaDb))
    on_stream = _stream(pdf, "\n".join(on), width, height, resources, matrix)
    off_stream = _stream(pdf, "\n".join(frame), width, height, pikepdf.Dictionary(), matrix)
    return pikepdf.Dictionary({"/" + on_state.lstrip("/"): on_stream, "/Off": off_stream})


def button_appearance(pdf, widget, caption, da, dr_fonts):
    width, height, matrix = widget_geometry(widget)
    mk = widget.get("/MK")
    border_width, style = _border(widget)
    ops = _frame(width, height, mk if mk is not None else {}, border_width if mk is not None and "/BC" in mk else 0, style)
    font_key, size, text_color = parse_da(da)
    font = TextFont(pdf, dr_fonts, font_key, caption)
    if size <= 0:
        size = min(12.0, max(4.0, (height - 4) * 0.7))
        if caption and font.width(caption, size) > width - 4:
            size = max(4.0, size * (width - 4) / font.width(caption, size))
    w = font.width(caption, size)
    ops.append(f"q BT {font.name} {fmt(size)} Tf {text_color} 1 0 0 1 {fmt((width - w) / 2, (height - size) / 2 + size * 0.22)} Tm {font.show(caption)} ET Q")
    font.finish()
    resources = pikepdf.Dictionary(Font=pikepdf.Dictionary({font.name: font.resource}))
    return _stream(pdf, "\n".join(ops), width, height, resources, matrix)


def barcode_appearance(pdf, widget, matrix_rows, quiet=2):
    """Vector modules for a 2-D barcode matrix (rows of 0/1)."""
    width, height, matrix = widget_geometry(widget)
    mk = widget.get("/MK")
    border_width, style = _border(widget)
    ops = _frame(width, height, mk if mk is not None else {}, border_width if mk is not None and "/BC" in mk else 0, style)
    rows = [row for row in (matrix_rows or []) if row]
    if rows:
        cols = max(len(r) for r in rows)
        module = min((width - 2 * quiet) / cols, (height - 2 * quiet) / len(rows))
        ox = (width - module * cols) / 2
        oy = (height - module * len(rows)) / 2
        rects = []
        for y, row in enumerate(rows):
            for x, bit in enumerate(row):
                if bit:
                    rects.append(f"{fmt(ox + x * module, oy + (len(rows) - 1 - y) * module, module, module)} re")
        ops.append("0 g " + " ".join(rects) + " f")
    return _stream(pdf, "\n".join(ops), width, height, pikepdf.Dictionary(), matrix)


def blank_appearance(pdf, widget):
    width, height, matrix = widget_geometry(widget)
    mk = widget.get("/MK")
    border_width, style = _border(widget)
    ops = _frame(width, height, mk if mk is not None else {}, border_width if mk is not None and "/BC" in mk else 0, style)
    return _stream(pdf, "\n".join(ops), width, height, pikepdf.Dictionary(), matrix)
