"""Map PDF base font names to Word font families and weight/style flags.

PDF names look like ``ABCDEF+TimesNewRomanPS-BoldItalicMT`` or
``Arial,Bold``. We strip the subset tag, split the style suffix, drop
foundry/technology suffixes (MT, PS, LTStd, Std) and space out CamelCase.
"""
from __future__ import annotations

import re
from pathlib import Path

_STYLE_WORDS = {
    "bold": ("bold", True, None), "semibold": ("bold", True, None), "demibold": ("bold", True, None),
    "black": ("bold", True, None), "heavy": ("bold", True, None), "extrabold": ("bold", True, None),
    "italic": ("italic", None, True), "oblique": ("italic", None, True),
    "bolditalic": ("both", True, True), "boldoblique": ("both", True, True),
    "regular": ("none", None, None), "roman": ("none", None, None), "medium": ("none", None, None),
    "light": ("none", None, None), "book": ("none", None, None), "normal": ("none", None, None),
    "plain": ("none", None, None), "mt": ("none", None, None), "ps": ("none", None, None),
    "ltstd": ("none", None, None), "std": ("none", None, None), "lt": ("none", None, None),
}
_FAMILY_ALIASES = {
    "arial": "Arial", "arialnarrow": "Arial Narrow", "helvetica": "Helvetica", "helveticaneue": "Helvetica Neue",
    "helveticaworld": "Helvetica World", "timesnewroman": "Times New Roman", "times": "Times",
    "timesroman": "Times", "courier": "Courier", "couriernew": "Courier New", "calibri": "Calibri",
    "cambria": "Cambria", "georgia": "Georgia", "verdana": "Verdana", "symbol": "Symbol",
    "zapfdingbats": "Zapf Dingbats", "wingdings": "Wingdings", "garamond": "Garamond",
}


def _split_camel(name: str) -> str:
    return re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Za-z])(?=\d)", " ", name).strip()


def map_font(pdf_name: str) -> tuple[str, bool, bool]:
    """Return (family, bold, italic) for a PDF base font name."""
    if not pdf_name:
        return "", False, False
    name = pdf_name.split("+", 1)[1] if "+" in pdf_name[:8] else pdf_name
    if re.match(r"(?i)(symbol|wingdings|webdings|zapf ?dingbats|dingbats)", name):
        # symbol fonts: the extracted text is already Unicode ("•", "✓"); naming
        # the font would make Word look the code point up in a non-Unicode font
        return "", False, False
    bold = italic = False
    # style parts after '-' or ','
    parts = re.split(r"[-,]", name)
    family_part = parts[0]
    style_parts = parts[1:]
    for sp in style_parts:
        for token in re.findall(r"[A-Za-z]+", sp):
            key = token.lower()
            if key in _STYLE_WORDS:
                _kind, b, i = _STYLE_WORDS[key]
                bold = bold or bool(b)
                italic = italic or bool(i)
            else:
                # compound like "BoldItalicMT" or "SemiBoldItalic"
                low = key
                if "bold" in low or "black" in low or "heavy" in low:
                    bold = True
                if "italic" in low or "oblique" in low:
                    italic = True
    # style words glued into the family part (e.g. "Arial,Bold" handled above; "HelveticaBold")
    fam = family_part
    for suffix in ("PSMT", "PS", "MT", "LTStd", "Std"):
        if fam.endswith(suffix) and len(fam) > len(suffix) + 2:
            fam = fam[: -len(suffix)]
    low = fam.lower()
    if low.endswith("bold"):
        bold = True; fam = fam[:-4]; low = fam.lower()
    if low.endswith("italic"):
        italic = True; fam = fam[:-6]; low = fam.lower()
    if low in _FAMILY_ALIASES:
        return _FAMILY_ALIASES[low], bold, italic
    return _split_camel(fam), bold, italic


# --- text measurement in Word's own fonts -----------------------------------
_FONT_DIRS = [
    Path("/Applications/Microsoft Word.app/Contents/Resources/DFonts"),
    Path("/System/Library/Fonts/Supplemental"),
    Path("/Library/Fonts"),
    Path.home() / "Library/Fonts",
]
_font_cache: dict = {}


def _font_file(family: str, bold: bool, italic: bool):
    """Locate the TrueType file Word would use for a family/style, if present."""
    styles = []
    if bold and italic:
        styles += [" Bold Italic", "-BoldItalic", "bi", "z", " BoldItalic"]
    elif bold:
        styles += [" Bold", "-Bold", "bd", "b"]
    elif italic:
        styles += [" Italic", "-Italic", "i", "z"]
    styles.append("")
    for d in _FONT_DIRS:
        if not d.is_dir():
            continue
        names = {f.name.lower(): f for f in d.iterdir() if f.suffix.lower() in (".ttf", ".otf", ".ttc")}
        for st in styles:
            for cand in (f"{family}{st}.ttf", f"{family}{st}.otf", f"{family}{st}.ttc", f"{family.replace(' ', '')}{st}.ttf"):
                hit = names.get(cand.lower())
                if hit is not None:
                    return hit, st != ""   # (file, style matched exactly)
    return None, False


def text_width(text: str, family: str, size: float, bold: bool = False, italic: bool = False) -> float:
    """Advance width (pt) of ``text`` set in Word's font at ``size``. Measured
    with the installed TrueType file (Word for Mac uses the same files); when
    the family is not installed an average-width estimate is used."""
    if not text:
        return 0.0
    key = (family, bold, italic)
    if key not in _font_cache:
        path, exact = _font_file(family or "Arial", bold, italic)
        if path is None and family and family != "Arial":
            path, exact = _font_file("Arial", bold, italic)
        font = None
        if path is not None:
            try:
                from PIL import ImageFont
                font = ImageFont.truetype(str(path), 100)   # measured at 100 pt, scaled linearly
            except Exception:  # noqa: BLE001
                font = None
        _font_cache[key] = (font, exact)
    font, exact = _font_cache[key]
    if font is None:
        avg = 0.55 if bold else 0.5
        return len(text) * avg * size
    width = font.getlength(text) * size / 100.0
    if bold and not exact:
        width *= 1.06   # synthetic bold widens glyphs a little
    return width


_SERIF_HINTS = ("times", "georgia", "garamond", "minion", "palatino", "book", "serif", "cambria", "century",
                "baskerville", "caslon", "didot", "bodoni", "charter", "utopia", "warnock", "adobe text", "nimbus rom",
                "liberation serif", "dejavu serif", "constantia", "goudy", "sabon", "janson", "bembo")
_MONO_HINTS = ("courier", "mono", "consolas", "menlo", "typewriter")
_installed_cache: dict = {}


def installed_family(family: str) -> str:
    """The family Word will actually use: ``family`` itself when its font file
    is installed, otherwise a stand-in of the same class (serif → Times New
    Roman, monospace → Courier New, else Arial). Measuring in the named family
    then matches what Word lays out."""
    if not family:
        return ""
    if family in _installed_cache:
        return _installed_cache[family]
    path, _exact = _font_file(family, False, False)
    if path is not None:
        out = family
    else:
        low = family.lower()
        if any(h in low for h in _MONO_HINTS):
            out = "Courier New"
        elif any(h in low for h in _SERIF_HINTS):
            out = "Times New Roman"
        else:
            out = "Arial"
    _installed_cache[family] = out
    return out
