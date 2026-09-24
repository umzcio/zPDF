"""ISO standards as outputs: PDF/A-2b / -3b, PDF/X-4 and PDF/E-1.

Conversion applies the fixups a conforming file needs (OutputIntent with an
ICC profile from macOS ColorSync, XMP identification synchronized with the
Info dictionary, embedded fonts — metric-compatible substitutes for the
standard 14 and system fonts matched by PostScript name — no JavaScript or
forbidden actions, printable annotations with appearances, no encryption,
device colors made device-independent through Default color spaces, ...).

`validate_standard` reports violations found by this module's own checks.
It is not a certified validator (such as veraPDF); it covers the rules this
app can fix or that commonly break conformance, and says so in its result.
"""
from datetime import datetime, timezone
from hashlib import sha256
import io
from pathlib import Path
import re

import pikepdf
from pikepdf import Name

import logging

from engine.errors import EngineError, require
from transforms import op, query
from transforms.optimize import walk, SUBSET_TAG, STANDARD14, _used_codes

logging.getLogger("fontTools").setLevel(logging.ERROR)
try:
    from pikepdf.models.metadata import PdfMetadata
    PdfMetadata.register_xml_namespace("http://www.aiim.org/pdfe/ns/id/", "pdfe")
except (ImportError, AttributeError, ValueError):
    pass
PROFILES = Path("/System/Library/ColorSync/Profiles")
SRGB = PROFILES / "sRGB Profile.icc"
CMYK = PROFILES / "Generic CMYK Profile.icc"
GRAY = PROFILES / "Generic Gray Gamma 2.2 Profile.icc"
SUPPLEMENTAL = Path("/System/Library/Fonts/Supplemental")
SUBSTITUTES = {
    "Helvetica": "Arial.ttf", "Helvetica-Bold": "Arial Bold.ttf", "Helvetica-Oblique": "Arial Italic.ttf",
    "Helvetica-BoldOblique": "Arial Bold Italic.ttf",
    "Arial": "Arial.ttf", "ArialMT": "Arial.ttf", "Arial,Bold": "Arial Bold.ttf", "Arial-BoldMT": "Arial Bold.ttf",
    "Arial,Italic": "Arial Italic.ttf", "Arial-ItalicMT": "Arial Italic.ttf",
    "Arial,BoldItalic": "Arial Bold Italic.ttf", "Arial-BoldItalicMT": "Arial Bold Italic.ttf",
    "Times-Roman": "Times New Roman.ttf", "Times-Bold": "Times New Roman Bold.ttf",
    "Times-Italic": "Times New Roman Italic.ttf", "Times-BoldItalic": "Times New Roman Bold Italic.ttf",
    "TimesNewRoman": "Times New Roman.ttf", "TimesNewRomanPSMT": "Times New Roman.ttf",
    "TimesNewRoman,Bold": "Times New Roman Bold.ttf", "TimesNewRomanPS-BoldMT": "Times New Roman Bold.ttf",
    "TimesNewRoman,Italic": "Times New Roman Italic.ttf", "TimesNewRomanPS-ItalicMT": "Times New Roman Italic.ttf",
    "Courier": "Courier New.ttf", "Courier-Bold": "Courier New Bold.ttf", "Courier-Oblique": "Courier New Italic.ttf",
    "Courier-BoldOblique": "Courier New Bold Italic.ttf", "CourierNew": "Courier New.ttf",
    "CourierNewPSMT": "Courier New.ttf",
    "Symbol": "/System/Library/Fonts/Symbol.ttf", "ZapfDingbats": "/System/Library/Fonts/ZapfDingbats.ttf",
}
FORBIDDEN_ACTIONS = {"/Launch", "/Sound", "/Movie", "/ResetForm", "/ImportData", "/Hide", "/SetOCGState",
                     "/Rendition", "/Trans", "/GoTo3DView", "/JavaScript"}
FORBIDDEN_ANNOTS = {"/Sound", "/Movie", "/Screen", "/3D", "/RichMedia", "/TrapNet"}
LEVELS = {"2b": ("2", "B"), "3b": ("3", "B"), "2u": ("2", "U"), "3u": ("3", "U")}
FIELD_FLAGS_HIDDEN = 2 | 32 | 256  # Hidden, NoView, ToggleNoView
PRINT = 4


# ---------------------------------------------------------------- helpers

def _icc_components(data):
    space = data[16:20]
    return {b"RGB ": 3, b"CMYK": 4, b"GRAY": 1}.get(space, 3)


def _icc_stream(pdf, path):
    require(Path(path).is_file(), "DEPENDENCY_UNAVAILABLE", "A required ColorSync profile is missing on this Mac.")
    data = Path(path).read_bytes()
    stream = pikepdf.Stream(pdf, data)
    stream.N = _icc_components(data)
    return pdf.make_indirect(stream)


def set_output_intent(pdf, subtype, profile, identifier, info):
    """Single OutputIntent (PDF/A-2 requires all intents to share one profile)."""
    icc = _icc_stream(pdf, profile)
    intent = pdf.make_indirect(pikepdf.Dictionary(
        Type=Name.OutputIntent, S=Name("/" + subtype), OutputConditionIdentifier=pikepdf.String(identifier),
        Info=pikepdf.String(info), OutputCondition=pikepdf.String(info), DestOutputProfile=icc))
    kept = pikepdf.Array()
    for existing in pdf.Root.get("/OutputIntents", []):
        if isinstance(existing, pikepdf.Dictionary) and existing.get("/S") != Name("/" + subtype):
            copy = pikepdf.Dictionary(existing)
            copy.DestOutputProfile = icc
            kept.append(pdf.make_indirect(copy))
    kept.append(intent)
    pdf.Root.OutputIntents = kept
    return icc


def _usage(pdf):
    """Device color spaces, transparency and fonts used anywhere in content."""
    found = {"rgb": False, "cmyk": False, "gray": False, "transparency": set(), "fonts": {}, "spots": set()}

    def space_kind(space):
        if isinstance(space, pikepdf.Name):
            return {Name.DeviceRGB: "rgb", Name.DeviceCMYK: "cmyk", Name.DeviceGray: "gray",
                    Name("/RGB"): "rgb", Name("/CMYK"): "cmyk", Name("/G"): "gray"}.get(space)
        if isinstance(space, pikepdf.Array) and len(space):
            head = space[0]
            if head == Name.Indexed and len(space) > 1:
                return space_kind(space[1])
            if head in (Name.Separation, Name.DeviceN) and len(space) > 2:
                names = [space[1]] if head == Name.Separation else list(space[1])
                for n in names:
                    if str(n) not in ("/None", "/All", "/Cyan", "/Magenta", "/Yellow", "/Black"):
                        found["spots"].add(str(n)[1:])
                return space_kind(space[2])
            if head == Name.Pattern and len(space) > 1:
                return space_kind(space[1])
        return None

    def visit(kind, page, **data):
        if kind == "color":
            k = space_kind(data["space"])
            if k:
                found[k] = True
        elif kind == "image":
            xobj = data["xobj"]
            space = xobj.get("/ColorSpace") if not data.get("inline") else xobj.get("/CS", xobj.get("/ColorSpace"))
            k = space_kind(space) if space is not None else None
            if k:
                found[k] = True
            if not data.get("inline") and ("/SMask" in xobj or isinstance(xobj.get("/SMask"), pikepdf.Stream)):
                found["transparency"].add(page)
        elif kind == "gstate":
            gs = data["gs"]
            if float(gs.get("/ca", 1)) < 1 or float(gs.get("/CA", 1)) < 1 or \
                    gs.get("/SMask", Name.None_) not in (Name.None_,) and isinstance(gs.get("/SMask"), pikepdf.Dictionary) or \
                    gs.get("/BM", Name.Normal) not in (Name.Normal, Name.Compatible):
                found["transparency"].add(page)
        elif kind == "group":
            if data["group"].get("/S") == Name.Transparency:
                found["transparency"].add(page)
        elif kind == "font":
            font = data["font"]
            found["fonts"][font.objgen] = font

    walk(pdf, visit)
    for index, page in enumerate(pdf.pages):
        group = page.obj.get("/Group")
        if isinstance(group, pikepdf.Dictionary) and group.get("/S") == Name.Transparency:
            found["transparency"].add(index)
    return found


def _font_embedded(font):
    subtype = font.get("/Subtype")
    if subtype == Name.Type3:
        return True
    if subtype == Name.Type0:
        kids = font.get("/DescendantFonts")
        if not isinstance(kids, pikepdf.Array) or not len(kids):
            return False
        descriptor = kids[0].get("/FontDescriptor")
    else:
        descriptor = font.get("/FontDescriptor")
    return isinstance(descriptor, pikepdf.Dictionary) and any(k in descriptor for k in ("/FontFile", "/FontFile2", "/FontFile3"))


def _font_name(font):
    return SUBSET_TAG.sub("", str(font.get("/BaseFont", "/Unnamed"))[1:])


_SYSTEM_INDEX = None


def _system_font(name):
    """Find a TrueType system font by PostScript name (lazy index)."""
    global _SYSTEM_INDEX
    if _SYSTEM_INDEX is None:
        _SYSTEM_INDEX = {}
        from fontTools.ttLib import TTFont, TTCollection
        for folder in (Path("/System/Library/Fonts"), SUPPLEMENTAL, Path("/Library/Fonts")):
            if not folder.is_dir():
                continue
            for path in sorted(folder.iterdir()):
                suffix = path.suffix.lower()
                try:
                    if suffix == ".ttf":
                        fonts = [(TTFont(path, lazy=True), 0)]
                    elif suffix == ".ttc":
                        fonts = [(f, i) for i, f in enumerate(TTCollection(path, lazy=True).fonts)]
                    else:
                        continue
                    for font, index in fonts:
                        if "glyf" not in font:
                            continue
                        ps = font["name"].getDebugName(6)
                        if ps and ps not in _SYSTEM_INDEX:
                            _SYSTEM_INDEX[ps] = (str(path), index)
                except Exception:  # noqa: BLE001 - unreadable fonts are skipped
                    continue
    base = name.replace(",", "-")
    for candidate in (name, base, base.replace(" ", "")):
        if candidate in _SYSTEM_INDEX:
            return _SYSTEM_INDEX[candidate]
    return None


def _substitute_path(name):
    if name in SUBSTITUTES:
        target = SUBSTITUTES[name]
        path = Path(target) if target.startswith("/") else SUPPLEMENTAL / target
        return (str(path), 0) if path.is_file() else None
    return _system_font(name)


def _encoding_names(font, symbolic):
    """code -> glyph name for a simple font's encoding (None for symbolic built-in)."""
    from fontTools.encodings.StandardEncoding import StandardEncoding
    from fontTools.encodings.MacRoman import MacRoman
    from fontTools import agl
    encoding = font.get("/Encoding")
    base = None
    differences = {}
    if isinstance(encoding, pikepdf.Name):
        base = str(encoding)
    elif isinstance(encoding, pikepdf.Dictionary):
        base = str(encoding.get("/BaseEncoding", "/StandardEncoding"))
        code = 0
        for item in encoding.get("/Differences", []):
            if isinstance(item, int):
                code = int(item)
            else:
                differences[code] = str(item)[1:]
                code += 1
    if symbolic and base is None and not differences:
        return None
    base = base or "/StandardEncoding"
    names = {}
    for code in range(256):
        if base == "/WinAnsiEncoding":
            try:
                char = bytes([code]).decode("cp1252")
                name = agl.UV2AGL.get(ord(char)) if code >= 32 else None
            except UnicodeDecodeError:
                name = None
        elif base == "/MacRomanEncoding":
            name = MacRoman[code] if code < len(MacRoman) else None
        else:
            name = StandardEncoding[code] if code < len(StandardEncoding) else None
        if name and name != ".notdef":
            names[code] = name
    names.update(differences)
    return names


def embed_font(pdf, font, used_codes):
    """Embed a substitute TrueType program into an unembedded simple font.
    Returns the substitute file name or raises EngineError."""
    from fontTools.ttLib import TTFont
    from fontTools import subset, agl
    from fontTools.ttLib.tables._c_m_a_p import cmap_format_4
    name = _font_name(font)
    subtype = font.get("/Subtype")
    if subtype not in (Name.Type1, Name.TrueType, Name.MMType1):
        raise EngineError("FONT_NOT_EMBEDDABLE", f"{name} is a composite font that cannot be substituted.")
    found = _substitute_path(name)
    if found is None:
        raise EngineError("FONT_NOT_EMBEDDABLE", f"No substitute font was found on this Mac for {name}.")
    path, index = found
    tt = TTFont(path, fontNumber=index, lazy=False)
    symbolic = name in ("Symbol", "ZapfDingbats") or (int(font.get("/FontDescriptor", {}).get("/Flags", 32)) & 4 and
                                                      not int(font.get("/FontDescriptor", {}).get("/Flags", 32)) & 32)
    codes = sorted(c for c in (used_codes or set()) if 0 <= c < 256) or list(range(32, 256))
    gids = {0}
    code_gid = {}
    names = _encoding_names(font, symbolic)
    best = tt.getBestCmap() or {}
    mac = next((t.cmap for t in tt["cmap"].tables if t.platformID == 1 and t.platEncID == 0), {})
    for code in codes:
        gid = None
        if symbolic:
            glyph = mac.get(code)
            if glyph is None and names and names.get(code):
                uni = agl.toUnicode(names[code])
                glyph = best.get(ord(uni)) if uni else None
            gid = tt.getGlyphID(glyph) if glyph else None
        else:
            glyph_name = names.get(code) if names else None
            uni = agl.toUnicode(glyph_name) if glyph_name else ""
            if uni and ord(uni[0]) in best:
                gid = tt.getGlyphID(best[ord(uni[0])])
        if gid is not None:
            code_gid[code] = gid
            gids.add(gid)
    options = subset.Options()
    options.retain_gids = True
    options.notdef_outline = True
    options.name_IDs = ["*"]
    options.glyph_names = False
    options.drop_tables += ["DSIG", "GSUB", "GPOS", "morx", "kerx", "kern"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(gids=sorted(gids))
    subsetter.subset(tt)
    if symbolic:
        # PDF/A: a symbolic TrueType font carries one (3,0) cmap for its codes.
        table = cmap_format_4(4)
        table.platformID, table.platEncID, table.language = 3, 0, 0
        order = tt.getGlyphOrder()
        table.cmap = {0xF000 + code: order[gid] for code, gid in code_gid.items()}
        tt["cmap"].tables = [table]
    out = io.BytesIO()
    tt.save(out)
    data = out.getvalue()
    units = tt["head"].unitsPerEm
    hmtx = tt["hmtx"].metrics
    order = tt.getGlyphOrder()
    first, last = min(codes), max(codes)
    widths = pikepdf.Array()
    for code in range(first, last + 1):
        gid = code_gid.get(code)
        widths.append(round(hmtx[order[gid]][0] * 1000 / units) if gid is not None else 0)
    head = tt["head"]
    os2 = tt["OS/2"] if "OS/2" in tt else None
    scale = 1000 / units
    tag = "".join(chr(65 + b % 26) for b in sha256((name + repr(sorted(gids))).encode()).digest()[:6])
    base = Name("/" + tag + "+" + re.sub(r"[^A-Za-z0-9,+\-_]", "", name))
    stream = pikepdf.Stream(pdf, data)
    stream.Length1 = len(data)
    italic = float(tt["post"].italicAngle) if "post" in tt else 0
    descriptor = pikepdf.Dictionary(
        Type=Name.FontDescriptor, FontName=base, Flags=4 if symbolic else 32 | (64 if italic else 0),
        FontBBox=[round(head.xMin * scale), round(head.yMin * scale), round(head.xMax * scale), round(head.yMax * scale)],
        ItalicAngle=italic, Ascent=round((os2.sTypoAscender if os2 else tt["hhea"].ascent) * scale),
        Descent=round((os2.sTypoDescender if os2 else tt["hhea"].descent) * scale),
        CapHeight=round((getattr(os2, "sCapHeight", 0) or 700 / scale) * scale), StemV=80,
        FontFile2=pdf.make_indirect(stream))
    font.Subtype = Name.TrueType
    font.BaseFont = base
    font.FirstChar, font.LastChar = first, last
    font.Widths = widths
    font.FontDescriptor = pdf.make_indirect(descriptor)
    if symbolic:
        if "/Encoding" in font:
            del font["/Encoding"]
    else:
        # Nonsymbolic TrueType: WinAnsi base plus AGL-named differences so every
        # code keeps the glyph its original encoding selected.
        from fontTools import agl as _agl
        diffs = pikepdf.Array()
        win = {}
        for code in codes:
            try:
                ch = bytes([code]).decode("cp1252")
                win[code] = _agl.UV2AGL.get(ord(ch))
            except UnicodeDecodeError:
                win[code] = None
        run = None
        for code in codes:
            wanted = names.get(code) if names else None
            if wanted and wanted != win.get(code) and _agl.toUnicode(wanted):
                if run != code:
                    diffs.append(code)
                diffs.append(Name("/" + wanted))
                run = code + 1
        encoding = pikepdf.Dictionary(Type=Name.Encoding, BaseEncoding=Name.WinAnsiEncoding)
        if len(diffs):
            encoding.Differences = diffs
        font.Encoding = encoding
    return Path(path).name


def embed_missing_fonts(pdf):
    usage = _usage(pdf)
    codes = _used_codes(pdf)
    embedded, failed = [], []
    fonts = dict(usage["fonts"])
    for obj in pdf.objects:
        if isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == Name.Font and obj.objgen not in fonts:
            if obj.get("/Subtype") != Name.Type0 and "/DescendantFonts" not in obj:
                fonts[obj.objgen] = obj
    for key, font in fonts.items():
        if _font_embedded(font):
            continue
        # Descendant CIDFonts are handled with their Type0 parent.
        if font.get("/Subtype") in (Name.CIDFontType0, Name.CIDFontType2):
            continue
        try:
            substitute = embed_font(pdf, font, codes.get(key))
            embedded.append({"font": _font_name(font), "substitute": substitute})
        except EngineError as exc:
            failed.append({"font": _font_name(font), "reason": exc.message})
    return embedded, failed


def _set_xmp(pdf, updates, remove_prefixes=()):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    had_xmp = "/Metadata" in pdf.Root
    with pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=True) as meta:
        if not had_xmp and "/Info" in pdf.trailer:
            meta.load_from_docinfo(pdf.docinfo, raise_failure=False)
        for key in list(meta.keys()):
            if any(key.startswith(p) for p in remove_prefixes):
                del meta[key]
        meta["xmp:ModifyDate"] = now.isoformat()
        meta["xmp:MetadataDate"] = now.isoformat()
        if not meta.get("xmp:CreateDate"):
            meta["xmp:CreateDate"] = now.isoformat()
        meta["pdf:Producer"] = "zPDF"
        for key, value in updates.items():
            meta[key] = value
    metadata = pdf.Root.get("/Metadata")
    if isinstance(metadata, pikepdf.Stream) and "/Filter" in metadata:
        metadata.write(metadata.read_bytes())


def _strip_actions(pdf):
    """Remove forbidden actions everywhere they can hang. Returns count."""
    removed = 0

    def bad(action):
        return isinstance(action, pikepdf.Dictionary) and str(action.get("/S", "")) in FORBIDDEN_ACTIONS

    root = pdf.Root
    names = root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/JavaScript" in names:
        del names["/JavaScript"]
        removed += 1
    for holder in list(pdf.objects):
        if not isinstance(holder, pikepdf.Dictionary):
            continue
        if bad(holder.get("/A")):
            del holder["/A"]
            removed += 1
        if bad(holder.get("/OpenAction")):
            del holder["/OpenAction"]
            removed += 1
        if "/AA" in holder:
            del holder["/AA"]
            removed += 1
        nxt = holder.get("/Next")
        if isinstance(nxt, pikepdf.Dictionary) and bad(nxt):
            del holder["/Next"]
            removed += 1
    return removed


# ---------------------------------------------------------------- conversion

def _fix_common(pdf, report, standard):
    """Fixups shared by PDF/A, /X and /E."""
    report["actions_removed"] = _strip_actions(pdf)
    acro = pdf.Root.get("/AcroForm")
    if isinstance(acro, pikepdf.Dictionary):
        if "/XFA" in acro:
            del acro["/XFA"]
            report["xfa_removed"] = True
        if acro.get("/NeedAppearances") is True:
            try:
                pdf.generate_appearance_streams()
            except (pikepdf.PdfError, AttributeError):
                pass
            del acro["/NeedAppearances"]
    removed_annots = 0
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if annots is None:
            continue
        kept = pikepdf.Array()
        for annot in annots:
            if not isinstance(annot, pikepdf.Dictionary):
                continue
            subtype = str(annot.get("/Subtype", ""))
            if subtype in FORBIDDEN_ANNOTS or (subtype == "/FileAttachment" and standard == "2"):
                removed_annots += 1
                continue
            if subtype != "/Popup":
                flags = int(annot.get("/F", 0))
                annot.F = (flags | PRINT) & ~FIELD_FLAGS_HIDDEN & ~1
            ap = annot.get("/AP")
            if isinstance(ap, pikepdf.Dictionary):
                for key in ("/R", "/D"):
                    if key in ap and subtype != "/Widget":
                        del ap[key]
            if subtype not in ("/Popup", "/Link") and not isinstance(ap, pikepdf.Dictionary):
                rect = [float(v) for v in annot.get("/Rect", [0, 0, 0, 0])]
                if abs(rect[2] - rect[0]) > 0 and abs(rect[3] - rect[1]) > 0:
                    # Invisible appearance keeps the annotation data valid for archiving.
                    empty = pdf.make_indirect(pikepdf.Stream(pdf, b""))
                    empty.Type, empty.Subtype = Name.XObject, Name.Form
                    empty.BBox = pikepdf.Array([0, 0, abs(rect[2] - rect[0]), abs(rect[3] - rect[1])])
                    annot.AP = pikepdf.Dictionary(N=empty)
                    report["appearances_added"] = report.get("appearances_added", 0) + 1
            kept.append(annot)
        page.obj.Annots = kept
    report["annotations_removed"] = removed_annots
    for obj in list(pdf.objects):
        if isinstance(obj, pikepdf.Stream):
            filters = obj.get("/Filter")
            filters = [filters] if isinstance(filters, pikepdf.Name) else list(filters or [])
            if Name.LZWDecode in filters:
                obj.write(obj.read_bytes(), filter=Name.FlateDecode)
                report["lzw_recompressed"] = report.get("lzw_recompressed", 0) + 1
            if obj.get("/Subtype") == Name.Image:
                if obj.get("/Interpolate") is True:
                    obj.Interpolate = False
                for key in ("/Alternates", "/OPI"):
                    if key in obj:
                        del obj[key]
            if obj.get("/Subtype") == Name.Form:
                for key in ("/OPI", "/PS"):
                    if key in obj:
                        del obj[key]
        elif isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == Name.ExtGState:
            for key in ("/TR", "/TR2"):
                if key in obj and not (key == "/TR2" and obj[key] == Name.Default):
                    del obj[key]
            if "/HTP" in obj:
                del obj["/HTP"]
    ocp = pdf.Root.get("/OCProperties")
    if isinstance(ocp, pikepdf.Dictionary):
        configs = [ocp.get("/D")] + list(ocp.get("/Configs", []))
        for n, config in enumerate(c for c in configs if isinstance(c, pikepdf.Dictionary)):
            if "/Name" not in config:
                config.Name = pikepdf.String("Default" if n == 0 else f"Configuration {n}")
            if "/AS" in config:
                del config["/AS"]
    embedded, failed = embed_missing_fonts(pdf)
    report["fonts_embedded"] = embedded
    report["fonts_failed"] = failed


def _default_space(pdf, name, profile):
    icc = _icc_stream(pdf, profile)
    space = pikepdf.Array([Name.ICCBased, icc])
    holders = [p.obj for p in pdf.pages] + [o for o in pdf.objects if isinstance(o, pikepdf.Stream)
                                             and o.get("/Subtype") == Name.Form]
    for holder in holders:
        res = holder.get("/Resources")
        if res is None and hasattr(holder, "get") and holder.get("/Type") == Name.Page:
            holder.Resources = pikepdf.Dictionary()
            res = holder.Resources
        if not isinstance(res, pikepdf.Dictionary):
            continue
        if "/ColorSpace" not in res:
            res.ColorSpace = pikepdf.Dictionary()
        if name not in res.ColorSpace:
            res.ColorSpace[name] = space


@op("convert_pdfa")
def convert_pdfa(ctx, level="2b"):
    pdf = ctx.pdf
    require(level in LEVELS, "INVALID_ARGUMENT", "Choose PDF/A-2b, -2u, -3b or -3u.")
    part, conformance = LEVELS[level]
    report = {"level": level}
    _fix_common(pdf, report, part)
    if report["fonts_failed"]:
        names = ", ".join(sorted({f["font"] for f in report["fonts_failed"]}))
        raise EngineError("FONT_NOT_EMBEDDABLE", f"These fonts could not be embedded, so the file cannot be PDF/A: {names}.")
    names = pdf.Root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/EmbeddedFiles" in names:
        if part == "2":
            del names["/EmbeddedFiles"]
            if "/Collection" in pdf.Root:
                del pdf.Root["/Collection"]
            report["embedded_files_removed"] = True
        else:
            af = pikepdf.Array()
            for _, spec in pikepdf.NameTree(names.EmbeddedFiles).items():
                if isinstance(spec, pikepdf.Dictionary):
                    spec.AFRelationship = spec.get("/AFRelationship", Name.Unspecified)
                    ef = spec.get("/EF", {})
                    for stream in ef.values() if isinstance(ef, pikepdf.Dictionary) else []:
                        if "/Subtype" not in stream:
                            stream.Subtype = Name("/application#2Foctet-stream")
                    if "/UF" not in spec and "/F" in spec:
                        spec.UF = spec.F
                    af.append(spec)
            pdf.Root.AF = af
    usage = _usage(pdf)
    if usage["cmyk"] and not usage["rgb"]:
        set_output_intent(pdf, "GTS_PDFA1", CMYK, "Generic CMYK", "Generic CMYK Profile (macOS ColorSync)")
        report["output_intent"] = "Generic CMYK"
    else:
        set_output_intent(pdf, "GTS_PDFA1", SRGB, "sRGB IEC61966-2.1", "sRGB IEC61966-2.1")
        report["output_intent"] = "sRGB"
        if usage["cmyk"]:
            _default_space(pdf, Name.DefaultCMYK, CMYK)
            report["default_cmyk"] = True
    for page in pdf.pages:
        group = page.obj.get("/Group")
        if isinstance(group, pikepdf.Dictionary) and group.get("/S") == Name.Transparency and "/CS" in group:
            cs = group.CS
            if cs == Name.DeviceCMYK and report["output_intent"] == "sRGB":
                group.CS = Name.DeviceRGB
    updates = {"pdfaid:part": part, "pdfaid:conformance": conformance}
    _set_xmp(pdf, updates, remove_prefixes=("pdfaid:",))
    ctx.save_options.update(force_version="1.7", encryption=False,
                            object_stream_mode=pikepdf.ObjectStreamMode.preserve)
    return report


@op("convert_pdfx")
def convert_pdfx(ctx, version="PDF/X-4", bleed=0.0, condition="Generic CMYK"):
    """PDF/X-4 basics: CMYK OutputIntent, TrimBox/BleedBox on every page,
    identification in Info and XMP, embedded fonts, no encryption or JavaScript."""
    pdf = ctx.pdf
    require(version == "PDF/X-4", "INVALID_ARGUMENT", "Only PDF/X-4 is supported.")
    report = {"version": version}
    _fix_common(pdf, report, "x")
    if report["fonts_failed"]:
        names = ", ".join(sorted({f["font"] for f in report["fonts_failed"]}))
        raise EngineError("FONT_NOT_EMBEDDABLE", f"These fonts could not be embedded, so the file cannot be PDF/X: {names}.")
    set_output_intent(pdf, "GTS_PDFX", CMYK, condition, "Generic CMYK Profile (macOS ColorSync)")
    usage = _usage(pdf)
    if usage["rgb"]:
        _default_space(pdf, Name.DefaultRGB, SRGB)
        report["default_rgb"] = True
    boxes = 0
    for page in pdf.pages:
        obj = page.obj
        from transforms.content import page_box
        media = page_box(page, "/MediaBox")
        if "/TrimBox" not in obj and "/ArtBox" not in obj:
            obj.TrimBox = pikepdf.Array(list(page_box(page, "/CropBox")))
            boxes += 1
        trim = [float(v) for v in obj.get("/TrimBox", obj.get("/ArtBox"))]
        if "/BleedBox" not in obj:
            b = float(bleed)
            obj.BleedBox = pikepdf.Array([max(media[0], trim[0] - b), max(media[1], trim[1] - b),
                                          min(media[2], trim[2] + b), min(media[3], trim[3] + b)])
    report["boxes_added"] = boxes
    info = pdf.docinfo
    info["/GTS_PDFXVersion"] = pikepdf.String(version)
    info["/Trapped"] = Name.False_ if "/Trapped" not in info or info.Trapped not in (Name.True_, Name.False_) else info.Trapped
    _set_xmp(pdf, {"pdfxid:GTS_PDFXVersion": version, "pdf:Trapped": "False"})
    info = pdf.docinfo
    info["/GTS_PDFXVersion"] = pikepdf.String(version)
    if "/Trapped" not in info:
        info["/Trapped"] = Name.False_
    ctx.save_options.update(force_version="1.6", encryption=False)
    return report


@op("convert_pdfe")
def convert_pdfe(ctx):
    """PDF/E-1 identification with embedded fonts and no encryption."""
    pdf = ctx.pdf
    report = {"version": "PDF/E-1"}
    embedded, failed = embed_missing_fonts(pdf)
    report["fonts_embedded"], report["fonts_failed"] = embedded, failed
    if failed:
        raise EngineError("FONT_NOT_EMBEDDABLE", "Some fonts could not be embedded, so the file cannot be PDF/E.")
    report["actions_removed"] = _strip_actions(pdf)
    _set_xmp(pdf, {"pdfe:ISO_PDFEVersion": "PDF/E-1"})
    ctx.save_options.update(force_version="1.6", encryption=False)
    return report


# ---------------------------------------------------------------- validation

def _issue(issues, rule, message, severity="error", count=1, fixable=True):
    for existing in issues:
        if existing["rule"] == rule and existing["message"] == message:
            existing["count"] += count
            return
    issues.append({"rule": rule, "message": message, "severity": severity, "count": count, "fixable": fixable})


XMP_KEYS = ("pdfaid:part", "pdfaid:conformance", "pdfxid:GTS_PDFXVersion", "pdfe:ISO_PDFEVersion",
            "pdfuaid:part", "dc:title", "pdf:Producer")


def _xmp(pdf):
    try:
        meta = pdf.open_metadata(set_pikepdf_as_editor=False, update_docinfo=False)
        out = {}
        for key in XMP_KEYS:
            try:
                value = meta.get(key)
            except (KeyError, ValueError):
                value = None
            if value is not None:
                out[key] = str(value)
        return out
    except Exception:  # noqa: BLE001 - unreadable XMP is itself a finding
        return None


def check_common(pdf, issues, standard, source_version):
    usage = _usage(pdf)
    if pdf.is_encrypted:
        _issue(issues, "encryption", "The file is encrypted.")
    for key, font in usage["fonts"].items():
        if not _font_embedded(font):
            fixable = font.get("/Subtype") in (Name.Type1, Name.TrueType, Name.MMType1) and \
                _substitute_path(_font_name(font)) is not None
            _issue(issues, "fonts", f"Font not embedded: {_font_name(font)}", fixable=fixable)
    names = pdf.Root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/JavaScript" in names:
        _issue(issues, "actions", "Document-level JavaScript is present.")
    for obj in pdf.objects:
        if isinstance(obj, pikepdf.Dictionary):
            for key in ("/A", "/OpenAction"):
                action = obj.get(key)
                if isinstance(action, pikepdf.Dictionary) and str(action.get("/S", "")) in FORBIDDEN_ACTIONS:
                    _issue(issues, "actions", f"Forbidden action: {str(action.S)[1:]}")
            if "/AA" in obj:
                _issue(issues, "actions", "Additional actions (triggers) are present.")
        if isinstance(obj, pikepdf.Stream):
            filters = obj.get("/Filter")
            filters = [filters] if isinstance(filters, pikepdf.Name) else list(filters or [])
            if Name.LZWDecode in filters:
                _issue(issues, "compression", "LZW-compressed stream.")
            if obj.get("/Subtype") == Name.Image and obj.get("/Interpolate") is True:
                _issue(issues, "images", "Image requests interpolation.")
            if obj.get("/Subtype") == Name.PS or obj.get("/Subtype2") == Name.PS:
                _issue(issues, "xobjects", "PostScript XObject.")
        elif isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == Name.ExtGState:
            if "/TR" in obj or ("/TR2" in obj and obj.TR2 != Name.Default):
                _issue(issues, "graphics", "Transfer function in graphics state.")
    acro = pdf.Root.get("/AcroForm")
    if isinstance(acro, pikepdf.Dictionary):
        if acro.get("/NeedAppearances") is True:
            _issue(issues, "forms", "Form requires viewer-generated appearances (NeedAppearances).")
        if "/XFA" in acro:
            _issue(issues, "forms", "XFA form data is present.")
    for index, page in enumerate(pdf.pages):
        for annot in page.obj.get("/Annots", []):
            if not isinstance(annot, pikepdf.Dictionary):
                continue
            subtype = str(annot.get("/Subtype", ""))
            if subtype in FORBIDDEN_ANNOTS:
                _issue(issues, "annotations", f"Forbidden annotation type {subtype[1:]}.")
                continue
            if subtype == "/FileAttachment" and standard == "2":
                _issue(issues, "annotations", "File attachment annotation (not allowed in PDF/A-2).")
            if subtype != "/Popup":
                flags = int(annot.get("/F", 0))
                if not flags & PRINT or flags & (FIELD_FLAGS_HIDDEN | 1):
                    _issue(issues, "annotations", "Annotation is not set to print or is hidden.")
            if subtype not in ("/Popup", "/Link") and not isinstance(annot.get("/AP"), pikepdf.Dictionary):
                rect = [float(v) for v in annot.get("/Rect", [0, 0, 0, 0])]
                if abs(rect[2] - rect[0]) > 0 and abs(rect[3] - rect[1]) > 0:
                    _issue(issues, "annotations", "Annotation without an appearance stream.")
    return usage


@query("validate_standard")
def validate_standard(ctx, standard="PDF/A-2b"):
    """Violations for PDF/A-2b/2u/3b/3u, PDF/X-4 or PDF/E-1 (this app's checks)."""
    pdf = ctx.pdf
    issues = []
    header = str(pdf.pdf_version)
    xmp = _xmp(pdf)
    intents = [i for i in pdf.Root.get("/OutputIntents", []) if isinstance(i, pikepdf.Dictionary)]
    if standard.startswith("PDF/A-"):
        level = standard[6:].lower()
        require(level in LEVELS, "INVALID_ARGUMENT", "Unknown PDF/A level.")
        part, conformance = LEVELS[level]
        if header > "1.7":
            _issue(issues, "version", f"PDF version {header} is newer than PDF/A-{part} allows (1.7).")
        if "/ID" not in pdf.trailer:
            _issue(issues, "structure", "The file has no document ID.")
        if xmp is None:
            _issue(issues, "metadata", "XMP metadata cannot be read.")
        elif xmp.get("pdfaid:part") != part or xmp.get("pdfaid:conformance", "").upper() != conformance:
            _issue(issues, "metadata", f"XMP does not identify the file as PDF/A-{part}{conformance.lower()}.")
        metadata = pdf.Root.get("/Metadata")
        if isinstance(metadata, pikepdf.Stream) and "/Filter" in metadata:
            _issue(issues, "metadata", "The XMP metadata stream is compressed.")
        usage = check_common(pdf, issues, part, header)
        pdfa_intents = [i for i in intents if i.get("/S") == Name.GTS_PDFA1]
        device = usage["rgb"] or usage["cmyk"] or bool(usage["transparency"])
        if not pdfa_intents:
            if device:
                _issue(issues, "color", "Device colors are used without a PDF/A OutputIntent.")
        else:
            profile = pdfa_intents[0].get("/DestOutputProfile")
            n = int(profile.get("/N", 3)) if isinstance(profile, pikepdf.Stream) else 0
            if n == 0:
                _issue(issues, "color", "The OutputIntent has no ICC profile.")
            if usage["cmyk"] and n == 3 and not _has_default(pdf, Name.DefaultCMYK):
                _issue(issues, "color", "DeviceCMYK is used with an RGB OutputIntent.")
            if usage["rgb"] and n == 4 and not _has_default(pdf, Name.DefaultRGB):
                _issue(issues, "color", "DeviceRGB is used with a CMYK OutputIntent.")
        if len({i.get("/DestOutputProfile").objgen for i in intents if isinstance(i.get("/DestOutputProfile"), pikepdf.Stream)}) > 1:
            _issue(issues, "color", "OutputIntents use different ICC profiles.")
        names = pdf.Root.get("/Names")
        if isinstance(names, pikepdf.Dictionary) and "/EmbeddedFiles" in names:
            if part == "2":
                _issue(issues, "attachments", "Embedded files are not allowed in PDF/A-2 unless they are PDF/A.",
                       severity="error")
            else:
                for _, spec in pikepdf.NameTree(names.EmbeddedFiles).items():
                    if isinstance(spec, pikepdf.Dictionary) and "/AFRelationship" not in spec:
                        _issue(issues, "attachments", "Embedded file without AFRelationship.")
        ocp = pdf.Root.get("/OCProperties")
        if isinstance(ocp, pikepdf.Dictionary):
            for config in [ocp.get("/D")] + list(ocp.get("/Configs", [])):
                if isinstance(config, pikepdf.Dictionary) and ("/Name" not in config or "/AS" in config):
                    _issue(issues, "layers", "Layer configuration needs a name and no automatic states.")
    elif standard == "PDF/X-4":
        usage = check_common(pdf, issues, "x", header)
        if not any(i.get("/S") == Name.GTS_PDFX for i in intents):
            _issue(issues, "color", "No PDF/X OutputIntent.")
        info = pdf.docinfo
        if str(info.get("/GTS_PDFXVersion", "")) != "PDF/X-4" or (xmp or {}).get("pdfxid:GTS_PDFXVersion") != "PDF/X-4":
            _issue(issues, "metadata", "The file is not identified as PDF/X-4 in Info and XMP.")
        if info.get("/Trapped") not in (Name.True_, Name.False_):
            _issue(issues, "metadata", "The Trapped key must be True or False.")
        for page in pdf.pages:
            if "/TrimBox" not in page.obj and "/ArtBox" not in page.obj:
                _issue(issues, "boxes", "Page without a TrimBox.")
        if header > "1.6":
            _issue(issues, "version", f"PDF version {header} is newer than PDF/X-4 (1.6).", severity="warning")
    elif standard == "PDF/E-1":
        check_common(pdf, issues, "e", header)
        if (xmp or {}).get("pdfe:ISO_PDFEVersion") != "PDF/E-1":
            _issue(issues, "metadata", "XMP does not identify the file as PDF/E-1.")
    else:
        raise EngineError("INVALID_ARGUMENT", "Unknown standard.")
    return {"standard": standard, "compliant": not any(i["severity"] == "error" for i in issues),
            "issues": issues, "validator": "zPDF built-in checks (not a certified validator)"}


def _has_default(pdf, name):
    for page in pdf.pages:
        res = page.obj.get("/Resources")
        if not isinstance(res, pikepdf.Dictionary) or name not in res.get("/ColorSpace", {}):
            return False
    return True


@query("standards_status")
def standards_status(ctx):
    """Which standards the file claims (XMP / Info)."""
    pdf = ctx.pdf
    xmp = _xmp(pdf) or {}
    claims = []
    if xmp.get("pdfaid:part"):
        claims.append(f"PDF/A-{xmp['pdfaid:part']}{xmp.get('pdfaid:conformance', '').lower()}")
    x = xmp.get("pdfxid:GTS_PDFXVersion") or str(pdf.docinfo.get("/GTS_PDFXVersion", ""))
    if x:
        claims.append(x)
    if xmp.get("pdfe:ISO_PDFEVersion"):
        claims.append(xmp["pdfe:ISO_PDFEVersion"])
    if xmp.get("pdfuaid:part"):
        claims.append(f"PDF/UA-{xmp['pdfuaid:part']}")
    return {"claims": claims, "version": str(pdf.pdf_version)}
