"""File-size optimization and space audit.

`optimize` downsamples and recompresses images (placement-aware: the
effective resolution is measured from every place an image is drawn),
subsets or unembeds fonts, removes optional data (metadata, thumbnails,
private application data, JavaScript, bookmarks, links, embedded files),
deduplicates identical streams, and asks the writer for object streams and
optional linearization (Fast Web View).

`space_audit` reports the bytes each category uses, like Acrobat's
"Audit space usage".
"""
from hashlib import sha256
import io
import math
import re
import zlib

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms.fonts import name_text
from transforms import op, query

STANDARD14 = {"Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
              "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
              "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Symbol", "ZapfDingbats"}
SUBSET_TAG = re.compile(r"^[A-Z]{6}\+")


# ---------------------------------------------------------------- content walking

def _mul(m, n):
    a, b, c, d, e, f = m
    A, B, C, D, E, F = n
    return (a * A + b * C, a * B + b * D, c * A + d * C, c * B + d * D, e * A + f * C + E, e * B + f * D + F)


class Placement:
    __slots__ = ("width", "height", "page")

    def __init__(self, width, height, page):
        self.width, self.height, self.page = width, height, page


def walk(pdf, visitor, pages=None, include_annotations=True):
    """Visit every page's content (and nested forms, and optionally annotation
    appearances) tracking the CTM. visitor(kind, page_index, **data):
      "image"  (xobj, ctm, inline=False)
      "stroke" (width_points)
      "gstate" (gs dict)
      "font"   (font dict, name)
      "text"   (font dict, operand)
      "color"  (space name or array, stroke flag)
    """
    indexes = range(len(pdf.pages)) if pages is None else pages
    for index in indexes:
        page = pdf.pages[index]
        res = page.obj.get("/Resources")
        if res is None:
            node = page.obj
            while res is None and "/Parent" in node:
                node = node.Parent
                res = node.get("/Resources")
        _walk_stream(page, res, (1, 0, 0, 1, 0, 0), index, visitor, 0, set())
        if include_annotations:
            for annot in page.obj.get("/Annots", []):
                if not isinstance(annot, pikepdf.Dictionary):
                    continue
                ap = annot.get("/AP")
                if not isinstance(ap, pikepdf.Dictionary):
                    continue
                normal = ap.get("/N")
                streams = [normal] if isinstance(normal, pikepdf.Stream) else \
                    [v for v in normal.values() if isinstance(v, pikepdf.Stream)] if isinstance(normal, pikepdf.Dictionary) else []
                for stream in streams:
                    _walk_stream(stream, stream.get("/Resources"), (1, 0, 0, 1, 0, 0), index, visitor, 1, set())


def _walk_stream(target, res, ctm, page_index, visitor, depth, active):
    if depth > 12:
        return
    key = target.obj.objgen if hasattr(target, "obj") else target.objgen
    if key in active and key != (0, 0):
        return
    active = active | {key}
    try:
        instructions = pikepdf.parse_content_stream(target)
    except (pikepdf.PdfError, TypeError, ValueError):
        return
    stack = []
    width = 1.0
    font = None
    xobjects = res.get("/XObject", {}) if isinstance(res, pikepdf.Dictionary) else {}
    gstates = res.get("/ExtGState", {}) if isinstance(res, pikepdf.Dictionary) else {}
    fonts = res.get("/Font", {}) if isinstance(res, pikepdf.Dictionary) else {}
    spaces = res.get("/ColorSpace", {}) if isinstance(res, pikepdf.Dictionary) else {}
    for item in instructions:
        if isinstance(item, pikepdf.ContentStreamInlineImage):
            visitor("image", page_index, xobj=item.iimage, ctm=ctm, inline=True)
            continue
        operands, operator = item.operands, str(item.operator)
        if operator == "q":
            stack.append((ctm, width))
        elif operator == "Q":
            if stack:
                ctm, width = stack.pop()
        elif operator == "cm" and len(operands) == 6:
            ctm = _mul(tuple(float(v) for v in operands), ctm)
        elif operator == "w" and operands:
            width = float(operands[0])
        elif operator in ("S", "s", "B", "B*", "b", "b*"):
            scale = math.sqrt(abs(ctm[0] * ctm[3] - ctm[1] * ctm[2]))
            visitor("stroke", page_index, width=width * scale)
        elif operator == "gs" and operands:
            gs = gstates.get(operands[0]) if isinstance(gstates, pikepdf.Dictionary) else None
            if isinstance(gs, pikepdf.Dictionary):
                if "/LW" in gs:
                    width = float(gs.LW)
                visitor("gstate", page_index, gs=gs)
        elif operator == "Tf" and operands:
            font = fonts.get(operands[0]) if isinstance(fonts, pikepdf.Dictionary) else None
            if isinstance(font, pikepdf.Dictionary):
                visitor("font", page_index, font=font, name=str(operands[0]))
        elif operator in ("Tj", "'", '"', "TJ") and font is not None:
            visitor("text", page_index, font=font, operand=operands[-1] if operands else None)
        elif operator in ("cs", "CS") and operands:
            name = operands[0]
            space = spaces.get(name, name) if isinstance(spaces, pikepdf.Dictionary) else name
            visitor("color", page_index, space=space, stroke=operator == "CS")
        elif operator in ("rg", "RG"):
            visitor("color", page_index, space=Name.DeviceRGB, stroke=operator == "RG")
        elif operator in ("k", "K"):
            visitor("color", page_index, space=Name.DeviceCMYK, stroke=operator == "K")
        elif operator in ("g", "G"):
            visitor("color", page_index, space=Name.DeviceGray, stroke=operator == "G")
        elif operator == "sh" and operands:
            shadings = res.get("/Shading", {}) if isinstance(res, pikepdf.Dictionary) else {}
            sh = shadings.get(operands[0]) if isinstance(shadings, pikepdf.Dictionary) else None
            if isinstance(sh, pikepdf.Object) and "/ColorSpace" in sh:
                visitor("color", page_index, space=sh.ColorSpace, stroke=False)
        elif operator == "Do" and operands:
            xobj = xobjects.get(operands[0]) if isinstance(xobjects, pikepdf.Dictionary) else None
            if not isinstance(xobj, pikepdf.Stream):
                continue
            subtype = xobj.get("/Subtype")
            if subtype == Name.Image:
                visitor("image", page_index, xobj=xobj, ctm=ctm, inline=False)
            elif subtype == Name.Form:
                matrix = tuple(float(v) for v in xobj.get("/Matrix", [1, 0, 0, 1, 0, 0]))
                if "/Group" in xobj:
                    visitor("group", page_index, group=xobj.Group)
                _walk_stream(xobj, xobj.get("/Resources", res), _mul(matrix, ctm), page_index, visitor, depth + 1, active)


def image_placements(pdf):
    """objgen -> largest displayed size (points) and pixel size."""
    placements = {}

    def visit(kind, page, **data):
        if kind != "image" or data.get("inline"):
            return
        xobj, m = data["xobj"], data["ctm"]
        w = math.hypot(m[0], m[1])
        h = math.hypot(m[2], m[3])
        key = xobj.objgen
        current = placements.get(key)
        if current is None or w * h > current.width * current.height:
            placements[key] = Placement(w, h, page)

    walk(pdf, visit)
    return placements


def effective_dpi(xobj, placement):
    if placement is None or placement.width <= 0 or placement.height <= 0:
        return None
    return min(int(xobj.Width) / (placement.width / 72), int(xobj.Height) / (placement.height / 72))


# ---------------------------------------------------------------- images

def _space_kind(xobj):
    space = xobj.get("/ColorSpace")
    if isinstance(space, pikepdf.Array) and len(space) and space[0] == Name.ICCBased:
        n = int(space[1].get("/N", 3))
        return {1: "gray", 3: "rgb", 4: "cmyk"}.get(n), space
    return {Name.DeviceRGB: "rgb", Name.DeviceGray: "gray", Name.DeviceCMYK: "cmyk"}.get(space), space


def _recompress_image(pdf, xobj, placement, settings):
    """Returns saved bytes (>0) or 0 when the image was left unchanged."""
    from PIL import Image
    if xobj.get("/ImageMask") is True or int(xobj.get("/BitsPerComponent", 8)) != 8:
        return 0
    if "/Decode" in xobj or "/Mask" in xobj and not isinstance(xobj.Mask, pikepdf.Stream):
        return 0
    filters = xobj.get("/Filter")
    filters = [filters] if isinstance(filters, pikepdf.Name) else list(filters or [])
    # JPEG 2000 is left as is: a malformed JPX stream can crash the image
    # decoder outright (no exception to catch), taking the helper with it.
    if any(f in (Name.JBIG2Decode, Name.CCITTFaxDecode, Name.JPXDecode) for f in filters):
        return 0
    kind, space = _space_kind(xobj)
    if kind is None:
        return 0
    original = len(xobj.read_raw_bytes())
    dpi = effective_dpi(xobj, placement)
    target = settings.get("color_dpi", 150) if kind != "gray" else settings.get("gray_dpi", settings.get("color_dpi", 150))
    threshold = float(settings.get("threshold", 1.5))
    scale = 1.0
    if target and dpi and dpi > target * threshold:
        scale = target / dpi
    to_gray = bool(settings.get("grayscale")) and kind in ("rgb", "cmyk")
    lossy = settings.get("jpeg_quality") is not None
    is_jpeg = Name.DCTDecode in filters
    if scale >= 1.0 and not to_gray and not (lossy and (not is_jpeg or settings.get("recompress_jpeg"))):
        return 0
    try:
        image = pikepdf.PdfImage(xobj).as_pil_image()
    except (pikepdf.PdfError, NotImplementedError, ValueError, OSError, pikepdf.models.image.UnsupportedImageTypeError):
        return 0
    width, height = image.size
    if scale < 1.0:
        width, height = max(1, round(width * scale)), max(1, round(height * scale))
        image = image.resize((width, height), Image.LANCZOS)
    new_space = space
    if to_gray:
        image = image.convert("RGB").convert("L") if image.mode == "CMYK" else image.convert("L")
        new_space = Name.DeviceGray
        kind = "gray"
    expected_mode = {"gray": "L", "rgb": "RGB", "cmyk": "CMYK"}[kind]
    if image.mode != expected_mode:
        if kind == "cmyk":
            return 0
        image = image.convert(expected_mode)
    buffer = io.BytesIO()
    if lossy and kind != "cmyk":
        image.save(buffer, "JPEG", quality=int(settings["jpeg_quality"]), optimize=True)
        data, flt = buffer.getvalue(), Name.DCTDecode
    else:
        data, flt = zlib.compress(image.tobytes(), 9), Name.FlateDecode
    if len(data) >= original and scale >= 1.0 and not to_gray:
        return 0
    smask = xobj.get("/SMask")
    if isinstance(smask, pikepdf.Stream) and scale < 1.0:
        try:
            mask = pikepdf.PdfImage(smask).as_pil_image().convert("L").resize((width, height), Image.LANCZOS)
            smask.write(zlib.compress(mask.tobytes(), 9), filter=Name.FlateDecode)
            smask.Width, smask.Height = width, height
            smask.BitsPerComponent = 8
            smask.ColorSpace = Name.DeviceGray
            for key in ("/DecodeParms", "/Decode", "/Matte"):
                if key in smask:
                    del smask[key]
        except (pikepdf.PdfError, NotImplementedError, ValueError, OSError):
            return 0
    elif isinstance(smask, pikepdf.Stream) and (int(smask.Width), int(smask.Height)) != (width, height):
        return 0
    xobj.write(data, filter=flt)
    for key in ("/DecodeParms", "/Interpolate"):
        if key in xobj:
            del xobj[key]
    xobj.Width, xobj.Height = width, height
    xobj.BitsPerComponent = 8
    xobj.ColorSpace = new_space
    return max(0, original - len(data))


# ---------------------------------------------------------------- fonts

def _base_name(font):
    return SUBSET_TAG.sub("", name_text(font.get("/BaseFont"))[1:])


def _descriptor(font):
    if font.get("/Subtype") == Name.Type0:
        kids = font.get("/DescendantFonts")
        if isinstance(kids, pikepdf.Array) and len(kids):
            return kids[0].get("/FontDescriptor"), kids[0]
        return None, None
    return font.get("/FontDescriptor"), font


def _unembed_standard14(font):
    if font.get("/Subtype") not in (Name.Type1, Name.TrueType, Name.MMType1):
        return 0
    name = _base_name(font)
    standard = name if name in STANDARD14 else None
    if standard is None:
        return 0
    descriptor = font.get("/FontDescriptor")
    if not isinstance(descriptor, pikepdf.Dictionary):
        return 0
    saved = 0
    for key in ("/FontFile", "/FontFile2", "/FontFile3"):
        if key in descriptor:
            try:
                saved += len(descriptor[key].read_raw_bytes())
            except pikepdf.PdfError:
                pass
            del descriptor[key]
    if saved:
        font.BaseFont = Name("/" + standard)
        font.Subtype = Name.Type1
        descriptor.FontName = Name("/" + standard)
    return saved


def _used_codes(pdf):
    """font objgen -> set of byte codes (simple fonts) or 2-byte codes (Type0)."""
    used = {}

    def add(font, operand):
        codes = used.setdefault(font.objgen, set())
        strings = []
        if isinstance(operand, pikepdf.Array):
            strings = [bytes(x) for x in operand if isinstance(x, pikepdf.String)]
        elif isinstance(operand, pikepdf.String):
            strings = [bytes(operand)]
        wide = font.get("/Subtype") == Name.Type0
        for raw in strings:
            if wide:
                codes.update(int.from_bytes(raw[i:i + 2], "big") for i in range(0, len(raw) - 1, 2))
            else:
                codes.update(raw)

    def visit(kind, page, **data):
        if kind == "text" and data.get("operand") is not None:
            add(data["font"], data["operand"])
        elif kind == "font":
            used.setdefault(data["font"].objgen, set())

    walk(pdf, visit)
    return used


def _subset_font(pdf, font, codes):
    """Subset an embedded, not-yet-subset TrueType font program to used glyphs."""
    from fontTools.ttLib import TTFont
    from fontTools import subset
    from fontTools import agl
    descriptor, cid = _descriptor(font)
    if not isinstance(descriptor, pikepdf.Dictionary) or "/FontFile2" not in descriptor:
        return 0
    if SUBSET_TAG.match(name_text(font.get("/BaseFont"))[1:]) or not codes:
        return 0
    stream = descriptor.FontFile2
    try:
        original = stream.read_bytes()
        tt = TTFont(io.BytesIO(original), lazy=False)
    except Exception:  # noqa: BLE001 - leave unreadable fonts untouched
        return 0
    order = tt.getGlyphOrder()
    gids = {0}
    if font.get("/Subtype") == Name.Type0:
        mapping = cid.get("/CIDToGIDMap", Name.Identity) if cid is not None else Name.Identity
        if mapping != Name.Identity:
            return 0
        gids.update(c for c in codes if c < len(order))
    else:
        cmap_table = tt["cmap"] if "cmap" in tt else None
        encoding = font.get("/Encoding")
        differences = {}
        if isinstance(encoding, pikepdf.Dictionary) and "/Differences" in encoding:
            code = 0
            for item in encoding.Differences:
                if isinstance(item, int):
                    code = int(item)
                else:
                    differences[code] = str(item)[1:]
                    code += 1
        for code in codes:
            gid = None
            name = differences.get(code)
            if name and name in tt.getReverseGlyphMap():
                gid = tt.getGlyphID(name)
            if gid is None and cmap_table is not None:
                for table in cmap_table.tables:
                    if table.platformID == 3 and table.platEncID == 0:
                        g = table.cmap.get(0xF000 + code) or table.cmap.get(code)
                        if g:
                            gid = tt.getGlyphID(g)
                            break
                    if table.platformID == 1 and table.platEncID == 0 and code in table.cmap:
                        gid = tt.getGlyphID(table.cmap[code])
                        break
                if gid is None:
                    char = name and agl.toUnicode(name) or bytes([code]).decode("cp1252", errors="ignore")
                    best = tt.getBestCmap() or {}
                    if char and ord(char[0]) in best:
                        gid = tt.getGlyphID(best[ord(char[0])])
            if gid is None:
                return 0  # cannot prove which glyph a code uses; keep the full font
            gids.add(gid)
    options = subset.Options()
    options.retain_gids = True
    options.notdef_outline = True
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.glyph_names = True
    options.layout_features = ["*"]
    options.drop_tables += ["DSIG"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(gids=sorted(gids))
    try:
        subsetter.subset(tt)
        out = io.BytesIO()
        tt.save(out)
    except Exception:  # noqa: BLE001
        return 0
    data = out.getvalue()
    if len(data) >= len(original):
        return 0
    stream.write(data, filter=Name.FlateDecode)
    for key in ("/Length1",):
        if key in stream:
            del stream[key]
    stream.Length1 = len(data)
    tag = "".join(chr(65 + b % 26) for b in sha256(repr(sorted(gids)).encode()).digest()[:6]) + "+"
    base = name_text(font.get("/BaseFont"), "/Font")[1:]
    font.BaseFont = Name("/" + tag + base)
    if cid is not None and cid is not font:
        cid.BaseFont = font.BaseFont
    descriptor.FontName = font.BaseFont
    return len(original) - len(data)


# ---------------------------------------------------------------- removal

def _strip_javascript(pdf):
    removed = 0
    root = pdf.Root
    names = root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/JavaScript" in names:
        del names["/JavaScript"]
        removed += 1

    def is_js(action):
        return isinstance(action, pikepdf.Dictionary) and action.get("/S") in (Name.JavaScript, Name("/Launch"))

    if is_js(root.get("/OpenAction")):
        del root["/OpenAction"]
        removed += 1
    holders = [root] + [p.obj for p in pdf.pages]
    for page in pdf.pages:
        holders += [a for a in page.obj.get("/Annots", []) if isinstance(a, pikepdf.Dictionary)]
    acro = root.get("/AcroForm")
    if isinstance(acro, pikepdf.Dictionary):
        stack = list(acro.get("/Fields", []))
        seen = set()
        while stack:
            node = stack.pop()
            if not isinstance(node, pikepdf.Dictionary) or node.objgen in seen:
                continue
            seen.add(node.objgen)
            holders.append(node)
            stack.extend(node.get("/Kids", []))
    for holder in holders:
        aa = holder.get("/AA")
        if isinstance(aa, pikepdf.Dictionary):
            for key in list(aa.keys()):
                if is_js(aa[key]):
                    del aa[key]
                    removed += 1
            if not len(aa):
                del holder["/AA"]
        if is_js(holder.get("/A")):
            del holder["/A"]
            removed += 1
    return removed


def _remove(pdf, what):
    counts = {}
    root = pdf.Root
    if what.get("metadata"):
        n = 0
        if "/Metadata" in root:
            del root["/Metadata"]
            n += 1
        for obj in pdf.objects:
            if isinstance(obj, (pikepdf.Dictionary, pikepdf.Stream)) and "/Metadata" in obj and obj.objgen != root.objgen:
                try:
                    del obj["/Metadata"]
                    n += 1
                except (pikepdf.PdfError, KeyError):
                    pass
        info = pdf.trailer.get("/Info")
        if isinstance(info, pikepdf.Dictionary):
            for key in list(info.keys()):
                if key not in ("/Title",) or what.get("title"):
                    del info[key]
        counts["metadata"] = n
    if what.get("thumbnails"):
        n = 0
        for page in pdf.pages:
            if "/Thumb" in page.obj:
                del page.obj["/Thumb"]
                n += 1
        counts["thumbnails"] = n
    if what.get("private_data"):
        n = 0
        for obj in [root] + [p.obj for p in pdf.pages] + list(pdf.objects):
            if isinstance(obj, (pikepdf.Dictionary, pikepdf.Stream)) and "/PieceInfo" in obj:
                try:
                    del obj["/PieceInfo"]
                    n += 1
                except (pikepdf.PdfError, KeyError):
                    pass
        counts["private_data"] = n
    if what.get("javascript"):
        counts["javascript"] = _strip_javascript(pdf)
    if what.get("bookmarks"):
        n = 1 if "/Outlines" in root else 0
        if n:
            del root["/Outlines"]
        if root.get("/PageMode") == Name.UseOutlines:
            root.PageMode = Name.UseNone
        counts["bookmarks"] = n
    if what.get("links"):
        n = 0
        for page in pdf.pages:
            annots = page.obj.get("/Annots")
            if annots is None:
                continue
            kept = [a for a in annots if not (isinstance(a, pikepdf.Dictionary) and a.get("/Subtype") == Name.Link)]
            n += len(annots) - len(kept)
            page.obj.Annots = pikepdf.Array(kept)
        counts["links"] = n
    if what.get("embedded_files"):
        n = 0
        names = root.get("/Names")
        if isinstance(names, pikepdf.Dictionary) and "/EmbeddedFiles" in names:
            del names["/EmbeddedFiles"]
            n += 1
        for key in ("/Collection", "/AF"):
            if key in root:
                del root[key]
        for page in pdf.pages:
            annots = page.obj.get("/Annots")
            if annots is None:
                continue
            kept = [a for a in annots if not (isinstance(a, pikepdf.Dictionary) and a.get("/Subtype") == Name.FileAttachment)]
            n += len(annots) - len(kept)
            page.obj.Annots = pikepdf.Array(kept)
        counts["embedded_files"] = n
    if what.get("structure"):
        n = 0
        if "/StructTreeRoot" in root:
            del root["/StructTreeRoot"]
            n = 1
        if "/MarkInfo" in root:
            del root["/MarkInfo"]
        for page in pdf.pages:
            if "/StructParents" in page.obj:
                del page.obj["/StructParents"]
        counts["structure"] = n
    return counts


def _dedupe_streams(pdf):
    """Point identical image XObjects and font programs at one copy."""
    canonical = {}
    saved = 0

    def fingerprint(stream):
        try:
            raw = stream.read_raw_bytes()
        except pikepdf.PdfError:
            return None, 0
        keys = sorted((k, repr(v)) for k, v in stream.items() if k not in ("/Length",))
        return sha256(raw + repr(keys).encode()).hexdigest(), len(raw)

    def canon(stream):
        nonlocal saved
        if not isinstance(stream, pikepdf.Stream) or not stream.is_indirect:
            return stream
        digest, size = fingerprint(stream)
        if digest is None:
            return stream
        existing = canonical.setdefault(digest, stream)
        if existing.objgen != stream.objgen:
            saved += size
            return existing
        return stream

    seen = set()
    holders = [p.obj for p in pdf.pages] + [o for o in pdf.objects if isinstance(o, pikepdf.Stream) and o.get("/Subtype") == Name.Form]
    for holder in holders:
        res = holder.get("/Resources")
        if not isinstance(res, pikepdf.Dictionary) or res.objgen in seen and res.objgen != (0, 0):
            continue
        seen.add(res.objgen)
        xobjects = res.get("/XObject")
        if isinstance(xobjects, pikepdf.Dictionary):
            for key in list(xobjects.keys()):
                value = xobjects[key]
                if isinstance(value, pikepdf.Stream) and value.get("/Subtype") == Name.Image:
                    xobjects[key] = canon(value)
    for obj in pdf.objects:
        if isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == Name.FontDescriptor:
            for key in ("/FontFile", "/FontFile2", "/FontFile3"):
                if key in obj:
                    obj[key] = canon(obj[key])
    return saved


# ---------------------------------------------------------------- operation

PRESETS = {
    "high": {"images": {"color_dpi": 225, "gray_dpi": 225, "jpeg_quality": 85, "threshold": 1.5}},
    "medium": {"images": {"color_dpi": 150, "gray_dpi": 150, "jpeg_quality": 70, "threshold": 1.5}},
    "low": {"images": {"color_dpi": 96, "gray_dpi": 96, "jpeg_quality": 50, "threshold": 1.3}},
}


@op("optimize")
def optimize(ctx, preset=None, images=None, fonts=None, remove=None, compress=True, linearize=False):
    """images: {"color_dpi", "gray_dpi", "threshold", "jpeg_quality" (None = lossless),
    "grayscale", "recompress_jpeg"} or False; fonts: {"subset", "unembed_standard14"};
    remove: {"metadata", "thumbnails", "private_data", "javascript", "bookmarks",
    "links", "embedded_files", "structure"}."""
    pdf = ctx.pdf
    settings = dict(PRESETS.get(preset, {}).get("images", {})) if preset else {}
    require(preset is None or preset in PRESETS, "INVALID_ARGUMENT", "Unknown optimization preset.")
    if isinstance(images, dict):
        settings.update(images)
    report = {"images": 0, "image_bytes_saved": 0, "fonts_subset": 0, "fonts_unembedded": 0, "font_bytes_saved": 0}
    if images is not False and settings:
        placements = image_placements(pdf)
        done = set()
        for page in pdf.pages:
            for xobj in _page_images(page):
                if xobj.objgen in done:
                    continue
                done.add(xobj.objgen)
                saved = _recompress_image(pdf, xobj, placements.get(xobj.objgen), settings)
                if saved:
                    report["images"] += 1
                    report["image_bytes_saved"] += saved
    fonts = fonts or {}
    if fonts.get("unembed_standard14") or fonts.get("subset"):
        codes = _used_codes(pdf) if fonts.get("subset") else {}
        for obj in list(pdf.objects):
            if not isinstance(obj, pikepdf.Dictionary) or obj.get("/Type") != Name.Font:
                continue
            if fonts.get("unembed_standard14"):
                saved = _unembed_standard14(obj)
                if saved:
                    report["fonts_unembedded"] += 1
                    report["font_bytes_saved"] += saved
                    continue
            if fonts.get("subset") and obj.objgen in codes:
                saved = _subset_font(pdf, obj, codes[obj.objgen])
                if saved:
                    report["fonts_subset"] += 1
                    report["font_bytes_saved"] += saved
    report["removed"] = _remove(pdf, remove or {})
    report["dedupe_bytes_saved"] = _dedupe_streams(pdf)
    if compress:
        ctx.save_options.update(object_stream_mode=pikepdf.ObjectStreamMode.generate, compress_streams=True,
                                recompress_flate=True)
    if linearize:
        ctx.save_options["linearize"] = True
    return report


def _page_images(page):
    """Image XObjects used by a page, including those nested in forms."""
    out, stack, seen = [], [page.obj.get("/Resources")], set()
    node = page.obj
    while stack[0] is None and "/Parent" in node:
        node = node.Parent
        stack[0] = node.get("/Resources")
    while stack:
        res = stack.pop()
        if not isinstance(res, pikepdf.Dictionary):
            continue
        xobjects = res.get("/XObject")
        if not isinstance(xobjects, pikepdf.Dictionary):
            continue
        for value in xobjects.values():
            if not isinstance(value, pikepdf.Stream) or value.objgen in seen:
                continue
            seen.add(value.objgen)
            if value.get("/Subtype") == Name.Image:
                out.append(value)
            elif value.get("/Subtype") == Name.Form:
                stack.append(value.get("/Resources"))
    return out


# ---------------------------------------------------------------- audit

CATEGORIES = ("images", "content", "fonts", "forms", "annotations", "bookmarks", "structure",
              "metadata", "embedded_files", "color", "thumbnails", "other")


@query("space_audit")
def space_audit(ctx):
    """Bytes per category. Objects are claimed by the first category that reaches them."""
    pdf = ctx.pdf
    claimed = {}
    sizes = dict.fromkeys(CATEGORIES, 0)

    def size_of(obj):
        try:
            base = len(obj.unparse()) if not isinstance(obj, pikepdf.Stream) else 60
        except (pikepdf.PdfError, TypeError):
            base = 40
        if isinstance(obj, pikepdf.Stream):
            try:
                base += len(obj.read_raw_bytes())
            except pikepdf.PdfError:
                pass
        return base

    def claim(value, category, depth=0):
        stack = [(value, category)]
        while stack:
            node, cat = stack.pop()
            if not isinstance(node, CONTAINERS):
                continue
            if node.is_indirect:
                if node.objgen in claimed:
                    continue
                if isinstance(node, pikepdf.Dictionary) and node.get("/Type") == Name.Page:
                    continue
                claimed[node.objgen] = cat
                sizes[cat] += size_of(node)
            sub = cat
            items = node.items() if isinstance(node, (pikepdf.Dictionary, pikepdf.Stream)) else enumerate(node)
            for key, child in items:
                if key in ("/Parent", "/P", "/Dest", "/Prev", "/IRT", "/Popup"):
                    continue
                if isinstance(child, pikepdf.Stream):
                    st = child.get("/Subtype")
                    if st == Name.Image:
                        stack.append((child, "images"))
                        continue
                    if key in ("/FontFile", "/FontFile2", "/FontFile3"):
                        stack.append((child, "fonts"))
                        continue
                    if key == "/Metadata":
                        stack.append((child, "metadata"))
                        continue
                if key == "/Font":
                    stack.append((child, "fonts"))
                elif key in ("/ColorSpace", "/OutputIntents") and cat == "content":
                    stack.append((child, "color"))
                else:
                    stack.append((child, sub))

    root = pdf.Root
    if "/Metadata" in root:
        claim(root.Metadata, "metadata")
    info = pdf.trailer.get("/Info")
    if isinstance(info, pikepdf.Dictionary):
        claim(info, "metadata")
    for page in pdf.pages:
        obj = page.obj
        if "/Thumb" in obj:
            claim(obj.Thumb, "thumbnails")
        for annot in obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary):
                cat = "forms" if annot.get("/Subtype") == Name.Widget else \
                    "embedded_files" if annot.get("/Subtype") == Name.FileAttachment else "annotations"
                claim(annot, cat)
        claim(obj.get("/Contents"), "content")
        claim(obj.get("/Resources"), "content")
        claimed[obj.objgen] = "other"
        sizes["other"] += size_of(obj)
    if "/AcroForm" in root:
        claim(root.AcroForm, "forms")
    if "/Outlines" in root:
        claim(root.Outlines, "bookmarks")
    if "/StructTreeRoot" in root:
        claim(root.StructTreeRoot, "structure")
    names = root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/EmbeddedFiles" in names:
        claim(names.EmbeddedFiles, "embedded_files")
    if "/OutputIntents" in root:
        claim(root.OutputIntents, "color")
    claim(root, "other")
    total = ctx.source.stat().st_size
    accounted = sum(sizes.values())
    sizes["other"] += max(0, total - accounted)
    return {"total": total, "categories": sizes}


CONTAINERS = (pikepdf.Dictionary, pikepdf.Array, pikepdf.Stream)


@query("image_inventory")
def image_inventory(ctx):
    """Every image XObject with pixel size, color, encoding and effective DPI."""
    pdf = ctx.pdf
    placements = image_placements(pdf)
    out, seen = [], set()
    for index, page in enumerate(pdf.pages):
        for xobj in _page_images(page):
            if xobj.objgen in seen:
                continue
            seen.add(xobj.objgen)
            kind, _ = _space_kind(xobj)
            filters = xobj.get("/Filter")
            filters = [filters] if isinstance(filters, pikepdf.Name) else list(filters or [])
            dpi = effective_dpi(xobj, placements.get(xobj.objgen))
            out.append({"page": index, "width": int(xobj.get("/Width", 0)), "height": int(xobj.get("/Height", 0)),
                        "color": kind or "other", "bits": int(xobj.get("/BitsPerComponent", 1)),
                        "filters": [str(f)[1:] for f in filters], "bytes": len(xobj.read_raw_bytes()),
                        "dpi": round(dpi) if dpi else None})
    return {"images": out}


@query("extract_images")
def extract_images(ctx, directory, min_pixels=16):
    """Write every image in its original encoding where possible (JPEG, JPEG
    2000, otherwise PNG/TIFF) into the app's private `directory`. The caller
    copies the results to the user's chosen folder; the document is untouched."""
    from pathlib import Path
    target = Path(directory)
    require(target.is_dir(), "INVALID_ARGUMENT", "The image folder is unavailable.")
    pdf = ctx.pdf
    written, skipped, seen = [], 0, set()
    for index, page in enumerate(pdf.pages):
        for n, xobj in enumerate(_page_images(page)):
            if xobj.objgen in seen:
                continue
            seen.add(xobj.objgen)
            if int(xobj.get("/Width", 0)) * int(xobj.get("/Height", 0)) < min_pixels:
                skipped += 1
                continue
            stem = target / f"page{index + 1:03d}-image{n + 1:02d}"
            try:
                path = pikepdf.PdfImage(xobj).extract_to(fileprefix=str(stem))
                written.append({"page": index, "path": str(path)})
            except Exception:  # noqa: BLE001 - unsupported encodings are reported, not fatal
                skipped += 1
    return {"images": written, "skipped": skipped}
