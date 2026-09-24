"""Recover Unicode for glyphs PDFium reports as unmapped control codes.

PDFium returns the raw character code when a font has no ToUnicode mapping
and the code is not in a standard encoding. The embedded font program still
names its glyphs, so we parse just enough of it to map code → glyph name →
Unicode: CFF (charset + encoding) and TrueType (cmap + post 2.0). Anything we
cannot resolve stays flagged; nothing is guessed from context.
"""
from __future__ import annotations

import re
import struct
from dataclasses import dataclass, field

# Compact Adobe Glyph List subset: names seen in Latin business documents.
_AGL: dict[str, str] = {
    "space": " ", "exclam": "!", "quotedbl": '"', "numbersign": "#", "dollar": "$", "percent": "%",
    "ampersand": "&", "quotesingle": "'", "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+",
    "comma": ",", "hyphen": "-", "period": ".", "slash": "/", "zero": "0", "one": "1", "two": "2", "three": "3",
    "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "colon": ":", "semicolon": ";",
    "less": "<", "equal": "=", "greater": ">", "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\",
    "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|",
    "braceright": "}", "asciitilde": "~", "exclamdown": "¡", "cent": "¢", "sterling": "£", "currency": "¤",
    "yen": "¥", "brokenbar": "¦", "section": "§", "dieresis": "¨", "copyright": "©", "ordfeminine": "ª",
    "guillemotleft": "«", "logicalnot": "¬", "registered": "®", "macron": "¯", "degree": "°", "plusminus": "±",
    "acute": "´", "mu": "µ", "paragraph": "¶", "periodcentered": "·", "cedilla": "¸", "ordmasculine": "º",
    "guillemotright": "»", "onequarter": "¼", "onehalf": "½", "threequarters": "¾", "questiondown": "¿",
    "multiply": "×", "divide": "÷", "endash": "–", "emdash": "—", "quoteleft": "‘", "quoteright": "’",
    "quotesinglbase": "‚", "quotedblleft": "“", "quotedblright": "”", "quotedblbase": "„", "dagger": "†",
    "daggerdbl": "‡", "bullet": "•", "ellipsis": "…", "perthousand": "‰", "guilsinglleft": "‹", "guilsinglright": "›",
    "fraction": "⁄", "Euro": "€", "trademark": "™", "minus": "−", "fi": "fi", "fl": "fl", "ff": "ff", "ffi": "ffi",
    "ffl": "ffl", "sfthyphen": "­", "hyphentwo": "-", "nbspace": " ", "nonbreakingspace": " ",
    "checkmark": "✓", "arrowright": "→", "arrowleft": "←", "arrowup": "↑", "arrowdown": "↓", "star": "★",
    "AE": "Æ", "OE": "Œ", "ae": "æ", "oe": "œ", "germandbls": "ß", "Eth": "Ð", "eth": "ð", "Thorn": "Þ", "thorn": "þ",
    "Lslash": "Ł", "lslash": "ł", "Oslash": "Ø", "oslash": "ø", "dotlessi": "ı", "florin": "ƒ", "circumflex": "ˆ",
    "caron": "ˇ", "breve": "˘", "dotaccent": "˙", "ring": "˚", "ogonek": "˛", "tilde": "˜", "hungarumlaut": "˝",
}
for _c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz":
    _AGL[_c] = _c
_ACCENTS = {"grave": "̀", "acute": "́", "circumflex": "̂", "tilde": "̃", "dieresis": "̈",
            "ring": "̊", "cedilla": "̧", "caron": "̌", "macron": "̄"}

_CFF_STD_STRINGS = (
    ".notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus "
    "comma hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater "
    "question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum "
    "underscore quoteleft a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde "
    "exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft "
    "guilsinglleft guilsinglright fi fl endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase "
    "quotedblbase quotedblright guillemotright ellipsis perthousand questiondown grave acute circumflex tilde macron "
    "breve dotaccent dieresis ring cedilla hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE "
    "ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior logicalnot mu trademark Eth onehalf plusminus "
    "Thorn onequarter divide brokenbar degree thorn threequarters twosuperior registered minus eth multiply "
    "threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis "
    "Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde Scaron Uacute "
    "Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde ccedilla "
    "eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave ntilde oacute ocircumflex odieresis "
    "ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron"
).split()
_CFF_N_STD_STRINGS = 391  # the CFF spec defines 391 standard strings; the table above covers the common prefix
# StandardEncoding code -> name (subset sufficient for lookups; full table for 32..126 plus common high codes)
_STD_ENCODING: dict[int, str] = {}
for _i, _n in enumerate(_CFF_STD_STRINGS[1:96]):
    _STD_ENCODING[32 + _i] = _n
_STD_ENCODING.update({161: "exclamdown", 162: "cent", 163: "sterling", 164: "fraction", 165: "yen", 166: "florin",
                      167: "section", 168: "currency", 169: "quotesingle", 170: "quotedblleft", 171: "guillemotleft",
                      172: "guilsinglleft", 173: "guilsinglright", 174: "fi", 175: "fl", 177: "endash", 178: "dagger",
                      179: "daggerdbl", 180: "periodcentered", 182: "paragraph", 183: "bullet", 184: "quotesinglbase",
                      185: "quotedblbase", 186: "quotedblright", 187: "guillemotright", 188: "ellipsis",
                      189: "perthousand", 191: "questiondown", 208: "emdash", 225: "AE", 227: "ordfeminine",
                      232: "Lslash", 233: "Oslash", 234: "OE", 235: "ordmasculine", 241: "ae", 245: "dotlessi",
                      248: "lslash", 249: "oslash", 250: "oe", 251: "germandbls"})
_MAC_GLYPH_NAMES = (
    ".notdef .null nonmarkingreturn space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft "
    "parenright asterisk plus comma hyphen period slash zero one two three four five six seven eight nine colon "
    "semicolon less equal greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft "
    "backslash bracketright asciicircum underscore grave a b c d e f g h i j k l m n o p q r s t u v w x y z "
    "braceleft bar braceright asciitilde Adieresis Aring Ccedilla Eacute Ntilde Odieresis Udieresis aacute agrave "
    "acircumflex adieresis atilde aring ccedilla eacute egrave ecircumflex edieresis iacute igrave icircumflex "
    "idieresis ntilde oacute ograve ocircumflex odieresis otilde uacute ugrave ucircumflex udieresis dagger degree "
    "cent sterling section bullet paragraph germandbls registered copyright trademark acute dieresis notequal AE "
    "Oslash infinity plusminus lessequal greaterequal yen mu partialdiff summation product pi integral ordfeminine "
    "ordmasculine Omega ae oslash questiondown exclamdown logicalnot radical florin approxequal Delta guillemotleft "
    "guillemotright ellipsis nonbreakingspace Agrave Atilde Otilde OE oe endash emdash quotedblleft quotedblright "
    "quoteleft quoteright divide lozenge ydieresis Ydieresis fraction currency guilsinglleft guilsinglright fi fl "
    "daggerdbl periodcentered quotesinglbase quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis "
    "Egrave Iacute Icircumflex Idieresis Igrave Oacute Ocircumflex apple Ograve Uacute Ucircumflex Ugrave dotlessi "
    "circumflex tilde macron breve dotaccent ring cedilla hungarumlaut ogonek caron Lslash lslash Scaron scaron "
    "Zcaron zcaron brokenbar Eth eth Yacute yacute Thorn thorn minus multiply onesuperior twosuperior threesuperior "
    "onehalf onequarter threequarters franc Gbreve gbreve Idotaccent Scedilla scedilla Cacute cacute Ccaron ccaron "
    "dcroat"
).split()


def glyph_name_to_unicode(name: str) -> str | None:
    if not name or name == ".notdef":
        return None
    base = name.split(".")[0]  # strip variant suffixes like "fi.alt"
    if base in _AGL:
        return _AGL[base]
    if "_" in base:
        parts = [glyph_name_to_unicode(p) for p in base.split("_") if p]
        if parts and all(parts):
            return "".join(parts)
    m = re.fullmatch(r"uni((?:[0-9A-Fa-f]{4})+)", base)
    if m:
        hexes = m.group(1)
        return "".join(chr(int(hexes[i:i + 4], 16)) for i in range(0, len(hexes), 4))
    m = re.fullmatch(r"u([0-9A-Fa-f]{4,6})", base)
    if m:
        return chr(int(m.group(1), 16))
    # accented letters: "eacute" -> e + combining acute
    for acc, comb in _ACCENTS.items():
        if base.endswith(acc) and len(base) > len(acc):
            letter = base[: -len(acc)]
            if letter in _AGL and len(_AGL[letter]) == 1:
                import unicodedata
                return unicodedata.normalize("NFC", _AGL[letter] + comb)
    return None


# --- CFF --------------------------------------------------------------------

def _cff_index(data: bytes, pos: int) -> tuple[list[bytes], int]:
    count = struct.unpack(">H", data[pos:pos + 2])[0]
    pos += 2
    if count == 0:
        return [], pos
    off_size = data[pos]
    pos += 1
    offsets = []
    for i in range(count + 1):
        chunk = data[pos + i * off_size: pos + (i + 1) * off_size]
        offsets.append(int.from_bytes(chunk, "big"))
    pos += (count + 1) * off_size
    base = pos - 1
    items = [data[base + offsets[i]: base + offsets[i + 1]] for i in range(count)]
    return items, base + offsets[-1]


def _cff_dict(data: bytes) -> dict[int, list[float]]:
    out: dict[int, list[float]] = {}
    operands: list[float] = []
    i = 0
    while i < len(data):
        b0 = data[i]
        if b0 <= 21:
            op = b0
            i += 1
            if b0 == 12:
                op = 1200 + data[i]
                i += 1
            out[op] = operands
            operands = []
        elif b0 == 28:
            operands.append(struct.unpack(">h", data[i + 1:i + 3])[0]); i += 3
        elif b0 == 29:
            operands.append(struct.unpack(">i", data[i + 1:i + 5])[0]); i += 5
        elif b0 == 30:  # real number
            i += 1
            s = ""
            done = False
            while i < len(data) and not done:
                for nib in (data[i] >> 4, data[i] & 15):
                    if nib <= 9: s += str(nib)
                    elif nib == 10: s += "."
                    elif nib == 11: s += "E"
                    elif nib == 12: s += "E-"
                    elif nib == 14: s += "-"
                    elif nib == 15: done = True; break
                i += 1
            try:
                operands.append(float(s or "0"))
            except ValueError:
                operands.append(0.0)
        elif 32 <= b0 <= 246:
            operands.append(b0 - 139); i += 1
        elif 247 <= b0 <= 250:
            operands.append((b0 - 247) * 256 + data[i + 1] + 108); i += 2
        elif 251 <= b0 <= 254:
            operands.append(-(b0 - 251) * 256 - data[i + 1] - 108); i += 2
        else:
            i += 1
    return out


def cff_code_to_name(data: bytes) -> dict[int, str]:
    """Return code -> glyph name for a bare CFF font program. Adds a synthetic
    entry under key -1 -> "|"-joined names of glyphs no code reaches, so the
    caller can resolve a single unreachable glyph."""
    hdr_size = data[2]
    pos = hdr_size
    _, pos = _cff_index(data, pos)                 # Name INDEX
    top_dicts, pos = _cff_index(data, pos)         # Top DICT INDEX
    strings, pos = _cff_index(data, pos)           # String INDEX
    top = _cff_dict(top_dicts[0])
    if 1230 in top:  # CIDFont: no glyph names
        return {}
    charstrings_off = int(top.get(17, [0])[0])
    n_glyphs = struct.unpack(">H", data[charstrings_off:charstrings_off + 2])[0] if charstrings_off else 0

    def sid_name(sid: int) -> str:
        if sid < _CFF_N_STD_STRINGS:
            return _CFF_STD_STRINGS[sid] if sid < len(_CFF_STD_STRINGS) else f"sid{sid}"
        k = sid - _CFF_N_STD_STRINGS
        return strings[k].decode("latin-1") if k < len(strings) else f"sid{sid}"

    # charset: GID -> SID
    charset_off = int(top.get(15, [0])[0])
    gid_names = [".notdef"]
    if charset_off == 0:
        gid_names = _CFF_STD_STRINGS[:n_glyphs]
    elif charset_off in (1, 2):
        return {}  # expert charsets: rare in documents
    else:
        fmt = data[charset_off]
        p = charset_off + 1
        if fmt == 0:
            for _ in range(n_glyphs - 1):
                gid_names.append(sid_name(struct.unpack(">H", data[p:p + 2])[0])); p += 2
        elif fmt in (1, 2):
            while len(gid_names) < n_glyphs:
                first = struct.unpack(">H", data[p:p + 2])[0]; p += 2
                if fmt == 1:
                    n_left = data[p]; p += 1
                else:
                    n_left = struct.unpack(">H", data[p:p + 2])[0]; p += 2
                for k in range(n_left + 1):
                    if len(gid_names) >= n_glyphs:
                        break
                    gid_names.append(sid_name(first + k))
    # encoding: code -> GID
    enc_off = int(top.get(16, [0])[0])
    code_to_name: dict[int, str] = {}
    if enc_off in (0, 1):
        by_name = {n: i for i, n in enumerate(gid_names)}
        for code, name in _STD_ENCODING.items():
            if name in by_name:
                code_to_name[code] = name
        reached = set(code_to_name.values())
        unreachable = [n for n in gid_names[1:] if n not in reached]
        if unreachable:
            code_to_name[-1] = "|".join(unreachable)
        return code_to_name
    fmt = data[enc_off]
    p = enc_off + 1
    base_fmt = fmt & 0x7F
    if base_fmt == 0:
        n_codes = data[p]; p += 1
        for gid in range(1, n_codes + 1):
            code = data[p]; p += 1
            if gid < len(gid_names):
                code_to_name[code] = gid_names[gid]
    elif base_fmt == 1:
        n_ranges = data[p]; p += 1
        gid = 1
        for _ in range(n_ranges):
            first = data[p]; n_left = data[p + 1]; p += 2
            for k in range(n_left + 1):
                if gid < len(gid_names):
                    code_to_name[first + k] = gid_names[gid]
                gid += 1
    if fmt & 0x80:  # supplements
        n_sups = data[p]; p += 1
        for _ in range(n_sups):
            code = data[p]; sid = struct.unpack(">H", data[p + 1:p + 3])[0]; p += 3
            code_to_name[code] = sid_name(sid)
    return code_to_name


# --- TrueType / OpenType --------------------------------------------------

def _tt_tables(data: bytes) -> dict[bytes, tuple[int, int]]:
    tag = data[:4]
    off = 0
    if tag == b"ttcf":
        off = struct.unpack(">I", data[12:16])[0]
    num = struct.unpack(">H", data[off + 4:off + 6])[0]
    tables = {}
    p = off + 12
    for _ in range(num):
        t, _cs, o, ln = struct.unpack(">4sIII", data[p:p + 16])
        tables[t] = (o, ln)
        p += 16
    return tables


def _tt_cmap(data: bytes, off: int) -> dict[int, int]:
    """code -> GID from (3,0) symbol, (1,0) mac, or (3,1) unicode subtables."""
    n = struct.unpack(">H", data[off + 2:off + 4])[0]
    subs = []
    for i in range(n):
        pid, eid, so = struct.unpack(">HHI", data[off + 4 + i * 8: off + 12 + i * 8])
        subs.append((pid, eid, off + so))
    order = sorted(subs, key=lambda s: {(3, 0): 0, (1, 0): 1, (3, 1): 2}.get((s[0], s[1]), 9))
    for pid, eid, so in order:
        fmt = struct.unpack(">H", data[so:so + 2])[0]
        m: dict[int, int] = {}
        if fmt == 0:
            for code in range(256):
                gid = data[so + 6 + code]
                if gid:
                    m[code] = gid
        elif fmt == 4:
            segx2 = struct.unpack(">H", data[so + 6:so + 8])[0]
            seg = segx2 // 2
            ends = struct.unpack(f">{seg}H", data[so + 14: so + 14 + segx2])
            starts = struct.unpack(f">{seg}H", data[so + 16 + segx2: so + 16 + 2 * segx2])
            deltas = struct.unpack(f">{seg}h", data[so + 16 + 2 * segx2: so + 16 + 3 * segx2])
            rng_off_pos = so + 16 + 3 * segx2
            rng = struct.unpack(f">{seg}H", data[rng_off_pos: rng_off_pos + segx2])
            for i in range(seg):
                if starts[i] > ends[i] or starts[i] == 0xFFFF:
                    continue
                for code in range(starts[i], min(ends[i], 0xFFFE) + 1):
                    if rng[i] == 0:
                        gid = (code + deltas[i]) & 0xFFFF
                    else:
                        gp = rng_off_pos + i * 2 + rng[i] + (code - starts[i]) * 2
                        if gp + 2 > len(data):
                            continue
                        gid = struct.unpack(">H", data[gp:gp + 2])[0]
                        if gid:
                            gid = (gid + deltas[i]) & 0xFFFF
                    if gid:
                        m[code] = gid
        else:
            continue
        if m:
            if (pid, eid) == (3, 0):
                # symbol fonts map 0xF000 + code
                m = {(c & 0xFF if 0xF000 <= c <= 0xF0FF else c): g for c, g in m.items()}
            return m
    return {}


def _tt_post_names(data: bytes, off: int, ln: int) -> list[str]:
    ver = struct.unpack(">I", data[off:off + 4])[0]
    if ver != 0x00020000:
        return []
    num = struct.unpack(">H", data[off + 32:off + 34])[0]
    idx = struct.unpack(f">{num}H", data[off + 34: off + 34 + 2 * num])
    p = off + 34 + 2 * num
    names: list[str] = []
    end = off + ln
    while p < end and p < len(data):
        k = data[p]
        names.append(data[p + 1:p + 1 + k].decode("latin-1"))
        p += 1 + k
    out = []
    for i in idx:
        if i < 258:
            out.append(_MAC_GLYPH_NAMES[i] if i < len(_MAC_GLYPH_NAMES) else "")
        else:
            j = i - 258
            out.append(names[j] if j < len(names) else "")
    return out


def _tt_unicode_cmap(data: bytes, off: int) -> dict[int, int]:
    """unicode -> GID from a (3,1) or (0,x) subtable, if present."""
    n = struct.unpack(">H", data[off + 2:off + 4])[0]
    for i in range(n):
        pid, eid, so = struct.unpack(">HHI", data[off + 4 + i * 8: off + 12 + i * 8])
        if (pid, eid) == (3, 1) or pid == 0:
            sub_off = off + so
            # reuse the format parser by faking a one-subtable header
            fake = struct.pack(">HHHHI", 0, 1, 3, 1, 12) + data[sub_off:]
            m = _tt_cmap(fake, 0)
            if m:
                return m
    return {}


def truetype_code_to_name(data: bytes) -> dict[int, str]:
    tables = _tt_tables(data)
    if b"CFF " in tables:
        o, ln = tables[b"CFF "]
        return cff_code_to_name(data[o:o + ln])
    if b"cmap" not in tables:
        return {}
    out: dict[int, str] = {}
    cmap = _tt_cmap(data, tables[b"cmap"][0])
    names = _tt_post_names(data, *tables[b"post"]) if b"post" in tables else []
    if names:
        out = {code: names[gid] for code, gid in cmap.items() if gid < len(names) and names[gid]}
    # Identity-encoded CID fonts: PDFium reports the GID as the code. Resolve it
    # through the font's own Unicode cmap when exactly one code point maps to it.
    uni = _tt_unicode_cmap(data, tables[b"cmap"][0])
    rev: dict[int, list[int]] = {}
    for u, g in uni.items():
        rev.setdefault(g, []).append(u)
    for gid, us in rev.items():
        if gid not in out and len(us) == 1:
            out[gid] = f"uni{us[0]:04X}"
    return out


@dataclass
class GlyphRecovery:
    """Per-document cache: font program bytes → code → Unicode text."""
    _cache: dict[bytes, dict[int, str]] = field(default_factory=dict)

    def lookup_bytes(self, data: bytes, code: int) -> str | None:
        key = data[:64] + len(data).to_bytes(4, "big")
        table = self._cache.get(key)
        if table is None:
            table = {}
            try:
                if data[:4] in (b"\x00\x01\x00\x00", b"true", b"OTTO", b"ttcf"):
                    names = truetype_code_to_name(data)
                elif data[:1] == b"\x01":
                    names = cff_code_to_name(data)
                elif data[:2] == b"%!":
                    names = type1_code_to_name(data)
                else:
                    names = {}
                unreachable = names.pop(-1, "")
                for c, n in names.items():
                    u = glyph_name_to_unicode(n)
                    if u:
                        table[c] = u
                if unreachable and "|" not in unreachable:
                    # exactly one glyph that no standard code reaches: a code outside
                    # the standard encoding can only mean that glyph
                    u = glyph_name_to_unicode(unreachable)
                    if u:
                        table["unreachable"] = u  # type: ignore[index]
            except Exception:  # noqa: BLE001 - a malformed font never breaks extraction
                table = {}
            self._cache[key] = table
        hit = table.get(code)
        if hit is None and code not in _STD_ENCODING and "unreachable" in table:
            return table["unreachable"]  # type: ignore[index]
        return hit


def type1_code_to_name(data: bytes) -> dict[int, str]:
    """Type 1 (PFA/PFB clear-text portion): 'dup <code> /<name> put' entries."""
    head = data[:200000].decode("latin-1", "replace")
    out: dict[int, str] = {}
    if "StandardEncoding" in head.split("eexec")[0]:
        out.update(_STD_ENCODING)
    for m in re.finditer(r"dup\s+(\d+)\s*/(\S+)\s+put", head):
        out[int(m.group(1))] = m.group(2)
    return out
