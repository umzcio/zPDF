"""AcroForm authoring, filling, form logic, flattening and XFA conversion.

Everything writes standard AcroForm structures: terminal fields with widget
annotations, /DA + /DR fonts, generated appearance streams (no reliance on
/NeedAppearances), /AA JavaScript actions using only Acrobat's built-in form
functions (interpreted safely by `formcalc`, never executed), and /CO for
calculation order.
"""
import re

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require
from transforms import op, query
from transforms import appearance as A
from transforms import formcalc as F

READONLY, REQUIRED, NOEXPORT = 1, 2, 4
MULTILINE, PASSWORD, NOTOGGLEOFF, RADIO, PUSH = 1 << 12, 1 << 13, 1 << 14, 1 << 15, 1 << 16
COMBO, EDIT, SORT, FILESELECT, MULTISELECT = 1 << 17, 1 << 18, 1 << 19, 1 << 20, 1 << 21
NOSPELL, NOSCROLL, COMB, UNISON, COMMIT = 1 << 22, 1 << 23, 1 << 24, 1 << 25, 1 << 26
HIDDEN, PRINT, NOVIEW = 2, 4, 32
KINDS = ("text", "checkbox", "radio", "combo", "list", "signature", "date", "button", "barcode", "number")
STYLES = {"solid": "/S", "dashed": "/D", "beveled": "/B", "inset": "/I", "underline": "/U"}
ALIGN = {"left": 0, "center": 1, "right": 2}
FONTS = {"helvetica": "Helv", "helvetica-bold": "HeBo", "times": "TiRo", "times-bold": "TiBo",
         "courier": "Cour", "courier-bold": "CoBo"}


# ------------------------------------------------------------ field model

def _text(value):
    if value is None:
        return ""
    if isinstance(value, pikepdf.Name):
        return str(value)[1:]
    return str(value)


def inherited(node, key, default=None):
    depth = 0
    while node is not None and depth < 32:
        if key in node:
            return node[key]
        node = node.get("/Parent")
        depth += 1
    return default


class Field:
    def __init__(self, name, node, widgets, pages):
        self.name = name
        self.node = node
        self.widgets = widgets
        self._pages = pages

    @property
    def ft(self):
        return str(inherited(self.node, "/FT") or "")

    @property
    def flags(self):
        return int(inherited(self.node, "/Ff") or 0)

    @property
    def kind(self):
        ft, flags = self.ft, self.flags
        if ft == "/Btn":
            if flags & PUSH:
                return "button"
            return "radio" if flags & RADIO else "checkbox"
        if ft == "/Ch":
            return "combo" if flags & COMBO else "list"
        if ft == "/Sig":
            return "signature"
        if ft == "/Tx":
            if "/PMD" in self.node:
                return "barcode"
            return "text"
        return "unknown"

    def page_of(self, widget):
        return self._pages.get(widget.objgen) if widget.is_indirect else None

    def value(self):
        return inherited(self.node, "/V")

    def scripts(self):
        aa = self.node.get("/AA") or (self.widgets[0].get("/AA") if self.widgets and self.widgets[0] is not self.node else None)
        out = {}
        if aa is None:
            return out
        for key in ("K", "F", "V", "C"):
            action = aa.get("/" + key)
            if isinstance(action, pikepdf.Dictionary) and str(action.get("/S", "")) == "/JavaScript":
                js = action.get("/JS")
                if isinstance(js, pikepdf.Stream):
                    out[key] = js.read_bytes().decode("latin-1", errors="replace")
                elif js is not None:
                    out[key] = str(js)
        return out

    def options(self):
        out = []
        for item in inherited(self.node, "/Opt") or []:
            if isinstance(item, pikepdf.Array) and len(item) >= 2:
                out.append((str(item[1]), str(item[0])))  # (label, export)
            else:
                out.append((str(item), str(item)))
        return out

    def on_states(self, widget):
        ap = widget.get("/AP")
        states = []
        if ap is not None and isinstance(ap.get("/N"), pikepdf.Dictionary) and not isinstance(ap.get("/N"), pikepdf.Stream):
            states = [str(k)[1:] for k in ap.N.keys() if str(k) != "/Off"]
        return states


def _page_map(pdf):
    pages = {}
    for index, page in enumerate(pdf.pages):
        for annot in page.obj.get("/Annots", []):
            if isinstance(annot, pikepdf.Dictionary) and annot.is_indirect:
                pages[annot.objgen] = index
    return pages


def fields(pdf):
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return []
    pages = _page_map(pdf)
    out, seen = [], set()

    def visit(node, prefix, depth):
        if depth > 32 or not isinstance(node, pikepdf.Dictionary):
            return
        key = node.objgen if node.is_indirect else id(node)
        if key in seen:
            return
        seen.add(key)
        part = _text(node.get("/T")) if "/T" in node else ""
        name = f"{prefix}.{part}" if prefix and part else (part or prefix)
        kids = [k for k in node.get("/Kids", []) if isinstance(k, pikepdf.Dictionary)]
        if kids and any("/T" in k for k in kids):
            for kid in kids:
                if "/T" in kid:
                    visit(kid, name, depth + 1)
                else:  # a widget directly under a non-terminal node
                    out.append(Field(name, node, [kid], pages))
            return
        widgets = kids if kids else ([node] if str(node.get("/Subtype", "")) == "/Widget" or "/Rect" in node else [])
        out.append(Field(name, node, widgets, pages))

    for root in acro.get("/Fields", []):
        visit(root, "", 0)
    return out


def find(pdf, name):
    matches = [f for f in fields(pdf) if f.name == name]
    require(matches, "NOT_FOUND", f"No form field is named “{name}”.")
    return matches[0]


def acroform(pdf):
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        acro = pdf.make_indirect(pikepdf.Dictionary(Fields=pikepdf.Array()))
        pdf.Root.AcroForm = acro
    if "/Fields" not in acro:
        acro.Fields = pikepdf.Array()
    fonts = A.ensure_resources(pdf, acro)
    if "/NeedAppearances" in acro:
        # Appearances are generated for every edit, so viewers need not rebuild them.
        del acro["/NeedAppearances"]
    return acro, fonts


def _logic(pdf, all_fields=None):
    logic = {}
    for field in all_fields or fields(pdf):
        scripts = field.scripts()
        if scripts:
            logic[field.name] = F.FieldLogic(field.name, scripts)
    return logic


def _da(field, widget, acro):
    return str(widget.get("/DA") or inherited(field.node, "/DA") or acro.get("/DA") or "/Helv 0 Tf 0 g")


# ------------------------------------------------------------- appearances

def _value_text(field):
    value = field.value()
    if value is None:
        return ""
    if isinstance(value, pikepdf.Array):
        return ", ".join(_text(v) for v in value)
    return _text(value)


def refresh(pdf, field, logic=None, acro=None, fonts=None, barcode=None):
    """Regenerate every widget appearance of `field` from its value."""
    if acro is None:
        acro, fonts = acroform(pdf)
    kind = field.kind
    flags = field.flags
    value = field.value()
    for widget in field.widgets:
        if "/Rect" not in widget:
            continue
        da = _da(field, widget, acro)
        quadding = int(widget.get("/Q", inherited(field.node, "/Q") or 0))
        if kind == "text":
            raw = _value_text(field)
            display, red = logic.display(raw) if logic is not None else (raw, False)
            max_len = inherited(field.node, "/MaxLen")
            ap = A.text_appearance(pdf, widget, flags, display, da, quadding, fonts,
                                   int(max_len) if max_len is not None else None, color=[1, 0, 0] if red else None)
            widget.AP = pikepdf.Dictionary(N=ap)
        elif kind == "barcode":
            rows = barcode if barcode is not None else None
            if rows is None:
                existing = widget.get("/AP")
                if existing is not None:
                    continue
            widget.AP = pikepdf.Dictionary(N=A.barcode_appearance(pdf, widget, rows or []))
        elif kind == "combo":
            raw = _value_text(field)
            labels = {export: label for label, export in field.options()}
            display, red = logic.display(raw) if logic is not None else (labels.get(raw, raw), False)
            ap = A.text_appearance(pdf, widget, 0, display, da, quadding, fonts, None, color=[1, 0, 0] if red else None)
            widget.AP = pikepdf.Dictionary(N=ap)
        elif kind == "list":
            selected = [_text(v) for v in value] if isinstance(value, pikepdf.Array) else ([_text(value)] if value is not None else [])
            top = int(inherited(field.node, "/TI") or 0)
            widget.AP = pikepdf.Dictionary(N=A.choice_list_appearance(pdf, widget, field.options(), selected, da, quadding, fonts, top))
        elif kind in ("checkbox", "radio"):
            states = field.on_states(widget) or [_text(widget.get("/ZPDFExport")) or "Yes"]
            on = states[0]
            mk = widget.get("/MK")
            style = str(widget.get("/ZPDFStyle", "")) or None
            color = A.parse_da(da)[2]
            ap_existing = widget.get("/AP")
            if ap_existing is None or not isinstance(ap_existing.get("/N"), pikepdf.Dictionary) or "/ZPDFGenerated" in widget:
                colors = _da_color(da)
                widget.AP = pikepdf.Dictionary(N=A.check_appearances(pdf, widget, on, style or ("circle" if kind == "radio" else "check"),
                                                                     fonts, colors, radio=kind == "radio"))
            current = _text(value) if value is not None else "Off"
            widget.AS = Name("/" + on) if current == on else Name.Off
        elif kind == "button":
            mk = widget.get("/MK")
            caption = _text(mk.get("/CA")) if mk is not None else ""
            widget.AP = pikepdf.Dictionary(N=A.button_appearance(pdf, widget, caption, da, fonts))
        elif kind == "signature":
            if "/AP" not in widget:
                widget.AP = pikepdf.Dictionary(N=A.blank_appearance(pdf, widget))


def _da_color(da):
    tokens = str(da).split()
    for i, token in enumerate(tokens):
        if token == "rg" and i >= 3:
            try:
                return [float(t) for t in tokens[i - 3:i]]
            except ValueError:
                return None
        if token == "g" and i >= 1:
            try:
                return [float(tokens[i - 1])]
            except ValueError:
                return None
    return None


# ------------------------------------------------------------ properties

def _color(value):
    if value is None:
        return None
    require(isinstance(value, (list, tuple)) and len(value) in (1, 3, 4), "INVALID_ARGUMENT", "Invalid color.")
    values = [float(v) for v in value]
    if any(v > 1 for v in values):
        values = [v / 255 for v in values]
    return pikepdf.Array(values)


def _js(script):
    return pikepdf.Dictionary(S=Name.JavaScript, JS=pikepdf.String(script))


def _set_flag(flags, bit, on):
    return (flags | bit) if on else (flags & ~bit)


def _check_name(pdf, name, allow_existing=False):
    require(isinstance(name, str) and name.strip() and len(name) <= 200 and "\0" not in name,
            "INVALID_ARGUMENT", "Field names must be non-empty.")
    require("." not in name, "INVALID_ARGUMENT", "Field names can’t contain periods.")
    if not allow_existing:
        require(name not in {f.name for f in fields(pdf)}, "INVALID_ARGUMENT", f"A field named “{name}” already exists.")


def _apply_properties(pdf, field, props, acro, fonts):
    node = field.node
    widgets = field.widgets
    flags = int(node.get("/Ff", 0))
    kind = field.kind
    if "tooltip" in props:
        if props["tooltip"]:
            node.TU = pikepdf.String(props["tooltip"])
        elif "/TU" in node:
            del node["/TU"]
    for key, bit in (("readonly", READONLY), ("required", REQUIRED), ("no_export", NOEXPORT)):
        if key in props:
            flags = _set_flag(flags, bit, bool(props[key]))
    if kind in ("text", "barcode"):
        for key, bit in (("multiline", MULTILINE), ("password", PASSWORD), ("comb", COMB)):
            if key in props:
                flags = _set_flag(flags, bit, bool(props[key]))
        if "scroll" in props:
            flags = _set_flag(flags, NOSCROLL, not props["scroll"])
        if "spellcheck" in props:
            flags = _set_flag(flags, NOSPELL, not props["spellcheck"])
        if "max_length" in props:
            if props["max_length"]:
                require(int(props["max_length"]) > 0, "INVALID_ARGUMENT", "Character limit must be positive.")
                node.MaxLen = int(props["max_length"])
            elif "/MaxLen" in node:
                del node["/MaxLen"]
        if flags & COMB:
            require(node.get("/MaxLen") is not None, "INVALID_ARGUMENT", "Comb fields need a character limit.")
            flags &= ~(MULTILINE | PASSWORD)
    if kind in ("combo", "list"):
        if "editable" in props and kind == "combo":
            flags = _set_flag(flags, EDIT, bool(props["editable"]))
        if "multi_select" in props and kind == "list":
            flags = _set_flag(flags, MULTISELECT, bool(props["multi_select"]))
        if "sort" in props:
            flags = _set_flag(flags, SORT, bool(props["sort"]))
        if "commit_on_select" in props:
            flags = _set_flag(flags, COMMIT, bool(props["commit_on_select"]))
        if "spellcheck" in props and kind == "combo":
            flags = _set_flag(flags, NOSPELL, not props["spellcheck"])
        if "options" in props:
            options = props["options"] or []
            require(isinstance(options, list) and len(options) <= 500, "INVALID_ARGUMENT", "Too many options.")
            items = []
            for option in options:
                if isinstance(option, dict):
                    label = str(option.get("label", "")).strip()
                    export = str(option.get("export") or label)
                else:
                    label = export = str(option)
                require(label, "INVALID_ARGUMENT", "Options need a label.")
                items.append((label, export))
            if flags & SORT:
                items.sort(key=lambda item: item[0].lower())
            node.Opt = pikepdf.Array([pikepdf.String(label) if label == export
                                      else pikepdf.Array([pikepdf.String(export), pikepdf.String(label)])
                                      for label, export in items])
    if kind == "radio" and "unison" in props:
        flags = _set_flag(flags, UNISON, bool(props["unison"]))
    if kind == "radio" and "toggle_off" in props:
        flags = _set_flag(flags, NOTOGGLEOFF, not props["toggle_off"])
    node.Ff = flags
    if "alignment" in props:
        node.Q = ALIGN.get(props["alignment"], 0)
    if any(k in props for k in ("font", "font_size", "text_color")):
        font_key, size, _ = A.parse_da(str(inherited(node, "/DA") or acro.get("/DA")))
        if "font" in props and props["font"]:
            font_key = FONTS.get(str(props["font"]).lower(), font_key)
        if "font_size" in props and props["font_size"] is not None:
            size = float(props["font_size"])
            require(0 <= size <= 144, "INVALID_ARGUMENT", "Font size must be between 0 (auto) and 144.")
        color = _color(props.get("text_color")) if props.get("text_color") is not None else None
        existing = _da_color(str(inherited(node, "/DA") or ""))
        color_values = [float(v) for v in color] if color is not None else (existing or [0])
        color_op = A.color_op(color_values)
        da = f"/{font_key} {A.fmt(size)} Tf {color_op}"
        node.DA = pikepdf.String(da)
        for widget in widgets:
            if widget is not node and "/DA" in widget:
                del widget["/DA"]
    for widget in widgets:
        mk = widget.get("/MK")
        if mk is None:
            mk = pikepdf.Dictionary()
            widget.MK = mk
        if "border_color" in props:
            if props["border_color"] is None:
                if "/BC" in mk:
                    del mk["/BC"]
            else:
                mk.BC = _color(props["border_color"])
        if "fill_color" in props:
            if props["fill_color"] is None:
                if "/BG" in mk:
                    del mk["/BG"]
            else:
                mk.BG = _color(props["fill_color"])
        if "border_width" in props or "border_style" in props:
            bs = widget.get("/BS") or pikepdf.Dictionary(Type=Name.Border)
            if "border_width" in props:
                bs.W = float(props["border_width"])
            if "border_style" in props:
                bs.S = Name(STYLES.get(props["border_style"], "/S"))
            widget.BS = bs
            if "/Border" in widget:
                del widget["/Border"]
        if "caption" in props and kind == "button":
            mk.CA = pikepdf.String(props["caption"] or "")
        if "check_style" in props and kind in ("checkbox", "radio"):
            style = props["check_style"]
            require(style in A.ZAPF, "INVALID_ARGUMENT", "Unknown check style.")
            mk.CA = pikepdf.String(A.ZAPF[style])
            widget.ZPDFGenerated = True
        if "rotation" in props:
            mk.R = int(props["rotation"]) % 360
        flags_f = int(widget.get("/F", PRINT))
        if "hidden" in props:
            flags_f = _set_flag(flags_f, HIDDEN, bool(props["hidden"]))
        if "print" in props:
            flags_f = _set_flag(flags_f, PRINT, bool(props["print"]))
        widget.F = flags_f
        if kind in ("checkbox", "radio") and any(k in props for k in ("border_color", "fill_color", "border_width",
                                                                       "border_style", "check_style", "text_color")):
            widget.ZPDFGenerated = True
    aa = node.get("/AA")
    def set_action(key, script):
        nonlocal aa
        if script:
            if aa is None:
                aa = pikepdf.Dictionary()
                node.AA = aa
            aa[Name("/" + key)] = _js(script)
        elif aa is not None and "/" + key in aa:
            del aa["/" + key]
    if "format" in props and kind in ("text", "combo"):
        fmt_js, key_js = F.format_scripts(props["format"])
        set_action("F", fmt_js)
        set_action("K", key_js)
    if "validate" in props and kind in ("text", "combo"):
        set_action("V", F.validate_script(props["validate"]))
    if "calculate" in props and kind in ("text", "combo"):
        spec = props["calculate"]
        if spec:
            known = {f.name for f in fields(pdf)}
            names = spec.get("fields", []) if spec.get("kind") != "sfn" else F.sfn_fields(F.parse_sfn(spec.get("expression", "")))
            missing = [n for n in names if n not in known and not any(k.startswith(n + ".") for k in known)]
            require(not missing, "INVALID_ARGUMENT", "Unknown fields in calculation: " + ", ".join(missing))
            require(field.name not in names, "INVALID_ARGUMENT", "A field can’t calculate from itself.")
        script = F.calculate_script(spec)
        set_action("C", script)
        order = acro.get("/CO")
        refs = [r for r in (order or []) if not (r.is_indirect and r.objgen == node.objgen)]
        if script:
            require(node.is_indirect, "ENGINE_FAILED", "Calculated fields must be indirect.")
            refs.append(node)
        if refs:
            acro.CO = pikepdf.Array(refs)
        elif "/CO" in acro:
            del acro["/CO"]
    if aa is not None and len(aa) == 0 and "/AA" in node:
        del node["/AA"]
    if "action" in props and kind == "button":
        _set_button_action(widgets, props["action"])
    if "default" in props:
        default = props["default"]
        if default in (None, ""):
            if "/DV" in node:
                del node["/DV"]
        elif kind in ("checkbox", "radio"):
            node.DV = Name("/" + str(default)) if default not in (False,) else Name.Off
        else:
            node.DV = pikepdf.String(str(default))
    if "barcode" in props and kind == "barcode":
        spec = props["barcode"] or {}
        pmd = node.get("/PMD") or pikepdf.Dictionary()
        symbology = {"qr": "/QRCode", "pdf417": "/PDF417", "datamatrix": "/DataMatrix"}.get(spec.get("symbology", "qr"), "/QRCode")
        pmd.Symbology = Name(symbology)
        pmd.ZPDFFields = pikepdf.Array([pikepdf.String(n) for n in spec.get("fields", [])])
        pmd.ECC = int(spec.get("ecc", 1))
        node.PMD = pmd


def _set_button_action(widgets, action):
    for widget in widgets:
        if "/A" in widget:
            del widget["/A"]
    if not action or action.get("kind") in (None, "none"):
        return
    kind = action["kind"]
    if kind == "submit":
        url = str(action.get("url", ""))
        require(re.match(r"^(https?|mailto):", url), "INVALID_ARGUMENT", "Enter an http(s) or mailto: URL.")
        flags = {"fdf": 0, "html": 4, "xfdf": 32, "pdf": 256}.get(action.get("format", "html"), 4)
        a = pikepdf.Dictionary(S=Name.SubmitForm, F=pikepdf.Dictionary(FS=Name.URL, F=pikepdf.String(url)), Flags=flags)
        if action.get("fields"):
            a.Fields = pikepdf.Array([pikepdf.String(n) for n in action["fields"]])
    elif kind == "reset":
        a = pikepdf.Dictionary(S=Name.ResetForm)
        if action.get("fields"):
            a.Fields = pikepdf.Array([pikepdf.String(n) for n in action["fields"]])
    elif kind == "print":
        a = pikepdf.Dictionary(S=Name.Named, N=Name.Print)
    elif kind == "url":
        url = str(action.get("url", ""))
        require(re.match(r"^(https?|mailto):", url), "INVALID_ARGUMENT", "Enter an http(s) or mailto: URL.")
        a = pikepdf.Dictionary(S=Name.URI, URI=pikepdf.String(url))
    else:
        raise EngineError("INVALID_ARGUMENT", "Unsupported button action.")
    for widget in widgets:
        widget.A = a


def _describe_action(widget):
    a = widget.get("/A")
    if a is None:
        return {"kind": "none"}
    s = str(a.get("/S", ""))
    if s == "/SubmitForm":
        target = a.get("/F")
        url = _text(target.get("/F")) if isinstance(target, pikepdf.Dictionary) else _text(target)
        flags = int(a.get("/Flags", 0))
        fmt = "pdf" if flags & 256 else "xfdf" if flags & 32 else "html" if flags & 4 else "fdf"
        return {"kind": "submit", "url": url, "format": fmt, "fields": [_text(f) for f in a.get("/Fields", [])]}
    if s == "/ResetForm":
        return {"kind": "reset", "fields": [_text(f) for f in a.get("/Fields", [])]}
    if s == "/Named":
        return {"kind": "print" if str(a.get("/N")) == "/Print" else "named", "name": _text(a.get("/N"))}
    if s == "/URI":
        return {"kind": "url", "url": _text(a.get("/URI"))}
    return {"kind": "other", "type": s[1:]}


# --------------------------------------------------------- create/modify

DEFAULT_SIZES = {"text": (150, 22), "date": (100, 22), "number": (100, 22), "checkbox": (14, 14), "radio": (14, 14),
                 "combo": (150, 22), "list": (150, 66), "signature": (180, 44), "button": (90, 24), "barcode": (96, 96)}


def _rect(page, rect, kind):
    from transforms.content import page_box
    box = page_box(page)
    if rect is None:
        w, h = DEFAULT_SIZES.get(kind, (120, 22))
        rect = [box[0] + 72, box[3] - 72 - h, box[0] + 72 + w, box[3] - 72]
    require(isinstance(rect, (list, tuple)) and len(rect) == 4, "INVALID_ARGUMENT", "Invalid field rectangle.")
    x0, y0, x1, y1 = [float(v) for v in rect]
    x0, x1 = sorted((x0, x1))
    y0, y1 = sorted((y0, y1))
    require(x1 - x0 >= 4 and y1 - y0 >= 4, "INVALID_ARGUMENT", "Fields must be at least 4 points wide and high.")
    require(box[0] - 1 <= x0 and x1 <= box[2] + 1 and box[1] - 1 <= y0 and y1 <= box[3] + 1,
            "INVALID_ARGUMENT", "Keep the field inside the page.")
    return pikepdf.Array([x0, y0, x1, y1])


def _unique(pdf, base):
    names = {f.name for f in fields(pdf)}
    if base not in names:
        return base
    number = 1
    while f"{base}_{number}" in names:
        number += 1
    return f"{base}_{number}"


@op("add_form_field")
def add_form_field(ctx, type, name=None, page=0, rect=None, **props):
    pdf = ctx.pdf
    require(type in KINDS, "INVALID_ARGUMENT", "Unsupported field type.")
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "Choose a page in this document.")
    acro, fonts = acroform(pdf)
    page_obj = pdf.pages[page]
    box = _rect(page_obj, rect, type)
    kind = {"date": "text", "number": "text"}.get(type, type)
    base_name = name or {"text": "Text", "date": "Date", "number": "Number", "checkbox": "Check Box",
                         "radio": "Group", "combo": "Dropdown", "list": "List Box", "signature": "Signature",
                         "button": "Button", "barcode": "Barcode"}[type]
    if type == "radio" and name and any(f.name == name and f.kind == "radio" for f in fields(pdf)):
        return _add_radio_button(ctx, find(pdf, name), page, box, props, acro, fonts)
    name = name or _unique(pdf, base_name + ("1" if base_name[-1].isalpha() else ""))
    if name and type != "radio":
        _check_name(pdf, name)
    elif type == "radio":
        _check_name(pdf, name)
    border = props.pop("border_color", [0, 0, 0] if kind != "signature" else [1, 0, 0])
    fill = props.pop("fill_color", None if kind not in ("button",) else [0.75, 0.75, 0.75])
    widget = pikepdf.Dictionary(Type=Name.Annot, Subtype=Name.Widget, Rect=box, P=page_obj.obj, F=PRINT,
                                MK=pikepdf.Dictionary(), BS=pikepdf.Dictionary(Type=Name.Border, W=float(props.pop("border_width", 1)),
                                                                                S=Name(STYLES.get(props.pop("border_style", "solid"), "/S"))))
    if border is not None:
        widget.MK.BC = _color(border)
    if fill is not None:
        widget.MK.BG = _color(fill)
    font_size = props.pop("font_size", 0 if kind in ("text", "combo", "button", "barcode") else 10)
    font_key = FONTS.get(str(props.pop("font", "helvetica")).lower(), "Helv")
    color = props.pop("text_color", None)
    color_op = A.color_op([float(v) for v in _color(color)]) if color is not None else "0 g"
    da = pikepdf.String(f"/{font_key} {A.fmt(float(font_size))} Tf {color_op}")
    if kind == "radio":
        export = str(props.pop("export_value", None) or "Choice1")
        parent = pdf.make_indirect(pikepdf.Dictionary(FT=Name.Btn, T=pikepdf.String(name), Ff=RADIO | NOTOGGLEOFF,
                                                      V=Name.Off, Kids=pikepdf.Array(), DA=da))
        widget.Parent = parent
        widget.MK.CA = pikepdf.String(A.ZAPF[props.pop("check_style", "circle")])
        widget.ZPDFGenerated = True
        widget.ZPDFExport = pikepdf.String(export)
        widget = pdf.make_indirect(widget)
        parent.Kids.append(widget)
        acro.Fields.append(parent)
        node = parent
    else:
        node = widget
        node.T = pikepdf.String(name)
        node.DA = da
        if kind == "text":
            node.FT = Name.Tx
            node.Ff = 0
        elif kind == "barcode":
            node.FT = Name.Tx
            node.Ff = READONLY
            node.PMD = pikepdf.Dictionary(Symbology=Name.QRCode, ECC=1, ZPDFFields=pikepdf.Array())
        elif kind == "checkbox":
            node.FT = Name.Btn
            node.Ff = 0
            node.V = Name.Off
            node.MK.CA = pikepdf.String(A.ZAPF[props.pop("check_style", "check")])
            node.ZPDFGenerated = True
            node.ZPDFExport = pikepdf.String(str(props.pop("export_value", None) or "Yes"))
        elif kind == "combo":
            node.FT = Name.Ch
            node.Ff = COMBO
            props.setdefault("options", ["Option 1", "Option 2", "Option 3"])
        elif kind == "list":
            node.FT = Name.Ch
            node.Ff = 0
            props.setdefault("options", ["Option 1", "Option 2", "Option 3"])
        elif kind == "signature":
            node.FT = Name.Sig
        elif kind == "button":
            node.FT = Name.Btn
            node.Ff = PUSH
            node.MK.CA = pikepdf.String(props.pop("caption", name))
            node.H = Name.P
        widget = pdf.make_indirect(node)
        node = widget
        acro.Fields.append(widget)
        if kind == "signature":
            acro.SigFlags = int(acro.get("/SigFlags", 0)) | 1
    if "/Annots" not in page_obj.obj:
        page_obj.obj.Annots = pikepdf.Array()
    page_obj.obj.Annots.append(widget)
    if type == "date":
        props.setdefault("format", {"kind": "date", "format": props.pop("date_format", "mm/dd/yyyy")})
    if type == "number":
        props.setdefault("format", {"kind": "number", "decimals": 2})
    barcode = props.pop("matrix", None)
    field = find(pdf, name)
    _apply_properties(pdf, field, props, acro, fonts)
    value = props.get("value")
    if value not in (None, "") and kind in ("text", "combo", "list"):
        _set_value(field, value)
    if kind in ("checkbox", "radio"):
        for w in field.widgets:
            if "/ZPDFExport" in w:
                on = str(w.ZPDFExport)
                w.AP = A_check(pdf, field, w, on, fonts)
    logic = _logic(pdf).get(name)
    refresh(pdf, field, logic, acro, fonts, barcode=barcode)
    _strip_private(field)
    return {"name": name, "page": page, "rect": [float(v) for v in box]}


def A_check(pdf, field, widget, on, fonts):
    mk = widget.get("/MK")
    char = str(mk.CA) if mk is not None and "/CA" in mk else "4"
    style = next((k for k, v in A.ZAPF.items() if v == char), "check")
    da = str(widget.get("/DA") or inherited(field.node, "/DA") or "/ZaDb 0 Tf 0 g")
    return pikepdf.Dictionary(N=A.check_appearances(pdf, widget, on, style, fonts, _da_color(da), radio=field.kind == "radio"))


def _strip_private(field):
    for widget in [field.node] + list(field.widgets):
        for key in ("/ZPDFExport", "/ZPDFGenerated", "/ZPDFStyle"):
            if key in widget:
                del widget[key]


def _add_radio_button(ctx, field, page, box, props, acro, fonts):
    pdf = ctx.pdf
    exports = {state for w in field.widgets for state in field.on_states(w)}
    export = str(props.pop("export_value", None) or f"Choice{len(exports) + 1}")
    require(export not in exports, "INVALID_ARGUMENT", f"This group already has a button with the value “{export}”.")
    template = field.widgets[0] if field.widgets else None
    mk = pikepdf.Dictionary(CA=pikepdf.String(A.ZAPF[props.pop("check_style", "circle")]))
    if template is not None and template.get("/MK") is not None:
        for key in ("/BC", "/BG"):
            if key in template.MK:
                mk[key] = template.MK[key]
    for key in ("border_color", "fill_color", "border_width", "border_style"):
        props.pop(key, None)
    widget = pdf.make_indirect(pikepdf.Dictionary(
        Type=Name.Annot, Subtype=Name.Widget, Rect=box, P=pdf.pages[page].obj, F=PRINT, Parent=field.node, MK=mk,
        BS=template.get("/BS") if template is not None and "/BS" in template else pikepdf.Dictionary(W=1, S=Name.S)))
    kids = field.node.get("/Kids")
    if kids is None:  # a merged single-button group becomes a parent with kids
        raise EngineError("UNSUPPORTED_OPERATION", "This radio group can’t take more buttons.")
    kids.append(widget)
    if "/Annots" not in pdf.pages[page].obj:
        pdf.pages[page].obj.Annots = pikepdf.Array()
    pdf.pages[page].obj.Annots.append(widget)
    widget.AP = A_check(pdf, field, widget, export, fonts)
    value = field.value()
    widget.AS = Name("/" + export) if value is not None and _text(value) == export else Name.Off
    return {"name": field.name, "page": page, "rect": [float(v) for v in box], "export": export}


@op("update_form_field")
def update_form_field(ctx, name, new_name=None, rect=None, widget=0, **props):
    pdf = ctx.pdf
    acro, fonts = acroform(pdf)
    field = find(pdf, name)
    if new_name and new_name != name:
        _check_name(pdf, new_name)
        require("/T" in field.node, "UNSUPPORTED_OPERATION", "This field can’t be renamed.")
        # Rename only the last component; fully qualified parents keep their names.
        field.node.T = pikepdf.String(new_name.split(".")[-1])
        for other in fields(pdf):
            other_logic = other.scripts().get("C")
            if other_logic and name in other_logic:
                calc = F.describe_calculate(other_logic)
                if calc and calc.get("kind") in ("sum", "product", "average", "min", "max"):
                    calc["fields"] = [new_name if n == name else n for n in calc["fields"]]
                    other.node.AA.C = _js(F.calculate_script(calc))
        field = find(pdf, new_name if "." not in name else name.rsplit(".", 1)[0] + "." + new_name)
    if rect is not None:
        require(0 <= widget < len(field.widgets), "INVALID_ARGUMENT", "Unknown widget.")
        w = field.widgets[widget]
        page = field.page_of(w)
        w.Rect = _rect(pdf.pages[page] if page is not None else pdf.pages[0], rect, field.kind)
        if field.kind in ("checkbox", "radio"):
            for index, target in enumerate(field.widgets):
                if index == widget:
                    states = field.on_states(target)
                    if states:
                        target.AP = A_check(pdf, field, target, states[0], fonts)
    if "export_value" in props and field.kind in ("checkbox", "radio"):
        export = str(props.pop("export_value"))
        require(export and export != "Off", "INVALID_ARGUMENT", "Export values can’t be empty or “Off”.")
        target = field.widgets[widget]
        old = (field.on_states(target) or ["Yes"])[0]
        target.AP = A_check(pdf, field, target, export, fonts)
        value = field.value()
        if value is not None and _text(value) == old:
            field.node.V = Name("/" + export)
    if "value" in props:
        _set_value(field, props.pop("value"))
    _apply_properties(pdf, field, props, acro, fonts)
    logic = _logic(pdf).get(field.name)
    refresh(pdf, field, logic, acro, fonts, barcode=props.get("matrix"))
    _strip_private(field)
    return {"name": field.name}


@op("delete_form_field")
def delete_form_field(ctx, name, widget=None):
    pdf = ctx.pdf
    field = find(pdf, name)
    targets = field.widgets if widget is None else [field.widgets[widget]]
    ids = {w.objgen for w in targets if w.is_indirect}
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if annots is not None:
            page.obj.Annots = pikepdf.Array([a for a in annots if not (a.is_indirect and a.objgen in ids)])
    removed = prune_fields(pdf)
    return {"removed": removed, "name": name}


@op("duplicate_form_field")
def duplicate_form_field(ctx, name, pages, widget=0, offset=None):
    """Add widgets of the same field on other pages (values stay linked)."""
    pdf = ctx.pdf
    acro, fonts = acroform(pdf)
    field = find(pdf, name)
    require(field.widgets, "INVALID_ARGUMENT", "This field has no widget to copy.")
    source = field.widgets[widget]
    require(isinstance(pages, list) and pages, "INVALID_ARGUMENT", "Choose pages.")
    node = field.node
    if node is source:
        # Split the merged field/widget into a parent field with widget kids.
        parent = pdf.make_indirect(pikepdf.Dictionary())
        for key in list(node.keys()):
            if key in ("/FT", "/T", "/TU", "/TM", "/Ff", "/V", "/DV", "/Opt", "/DA", "/Q", "/MaxLen", "/AA", "/PMD", "/TI", "/I"):
                parent[key] = node[key]
                if key not in ("/DA", "/Q"):
                    del node[key]
        parent.Kids = pikepdf.Array([node])
        node.Parent = parent
        fields_array = acro.Fields
        for index, ref in enumerate(list(fields_array)):
            if ref.is_indirect and ref.objgen == node.objgen:
                fields_array[index] = parent
        if node.is_indirect:
            for co_index, ref in enumerate(list(acro.get("/CO", []))):
                if ref.is_indirect and ref.objgen == node.objgen:
                    acro.CO[co_index] = parent
        node = parent
    source_page = field.page_of(source)
    created = 0
    for page in pages:
        require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "Choose pages in this document.")
        if page == source_page:
            continue
        copy = pikepdf.Dictionary({k: v for k, v in source.items() if k not in ("/P", "/Parent", "/AP", "/AS")})
        rect = [float(v) for v in source.Rect]
        if offset:
            rect = [rect[0] + offset[0], rect[1] + offset[1], rect[2] + offset[0], rect[3] + offset[1]]
        copy.Rect = _rect(pdf.pages[page], rect, field.kind)
        copy.P = pdf.pages[page].obj
        copy.Parent = node
        if "/MK" in source:
            copy.MK = pikepdf.Dictionary({k: v for k, v in source.MK.items()})
        ref = pdf.make_indirect(copy)
        node.Kids.append(ref)
        if "/Annots" not in pdf.pages[page].obj:
            pdf.pages[page].obj.Annots = pikepdf.Array()
        pdf.pages[page].obj.Annots.append(ref)
        if field.kind in ("checkbox", "radio"):
            states = field.on_states(source) or ["Yes"]
            ref.AP = A_check(pdf, find(pdf, name), ref, states[0], fonts)
        created += 1
    field = find(pdf, name)
    refresh(pdf, field, _logic(pdf).get(name), acro, fonts)
    return {"created": created}


def prune_fields(pdf):
    """Drop form fields whose widgets are no longer on any page."""
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return 0
    placed = set()
    for page in pdf.pages:
        for annot in page.obj.get("/Annots", []):
            if annot.is_indirect:
                placed.add(annot.objgen)
    removed = 0

    def keep(node, depth=0):
        nonlocal removed
        if depth > 32 or not isinstance(node, pikepdf.Dictionary):
            return False
        kids = node.get("/Kids")
        if kids is not None:
            kept = [k for k in kids if keep(k, depth + 1)]
            if len(kept) != len(kids):
                node.Kids = pikepdf.Array(kept)
            if not kept:
                removed += 1
            return bool(kept)
        alive = node.is_indirect and node.objgen in placed
        if not alive:
            removed += 1
        return alive

    roots = [r for r in acro.get("/Fields", []) if keep(r)]
    acro.Fields = pikepdf.Array(roots)
    if "/CO" in acro:
        live = set()
        def collect(node, depth=0):
            if depth > 32 or not isinstance(node, pikepdf.Dictionary):
                return
            if node.is_indirect:
                live.add(node.objgen)
            for kid in node.get("/Kids", []):
                collect(kid, depth + 1)
        for r in roots:
            collect(r)
        co = [r for r in acro.CO if r.is_indirect and r.objgen in live]
        if co:
            acro.CO = pikepdf.Array(co)
        else:
            del acro["/CO"]
    if not roots:
        del pdf.Root["/AcroForm"]
    return removed


@op("set_tab_order")
def set_tab_order(ctx, page, mode="manual", order=None):
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "Choose a page in this document.")
    obj = pdf.pages[page].obj
    modes = {"row": Name.R, "column": Name.C, "structure": Name.S}
    if mode in modes:
        obj.Tabs = modes[mode]
        return {"mode": mode}
    require(mode == "manual" and isinstance(order, list), "INVALID_ARGUMENT", "Provide the field order.")
    if "/Tabs" in obj:
        del obj["/Tabs"]
    annots = list(obj.get("/Annots", []))
    by_field = {}
    for f in fields(pdf):
        for index, w in enumerate(f.widgets):
            if f.page_of(w) == page:
                by_field.setdefault(f.name, []).append(w)
    ordered = []
    for name in order:
        for w in by_field.pop(name, []):
            ordered.append(w)
    ids = {w.objgen for w in ordered}
    remaining_widgets = [a for a in annots if str(a.get("/Subtype", "")) == "/Widget" and a.objgen not in ids]
    others = [a for a in annots if str(a.get("/Subtype", "")) != "/Widget"]
    obj.Annots = pikepdf.Array(ordered + remaining_widgets + others)
    return {"mode": "manual", "ordered": len(ordered)}


@op("set_calculation_order")
def set_calculation_order(ctx, order):
    pdf = ctx.pdf
    acro, _ = acroform(pdf)
    by_name = {f.name: f for f in fields(pdf)}
    refs = []
    for name in order:
        require(name in by_name, "NOT_FOUND", f"No form field is named “{name}”.")
        require(by_name[name].scripts().get("C"), "INVALID_ARGUMENT", f"“{name}” has no calculation.")
        refs.append(by_name[name].node)
    for f in by_name.values():
        if f.scripts().get("C") and f.name not in order:
            refs.append(f.node)
    acro.CO = pikepdf.Array(refs)
    return {"order": order}


# ------------------------------------------------------------------- fill

def _set_value(field, value, checked=None):
    kind = field.kind
    node = field.node
    require(kind != "signature", "UNSUPPORTED_OPERATION", "Signature fields are signed, not filled.")
    require(kind != "button", "UNSUPPORTED_OPERATION", "Buttons have no value.")
    if kind in ("text", "barcode"):
        text = "" if value is None else str(value)
        require("\0" not in text, "INVALID_ARGUMENT", "Text can’t contain NUL characters.")
        max_len = inherited(node, "/MaxLen")
        if max_len is not None and len(text) > int(max_len):
            text = text[:int(max_len)]
        node.V = pikepdf.String(text)
    elif kind == "checkbox":
        on_states = [s for w in field.widgets for s in field.on_states(w)] or ["Yes"]
        if isinstance(value, bool) or value is None:
            on = on_states[0] if (value or checked) else None
        else:
            on = str(value) if str(value) in on_states else (on_states[0] if str(value) not in ("", "Off") else None)
        node.V = Name("/" + on) if on else Name.Off
        for w in field.widgets:
            states = field.on_states(w)
            w.AS = Name("/" + on) if on and on in states else Name.Off
    elif kind == "radio":
        states = {s for w in field.widgets for s in field.on_states(w)}
        options = [str(o) for o in (inherited(node, "/Opt") or [])]
        target = None if value in (None, "", "Off", False) else str(value)
        if target is not None and target not in states and options and target in options:
            target = str(options.index(target))
        require(target is None or target in states, "INVALID_ARGUMENT",
                f"“{value}” is not an option of the radio group “{field.name}”.")
        node.V = Name("/" + target) if target else Name.Off
        for w in field.widgets:
            w.AS = Name("/" + target) if target and target in field.on_states(w) else Name.Off
    elif kind in ("combo", "list"):
        options = field.options()
        values = value if isinstance(value, list) else ([] if value in (None, "") else [value])
        values = [str(v) for v in values]
        exports = []
        for v in values:
            match = next((export for label, export in options if export == v), None) or \
                    next((export for label, export in options if label == v), None)
            if match is None:
                require(kind == "combo" and field.flags & EDIT, "INVALID_ARGUMENT",
                        f"“{v}” is not an option of “{field.name}”.")
                match = v
            exports.append(match)
        order = {export: i for i, (_, export) in enumerate(options)}
        exports = sorted(dict.fromkeys(exports), key=lambda e: order.get(e, len(order)))
        if kind == "list" and len(exports) > 1:
            require(field.flags & MULTISELECT, "INVALID_ARGUMENT", f"“{field.name}” allows one selection.")
        if not exports:
            if "/V" in node:
                del node["/V"]
            if "/I" in node:
                del node["/I"]
            return
        node.V = pikepdf.Array([pikepdf.String(e) for e in exports]) if len(exports) > 1 else pikepdf.String(exports[0])
        indices = sorted(i for i, (_, export) in enumerate(options) if export in exports)
        if indices and (kind == "list" or len(indices) == len(exports)):
            node.I = pikepdf.Array(indices)
        elif "/I" in node:
            del node["/I"]


def _apply_logic(pdf, touched, logic=None, all_fields=None, normalize=True):
    """Normalize formatted input, run calculations, and refresh appearances."""
    all_fields = all_fields or fields(pdf)
    logic = logic if logic is not None else _logic(pdf, all_fields)
    by_name = {f.name: f for f in all_fields}
    acro, fonts = acroform(pdf)
    errors = {}
    for name in list(touched):
        field = by_name.get(name)
        if field is None or field.kind not in ("text", "combo") or name not in logic:
            continue
        raw = _value_text(field)
        error = logic[name].check(raw)
        if error:
            errors[name] = error
        elif normalize:
            normalized = logic[name].normalize(raw)
            if normalized != raw:
                _set_value(field, normalized)
    values = {f.name: _value_text(f) for f in all_fields if f.kind in ("text", "combo", "list", "checkbox", "radio")}
    order = [f.name for ref in (acro.get("/CO") or []) for f in all_fields if ref.is_indirect and f.node.is_indirect and f.node.objgen == ref.objgen]
    changed = F.calculate(logic, values, order, _expander(values))
    for name, value in changed.items():
        _set_value(by_name[name], value)
    for name in set(touched) | set(changed) | {n for n in logic if logic[n].format}:
        if name in by_name:
            refresh(pdf, by_name[name], logic.get(name), acro, fonts)
    return changed, errors


def _expander(values):
    def expand(name):
        if name in values:
            return [name]
        prefix = name + "."
        return [n for n in values if n.startswith(prefix)]
    return expand


@op("fill_fields")
def fill_fields(ctx, values):
    """Set values by field name: str for text/choice, bool/export for buttons,
    list[str] for multi-select list boxes."""
    pdf = ctx.pdf
    require(isinstance(values, dict) and values, "INVALID_ARGUMENT", "No values to fill.")
    all_fields = fields(pdf)
    by_name = {f.name: f for f in all_fields}
    for name, value in values.items():
        require(name in by_name, "NOT_FOUND", f"No form field is named “{name}”.")
        require(not by_name[name].flags & READONLY, "READ_ONLY_FIELD", f"“{name}” is read-only.")
        _set_value(by_name[name], value)
    changed, errors = _apply_logic(pdf, set(values), all_fields=all_fields)
    require(not errors, "INVALID_FIELD_VALUE", next(iter(errors.values())) if errors else "")
    return {"filled": len(values), "calculated": changed}


@op("fill_widgets")
def fill_widgets(ctx, edits):
    """Field edits located by (page, annotation index), as captured from PDFKit."""
    pdf = ctx.pdf
    require(isinstance(edits, list) and edits, "INVALID_ARGUMENT", "No field edits.")
    all_fields = fields(pdf)
    by_widget = {w.objgen: f for f in all_fields for w in f.widgets if w.is_indirect}
    touched = set()
    for edit in edits:
        page, index = edit.get("page"), edit.get("index")
        require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "A field edit refers to a missing page.")
        annots = pdf.pages[page].obj.get("/Annots", [])
        require(isinstance(index, int) and 0 <= index < len(annots), "FIELD_MISMATCH",
                "The field no longer matches the opened document. No file was replaced.")
        widget = annots[index]
        field = by_widget.get(widget.objgen)
        require(field is not None, "FIELD_MISMATCH", "The field no longer matches the opened document.")
        expected = edit.get("name")
        require(expected is None or expected in (field.name, field.name.split(".")[-1]) or
                field.name.endswith("." + expected) or expected == field.name, "FIELD_MISMATCH",
                "The field no longer matches the opened document. No file was replaced.")
        kind = field.kind
        if kind in ("checkbox",):
            _set_value(field, bool(edit.get("checked")))
        elif kind == "radio":
            if edit.get("checked"):
                states = field.on_states(widget)
                _set_value(field, states[0] if states else edit.get("value"))
            elif _text(field.value()) in field.on_states(widget):
                _set_value(field, None)
        elif kind in ("signature", "button"):
            continue
        else:
            value = edit.get("values") if edit.get("values") is not None else edit.get("value", "")
            _set_value(field, value)
        touched.add(field.name)
    changed, errors = _apply_logic(pdf, touched, all_fields=fields(pdf))
    require(not errors, "INVALID_FIELD_VALUE", next(iter(errors.values())) if errors else "")
    return {"filled": len(touched), "calculated": changed}


@op("reset_form")
def reset_form(ctx, names=None):
    pdf = ctx.pdf
    targets = [f for f in fields(pdf) if names is None or f.name in names]
    for field in targets:
        if field.kind in ("signature", "button"):
            continue
        default = inherited(field.node, "/DV")
        if field.kind in ("checkbox", "radio"):
            _set_value(field, _text(default) if default is not None and _text(default) != "Off" else None)
        elif default is None:
            _set_value(field, "" if field.kind in ("text", "barcode") else None)
        else:
            _set_value(field, [_text(v) for v in default] if isinstance(default, pikepdf.Array) else _text(default))
    _apply_logic(pdf, {f.name for f in targets}, normalize=False)
    return {"reset": len(targets)}


@op("recalculate")
def recalculate(ctx):
    changed, _ = _apply_logic(ctx.pdf, set(), normalize=False)
    return {"calculated": changed}


@op("update_barcodes")
def update_barcodes(ctx, items):
    """items: [{name, value, matrix}] computed by the app (CoreImage encoders)."""
    pdf = ctx.pdf
    acro, fonts = acroform(pdf)
    for item in items:
        field = find(pdf, item["name"])
        require(field.kind == "barcode", "INVALID_ARGUMENT", "Not a barcode field.")
        field.node.V = pikepdf.String(str(item.get("value", "")))
        refresh(pdf, field, None, acro, fonts, barcode=item.get("matrix") or [])
    return {"updated": len(items)}


# ------------------------------------------------------------ flattening

@op("flatten_form_fields")
def flatten_form_fields(ctx, names=None):
    """Draw field appearances into the page content and remove the fields."""
    from transforms.content import stamp_appearances
    pdf = ctx.pdf
    all_fields = fields(pdf)
    require(all_fields, "NO_FIELDS", "This document has no form fields to flatten.")
    targets = [f for f in all_fields if names is None or f.name in names]
    logic = _logic(pdf, all_fields)
    acro, fonts = acroform(pdf)
    ids = set()
    for field in targets:
        if field.kind != "signature" or "/V" not in field.node:
            refresh(pdf, field, logic.get(field.name), acro, fonts) if field.kind not in ("barcode", "signature") else None
        for w in field.widgets:
            if w.is_indirect:
                ids.add(w.objgen)
    count = 0
    for page in pdf.pages:
        annots = page.obj.get("/Annots")
        if not annots:
            continue
        flatten = [a for a in annots if a.is_indirect and a.objgen in ids]
        if not flatten:
            continue
        visible = [a for a in flatten if not int(a.get("/F", 0)) & HIDDEN and "/AP" in a]
        page.obj.Annots = pikepdf.Array([a for a in annots if not (a.is_indirect and a.objgen in ids)])
        stamp_appearances(pdf, page, visible)
        count += len(flatten)
    prune_fields(pdf)
    return {"flattened": count}


@op("convert_xfa_form")
def convert_xfa_form(ctx):
    """Keep a hybrid form's AcroForm fields and drop the XFA packet."""
    pdf = ctx.pdf
    acro = pdf.Root.get("/AcroForm")
    require(acro is not None and "/XFA" in acro, "NOT_XFA", "This document has no XFA form.")
    require(len(acro.get("/Fields", [])) > 0, "DYNAMIC_XFA",
            "This is a dynamic XFA form without standard fields, so it can’t be converted.")
    del acro["/XFA"]
    if "/NeedsRendering" in pdf.Root:
        del pdf.Root["/NeedsRendering"]
    _, fonts = acroform(pdf)
    regenerated = 0
    for field in fields(pdf):
        if any("/AP" not in w for w in field.widgets) and field.kind not in ("signature",):
            refresh(pdf, field, None, acro, fonts)
            regenerated += 1
    return {"fields": len(fields(pdf)), "regenerated": regenerated}


# --------------------------------------------------------------- queries

def _color_list(value):
    return [float(v) for v in value] if value is not None else None


def describe(field, logic):
    node = field.node
    flags = field.flags
    first = field.widgets[0] if field.widgets else pikepdf.Dictionary()
    mk = first.get("/MK") or pikepdf.Dictionary()
    bs = first.get("/BS")
    da = str(first.get("/DA") or inherited(node, "/DA") or "/Helv 0 Tf 0 g")
    font_key, size, _ = A.parse_da(da)
    value = field.value()
    kind = field.kind
    info = {
        "name": field.name, "kind": kind, "tooltip": _text(inherited(node, "/TU")),
        "readonly": bool(flags & READONLY), "required": bool(flags & REQUIRED),
        "value": ([_text(v) for v in value] if isinstance(value, pikepdf.Array) else _text(value)) if value is not None else None,
        "default": _text(inherited(node, "/DV")) if inherited(node, "/DV") is not None else None,
        "font": next((k for k, v in FONTS.items() if v == font_key), font_key), "font_size": size,
        "text_color": _da_color(da), "alignment": {0: "left", 1: "center", 2: "right"}.get(int(inherited(node, "/Q") or 0), "left"),
        "border_color": _color_list(mk.get("/BC")), "fill_color": _color_list(mk.get("/BG")),
        "border_width": float(bs.get("/W", 1)) if bs is not None else 1.0,
        "border_style": next((k for k, v in STYLES.items() if bs is not None and str(bs.get("/S", "/S")) == v), "solid"),
        "hidden": bool(int(first.get("/F", 0)) & HIDDEN), "print": bool(int(first.get("/F", PRINT)) & PRINT),
        "widgets": [{"page": field.page_of(w), "rect": [float(v) for v in w.get("/Rect", [0, 0, 0, 0])],
                     "export": (field.on_states(w) or [None])[0]} for w in field.widgets],
    }
    if kind in ("text", "barcode"):
        max_len = inherited(node, "/MaxLen")
        info.update({"multiline": bool(flags & MULTILINE), "password": bool(flags & PASSWORD), "comb": bool(flags & COMB),
                     "scroll": not flags & NOSCROLL, "spellcheck": not flags & NOSPELL,
                     "max_length": int(max_len) if max_len is not None else None})
    if kind in ("combo", "list"):
        info.update({"options": [{"label": l, "export": e} for l, e in field.options()],
                     "editable": bool(flags & EDIT), "multi_select": bool(flags & MULTISELECT),
                     "sort": bool(flags & SORT), "commit_on_select": bool(flags & COMMIT)})
    if kind in ("checkbox", "radio"):
        info["check_style"] = next((k for k, v in A.ZAPF.items() if "/CA" in mk and str(mk.CA) == v), "check" if kind == "checkbox" else "circle")
        info["exports"] = sorted({s for w in field.widgets for s in field.on_states(w)})
    if kind == "button":
        info["caption"] = _text(mk.get("/CA"))
        info["action"] = _describe_action(first)
    if kind == "barcode":
        pmd = node.get("/PMD") or pikepdf.Dictionary()
        info["barcode"] = {"symbology": {"/QRCode": "qr", "/PDF417": "pdf417", "/DataMatrix": "datamatrix"}.get(str(pmd.get("/Symbology", "/QRCode")), "qr"),
                           "fields": [_text(n) for n in pmd.get("/ZPDFFields", [])]}
    if kind == "signature":
        info["signed"] = isinstance(value, pikepdf.Dictionary) and "/ByteRange" in value
        info["value"] = None
    scripts = field.scripts()
    info["format"] = F.describe_format(scripts.get("F")) if scripts.get("F") else {"kind": "none"}
    info["validate"] = F.describe_validate(scripts.get("V")) if scripts.get("V") else None
    info["calculate"] = F.describe_calculate(scripts.get("C")) if scripts.get("C") else None
    if field.name in logic and logic[field.name].unsupported:
        info["unsupported_scripts"] = logic[field.name].unsupported
    return info


@query("form_fields")
def form_fields_query(ctx):
    pdf = ctx.pdf
    all_fields = fields(pdf)
    logic = _logic(pdf, all_fields)
    acro = pdf.Root.get("/AcroForm")
    order = []
    if acro is not None:
        for ref in acro.get("/CO") or []:
            for f in all_fields:
                if ref.is_indirect and f.node.is_indirect and f.node.objgen == ref.objgen:
                    order.append(f.name)
    tabs = []
    for index, page in enumerate(pdf.pages):
        mode = str(page.obj.get("/Tabs", ""))
        tabs.append({"R": "row", "C": "column", "S": "structure"}.get(mode[1:], "manual"))
    return {"fields": [describe(f, logic) for f in all_fields], "calculation_order": order, "tab_order": tabs,
            "xfa": acro is not None and "/XFA" in acro,
            "needs_appearances": bool(acro is not None and acro.get("/NeedAppearances", False)),
            "has_logic": any(l.format or l.calculate or l.validate for l in logic.values())}


@query("form_calculate")
def form_calculate(ctx, values, touched=None):
    """Live form logic for on-screen values (name -> text): returns the
    normalized values, calculated values, display strings and errors."""
    pdf = ctx.pdf
    all_fields = fields(pdf)
    logic = _logic(pdf, all_fields)
    current = {f.name: _value_text(f) for f in all_fields if f.kind in ("text", "combo", "list", "checkbox", "radio")}
    errors, normalized = {}, {}
    for name, value in (values or {}).items():
        text = "" if value is None else str(value)
        if name in logic and (touched is None or name in touched):
            error = logic[name].check(text)
            if error:
                errors[name] = error
                continue
            text = logic[name].normalize(text)
            if text != value:
                normalized[name] = text
        current[name] = text
    order = []
    acro = pdf.Root.get("/AcroForm")
    if acro is not None:
        for ref in acro.get("/CO") or []:
            order += [f.name for f in all_fields if ref.is_indirect and f.node.is_indirect and f.node.objgen == ref.objgen]
    changed = F.calculate(logic, current, order, _expander(current))
    current.update(changed)
    display = {name: logic[name].display(current.get(name))[0] for name in logic if logic[name].format}
    return {"calculated": changed, "normalized": normalized, "display": display, "errors": errors,
            "values": {n: current[n] for n in set(changed) | set(normalized)}}


@query("widget_kinds")
def widget_kinds(ctx, widgets):
    """Field kinds for PDFKit widget locations (used to route Save)."""
    pdf = ctx.pdf
    all_fields = fields(pdf)
    by_widget = {w.objgen: f for f in all_fields for w in f.widgets if w.is_indirect}
    out = []
    for page, index in widgets:
        annots = pdf.pages[page].obj.get("/Annots", []) if 0 <= page < len(pdf.pages) else []
        field = by_widget.get(annots[index].objgen) if 0 <= index < len(annots) else None
        if field is None:
            out.append(None)
            continue
        out.append({"name": field.name, "kind": field.kind, "editable": bool(field.flags & EDIT),
                    "multi": bool(field.flags & MULTISELECT),
                    "options": [e for _, e in field.options()] + [l for l, _ in field.options()]})
    logic = _logic(pdf, all_fields)
    return {"widgets": out, "has_logic": any(l.format or l.calculate or l.validate for l in logic.values())}
