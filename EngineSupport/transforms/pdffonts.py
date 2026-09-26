"""Reading the fonts of existing PDF text: code splitting, Unicode, widths.

`FontInfo` answers what the interpreter needs for every glyph a show
operator paints (character codes, advance widths, vertical extent, Unicode
text) and what editing needs to write new text in an existing font
(`encode`, `can_encode`). Standard-14 fonts that carry no widths use the
metrics of the equivalent macOS system faces.
"""
from functools import lru_cache
from io import BytesIO
from pathlib import Path
import re

import pikepdf

from transforms.fonts import name_text
from pikepdf import Name

SUBSET = re.compile(r"^[A-Z]{6}\+")

STANDARD_FACES = {
    "Helvetica": ("/System/Library/Fonts/Helvetica.ttc", "Helvetica"),
    "Helvetica-Bold": ("/System/Library/Fonts/Helvetica.ttc", "Helvetica-Bold"),
    "Helvetica-Oblique": ("/System/Library/Fonts/Helvetica.ttc", "Helvetica-Oblique"),
    "Helvetica-BoldOblique": ("/System/Library/Fonts/Helvetica.ttc", "Helvetica-BoldOblique"),
    "Times-Roman": ("/System/Library/Fonts/Times.ttc", "Times-Roman"),
    "Times-Bold": ("/System/Library/Fonts/Times.ttc", "Times-Bold"),
    "Times-Italic": ("/System/Library/Fonts/Times.ttc", "Times-Italic"),
    "Times-BoldItalic": ("/System/Library/Fonts/Times.ttc", "Times-BoldItalic"),
    "Symbol": ("/System/Library/Fonts/Symbol.ttf", None),
    "ZapfDingbats": ("/System/Library/Fonts/ZapfDingbats.ttf", None),
}
ALIASES = {
    "Arial": "Helvetica", "ArialMT": "Helvetica", "Arial,Bold": "Helvetica-Bold", "Arial-BoldMT": "Helvetica-Bold",
    "Arial,Italic": "Helvetica-Oblique", "Arial-ItalicMT": "Helvetica-Oblique",
    "Arial,BoldItalic": "Helvetica-BoldOblique", "Arial-BoldItalicMT": "Helvetica-BoldOblique",
    "TimesNewRoman": "Times-Roman", "TimesNewRomanPSMT": "Times-Roman", "TimesNewRoman,Bold": "Times-Bold",
    "TimesNewRomanPS-BoldMT": "Times-Bold", "TimesNewRoman,Italic": "Times-Italic",
    "TimesNewRomanPS-ItalicMT": "Times-Italic", "TimesNewRoman,BoldItalic": "Times-BoldItalic",
    "TimesNewRomanPS-BoldItalicMT": "Times-BoldItalic", "Times": "Times-Roman",
}


# ------------------------------------------------------------------ encodings

def _standard_encoding():
    from fontTools.encodings.StandardEncoding import StandardEncoding
    return list(StandardEncoding)


def _mac_roman():
    from fontTools.encodings.MacRoman import MacRoman
    return list(MacRoman)


def _unicode_of_name(name):
    if not name or name == ".notdef":
        return ""
    from fontTools import agl
    text = agl.toUnicode(name)
    if text:
        return text
    match = re.match(r"^(?:uni|u)([0-9A-Fa-f]{4,6})$", name)
    if match:
        try:
            return chr(int(match.group(1), 16))
        except ValueError:
            return ""
    return ""


@lru_cache(maxsize=None)
def base_encoding_names(name):
    """256 glyph names (or None entries) for a named base encoding."""
    if name == "StandardEncoding":
        return tuple(n if n != ".notdef" else None for n in _standard_encoding())
    if name == "MacRomanEncoding":
        return tuple(n if n != ".notdef" else None for n in _mac_roman())
    return None


def _winansi_char(code):
    if code in (0x81, 0x8D, 0x8F, 0x90, 0x9D):
        return ""
    if code == 0xAD:
        return "-"
    try:
        return bytes([code]).decode("cp1252")
    except UnicodeDecodeError:
        return ""


# ------------------------------------------------------------------ CMaps

TOKEN = re.compile(rb"<[0-9A-Fa-f\s]*>|\[|\]|/[^\s/<>\[\]()]+|-?\d+|[A-Za-z]+")


def _hex(token):
    return bytes.fromhex(token[1:-1].decode("ascii").replace(" ", "").replace("\n", "").replace("\r", "")
                         .replace("\t", "") + ("0" if len(re.sub(rb"\s", b"", token[1:-1])) % 2 else ""))


def _utf16(data):
    if not data:
        return ""
    try:
        return data.decode("utf-16-be", errors="ignore")
    except Exception:
        return ""


def parse_cmap(data):
    """Returns (codespace [(nbytes, lo, hi)], unicode {code: str}, cids {code: cid})."""
    tokens = TOKEN.findall(data)
    codespace, uni, cids = [], {}, {}
    i, n = 0, len(tokens)
    mode = None
    while i < n:
        t = tokens[i]
        if t in (b"begincodespacerange", b"beginbfchar", b"beginbfrange", b"begincidrange", b"begincidchar",
                 b"beginnotdefrange"):
            mode = t[5:]
            i += 1
            continue
        if t.startswith(b"end"):
            mode = None
            i += 1
            continue
        try:
            if mode == b"codespacerange" and t.startswith(b"<") and i + 1 < n:
                lo, hi = _hex(t), _hex(tokens[i + 1])
                codespace.append((len(lo), int.from_bytes(lo, "big"), int.from_bytes(hi, "big")))
                i += 2
                continue
            if mode == b"bfchar" and t.startswith(b"<") and i + 1 < n:
                src, dst = _hex(t), tokens[i + 1]
                if dst.startswith(b"<"):
                    uni[int.from_bytes(src, "big")] = _utf16(_hex(dst))
                elif dst.startswith(b"/"):
                    uni[int.from_bytes(src, "big")] = _unicode_of_name(dst[1:].decode("latin-1"))
                i += 2
                continue
            if mode == b"bfrange" and t.startswith(b"<") and i + 2 < n:
                lo, hi = int.from_bytes(_hex(t), "big"), int.from_bytes(_hex(tokens[i + 1]), "big")
                dst = tokens[i + 2]
                if hi - lo > 65535:
                    hi = lo + 65535
                if dst == b"[":
                    j = i + 3
                    code = lo
                    while j < n and tokens[j] != b"]":
                        if tokens[j].startswith(b"<"):
                            uni[code] = _utf16(_hex(tokens[j]))
                        code += 1
                        j += 1
                    i = j + 1
                    continue
                if dst.startswith(b"<"):
                    base = _hex(dst)
                    if len(base) >= 2:
                        prefix, last = base[:-2], int.from_bytes(base[-2:], "big")
                        for k, code in enumerate(range(lo, hi + 1)):
                            value = last + k
                            if value > 0xFFFF:
                                break
                            uni[code] = _utf16(prefix + value.to_bytes(2, "big"))
                    else:
                        for k, code in enumerate(range(lo, hi + 1)):
                            uni[code] = chr(base[0] + k) if base else ""
                i += 3
                continue
            if mode == b"cidrange" and t.startswith(b"<") and i + 2 < n:
                lo, hi = int.from_bytes(_hex(t), "big"), int.from_bytes(_hex(tokens[i + 1]), "big")
                start = int(tokens[i + 2])
                if hi - lo <= 65535:
                    for k, code in enumerate(range(lo, hi + 1)):
                        cids[code] = start + k
                i += 3
                continue
            if mode == b"cidchar" and t.startswith(b"<") and i + 1 < n:
                cids[int.from_bytes(_hex(t), "big")] = int(tokens[i + 1])
                i += 2
                continue
        except (ValueError, IndexError):
            pass
        i += 1
    return codespace, uni, cids


# ------------------------------------------------------------------ system metrics

@lru_cache(maxsize=16)
def _system_face(path, postscript):
    from fontTools.ttLib import TTFont, TTCollection
    if not Path(path).exists():
        return None
    try:
        if path.endswith((".ttc", ".otc")):
            collection = TTCollection(path, lazy=True)
            fonts = collection.fonts
            font = next((f for f in fonts if f["name"].getDebugName(6) == postscript), fonts[0])
            cmap = dict(font.getBestCmap() or {})
            units = font["head"].unitsPerEm
            hmtx = dict(font["hmtx"].metrics)
            collection.close()
        else:
            font = TTFont(path, lazy=True)
            cmap = dict(font.getBestCmap() or {})
            units = font["head"].unitsPerEm
            hmtx = dict(font["hmtx"].metrics)
            font.close()
        return cmap, units, hmtx
    except Exception:
        return None


def standard_width(base, char):
    """Advance (1/1000 em) of `char` in a standard-14 font, from system faces."""
    name = ALIASES.get(base, base)
    if name.startswith("Courier"):
        return 600
    entry = STANDARD_FACES.get(name)
    if entry is None:
        lowered = name.lower()
        if "courier" in lowered or "mono" in lowered:
            return 600
        bold = "bold" in lowered
        italic = "italic" in lowered or "oblique" in lowered
        family = "Times" if ("times" in lowered or "serif" in lowered and "sans" not in lowered) else "Helvetica"
        suffix = {(False, False): "", (True, False): "-Bold", (False, True): "-Oblique" if family == "Helvetica" else "-Italic",
                  (True, True): "-BoldOblique" if family == "Helvetica" else "-BoldItalic"}[(bold, italic)]
        entry = STANDARD_FACES.get(family + suffix if family + suffix in STANDARD_FACES else ("Times-Roman" if family == "Times" and not suffix else family + suffix))
        if entry is None:
            entry = STANDARD_FACES["Helvetica"]
    face = _system_face(*entry)
    if face is None or not char:
        return 556
    cmap, units, hmtx = face
    glyph = cmap.get(ord(char[0]))
    if glyph is None or glyph not in hmtx:
        return 556 if char != " " else 278
    return hmtx[glyph][0] * 1000 / units


# ------------------------------------------------------------------ fonts

def _number(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


class FontInfo:
    def __init__(self, font):
        self.obj = font
        self.key = f"{font.objgen[0]} {font.objgen[1]}" if font.is_indirect else f"d{id(font)}"
        self.subtype = str(font.get("/Subtype", ""))
        base = name_text(font.get("/BaseFont")).lstrip("/")
        self.subset = bool(SUBSET.match(base))
        self.base_font = SUBSET.sub("", base) or "Unknown"
        self.is_type0 = self.subtype == "/Type0"
        self.is_type3 = self.subtype == "/Type3"
        descendant = None
        if self.is_type0:
            kids = font.get("/DescendantFonts")
            if isinstance(kids, pikepdf.Array) and len(kids):
                descendant = kids[0]
        self.descendant = descendant
        descriptor = (descendant if descendant is not None else font).get("/FontDescriptor")
        self.descriptor = descriptor if isinstance(descriptor, pikepdf.Dictionary) else pikepdf.Dictionary()
        self.flags = int(_number(self.descriptor.get("/Flags", 0)))
        self.program_key = next((k for k in ("/FontFile", "/FontFile2", "/FontFile3") if k in self.descriptor), None)
        self.embedded = self.program_key is not None
        ascent = _number(self.descriptor.get("/Ascent", 0)) / 1000
        descent = _number(self.descriptor.get("/Descent", 0)) / 1000
        bbox = self.descriptor.get("/FontBBox")
        if (ascent <= 0.2 or ascent > 1.6) and isinstance(bbox, pikepdf.Array) and len(bbox) == 4:
            ascent = _number(bbox[3]) / 1000
        if not 0.2 < ascent <= 1.6:
            ascent = 0.8
        if descent >= 0 or descent < -0.8:
            descent = -0.2
        self.ascent, self.descent = ascent, descent
        self.font_matrix = (0.001, 0, 0, 0.001, 0, 0)
        if self.is_type3:
            fm = font.get("/FontMatrix")
            if isinstance(fm, pikepdf.Array) and len(fm) == 6:
                self.font_matrix = tuple(_number(v) for v in fm)
            self.ascent, self.descent = 0.8, -0.2
        self._widths = {}
        self._default_width = 0.0
        self._to_unicode = {}
        self._names = {}
        self.codespace = [(1, 0, 255)]
        self._cids = None  # None: identity
        self._program_chars = None
        self._reverse = None
        self._load()

    # -------------------------------------------------------------- loading
    def _load(self):
        font = self.obj
        tu = font.get("/ToUnicode")
        if isinstance(tu, pikepdf.Stream):
            try:
                space, uni, _ = parse_cmap(tu.read_bytes())
                self._to_unicode = uni
                if self.is_type0 and space and not isinstance(font.get("/Encoding"), pikepdf.Stream) \
                        and str(font.get("/Encoding", "")) not in ("/Identity-H", "/Identity-V"):
                    self.codespace = space
            except pikepdf.PdfError:
                pass
        if self.is_type0:
            self._load_cid()
        else:
            self._load_simple()

    def _load_cid(self):
        font, desc = self.obj, self.descendant
        encoding = font.get("/Encoding")
        self.codespace = [(2, 0, 0xFFFF)]
        if isinstance(encoding, pikepdf.Stream):
            try:
                space, _, cids = parse_cmap(encoding.read_bytes())
                if space:
                    self.codespace = space
                if cids:
                    self._cids = cids
            except pikepdf.PdfError:
                pass
        elif isinstance(encoding, Name):
            name = str(encoding)
            if name not in ("/Identity-H", "/Identity-V") and self._to_unicode:
                # Predefined CMaps: take code lengths from ToUnicode when possible.
                lengths = {max(1, (c.bit_length() + 7) // 8) for c in list(self._to_unicode)[:64]}
                if lengths == {1}:
                    self.codespace = [(1, 0, 0xFF)]
        if desc is None:
            self._default_width = 1000
            return
        self._default_width = _number(desc.get("/DW", 1000), 1000)
        w = desc.get("/W")
        if isinstance(w, pikepdf.Array):
            items = list(w)
            i = 0
            while i < len(items):
                try:
                    first = int(items[i])
                    nxt = items[i + 1]
                    if isinstance(nxt, pikepdf.Array):
                        for k, value in enumerate(nxt):
                            self._widths[first + k] = _number(value)
                        i += 2
                    else:
                        last, value = int(nxt), _number(items[i + 2])
                        for cid in range(first, min(last, first + 65535) + 1):
                            self._widths[cid] = value
                        i += 3
                except (IndexError, TypeError, ValueError):
                    break

    def _load_simple(self):
        font = self.obj
        first = int(_number(font.get("/FirstChar", 0)))
        widths = font.get("/Widths")
        if isinstance(widths, pikepdf.Array):
            for k, value in enumerate(widths):
                self._widths[first + k] = _number(value)
        self._default_width = _number(self.descriptor.get("/MissingWidth", 0))
        encoding = font.get("/Encoding")
        base_name, differences = None, None
        if isinstance(encoding, Name):
            base_name = str(encoding)[1:]
        elif isinstance(encoding, pikepdf.Dictionary):
            if "/BaseEncoding" in encoding:
                base_name = str(encoding.BaseEncoding)[1:]
            differences = encoding.get("/Differences")
        symbolic = bool(self.flags & 4) and not (self.flags & 32)
        self.symbolic = symbolic
        self.base_encoding = base_name
        names = {}
        if base_name in ("StandardEncoding", "MacRomanEncoding"):
            table = base_encoding_names(base_name)
            names = {code: table[code] for code in range(256) if table[code]}
        elif base_name is None and not symbolic and self.subtype == "/Type1" and not self.base_font.startswith(("Symbol", "ZapfDingbats")):
            table = base_encoding_names("StandardEncoding")
            names = {code: table[code] for code in range(256) if table[code]}
        if isinstance(differences, pikepdf.Array):
            code = 0
            for item in differences:
                if isinstance(item, Name):
                    names[code] = str(item)[1:]
                    code += 1
                else:
                    try:
                        code = int(item)
                    except (TypeError, ValueError):
                        pass
        self._names = names
        self._differences = isinstance(differences, pikepdf.Array)

    # -------------------------------------------------------------- per code
    def split(self, data):
        """Character codes of a string operand: [(code, nbytes)]."""
        if not self.is_type0:
            return [(b, 1) for b in data]
        out = []
        i, n = 0, len(data)
        spaces = sorted(self.codespace, key=lambda s: s[0])
        while i < n:
            chosen = None
            for nbytes, lo, hi in spaces:
                if i + nbytes <= n:
                    value = int.from_bytes(data[i:i + nbytes], "big")
                    if lo <= value <= hi:
                        chosen = (value, nbytes)
                        break
            if chosen is None:
                nbytes = min(spaces[0][0] if spaces else 2, n - i) or 1
                chosen = (int.from_bytes(data[i:i + nbytes], "big"), nbytes)
            out.append(chosen)
            i += chosen[1]
        return out

    def cid(self, code):
        if self._cids is None:
            return code
        return self._cids.get(code, 0)

    def width(self, code):
        """Horizontal displacement in text space per unit font size."""
        if self.is_type0:
            return self._widths.get(self.cid(code), self._default_width) / 1000
        if code in self._widths:
            w = self._widths[code]
            if self.is_type3:
                return w * self.font_matrix[0]
            return w / 1000
        if self.is_type3:
            return 0.5
        if "/Widths" not in self.obj:
            return standard_width(self.base_font, self.unicode(code) or " ") / 1000
        return self._default_width / 1000

    def unicode(self, code):
        if code in self._to_unicode:
            return self._to_unicode[code]
        if self.is_type0:
            return self._program_unicode(code)
        name = self._names.get(code)
        if name:
            return _unicode_of_name(name)
        base = getattr(self, "base_encoding", None)
        if base == "WinAnsiEncoding" or (base is None and self.subtype == "/TrueType" and not self.symbolic):
            return _winansi_char(code)
        if base is None and not self._names and 32 <= code < 127:
            return chr(code)
        if self.symbolic and 32 <= code < 256:
            return self._program_unicode(code) or (chr(code) if 32 <= code < 127 else "")
        return ""

    def is_space(self, code, nbytes):
        return nbytes == 1 and code == 32

    # -------------------------------------------------------------- program
    def _program(self):
        if not self.embedded:
            return None
        if hasattr(self, "_parsed_program"):
            return self._parsed_program
        self._parsed_program = None
        try:
            data = self.descriptor[self.program_key].read_bytes()
            if self.program_key == "/FontFile2" or (self.program_key == "/FontFile3" and
                                                     str(self.descriptor[self.program_key].get("/Subtype", "")) == "/OpenType"):
                from fontTools.ttLib import TTFont
                self._parsed_program = ("sfnt", TTFont(BytesIO(data), lazy=True))
            elif self.program_key == "/FontFile3":
                from fontTools.cffLib import CFFFontSet
                cff = CFFFontSet()
                cff.decompile(BytesIO(data), None)
                self._parsed_program = ("cff", cff[cff.fontNames[0]])
        except Exception:
            self._parsed_program = None
        return self._parsed_program

    def _program_unicode(self, code):
        program = self._program()
        if program is None or program[0] != "sfnt":
            return ""
        font = program[1]
        try:
            if self.is_type0:
                gid = self.cid(code)
                cid_to_gid = self.descendant.get("/CIDToGIDMap") if self.descendant is not None else None
                if isinstance(cid_to_gid, pikepdf.Stream):
                    table = cid_to_gid.read_bytes()
                    gid = int.from_bytes(table[gid * 2:gid * 2 + 2], "big") if gid * 2 + 2 <= len(table) else 0
                reverse = self._gid_unicode(font)
                return reverse.get(gid, "")
            cmap = font["cmap"]
            for table in cmap.tables:
                if table.platformID == 3 and table.platEncID == 0:
                    glyph = table.cmap.get(0xF000 + code) or table.cmap.get(code)
                    if glyph:
                        return _unicode_of_name(glyph)
        except Exception:
            return ""
        return ""

    def _gid_unicode(self, font):
        if getattr(self, "_gid_map", None) is None:
            self._gid_map = {}
            try:
                order = font.getGlyphOrder()
                index = {name: i for i, name in enumerate(order)}
                for uni, name in (font.getBestCmap() or {}).items():
                    gid = index.get(name)
                    if gid is not None and gid not in self._gid_map:
                        self._gid_map[gid] = chr(uni)
            except Exception:
                pass
        return self._gid_map

    # -------------------------------------------------------------- encoding new text
    def _reverse_map(self):
        if self._reverse is not None:
            return self._reverse
        reverse = {}
        if self.is_type0:
            for code, text in self._to_unicode.items():
                if len(text) == 1 and text not in reverse:
                    reverse[text] = code
            if not self.subset:
                program = self._program()
                identity = self._cids is None and (self.descendant is None or
                                                   not isinstance(self.descendant.get("/CIDToGIDMap"), pikepdf.Stream))
                if program and program[0] == "sfnt" and identity:
                    for gid, char in self._gid_unicode(program[1]).items():
                        reverse.setdefault(char, gid)
        else:
            available = self._available_simple_codes()
            for code in range(256):
                if available is not None and code not in available:
                    continue
                text = self.unicode(code)
                if len(text) == 1 and text not in reverse:
                    reverse[text] = code
        self._reverse = reverse
        return reverse

    def _available_simple_codes(self):
        """Codes whose glyphs exist, or None when every mapped code is usable."""
        if not self.embedded:
            return None
        codes = set(self._to_unicode) if self._to_unicode else set()
        if self.subset or self.program_key == "/FontFile3":
            program = self._program()
            if program is not None:
                kind, font = program
                try:
                    if kind == "cff":
                        names = set(font.charset)
                        for code in range(256):
                            name = self._names.get(code)
                            if name and name in names:
                                codes.add(code)
                            elif not name and not self._names:
                                std = base_encoding_names("StandardEncoding")[code]
                                if std and std in names:
                                    codes.add(code)
                    else:
                        glyf = font["glyf"] if "glyf" in font else None
                        order = set(font.getGlyphOrder())
                        for table in font["cmap"].tables:
                            for key, glyph in table.cmap.items():
                                code = key - 0xF000 if 0xF000 <= key <= 0xF0FF else key
                                if 0 <= code < 256 and glyph in order:
                                    if glyf is None or glyph == ".notdef":
                                        continue
                                    g = glyf[glyph]
                                    if getattr(g, "numberOfContours", 0) != 0 or code == 32:
                                        codes.add(code)
                        if self._differences and "post" in font:
                            for code, name in self._names.items():
                                if name in order:
                                    codes.add(code)
                except Exception:
                    pass
            elif self._differences:
                codes |= set(self._names)
            return codes
        return None

    def can_encode(self, text):
        reverse = self._reverse_map()
        return all(ch in reverse for ch in text)

    def encode(self, text):
        """Bytes for `text` in this font's encoding (call can_encode first)."""
        reverse = self._reverse_map()
        if self.is_type0:
            nbytes = min((s[0] for s in self.codespace), default=2)
            nbytes = max(nbytes, 2) if all(s[0] >= 2 for s in self.codespace) else nbytes
            return b"".join(reverse[ch].to_bytes(nbytes, "big") for ch in text)
        return bytes(reverse[ch] for ch in text)

    def text_width(self, data, size, char_spacing=0.0, word_spacing=0.0, scale=1.0):
        total = 0.0
        for code, nbytes in self.split(data):
            total += (self.width(code) * size + char_spacing + (word_spacing if self.is_space(code, nbytes) else 0)) * scale
        return total

    # -------------------------------------------------------------- style
    def style(self):
        name = self.base_font
        lowered = name.lower()
        weight = _number(self.descriptor.get("/FontWeight", 0))
        bold = bool(re.search(r"bold|black|heavy|semibold|demi", lowered)) or weight >= 600 or bool(self.flags & (1 << 18))
        italic = bool(re.search(r"italic|oblique|slanted", lowered)) or bool(self.flags & 64) or \
            _number(self.descriptor.get("/ItalicAngle", 0)) < -3
        mono = bool(self.flags & 1) or bool(re.search(r"courier|mono|consol|menlo", lowered))
        serif = bool(self.flags & 2) or bool(re.search(r"times|serif|georgia|garamond|minion|cambria|palatino|book", lowered)) \
            and "sans" not in lowered
        family = re.split(r"[-,]", name)[0]
        family = re.sub(r"(PSMT|MT|PS)$", "", family) or name
        # "TimesNewRoman" -> "Times New Roman" style spacing for lookups.
        spaced = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", family)
        return {"base": name, "family": spaced, "bold": bold, "italic": italic, "mono": mono,
                "serif": serif and not mono, "embedded": self.embedded, "subset": self.subset}


_CACHE_KEY = "_zpdf_font_cache"


def font_info(cache, font):
    key = font.objgen if font.is_indirect else id(font)
    info = cache.get(key)
    if info is None:
        info = FontInfo(font)
        cache[key] = info
    return info
