"""Print production: preflight profiles, printer marks, transparency
flattening (page rasterization), ink manager (spot → process mapping) and
hairline fixes.

Flattening here rasterizes each page that uses transparency at the chosen
resolution (vector content becomes an image; the page's original text is
kept as an invisible, searchable layer). Acrobat's flattener keeps vectors
where it can; this implementation trades that for predictability.
"""
from datetime import date
import math
from pathlib import Path

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require
from transforms import op, query
from transforms.content import (form_xobject, place_form, remove_overlays, visual_matrix, visual_size,
                                page_box, fmt, invert, apply, rotation)
from transforms.fonts import EmbeddedFont
from transforms.optimize import walk, image_placements, effective_dpi, _page_images, _space_kind, _strip_javascript
from transforms import pdfa

PROFILES = {
    "commercial": {"title": "Commercial print (PDF/X-4 readiness)", "min_dpi": 225, "warn_dpi": 300, "rgb": "warning",
                   "transparency": "warning", "trim": "error", "hairline": 0.25, "annotations": "warning",
                   "standard": "PDF/X-4"},
    "digital": {"title": "Digital printing", "min_dpi": 150, "warn_dpi": 200, "rgb": None, "transparency": None,
                "trim": None, "hairline": 0.25, "annotations": None, "standard": None},
    "web": {"title": "Online publishing", "max_dpi": 200, "rgb": None, "transparency": None, "trim": None,
            "hairline": None, "annotations": None, "standard": None},
    "archive": {"title": "Archiving (PDF/A-2b readiness)", "min_dpi": None, "rgb": None, "transparency": None,
                "trim": None, "hairline": None, "annotations": None, "standard": "PDF/A-2b"},
}


# ---------------------------------------------------------------- functions

class _PS:
    """Minimal PostScript calculator (Type 4 function) evaluator."""

    def __init__(self, source):
        tokens = source.replace("{", " { ").replace("}", " } ").split()
        self.program, rest = self._parse(tokens, 0)

    def _parse(self, tokens, i):
        out = []
        require(tokens and tokens[i] == "{", "UNSUPPORTED_FUNCTION", "Unsupported tint transform.")
        i += 1
        while i < len(tokens):
            t = tokens[i]
            if t == "{":
                block, i = self._parse(tokens, i)
                out.append(block)
                continue
            if t == "}":
                return out, i + 1
            try:
                out.append(float(t) if any(c in t for c in ".eE") else int(t))
            except ValueError:
                out.append(t)
            i += 1
        return out, i

    def run(self, inputs):
        stack = list(inputs)
        self._exec(self.program, stack)
        return stack

    def _exec(self, program, s):
        for item in program:
            if isinstance(item, list):
                s.append(item)
                continue
            if not isinstance(item, str):
                s.append(item)
                continue
            if item == "true":
                s.append(True)
            elif item == "false":
                s.append(False)
            elif item in ("add", "sub", "mul", "div", "idiv", "mod", "exp", "atan", "eq", "ne", "gt", "ge", "lt",
                          "le", "and", "or", "xor", "bitshift"):
                b, a = s.pop(), s.pop()
                s.append({
                    "add": lambda: a + b, "sub": lambda: a - b, "mul": lambda: a * b,
                    "div": lambda: a / b if b else 0.0, "idiv": lambda: int(a) // int(b) if b else 0,
                    "mod": lambda: int(a) % int(b) if b else 0, "exp": lambda: math.pow(a, b) if a >= 0 else 0.0,
                    "atan": lambda: math.degrees(math.atan2(a, b)) % 360, "eq": lambda: a == b, "ne": lambda: a != b,
                    "gt": lambda: a > b, "ge": lambda: a >= b, "lt": lambda: a < b, "le": lambda: a <= b,
                    "and": lambda: a and b if isinstance(a, bool) else int(a) & int(b),
                    "or": lambda: a or b if isinstance(a, bool) else int(a) | int(b),
                    "xor": lambda: a != b if isinstance(a, bool) else int(a) ^ int(b),
                    "bitshift": lambda: int(a) << int(b) if b >= 0 else int(a) >> -int(b)}[item]())
            elif item in ("neg", "abs", "ceiling", "floor", "round", "truncate", "sqrt", "sin", "cos", "ln", "log",
                          "cvi", "cvr", "not"):
                a = s.pop()
                s.append({
                    "neg": lambda: -a, "abs": lambda: abs(a), "ceiling": lambda: math.ceil(a),
                    "floor": lambda: math.floor(a), "round": lambda: math.floor(a + 0.5), "truncate": lambda: math.trunc(a),
                    "sqrt": lambda: math.sqrt(max(a, 0)), "sin": lambda: math.sin(math.radians(a)),
                    "cos": lambda: math.cos(math.radians(a)), "ln": lambda: math.log(a) if a > 0 else 0.0,
                    "log": lambda: math.log10(a) if a > 0 else 0.0, "cvi": lambda: int(a), "cvr": lambda: float(a),
                    "not": lambda: (not a) if isinstance(a, bool) else ~int(a)}[item]())
            elif item == "dup":
                s.append(s[-1])
            elif item == "pop":
                s.pop()
            elif item == "exch":
                s[-1], s[-2] = s[-2], s[-1]
            elif item == "copy":
                n = int(s.pop())
                s.extend(s[-n:] if n else [])
            elif item == "index":
                n = int(s.pop())
                s.append(s[-1 - n])
            elif item == "roll":
                j, n = int(s.pop()), int(s.pop())
                if n:
                    part = s[-n:]
                    j %= n
                    s[-n:] = part[-j:] + part[:-j] if j else part
            elif item == "if":
                proc, cond = s.pop(), s.pop()
                if cond:
                    self._exec(proc, s)
            elif item == "ifelse":
                other, proc, cond = s.pop(), s.pop(), s.pop()
                self._exec(proc if cond else other, s)
            else:
                raise EngineError("UNSUPPORTED_FUNCTION", f"Unsupported tint transform operator {item}.")


def evaluate(function, t):
    """Evaluate a 1-input PDF function; returns a list of outputs clipped to Range."""
    ftype = int(function.get("/FunctionType", -1))
    domain = [float(v) for v in function.get("/Domain", [0, 1])]
    t = min(max(t, domain[0]), domain[1])
    if ftype == 2:
        c0 = [float(v) for v in function.get("/C0", [0])]
        c1 = [float(v) for v in function.get("/C1", [1])]
        n = float(function.get("/N", 1))
        out = [a + (t ** n) * (b - a) for a, b in zip(c0, c1)]
    elif ftype == 4:
        out = [float(v) for v in _PS(function.read_bytes().decode("latin-1")).run([t])]
    elif ftype == 0:
        size = int(function.Size[0])
        bits = int(function.BitsPerSample)
        rng = [float(v) for v in function.Range]
        outs = len(rng) // 2
        enc = [float(v) for v in function.get("/Encode", [0, size - 1])]
        dec = [float(v) for v in function.get("/Decode", rng)]
        data = function.read_bytes()
        e = enc[0] + (t - domain[0]) * (enc[1] - enc[0]) / ((domain[1] - domain[0]) or 1)
        e = min(max(e, 0), size - 1)
        i0 = int(math.floor(e))
        i1 = min(i0 + 1, size - 1)
        frac = e - i0
        maxv = (1 << bits) - 1

        def sample(i, j):
            index = i * outs + j
            if bits == 8:
                return data[index]
            if bits == 16:
                return int.from_bytes(data[index * 2:index * 2 + 2], "big")
            raise EngineError("UNSUPPORTED_FUNCTION", "Unsupported sampled tint transform.")

        out = []
        for j in range(outs):
            v = sample(i0, j) * (1 - frac) + sample(i1, j) * frac
            out.append(dec[2 * j] + v * (dec[2 * j + 1] - dec[2 * j]) / maxv)
    elif ftype == 3:
        functions = list(function.Functions)
        bounds = [float(v) for v in function.get("/Bounds", [])]
        encode = [float(v) for v in function.Encode]
        k = 0
        while k < len(bounds) and t >= bounds[k]:
            k += 1
        lo = domain[0] if k == 0 else bounds[k - 1]
        hi = domain[1] if k == len(bounds) else bounds[k]
        e0, e1 = encode[2 * k], encode[2 * k + 1]
        tt = e0 + (t - lo) * (e1 - e0) / ((hi - lo) or 1)
        return evaluate(functions[k], tt)
    else:
        raise EngineError("UNSUPPORTED_FUNCTION", "Unsupported tint transform.")
    rng = function.get("/Range")
    if rng is not None:
        r = [float(v) for v in rng]
        out = [min(max(v, r[2 * i]), r[2 * i + 1]) for i, v in enumerate(out[:len(r) // 2])]
    return out


# ---------------------------------------------------------------- inks

def _separations(pdf):
    """name -> list of (resource dict, key, colorspace array)."""
    found = {}
    holders = [p.obj for p in pdf.pages] + [o for o in pdf.objects if isinstance(o, pikepdf.Stream)
                                             and o.get("/Subtype") == Name.Form]
    for page in pdf.pages:
        for annot in page.obj.get("/Annots", []):
            ap = annot.get("/AP") if isinstance(annot, pikepdf.Dictionary) else None
            if isinstance(ap, pikepdf.Dictionary) and isinstance(ap.get("/N"), pikepdf.Stream):
                holders.append(ap.N)
    for holder in holders:
        res = holder.get("/Resources")
        if not isinstance(res, pikepdf.Dictionary):
            continue
        spaces = res.get("/ColorSpace")
        if not isinstance(spaces, pikepdf.Dictionary):
            continue
        for key, space in spaces.items():
            if isinstance(space, pikepdf.Array) and len(space) == 4 and space[0] == Name.Separation:
                name = str(space[1])[1:]
                if name not in ("All", "None"):
                    found.setdefault(name, []).append((res, key, space))
            elif isinstance(space, pikepdf.Array) and len(space) >= 4 and space[0] == Name.DeviceN:
                for n in space[1]:
                    name = str(n)[1:]
                    if name not in ("Cyan", "Magenta", "Yellow", "Black", "None", "All"):
                        found.setdefault(name, [])
    return found


@query("inks")
def inks(ctx):
    pdf = ctx.pdf
    usage = pdfa._usage(pdf)
    seps = _separations(pdf)
    spots = []
    for name in sorted(set(seps) | usage["spots"]):
        entries = seps.get(name, [])
        alternate = str(entries[0][2][2])[1:] if entries and isinstance(entries[0][2][2], pikepdf.Name) else \
            ("ICCBased" if entries else "DeviceN")
        preview = None
        if entries:
            try:
                values = evaluate(entries[0][2][3], 1.0)
                preview = {"space": alternate, "values": values}
            except EngineError:
                pass
        spots.append({"name": name, "alternate": alternate, "mappable": bool(entries), "preview": preview})
    process = [c for c, used in (("Cyan", usage["cmyk"]), ("Magenta", usage["cmyk"]), ("Yellow", usage["cmyk"]),
                                  ("Black", usage["cmyk"] or usage["gray"])) if used]
    return {"process": process, "spots": spots, "rgb": usage["rgb"]}


def _alt_ops(space, values, stroke):
    alt = space[2]
    if alt == Name.DeviceCMYK:
        return [pikepdf.ContentStreamInstruction([float(v) for v in values[:4]], pikepdf.Operator("K" if stroke else "k"))]
    if alt == Name.DeviceRGB:
        return [pikepdf.ContentStreamInstruction([float(v) for v in values[:3]], pikepdf.Operator("RG" if stroke else "rg"))]
    if alt == Name.DeviceGray:
        return [pikepdf.ContentStreamInstruction([float(values[0])], pikepdf.Operator("G" if stroke else "g"))]
    return None


@op("map_spots_to_process")
def map_spots_to_process(ctx, names=None):
    """Replace Separation colors (content operators and images) by their
    alternate process values. Shadings/patterns in spot colors are reported."""
    pdf = ctx.pdf
    seps = _separations(pdf)
    targets = set(seps) if names is None else set(names)
    spaces = {}
    for name in targets:
        for res, key, space in seps.get(name, []):
            if space[2] in (Name.DeviceCMYK, Name.DeviceRGB, Name.DeviceGray):
                spaces[(res.objgen if res.is_indirect else id(res), str(key))] = space
    converted, unsupported = 0, 0

    def rewrite(stream, res):
        nonlocal converted, unsupported
        if not isinstance(res, pikepdf.Dictionary):
            return
        cs = res.get("/ColorSpace")
        if not isinstance(cs, pikepdf.Dictionary):
            return
        local = {}
        for key, space in cs.items():
            if isinstance(space, pikepdf.Array) and len(space) == 4 and space[0] == Name.Separation and \
                    str(space[1])[1:] in targets and space[2] in (Name.DeviceCMYK, Name.DeviceRGB, Name.DeviceGray):
                local[str(key)] = space
        if not local:
            return
        try:
            instructions = pikepdf.parse_content_stream(stream)
        except pikepdf.PdfError:
            return
        out, current = [], {False: None, True: None}
        changed = False
        for item in instructions:
            if isinstance(item, pikepdf.ContentStreamInlineImage):
                out.append(item)
                continue
            operator = str(item.operator)
            if operator in ("cs", "CS") and item.operands:
                stroke = operator == "CS"
                space = local.get(str(item.operands[0]))
                current[stroke] = space
                if space is not None:
                    changed = True
                    continue
            elif operator in ("scn", "SCN", "sc", "SC") and current[operator.isupper()] is not None and item.operands:
                space = current[operator.isupper()]
                try:
                    values = evaluate(space[3], float(item.operands[0]))
                except EngineError:
                    unsupported += 1
                    out.append(item)
                    continue
                replacement = _alt_ops(space, values, operator.isupper())
                if replacement:
                    out.extend(replacement)
                    converted += 1
                    changed = True
                    continue
            elif operator in ("rg", "RG", "k", "K", "g", "G"):
                current[operator.isupper()] = None
            out.append(item)
        if changed:
            stream.write(pikepdf.unparse_content_stream(out))

    for page in pdf.pages:
        res = page.obj.get("/Resources")
        contents = page.obj.get("/Contents")
        if contents is None:
            continue
        if isinstance(contents, pikepdf.Array):
            joined = b"\n".join(s.read_bytes() for s in contents)
            merged = pdf.make_indirect(pikepdf.Stream(pdf, joined))
            page.obj.Contents = merged
            contents = merged
        rewrite(contents, res)
    for obj in list(pdf.objects):
        if isinstance(obj, pikepdf.Stream) and obj.get("/Subtype") == Name.Form:
            rewrite(obj, obj.get("/Resources"))
    images = 0
    from PIL import Image
    for obj in list(pdf.objects):
        if not (isinstance(obj, pikepdf.Stream) and obj.get("/Subtype") == Name.Image):
            continue
        space = obj.get("/ColorSpace")
        if not (isinstance(space, pikepdf.Array) and len(space) == 4 and space[0] == Name.Separation
                and str(space[1])[1:] in targets):
            continue
        alt = space[2]
        if alt not in (Name.DeviceCMYK, Name.DeviceRGB, Name.DeviceGray) or int(obj.get("/BitsPerComponent", 8)) != 8:
            unsupported += 1
            continue
        try:
            raw = obj.read_bytes()
            gray = Image.frombytes("L", (int(obj.Width), int(obj.Height)), raw[:int(obj.Width) * int(obj.Height)])
            lut = [evaluate(space[3], i / 255) for i in range(256)]
            channels = [gray.point([round(v[c] * 255) for v in lut]) for c in range(len(lut[0]))]
            mode = {4: "CMYK", 3: "RGB", 1: "L"}[len(channels)]
            merged = Image.merge(mode, channels) if len(channels) > 1 else channels[0]
            import zlib
            obj.write(zlib.compress(merged.tobytes(), 9), filter=Name.FlateDecode)
            obj.ColorSpace = alt
            if "/Decode" in obj:
                del obj["/Decode"]
            images += 1
        except (EngineError, ValueError, pikepdf.PdfError):
            unsupported += 1
    return {"converted": converted, "images": images, "unsupported": unsupported}


# ---------------------------------------------------------------- marks

REGISTRATION = None


def _registration_space(pdf):
    fn = pikepdf.Dictionary(FunctionType=2, Domain=[0, 1], C0=[0, 0, 0, 0], C1=[1, 1, 1, 1], N=1)
    return pdf.make_indirect(pikepdf.Array([Name.Separation, Name.All, Name.DeviceCMYK, fn]))


@op("printer_marks")
def printer_marks(ctx, pages=None, crop=True, bleed_marks=True, registration=True, color_bars=True,
                  page_info=True, bleed=9.0, offset=6.0, weight=0.25, title=None):
    """Add printer marks outside the trim/bleed area. The MediaBox grows to
    hold them; TrimBox and BleedBox are set; CropBox shows the marks."""
    pdf = ctx.pdf
    indexes = range(len(pdf.pages)) if pages is None else pages
    bleed, offset, weight = float(bleed), float(offset), float(weight)
    require(0 <= bleed <= 72 and 0 <= offset <= 36 and 0.05 <= weight <= 2, "INVALID_ARGUMENT", "Invalid mark settings.")
    font = EmbeddedFont(pdf, {"family": "sans"}) if page_info else None
    reg = _registration_space(pdf)
    margin = bleed + offset + 30
    count = len(pdf.pages)
    for index in indexes:
        page = pdf.pages[index]
        obj = page.obj
        _remove_marks(pdf, page)
        trim = [float(v) for v in obj.get("/TrimBox", obj.get("/ArtBox", page_box(page, "/CropBox")))]
        tx0, ty0, tx1, ty1 = min(trim[0], trim[2]), min(trim[1], trim[3]), max(trim[0], trim[2]), max(trim[1], trim[3])
        bx0, by0, bx1, by1 = tx0 - bleed, ty0 - bleed, tx1 + bleed, ty1 + bleed
        original_media = [float(v) for v in page_box(page, "/MediaBox")]
        media = [min(original_media[0], bx0 - offset - 30), min(original_media[1], by0 - offset - 30),
                 max(original_media[2], bx1 + offset + 30), max(original_media[3], by1 + offset + 30)]
        ops = [f"/Reg cs /Reg CS 1 scn 1 SCN {fmt(weight)} w"]
        length = 18.0
        if crop:
            o = bleed + offset
            for x, y, sx, sy in ((tx0, ty0, -1, -1), (tx1, ty0, 1, -1), (tx0, ty1, -1, 1), (tx1, ty1, 1, 1)):
                ops.append(f"{fmt(x + sx * o)} {fmt(y)} m {fmt(x + sx * (o + length))} {fmt(y)} l S")
                ops.append(f"{fmt(x)} {fmt(y + sy * o)} m {fmt(x)} {fmt(y + sy * (o + length))} l S")
        if bleed_marks and bleed > 0:
            for x, y, sx, sy in ((bx0, by0, -1, -1), (bx1, by0, 1, -1), (bx0, by1, -1, 1), (bx1, by1, 1, 1)):
                ops.append(f"{fmt(x + sx * 2)} {fmt(y)} m {fmt(x + sx * 10)} {fmt(y)} l S")
                ops.append(f"{fmt(x)} {fmt(y + sy * 2)} m {fmt(x)} {fmt(y + sy * 10)} l S")
        if registration:
            r = 6.0
            d = bleed + offset + 12
            cx, cy = (tx0 + tx1) / 2, (ty0 + ty1) / 2
            for x, y in ((cx, ty1 + d), (cx, ty0 - d), (tx0 - d, cy), (tx1 + d, cy)):
                k = 0.5523 * r
                ops.append(f"{fmt(x + r)} {fmt(y)} m {fmt(x + r)} {fmt(y + k)} {fmt(x + k)} {fmt(y + r)} {fmt(x)} {fmt(y + r)} c "
                           f"{fmt(x - k)} {fmt(y + r)} {fmt(x - r)} {fmt(y + k)} {fmt(x - r)} {fmt(y)} c "
                           f"{fmt(x - r)} {fmt(y - k)} {fmt(x - k)} {fmt(y - r)} {fmt(x)} {fmt(y - r)} c "
                           f"{fmt(x + k)} {fmt(y - r)} {fmt(x + r)} {fmt(y - k)} {fmt(x + r)} {fmt(y)} c S")
                ops.append(f"{fmt(x - r * 1.6)} {fmt(y)} m {fmt(x + r * 1.6)} {fmt(y)} l S "
                           f"{fmt(x)} {fmt(y - r * 1.6)} m {fmt(x)} {fmt(y + r * 1.6)} l S")
        if color_bars:
            size = 10.0
            y = ty1 + bleed + offset + 4
            x = tx0 + 24
            patches = [(1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1), (1, 1, 0, 0), (1, 0, 1, 0), (0, 1, 1, 0),
                       (0, 0, 0, 0.25), (0, 0, 0, 0.5), (0, 0, 0, 0.75)]
            for n, (c, m, yy, k) in enumerate(patches):
                if x + (n + 1) * size > tx1 - 24:
                    break
                ops.append(f"{c} {m} {yy} {k} k {fmt(x + n * size)} {fmt(y)} {fmt(size)} {fmt(size)} re f")
            ops.append("/Reg cs 1 scn")
        if page_info and font is not None:
            label = f"{title or 'Document'}  Page {index + 1} of {count}  {date.today().isoformat()}"
            ops.append(f"BT /F1 6 Tf 1 0 0 1 {fmt(tx0)} {fmt(by0 - offset - 14)} Tm {font.encode(label)} Tj ET")
        res = pikepdf.Dictionary(ColorSpace=pikepdf.Dictionary(Reg=reg))
        if font is not None:
            res.Font = pikepdf.Dictionary(F1=font.ref)
        form = form_xobject(pdf, "\n".join(ops).encode(), media, res, "PrinterMarks")
        form.ZPDFMedia = pikepdf.Array(original_media)
        crop_box = obj.get("/CropBox")
        form.ZPDFCrop = pikepdf.Array([float(v) for v in crop_box]) if crop_box is not None else Name.None_
        place_form(pdf, page, form, (1, 0, 0, 1, 0, 0), prefix="ZPDFpm")
        obj.MediaBox = pikepdf.Array(media)
        obj.CropBox = pikepdf.Array(media)
        obj.TrimBox = pikepdf.Array([tx0, ty0, tx1, ty1])
        obj.BleedBox = pikepdf.Array([bx0, by0, bx1, by1])
    if font is not None:
        font.finish()
    return {"pages": len(list(indexes))}


def _remove_marks(pdf, page):
    from transforms.content import resources
    xobjects = resources(page).get("/XObject", pikepdf.Dictionary())
    original = None
    for value in xobjects.values():
        if isinstance(value, pikepdf.Stream) and str(value.get("/ZPDFKind", "")) == "/PrinterMarks":
            original = (value.get("/ZPDFMedia"), value.get("/ZPDFCrop"))
    removed = remove_overlays(pdf, page, "PrinterMarks")
    if removed and original and original[0] is not None:
        page.obj.MediaBox = pikepdf.Array([float(v) for v in original[0]])
        if isinstance(original[1], pikepdf.Array):
            page.obj.CropBox = pikepdf.Array([float(v) for v in original[1]])
        elif "/CropBox" in page.obj:
            del page.obj["/CropBox"]
    return removed


@op("remove_printer_marks")
def remove_printer_marks(ctx, pages=None):
    pdf = ctx.pdf
    indexes = range(len(pdf.pages)) if pages is None else pages
    return {"removed": sum(_remove_marks(pdf, pdf.pages[i]) for i in indexes)}


# ---------------------------------------------------------------- flattening

def _words_from_text(doc_page, page):
    """Existing text as OCR-style word boxes in visual space (for searchability)."""
    tp = doc_page.get_textpage()
    count = tp.count_chars()
    m = invert(visual_matrix(page))
    lines, line, word, box = [], [], "", None
    last_bottom = None

    def flush_word():
        nonlocal word, box
        if word.strip() and box:
            x0, y0 = apply(m, box[0], box[1])
            x1, y1 = apply(m, box[2], box[3])
            line.append({"t": word.strip(), "b": [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]})
        word, box = "", None

    text = tp.get_text_range(0, count) if count else ""
    for i in range(min(count, len(text))):
        ch = text[i]
        if ch in (" ", "\t", "\r", "\n", "\x02"):
            flush_word()
            if ch in ("\r", "\n") and line:
                lines.append(line)
                line = []
            continue
        l, b, r, t = tp.get_charbox(i)
        if box is None:
            box = [l, b, r, t]
        else:
            box = [min(box[0], l), min(box[1], b), max(box[2], r), max(box[3], t)]
        word += ch
        last_bottom = b
    flush_word()
    if line:
        lines.append(line)
    tp.close()
    del last_bottom
    return lines


@op("flatten_transparency")
def flatten_transparency(ctx, pages=None, dpi=300, keep_text=True):
    """Rasterize pages that use transparency (or `pages`) at `dpi`."""
    from transforms.ocr import ocr_text_layer
    pdf = ctx.pdf
    require(72 <= int(dpi) <= 1200, "INVALID_ARGUMENT", "Choose 72–1200 dpi.")
    targets = sorted(pdfa._usage(pdf)["transparency"]) if pages is None else list(pages)
    if not targets:
        return {"pages": 0}
    layers = []
    with ctx.pdfium() as doc:
        for index in targets:
            dp = doc[index]
            image = dp.render(scale=int(dpi) / 72, draw_annots=False, may_draw_forms=False).to_pil().convert("RGB")
            path = ctx.scratch(".png")
            image.save(path)
            if keep_text:
                lines = _words_from_text(dp, pdf.pages[index])
                if lines:
                    layers.append({"page": index, "lines": lines})
            dp.close()
            from transforms.ocr import replace_page_image
            replace_page_image(ctx, [{"page": index, "path": str(path)}])
    if layers:
        ocr_text_layer(ctx, layers)
    return {"pages": len(targets), "dpi": int(dpi)}


@op("fix_hairlines")
def fix_hairlines(ctx, min_width=0.25):
    """Raise stroke widths thinner than `min_width` points (CTM-aware)."""
    pdf = ctx.pdf
    minimum = float(min_width)
    fixed = 0

    def rewrite(stream, ctm0=(1, 0, 0, 1, 0, 0)):
        nonlocal fixed
        try:
            instructions = pikepdf.parse_content_stream(stream)
        except pikepdf.PdfError:
            return
        from transforms.optimize import _mul
        ctm, stack, out, changed = ctm0, [], [], False
        for item in instructions:
            if isinstance(item, pikepdf.ContentStreamInlineImage):
                out.append(item)
                continue
            operator = str(item.operator)
            if operator == "q":
                stack.append(ctm)
            elif operator == "Q" and stack:
                ctm = stack.pop()
            elif operator == "cm" and len(item.operands) == 6:
                ctm = _mul(tuple(float(v) for v in item.operands), ctm)
            elif operator == "w" and item.operands:
                scale = math.sqrt(abs(ctm[0] * ctm[3] - ctm[1] * ctm[2])) or 1
                width = float(item.operands[0])
                if width * scale < minimum:
                    out.append(pikepdf.ContentStreamInstruction([round(minimum / scale, 4)], pikepdf.Operator("w")))
                    fixed += 1
                    changed = True
                    continue
            out.append(item)
        if changed:
            stream.write(pikepdf.unparse_content_stream(out))

    for page in pdf.pages:
        contents = page.obj.get("/Contents")
        if contents is None:
            continue
        if isinstance(contents, pikepdf.Array):
            merged = pdf.make_indirect(pikepdf.Stream(pdf, b"\n".join(s.read_bytes() for s in contents)))
            page.obj.Contents = merged
            contents = merged
        rewrite(contents)
    for obj in list(pdf.objects):
        if isinstance(obj, pikepdf.Stream) and obj.get("/Subtype") == Name.Form and "/ZPDFKind" not in obj:
            rewrite(obj)
        elif isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == Name.ExtGState and "/LW" in obj:
            if float(obj.LW) < minimum:
                obj.LW = minimum
                fixed += 1
    return {"fixed": fixed}


# ---------------------------------------------------------------- preflight

def _result(results, rid, title, severity, detail="", pages=None, fix=None):
    results.append({"id": rid, "title": title, "severity": severity, "detail": detail,
                    "pages": sorted(set(pages or []))[:200], "fix": fix})


@query("preflight")
def preflight(ctx, profile="commercial"):
    require(profile in PROFILES, "INVALID_ARGUMENT", "Unknown preflight profile.")
    settings = PROFILES[profile]
    pdf = ctx.pdf
    results = []
    usage = pdfa._usage(pdf)
    version = str(pdf.pdf_version)
    _result(results, "version", f"PDF version {version}", "info")
    if pdf.is_encrypted:
        _result(results, "encryption", "Document is encrypted", "error" if profile != "web" else "warning")
    missing = [f for f in usage["fonts"].values() if not pdfa._font_embedded(f)]
    if missing:
        names = sorted({pdfa._font_name(f) for f in missing})
        _result(results, "fonts", f"{len(names)} font(s) not embedded", "error" if profile != "web" else "warning",
                ", ".join(names), fix="embed_fonts")
    else:
        _result(results, "fonts", "All fonts embedded", "pass", f"{len(usage['fonts'])} font(s)")
    # Images
    placements = image_placements(pdf)
    low, high, seen = [], [], set()
    for index, page in enumerate(pdf.pages):
        for xobj in _page_images(page):
            if xobj.objgen in seen:
                continue
            seen.add(xobj.objgen)
            dpi = effective_dpi(xobj, placements.get(xobj.objgen))
            if dpi is None or int(xobj.get("/Width", 0)) * int(xobj.get("/Height", 0)) < 64:
                continue
            page_of = placements[xobj.objgen].page
            if settings.get("min_dpi") and dpi < settings["min_dpi"]:
                low.append((page_of, dpi))
            if settings.get("max_dpi") and dpi > settings["max_dpi"]:
                high.append((page_of, dpi))
    if settings.get("min_dpi"):
        if low:
            worst = min(d for _, d in low)
            _result(results, "resolution", f"{len(low)} image(s) below {settings['min_dpi']} dpi",
                    "error" if profile == "commercial" else "warning", f"Lowest effective resolution {round(worst)} dpi",
                    [p for p, _ in low])
        else:
            _result(results, "resolution", f"Image resolution ≥ {settings['min_dpi']} dpi", "pass")
    if settings.get("max_dpi"):
        if high:
            _result(results, "resolution", f"{len(high)} image(s) above {settings['max_dpi']} dpi", "warning",
                    "Downsampling reduces file size for screen use.", [p for p, _ in high], fix="downsample")
        else:
            _result(results, "resolution", "Images are sized for screen use", "pass")
    spaces = [n for n, used in (("RGB", usage["rgb"]), ("CMYK", usage["cmyk"]), ("Gray", usage["gray"])) if used]
    _result(results, "color", "Color spaces: " + (", ".join(spaces) or "none"), "info")
    if usage["rgb"] and settings.get("rgb"):
        _result(results, "rgb", "RGB color is used", settings["rgb"],
                "Commercial print expects CMYK or ICC-based color; PDF/X-4 accepts RGB with a profile.",
                fix="convert_pdfx")
    if usage["spots"]:
        _result(results, "spots", f"{len(usage['spots'])} spot color(s)", "warning" if profile != "commercial" else "info",
                ", ".join(sorted(usage["spots"])), fix="map_spots")
    if usage["transparency"]:
        severity = settings.get("transparency") or "info"
        _result(results, "transparency", f"Transparency on {len(usage['transparency'])} page(s)", severity,
                "Flattening rasterizes those pages.", sorted(usage["transparency"]), fix="flatten")
    if settings.get("hairline"):
        thin = []

        def visit(kind, page, **data):
            if kind == "stroke" and data["width"] < settings["hairline"]:
                thin.append(page)
        walk(pdf, visit, include_annotations=False)
        if thin:
            _result(results, "hairlines", f"{len(thin)} line(s) thinner than {settings['hairline']} pt", "warning",
                    pages=thin, fix="hairlines")
        else:
            _result(results, "hairlines", "No hairlines", "pass")
    if settings.get("trim"):
        no_trim = [i for i, p in enumerate(pdf.pages) if "/TrimBox" not in p.obj and "/ArtBox" not in p.obj]
        if no_trim:
            _result(results, "trim", f"{len(no_trim)} page(s) without a TrimBox", settings["trim"], pages=no_trim,
                    fix="set_trim")
        else:
            _result(results, "trim", "TrimBox set on every page", "pass")
    annotated = [i for i, p in enumerate(pdf.pages)
                 if any(isinstance(a, pikepdf.Dictionary) and a.get("/Subtype") not in (Name.Link, Name.Popup)
                        for a in p.obj.get("/Annots", []))]
    if annotated and settings.get("annotations"):
        _result(results, "annotations", f"Annotations or form fields on {len(annotated)} page(s)",
                settings["annotations"], "They may not print as expected; flatten them for output.",
                annotated, fix="flatten_annotations")
    names = pdf.Root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/JavaScript" in names or \
            isinstance(pdf.Root.get("/OpenAction"), pikepdf.Dictionary) and pdf.Root.OpenAction.get("/S") == Name.JavaScript:
        _result(results, "javascript", "JavaScript present", "warning" if profile != "archive" else "error",
                fix="remove_javascript")
    overprint = False
    for obj in pdf.objects:
        if isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == Name.ExtGState and \
                (obj.get("/OP") is True or obj.get("/op") is True):
            overprint = True
            break
    if overprint:
        _result(results, "overprint", "Overprinting is used", "info", "Check with Output Preview.")
    sizes = {tuple(round(v) for v in visual_size(p)) for p in pdf.pages}
    if len(sizes) > 1:
        _result(results, "sizes", f"{len(sizes)} different page sizes", "info" if profile != "commercial" else "warning")
    if settings.get("standard"):
        report = pdfa.validate_standard(ctx, settings["standard"])
        if report["compliant"]:
            _result(results, "standard", f"Meets {settings['standard']} checks", "pass")
        else:
            for issue in report["issues"]:
                if issue["rule"] in ("fonts",):
                    continue
                _result(results, "standard", issue["message"], issue["severity"],
                        f"{settings['standard']} rule: {issue['rule']}",
                        fix="convert_pdfx" if settings["standard"] == "PDF/X-4" else "convert_pdfa")
    order = {"error": 0, "warning": 1, "info": 2, "pass": 3}
    results.sort(key=lambda r: order[r["severity"]])
    return {"profile": profile, "title": settings["title"], "results": results,
            "errors": sum(r["severity"] == "error" for r in results),
            "warnings": sum(r["severity"] == "warning" for r in results)}


@op("set_trim_to_crop")
def set_trim_to_crop(ctx, pages=None):
    """Give pages without a TrimBox (or ArtBox) a TrimBox equal to the CropBox."""
    pdf = ctx.pdf
    indexes = range(len(pdf.pages)) if pages is None else pages
    changed = 0
    for index in indexes:
        page = pdf.pages[index]
        if "/TrimBox" not in page.obj and "/ArtBox" not in page.obj:
            page.obj.TrimBox = pikepdf.Array(list(page_box(page, "/CropBox")))
            changed += 1
    return {"pages": changed}


# "remove_javascript" is registered by properties.py (all scripts or by id).


@op("embed_fonts")
def embed_fonts(ctx):
    embedded, failed = pdfa.embed_missing_fonts(ctx.pdf)
    if failed and not embedded:
        raise EngineError("FONT_NOT_EMBEDDABLE", "No substitute fonts were found: " +
                          ", ".join(sorted({f["font"] for f in failed})) + ".")
    return {"embedded": embedded, "failed": failed}
