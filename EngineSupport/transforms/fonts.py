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
    "Courier New Bold Italic.ttf": "courbi.ttf", "Symbol.ttf": "symbol.ttf",
    # Faces inside macOS collections, by PostScript name.
    ("Helvetica.ttc", "Helvetica"): "arial.ttf", ("Helvetica.ttc", "Helvetica-Bold"): "arialbd.ttf",
    ("Helvetica.ttc", "Helvetica-Oblique"): "ariali.ttf", ("Helvetica.ttc", "Helvetica-BoldOblique"): "arialbi.ttf",
    ("Times.ttc", "Times-Roman"): "times.ttf", ("Times.ttc", "Times-Bold"): "timesbd.ttf",
    ("Times.ttc", "Times-Italic"): "timesi.ttf", ("Times.ttc", "Times-BoldItalic"): "timesbi.ttf",
}
_WINDOWS_PROFILES = {"sRGB Profile.icc": "sRGB Color Space Profile.icm", "Generic CMYK Profile.icc": "RSWOP.icm"}


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
