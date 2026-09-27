"""Embedded Unicode fonts for text the app draws into page content.

Text is encoded as Identity-H glyph IDs of a subset TrueType/OpenType font with
a ToUnicode map, so drawn text is searchable, copyable and exported correctly.
Glyph IDs are retained by the subset, which keeps the CID->GID map Identity.
"""
from io import BytesIO
from pathlib import Path
import os
import sys

import pikepdf
from pikepdf import Name

from engine.errors import EngineError

DEFAULT_FONTS = (
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
)
STYLE_FONTS = {
    ("sans", False, False): "/System/Library/Fonts/Supplemental/Arial.ttf",
    ("sans", True, False): "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ("sans", False, True): "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
    ("sans", True, True): "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf",
    ("serif", False, False): "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    ("serif", True, False): "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf",
    ("serif", False, True): "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf",
    ("serif", True, True): "/System/Library/Fonts/Supplemental/Times New Roman Bold Italic.ttf",
    ("mono", False, False): "/System/Library/Fonts/Supplemental/Courier New.ttf",
    ("mono", True, False): "/System/Library/Fonts/Supplemental/Courier New Bold.ttf",
    ("mono", False, True): "/System/Library/Fonts/Supplemental/Courier New Italic.ttf",
    ("mono", True, True): "/System/Library/Fonts/Supplemental/Courier New Bold Italic.ttf",
}


WINDOWS_FONTS = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts"
WINDOWS_COLOR = Path(os.environ.get("WINDIR", r"C:\Windows")) / "System32" / "spool" / "drivers" / "color"
# macOS system file -> the Windows file with the same design (metrics-compatible).
_WINDOWS_EQUIVALENTS = {
    "Arial.ttf": "arial.ttf", "Arial Bold.ttf": "arialbd.ttf", "Arial Italic.ttf": "ariali.ttf",
    "Arial Bold Italic.ttf": "arialbi.ttf", "Arial Unicode.ttf": "arial.ttf",
    "Times New Roman.ttf": "times.ttf", "Times New Roman Bold.ttf": "timesbd.ttf",
    "Times New Roman Italic.ttf": "timesi.ttf", "Times New Roman Bold Italic.ttf": "timesbi.ttf",
    "Courier New.ttf": "cour.ttf", "Courier New Bold.ttf": "courbd.ttf", "Courier New Italic.ttf": "couri.ttf",
    "Courier New Bold Italic.ttf": "courbi.ttf", "Symbol.ttf": "symbol.ttf", "ZapfDingbats.ttf": "seguisym.ttf",
    # Faces inside macOS collections, by PostScript name.
    ("Helvetica.ttc", "Helvetica"): "arial.ttf", ("Helvetica.ttc", "Helvetica-Bold"): "arialbd.ttf",
    ("Helvetica.ttc", "Helvetica-Oblique"): "ariali.ttf", ("Helvetica.ttc", "Helvetica-BoldOblique"): "arialbi.ttf",
    ("Times.ttc", "Times-Roman"): "times.ttf", ("Times.ttc", "Times-Bold"): "timesbd.ttf",
    ("Times.ttc", "Times-Italic"): "timesi.ttf", ("Times.ttc", "Times-BoldItalic"): "timesbi.ttf",
}
_WINDOWS_PROFILES = {"sRGB Profile.icc": "sRGB Color Space Profile.icm", "Generic CMYK Profile.icc": "RSWOP.icm"}


# ZapfDingbats built-in encoding: code -> Unicode (Adobe's dingbats mapping). Used to
# substitute a Unicode font (Windows: Segoe UI Symbol) where Zapf Dingbats isn't installed.
ZAPF_UNICODE = {
    33: 0x2701, 34: 0x2702, 35: 0x2703, 36: 0x2704, 37: 0x260E, 38: 0x2706, 39: 0x2707, 40: 0x2708,
    41: 0x2709, 42: 0x261B, 43: 0x261E, 44: 0x270C, 45: 0x270D, 46: 0x270E, 47: 0x270F, 48: 0x2710,
    49: 0x2711, 50: 0x2712, 51: 0x2713, 52: 0x2714, 53: 0x2715, 54: 0x2716, 55: 0x2717, 56: 0x2718,
    57: 0x2719, 58: 0x271A, 59: 0x271B, 60: 0x271C, 61: 0x271D, 62: 0x271E, 63: 0x271F, 64: 0x2720,
    65: 0x2721, 66: 0x2722, 67: 0x2723, 68: 0x2724, 69: 0x2725, 70: 0x2726, 71: 0x2727, 72: 0x2605,
    73: 0x2729, 74: 0x272A, 75: 0x272B, 76: 0x272C, 77: 0x272D, 78: 0x272E, 79: 0x272F, 80: 0x2730,
    81: 0x2731, 82: 0x2732, 83: 0x2733, 84: 0x2734, 85: 0x2735, 86: 0x2736, 87: 0x2737, 88: 0x2738,
    89: 0x2739, 90: 0x273A, 91: 0x273B, 92: 0x273C, 93: 0x273D, 94: 0x273E, 95: 0x273F, 96: 0x2740,
    97: 0x2741, 98: 0x2742, 99: 0x2743, 100: 0x2744, 101: 0x2745, 102: 0x2746, 103: 0x2747, 104: 0x2748,
    105: 0x2749, 106: 0x274A, 107: 0x274B, 108: 0x25CF, 109: 0x274D, 110: 0x25A0, 111: 0x274F, 112: 0x2750,
    113: 0x2751, 114: 0x2752, 115: 0x25B2, 116: 0x25BC, 117: 0x25C6, 118: 0x2756, 119: 0x25D7, 120: 0x2758,
    121: 0x2759, 122: 0x275A, 123: 0x275B, 124: 0x275C, 125: 0x275D, 126: 0x275E, 128: 0x2768, 129: 0x2769,
    130: 0x276A, 131: 0x276B, 132: 0x276C, 133: 0x276D, 134: 0x276E, 135: 0x276F, 136: 0x2770, 137: 0x2771,
    138: 0x2772, 139: 0x2773, 140: 0x2774, 141: 0x2775, 161: 0x2761, 162: 0x2762, 163: 0x2763, 164: 0x2764,
    165: 0x2765, 166: 0x2766, 167: 0x2767, 168: 0x2663, 169: 0x2666, 170: 0x2665, 171: 0x2660, 172: 0x2460,
    173: 0x2461, 174: 0x2462, 175: 0x2463, 176: 0x2464, 177: 0x2465, 178: 0x2466, 179: 0x2467, 180: 0x2468,
    181: 0x2469, 182: 0x2776, 183: 0x2777, 184: 0x2778, 185: 0x2779, 186: 0x277A, 187: 0x277B, 188: 0x277C,
    189: 0x277D, 190: 0x277E, 191: 0x277F, 192: 0x2780, 193: 0x2781, 194: 0x2782, 195: 0x2783, 196: 0x2784,
    197: 0x2785, 198: 0x2786, 199: 0x2787, 200: 0x2788, 201: 0x2789, 202: 0x278A, 203: 0x278B, 204: 0x278C,
    205: 0x278D, 206: 0x278E, 207: 0x278F, 208: 0x2790, 209: 0x2791, 210: 0x2792, 211: 0x2793, 212: 0x2794,
    213: 0x2192, 214: 0x2194, 215: 0x2195, 216: 0x2798, 217: 0x2799, 218: 0x279A, 219: 0x279B, 220: 0x279C,
    221: 0x279D, 222: 0x279E, 223: 0x279F, 224: 0x27A0, 225: 0x27A1, 226: 0x27A2, 227: 0x27A3, 228: 0x27A4,
    229: 0x27A5, 230: 0x27A6, 231: 0x27A7, 232: 0x27A8, 233: 0x27A9, 234: 0x27AA, 235: 0x27AB, 236: 0x27AC,
    237: 0x27AD, 238: 0x27AE, 239: 0x27AF, 241: 0x27B1, 242: 0x27B2, 243: 0x27B3, 244: 0x27B4, 245: 0x27B5,
    246: 0x27B6, 247: 0x27B7, 248: 0x27B8, 249: 0x27B9, 250: 0x27BA, 251: 0x27BB, 252: 0x27BC, 253: 0x27BD,
    254: 0x27BE,
}


def system_path(path, postscript=None):
    """A macOS system font or color profile path, or its Windows equivalent
    when running on Windows (None if there is none). Unchanged on macOS."""
    path = str(path)
    if sys.platform != "win32" or Path(path).exists():
        return path
    name = Path(path).name
    if name in _WINDOWS_PROFILES:
        target = WINDOWS_COLOR / _WINDOWS_PROFILES[name]
    else:
        mapped = _WINDOWS_EQUIVALENTS.get((name, postscript)) or _WINDOWS_EQUIVALENTS.get(name)
        target = WINDOWS_FONTS / mapped if mapped else None
    return str(target) if target is not None and target.exists() else None


def system_font_folders():
    if sys.platform == "win32":
        local = Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "Windows" / "Fonts"
        return [WINDOWS_FONTS, local]
    return [Path("/System/Library/Fonts"), Path("/System/Library/Fonts/Supplemental"), Path("/Library/Fonts")]


def _fallback_candidates():
    """Broad-coverage fonts, best first. Windows has no Arial Unicode, so it
    chains Arial, Segoe UI Symbol and the CJK Gothic families."""
    if sys.platform == "win32":
        names = ("arial.ttf", "seguisym.ttf", "YuGothM.ttc", "msgothic.ttc")
        paths = [str(WINDOWS_FONTS / name) for name in names]
    else:
        paths = list(DEFAULT_FONTS)
    return [path for path in paths if Path(path).exists()]


_CMAPS = {}


def _cmap(path):
    if path not in _CMAPS:
        from fontTools.ttLib import TTFont
        try:
            with TTFont(path, fontNumber=0, lazy=True) as font:
                _CMAPS[path] = frozenset((font.getBestCmap() or {}).keys())
        except Exception:  # noqa: BLE001 - an unreadable font covers nothing
            _CMAPS[path] = frozenset()
    return _CMAPS[path]


def fallback_font(text=""):
    """{"path"} of the first fallback font with glyphs for all of `text`
    (else the best one), or None when no fallback font is installed."""
    candidates = _fallback_candidates()
    needed = {ord(c) for c in text if not c.isspace()}
    for path in candidates:
        if needed <= _cmap(path):
            return {"path": path}
    return {"path": candidates[0]} if candidates else None


def resolve_font(spec=None):
    """spec: None, a font file path, or {"path", "index"} / {"family", "bold", "italic"}."""
    if isinstance(spec, str):
        return spec, 0
    if isinstance(spec, dict):
        if spec.get("path"):
            return spec["path"], int(spec.get("index", 0))
        family = spec.get("family", "sans")
        path = STYLE_FONTS.get((family, bool(spec.get("bold")), bool(spec.get("italic"))))
        path = path and system_path(path)
        if path and Path(path).exists():
            return path, 0
    for path in DEFAULT_FONTS:
        path = system_path(path)
        if path and Path(path).exists():
            return path, 0
    raise EngineError("DEPENDENCY_UNAVAILABLE", "No usable font was found on this computer.")


class EmbeddedFont:
    def __init__(self, pdf, spec=None):
        from fontTools.ttLib import TTFont
        path, index = resolve_font(spec)
        self.pdf = pdf
        self.path = path
        self.index = index
        self.font = TTFont(path, fontNumber=index, lazy=False)
        self.cmap = self.font.getBestCmap() or {}
        self.units = self.font["head"].unitsPerEm
        self.hmtx = self.font["hmtx"].metrics
        self.order = self.font.getGlyphOrder()
        self.used = {}  # gid -> text
        self._gids = {}
        self._index = {name: i for i, name in enumerate(self.order)}
        self.ref = pdf.make_indirect(pikepdf.Dictionary(Type=Name.Font))
        name = self.font["name"].getDebugName(6) or "Font"
        self.base = "".join(c for c in name if c.isalnum() or c in "-_")[:48] or "Font"
        os2 = self.font["OS/2"] if "OS/2" in self.font else None
        self.ascent = (getattr(os2, "sTypoAscender", 0) or self.font["hhea"].ascent) / self.units
        self.descent = (getattr(os2, "sTypoDescender", 0) or self.font["hhea"].descent) / self.units
        self.cap_height = (getattr(os2, "sCapHeight", 0) or self.ascent * self.units * 0.7) / self.units

    def gid(self, char):
        return self._index.get(self.cmap.get(ord(char)), 0)

    def _gid_cached(self, char):
        if char not in self._gids:
            self._gids[char] = self.gid(char)
        return self._gids[char]

    def advance(self, gid):
        return self.hmtx[self.order[gid]][0] / self.units

    def width(self, text, size):
        return sum(self.advance(self._gid_cached(c)) for c in text) * size

    def has_glyphs(self, text):
        return all(self._gid_cached(c) != 0 for c in text if not c.isspace())

    def encode(self, text):
        """Hex string operand for Tj; records glyphs for the subset."""
        out = []
        for char in text:
            gid = self._gid_cached(char)
            self.used.setdefault(gid, char)
            out.append(f"{gid:04X}")
        return "<" + "".join(out) + ">"

    def finish(self):
        from fontTools import subset
        gids = sorted(set(self.used) | {0})
        options = subset.Options()
        options.retain_gids = True
        options.notdef_outline = True
        options.name_IDs = ["*"]
        options.drop_tables += ["DSIG", "GSUB", "GPOS", "morx", "kerx"]
        subsetter = subset.Subsetter(options)
        subsetter.populate(glyphs=[self.order[g] for g in gids])
        font = self.font
        subsetter.subset(font)
        data = BytesIO()
        font.save(data)
        import hashlib
        seed = hashlib.sha1(repr(sorted(self.used)).encode()).digest()
        tag = "".join(chr(65 + b % 26) for b in seed[:6]) + "+"
        base = Name("/" + tag + self.base)
        cff = "CFF " in font or "CFF2" in font
        stream = pikepdf.Stream(self.pdf, data.getvalue())
        if cff:
            stream.Subtype = Name.OpenType
        widths = pikepdf.Array()
        for gid in gids:
            widths.append(gid)
            widths.append(pikepdf.Array([round(self.advance(gid) * 1000)]))
        head = self.font["head"]
        scale = 1000 / self.units
        descriptor = pikepdf.Dictionary(
            Type=Name.FontDescriptor, FontName=base, Flags=32,
            FontBBox=[round(head.xMin * scale), round(head.yMin * scale),
                      round(head.xMax * scale), round(head.yMax * scale)],
            ItalicAngle=0, Ascent=round(self.ascent * 1000), Descent=round(self.descent * 1000),
            CapHeight=round(self.cap_height * 1000), StemV=80)
        descriptor[Name.FontFile3 if cff else Name.FontFile2] = self.pdf.make_indirect(stream)
        cid = pikepdf.Dictionary(
            Type=Name.Font, Subtype=Name.CIDFontType0 if cff else Name.CIDFontType2,
            BaseFont=base, CIDSystemInfo=pikepdf.Dictionary(Registry="Adobe", Ordering="Identity", Supplement=0),
            FontDescriptor=self.pdf.make_indirect(descriptor), W=widths, DW=1000)
        if not cff:
            cid.CIDToGIDMap = Name.Identity
        lines = ["/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
                 "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
                 "/CMapName /Adobe-Identity-UCS def", "/CMapType 2 def",
                 "1 begincodespacerange", "<0000> <FFFF>", "endcodespacerange"]
        entries = [(g, t) for g, t in sorted(self.used.items()) if g]
        for start in range(0, len(entries), 100):
            chunk = entries[start:start + 100]
            lines.append(f"{len(chunk)} beginbfchar")
            for g, t in chunk:
                lines.append(f"<{g:04X}> <{t.encode('utf-16-be').hex().upper()}>")
            lines.append("endbfchar")
        lines += ["endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end"]
        to_unicode = self.pdf.make_indirect(pikepdf.Stream(self.pdf, "\n".join(lines).encode()))
        self.ref.Subtype = Name.Type0
        self.ref.BaseFont = base
        self.ref.Encoding = Name("/Identity-H")
        self.ref.DescendantFonts = pikepdf.Array([self.pdf.make_indirect(cid)])
        self.ref.ToUnicode = to_unicode
        return self.ref


def name_text(value, default=""):
    """Text of a PDF name such as /BaseFont, with its leading slash. Names are
    bytes: GBK/Shift-JIS font names (common in CJK documents) are not UTF-8, and
    str(pikepdf.Name) raises on them, so decode leniently instead."""
    import re
    if value is None:
        return default
    if isinstance(value, pikepdf.Name):
        raw = value.unparse()  # b"/Sim#BA..." with #xx escapes
        data = re.sub(rb"#([0-9A-Fa-f]{2})", lambda m: bytes([int(m.group(1), 16)]), raw)
        return data.decode("utf-8", errors="replace")
    return str(value)


def pdf_string(text):
    """Literal string operand for standard-14 WinAnsi text."""
    raw = text.encode("cp1252", errors="replace")
    return "(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)").decode("latin-1") + ")"


def color_ops(color, stroke=False):
    """[r, g, b] or [r, g, b, a] as 0-255 ints or 0-1 floats."""
    if color is None:
        return ""
    values = list(color)[:3]
    if any(v > 1 for v in values):
        values = [v / 255 for v in values]
    return " ".join(f"{v:.4f}" for v in values) + (" RG" if stroke else " rg")


def alpha(color):
    if color is None or len(color) < 4:
        return 1.0
    a = color[3]
    return a / 255 if a > 1 else a
