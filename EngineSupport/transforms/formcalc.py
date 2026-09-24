"""A safe interpreter for Acrobat's standard form scripts.

No JavaScript is executed. Field action scripts are matched against the
built-in Acrobat form functions (AFNumber_*, AFPercent_*, AFDate_*,
AFTime_*, AFSpecial_*, AFRange_Validate, AFSimple_Calculate) and Simplified
Field Notation (the `/** BVCALC ... EVCALC **/` block Acrobat writes); their
arguments are parsed as literals only. Anything else is reported as an
unsupported script and left untouched.
"""
import datetime as dt
import math
import re

NUMBER = re.compile(r"[-+]?(?:\d+(?:[.,]\d*)?|[.,]\d+)(?:[eE][-+]?\d+)?")
CALL = re.compile(r"\b(AF\w+)\s*\((.*)\)\s*;?\s*$", re.S)
SFN = re.compile(r"/\*\*\s*BVCALC\s+(.*?)\s+EVCALC\s*\*\*/", re.S)

SEPARATORS = {0: (",", "."), 1: ("", "."), 2: (".", ","), 3: ("", ","), 4: ("'", ".")}
SPECIAL = {0: "zip", 1: "zip4", 2: "phone", 3: "ssn"}
TIME_FORMATS = {0: "HH:MM", 1: "h:MM tt", 2: "HH:MM:ss", 3: "h:MM:ss tt"}


class Unsupported(Exception):
    pass


# ------------------------------------------------------------ parse args

def _split_args(text):
    """Literal arguments: numbers, strings, booleans, `new Array(...)`, [..]."""
    args, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n,":
            i += 1
            continue
        if c in "\"'":
            j, out = i + 1, []
            while j < n and text[j] != c:
                if text[j] == "\\" and j + 1 < n:
                    j += 1
                    out.append({"n": "\n", "t": "\t", "r": "\r"}.get(text[j], text[j]))
                else:
                    out.append(text[j])
                j += 1
            if j >= n:
                raise Unsupported("unterminated string")
            args.append("".join(out))
            i = j + 1
            continue
        match = re.match(r"new\s+Array\s*\(", text[i:])
        if match or c == "[":
            start = i + (match.end() if match else 1)
            depth, j = 1, start
            close = ")" if match else "]"
            opener = "(" if match else "["
            quote = None
            while j < n and depth:
                ch = text[j]
                if quote:
                    if ch == "\\":
                        j += 1
                    elif ch == quote:
                        quote = None
                elif ch in "\"'":
                    quote = ch
                elif ch == opener:
                    depth += 1
                elif ch == close:
                    depth -= 1
                j += 1
            if depth:
                raise Unsupported("unterminated array")
            args.append(_split_args(text[start:j - 1]))
            i = j
            continue
        match = re.match(r"true|false", text[i:])
        if match:
            args.append(match.group(0) == "true")
            i += match.end()
            continue
        match = re.match(r"[-+]?\d+(?:\.\d+)?", text[i:])
        if match:
            value = float(match.group(0))
            args.append(int(value) if value.is_integer() else value)
            i += match.end()
            continue
        raise Unsupported(f"unsupported argument near {text[i:i + 12]!r}")
    return args


def parse_script(js):
    """(function name, literal args) for a single standard call, else None."""
    if not js:
        return None
    text = js.strip()
    sfn = SFN.search(text)
    if sfn:
        return ("SFN", [sfn.group(1).strip()])
    # Tolerate the "event.value = ..." forms Acrobat never writes for these.
    match = CALL.search(text)
    if not match or text[:match.start()].strip() not in ("",):
        raise Unsupported("custom script")
    return match.group(1), _split_args(match.group(2))


# -------------------------------------------------------------- numbers

def make_number(value, sep_style=0):
    """AFMakeNumber: parse user input, tolerating separators and currency."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if not text:
        return None
    negative = text.startswith("(") and text.endswith(")")
    thousands, decimal = SEPARATORS.get(sep_style, (",", "."))
    cleaned = re.sub(r"[^\d,.\-+'eE]", "", text)
    if decimal == ",":
        cleaned = cleaned.replace(".", "").replace("'", "").replace(",", ".")
    else:
        cleaned = cleaned.replace(",", "").replace("'", "")
    match = NUMBER.search(cleaned)
    if not match:
        return None
    try:
        number = float(match.group(0))
    except ValueError:
        return None
    if negative or text.lstrip().startswith("-"):
        number = -abs(number)
    return number


def _group(digits, sep):
    if not sep:
        return digits
    out = []
    while len(digits) > 3:
        out.insert(0, digits[-3:])
        digits = digits[:-3]
    out.insert(0, digits)
    return sep.join(out)


def format_number(number, decimals=2, sep_style=0, neg_style=0, currency="", prepend=True):
    """AFNumber_Format -> (text, red)."""
    if number is None:
        return "", False
    decimals = max(0, min(int(decimals), 10))
    thousands, decimal = SEPARATORS.get(int(sep_style), (",", "."))
    rounded = round(abs(number) + 0.0, decimals)
    whole, _, frac = f"{rounded:.{decimals}f}".partition(".")
    text = _group(whole, thousands) + (decimal + frac if decimals else "")
    if currency:
        text = (currency + text) if prepend else (text + currency)
    negative = number < 0 and rounded != 0
    red = negative and int(neg_style) in (1, 3)
    if negative:
        text = f"({text})" if int(neg_style) in (2, 3) else "-" + text
    return text, red


def format_percent(number, decimals=2, sep_style=0):
    if number is None:
        return ""
    text, _ = format_number(number * 100, decimals, sep_style, 0)
    return text + "%"


# ---------------------------------------------------------------- dates

MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December"]
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
TOKEN = re.compile(r"mmmm|mmm|mm|m|dddd|ddd|dd|d|yyyy|yy|HH|H|hh|h|MM|M|ss|s|tt|t|\\.|.", re.S)


def format_date(moment, fmt):
    out = []
    for token in TOKEN.findall(fmt):
        if token.startswith("\\"):
            out.append(token[1:])
            continue
        hour12 = moment.hour % 12 or 12
        out.append({
            "mmmm": MONTHS[moment.month - 1], "mmm": MONTHS[moment.month - 1][:3],
            "mm": f"{moment.month:02d}", "m": str(moment.month),
            "dddd": DAYS[moment.weekday()], "ddd": DAYS[moment.weekday()][:3],
            "dd": f"{moment.day:02d}", "d": str(moment.day),
            "yyyy": f"{moment.year:04d}", "yy": f"{moment.year % 100:02d}",
            "HH": f"{moment.hour:02d}", "H": str(moment.hour), "hh": f"{hour12:02d}", "h": str(hour12),
            "MM": f"{moment.minute:02d}", "M": str(moment.minute),
            "ss": f"{moment.second:02d}", "s": str(moment.second),
            "tt": "am" if moment.hour < 12 else "pm", "t": "a" if moment.hour < 12 else "p",
        }.get(token, token))
    return "".join(out)


def parse_date(text, fmt="mm/dd/yyyy"):
    """Acrobat-style lenient date parsing guided by the format's field order."""
    if text is None:
        return None
    text = str(text).strip()
    if not text:
        return None
    lower = text.lower()
    month_name = None
    for index, name in enumerate(MONTHS):
        if name.lower()[:3] in lower:
            month_name = index + 1
            break
    numbers = [int(n) for n in re.findall(r"\d+", text)]
    order = [t[0] for t in TOKEN.findall(fmt) if t[:1] in ("m", "d", "y") and t not in ("ddd", "dddd")]
    order = list(dict.fromkeys(order)) or ["m", "d", "y"]
    parts = {}
    if month_name:
        parts["m"] = month_name
        order = [o for o in order if o != "m"]
    for key, value in zip(order, numbers):
        parts[key] = value
    remaining = numbers[len(order):]
    today = dt.date.today()
    year = parts.get("y", today.year)
    if year < 100:
        year += 2000 if year < 50 else 1900
    try:
        moment = dt.datetime(year, parts.get("m", 1 if "m" not in order else today.month), parts.get("d", 1))
    except ValueError:
        return None
    time_numbers = remaining
    if ":" in text and time_numbers:
        hour = time_numbers[0]
        minute = time_numbers[1] if len(time_numbers) > 1 else 0
        second = time_numbers[2] if len(time_numbers) > 2 else 0
        if "pm" in lower and hour < 12:
            hour += 12
        if "am" in lower and hour == 12:
            hour = 0
        try:
            moment = moment.replace(hour=hour, minute=minute, second=second)
        except ValueError:
            return None
    return moment


def parse_time(text):
    match = re.search(r"(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*([ap])?", str(text or "").lower())
    if not match:
        return None
    hour, minute, second = int(match.group(1)), int(match.group(2) or 0), int(match.group(3) or 0)
    if match.group(4) == "p" and hour < 12:
        hour += 12
    if match.group(4) == "a" and hour == 12:
        hour = 0
    if hour > 23 or minute > 59 or second > 59:
        return None
    return dt.datetime(2000, 1, 1, hour, minute, second)


def format_special(value, kind):
    digits = re.sub(r"\D", "", str(value or ""))
    if kind == 0:
        return digits[:5]
    if kind == 1:
        return digits[:5] + ("-" + digits[5:9] if len(digits) > 5 else "")
    if kind == 2:
        if len(digits) == 10:
            return f"({digits[:3]}) {digits[3:6]}-{digits[6:]}"
        if len(digits) == 7:
            return f"{digits[:3]}-{digits[3:]}"
        return digits
    if kind == 3:
        return f"{digits[:3]}-{digits[3:5]}-{digits[5:9]}" if len(digits) >= 9 else digits
    return str(value)


def special_valid(value, kind):
    digits = re.sub(r"\D", "", str(value or ""))
    if not digits:
        return True
    return {0: len(digits) == 5, 1: len(digits) == 9, 2: len(digits) in (7, 10), 3: len(digits) == 9}.get(kind, True)


# ------------------------------------------------------- field behaviors

def describe_format(js):
    """Structured description of a format script (for the inspector)."""
    try:
        parsed = parse_script(js)
    except Unsupported:
        return {"kind": "custom", "script": js}
    if not parsed:
        return {"kind": "none"}
    name, args = parsed
    if name == "AFNumber_Format":
        a = (args + [2, 0, 0, 0, "", True])[:6]
        return {"kind": "number", "decimals": a[0], "separator": a[1], "negative": a[2],
                "currency": a[4], "prepend": bool(a[5])}
    if name == "AFPercent_Format":
        a = (args + [2, 0])[:2]
        return {"kind": "percent", "decimals": a[0], "separator": a[1]}
    if name in ("AFDate_FormatEx", "AFDate_Format"):
        fmt = args[0] if args and isinstance(args[0], str) else DATE_PRESETS.get(args[0] if args else 0, "m/d/yy")
        return {"kind": "date", "format": fmt}
    if name == "AFTime_Format":
        return {"kind": "time", "style": int(args[0]) if args else 0}
    if name == "AFTime_FormatEx":
        return {"kind": "time", "format": args[0] if args else "HH:MM"}
    if name == "AFSpecial_Format":
        return {"kind": "special", "style": int(args[0]) if args else 0}
    return {"kind": "custom", "script": js}


DATE_PRESETS = {0: "m/d", 1: "m/d/yy", 2: "mm/dd/yy", 3: "mm/yy", 4: "d-mmm", 5: "d-mmm-yy", 6: "dd-mmm-yy",
                7: "yy-mm-dd", 8: "mmm-yy", 9: "mmmm-yy", 10: "mmm d, yyyy", 11: "mmmm d, yyyy",
                12: "m/d/yy h:MM tt", 13: "m/d/yy HH:MM"}


def format_scripts(spec):
    """(format JS, keystroke JS) for an inspector format description."""
    kind = (spec or {}).get("kind", "none")
    if kind == "number":
        currency = str(spec.get("currency", "")).replace("\\", "\\\\").replace('"', '\\"')
        args = f'{int(spec.get("decimals", 2))}, {int(spec.get("separator", 0))}, {int(spec.get("negative", 0))}, 0, "{currency}", {"true" if spec.get("prepend", True) else "false"}'
        return f"AFNumber_Format({args});", f"AFNumber_Keystroke({args});"
    if kind == "percent":
        args = f'{int(spec.get("decimals", 2))}, {int(spec.get("separator", 0))}'
        return f"AFPercent_Format({args});", f"AFPercent_Keystroke({args});"
    if kind == "date":
        fmt = str(spec.get("format", "mm/dd/yyyy")).replace('"', "")
        return f'AFDate_FormatEx("{fmt}");', f'AFDate_KeystrokeEx("{fmt}");'
    if kind == "time":
        if spec.get("format"):
            fmt = str(spec["format"]).replace('"', "")
            return f'AFTime_FormatEx("{fmt}");', f'AFTime_KeystrokeEx("{fmt}");'
        style = int(spec.get("style", 0))
        return f"AFTime_Format({style});", f"AFTime_Keystroke({style});"
    if kind == "special":
        style = int(spec.get("style", 0))
        return f"AFSpecial_Format({style});", f"AFSpecial_Keystroke({style});"
    return None, None


def validate_script(spec):
    if not spec or (spec.get("min") is None and spec.get("max") is None):
        return None
    low, high = spec.get("min"), spec.get("max")
    def num(v):
        return repr(float(v)).rstrip("0").rstrip(".") if v is not None else "0"
    return (f"AFRange_Validate({'true' if low is not None else 'false'}, {num(low)}, "
            f"{'true' if high is not None else 'false'}, {num(high)});")


def describe_validate(js):
    try:
        parsed = parse_script(js)
    except Unsupported:
        return {"kind": "custom", "script": js}
    if not parsed or parsed[0] != "AFRange_Validate":
        return {"kind": "custom", "script": js} if parsed else None
    a = (parsed[1] + [False, 0, False, 0])[:4]
    return {"kind": "range", "min": a[1] if a[0] else None, "max": a[3] if a[2] else None}


def calculate_script(spec):
    if not spec:
        return None
    kind = spec.get("kind")
    if kind in ("sum", "product", "average", "min", "max"):
        op = {"sum": "SUM", "product": "PRD", "average": "AVG", "min": "MIN", "max": "MAX"}[kind]
        names = ", ".join('"' + str(n).replace("\\", "\\\\").replace('"', '\\"') + '"' for n in spec.get("fields", []))
        return f'AFSimple_Calculate("{op}", new Array ({names}));'
    if kind == "sfn":
        expr = str(spec.get("expression", "")).strip()
        parse_sfn(expr)  # reject invalid notation early
        return f"/** BVCALC {expr} EVCALC **/ event.value = AFMakeNumber(0);"
    return None


def describe_calculate(js):
    try:
        parsed = parse_script(js)
    except Unsupported:
        return {"kind": "custom", "script": js}
    if not parsed:
        return None
    name, args = parsed
    if name == "SFN":
        return {"kind": "sfn", "expression": args[0]}
    if name == "AFSimple_Calculate" and len(args) >= 2:
        kind = {"SUM": "sum", "PRD": "product", "AVG": "average", "MIN": "min", "MAX": "max"}.get(str(args[0]).upper())
        fields = args[1] if isinstance(args[1], list) else [args[1]]
        return {"kind": kind or "custom", "fields": [str(f) for f in fields]}
    return {"kind": "custom", "script": js}


# ------------------------------------------------ Simplified Field Notation

def _sfn_tokens(expr):
    tokens, i = [], 0
    while i < len(expr):
        c = expr[i]
        if c.isspace():
            i += 1
        elif c in "+-*/()":
            tokens.append(c)
            i += 1
        elif c.isdigit() or (c == "." and i + 1 < len(expr) and expr[i + 1].isdigit()):
            m = re.match(r"\d*\.?\d+(?:[eE][-+]?\d+)?", expr[i:])
            tokens.append(float(m.group(0)))
            i += m.end()
        else:
            name = []
            while i < len(expr) and (expr[i] == "\\" or expr[i] not in "+-*/() \t\r\n"):
                if expr[i] == "\\" and i + 1 < len(expr):
                    i += 1
                name.append(expr[i])
                i += 1
            tokens.append(("field", "".join(name)))
    return tokens


def parse_sfn(expr):
    tokens = _sfn_tokens(expr)
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else None

    def take():
        nonlocal pos
        pos += 1
        return tokens[pos - 1]

    def primary():
        token = peek()
        if token is None:
            raise Unsupported("incomplete expression")
        if token == "(":
            take()
            node = additive()
            if take() != ")":
                raise Unsupported("missing )")
            return node
        if token == "-":
            take()
            return ("neg", primary())
        if token == "+":
            take()
            return primary()
        take()
        if isinstance(token, float):
            return ("num", token)
        if isinstance(token, tuple):
            return token
        raise Unsupported("unexpected token")

    def term():
        node = primary()
        while peek() in ("*", "/"):
            node = (take(), node, primary())
        return node

    def additive():
        node = term()
        while peek() in ("+", "-"):
            node = (take(), node, term())
        return node

    tree = additive()
    if pos != len(tokens):
        raise Unsupported("trailing tokens")
    return tree


def sfn_fields(tree):
    if tree[0] == "field":
        return [tree[1]]
    if tree[0] == "num":
        return []
    if tree[0] == "neg":
        return sfn_fields(tree[1])
    return sfn_fields(tree[1]) + sfn_fields(tree[2])


def eval_sfn(tree, lookup):
    kind = tree[0]
    if kind == "num":
        return tree[1]
    if kind == "field":
        return lookup(tree[1])
    if kind == "neg":
        return -eval_sfn(tree[1], lookup)
    a, b = eval_sfn(tree[1], lookup), eval_sfn(tree[2], lookup)
    if kind == "+":
        return a + b
    if kind == "-":
        return a - b
    if kind == "*":
        return a * b
    return a / b if b else 0.0


# --------------------------------------------------------------- engine

class FieldLogic:
    """Parsed behaviors of one field (format, keystroke, validate, calculate)."""

    def __init__(self, name, scripts):
        self.name = name
        self.unsupported = []
        self.format = self._parse(scripts.get("F"), "format")
        self.validate = self._parse(scripts.get("V"), "validate")
        self.calculate = self._parse(scripts.get("C"), "calculate")
        self.keystroke = self._parse(scripts.get("K"), "keystroke")

    def _parse(self, js, role):
        if not js:
            return None
        try:
            return parse_script(js)
        except Unsupported:
            self.unsupported.append(role)
            return None

    def display(self, value):
        """(display text, red) for a stored value."""
        if self.format is None:
            return (value or ""), False
        name, args = self.format
        text = "" if value is None else str(value)
        if text.strip() == "":
            return "", False
        if name == "AFNumber_Format":
            a = (args + [2, 0, 0, 0, "", True])[:6]
            number = make_number(text, a[1])
            if number is None:
                return text, False
            return format_number(number, a[0], a[1], a[2], a[4], bool(a[5]))
        if name == "AFPercent_Format":
            a = (args + [2, 0])[:2]
            number = make_number(text, a[1])
            return (format_percent(number, a[0], a[1]) if number is not None else text), False
        if name in ("AFDate_FormatEx", "AFDate_Format"):
            fmt = args[0] if args and isinstance(args[0], str) else DATE_PRESETS.get(args[0] if args else 1, "m/d/yy")
            moment = parse_date(text, fmt)
            return (format_date(moment, fmt) if moment else text), False
        if name in ("AFTime_Format", "AFTime_FormatEx"):
            fmt = args[0] if name == "AFTime_FormatEx" and args else TIME_FORMATS.get(int(args[0]) if args else 0, "HH:MM")
            moment = parse_time(text)
            return (format_date(moment, fmt) if moment else text), False
        if name == "AFSpecial_Format":
            return format_special(text, int(args[0]) if args else 0), False
        return text, False

    def normalize(self, value):
        """The value to store for user input (formatted input is unformatted)."""
        if self.format is None or value is None:
            return value
        name, args = self.format
        text = str(value)
        if name == "AFNumber_Format" and text.strip():
            a = (args + [2, 0])[:2]
            number = make_number(text, a[1])
            return _plain(number) if number is not None else text
        if name == "AFPercent_Format" and text.strip():
            a = (args + [2, 0])[:2]
            number = make_number(text.replace("%", ""), a[1])
            if number is None:
                return text
            return _plain(number / 100 if "%" in text else number)
        if name == "AFSpecial_Format" and text.strip():
            return re.sub(r"\D", "", text)
        return value

    def check(self, value):
        """Validation error message, or None."""
        text = "" if value is None else str(value).strip()
        if not text:
            return None
        fmt = self.format or self.keystroke
        if fmt:
            name, args = fmt
            if name.startswith(("AFNumber", "AFPercent")):
                if make_number(text, (args + [2, 0])[1]) is None:
                    return f"The value entered does not match the format of the field [ {self.name} ]"
            elif name.startswith("AFDate"):
                pattern = args[0] if args and isinstance(args[0], str) else "m/d/yy"
                if parse_date(text, pattern) is None:
                    return f"Invalid date/time: please ensure that the date/time exists. Field [ {self.name} ] should match format {pattern}"
            elif name.startswith("AFTime"):
                if parse_time(text) is None:
                    return f"The value entered does not match the format of the field [ {self.name} ]"
            elif name.startswith("AFSpecial"):
                if not special_valid(text, int(args[0]) if args else 0):
                    return f"The value entered does not match the format of the field [ {self.name} ]"
        if self.validate and self.validate[0] == "AFRange_Validate":
            a = (self.validate[1] + [False, 0, False, 0])[:4]
            number = make_number(text)
            if number is None:
                return f"The value entered does not match the format of the field [ {self.name} ]"
            if (a[0] and number < a[1]) or (a[2] and number > a[3]):
                if a[0] and a[2]:
                    return f"Invalid value: must be greater than or equal to {_plain(a[1])} and less than or equal to {_plain(a[3])}."
                if a[0]:
                    return f"Invalid value: must be greater than or equal to {_plain(a[1])}."
                return f"Invalid value: must be less than or equal to {_plain(a[3])}."
        return None

    def dependencies(self):
        if not self.calculate:
            return []
        name, args = self.calculate
        if name == "SFN":
            try:
                return sfn_fields(parse_sfn(args[0]))
            except Unsupported:
                return []
        if name == "AFSimple_Calculate" and len(args) >= 2:
            fields = args[1] if isinstance(args[1], list) else [args[1]]
            return [str(f) for f in fields]
        return []

    def compute(self, lookup_value, expand):
        """New value for a calculated field, or None when not computable."""
        if not self.calculate:
            return None
        name, args = self.calculate
        if name == "AFSimple_Calculate" and len(args) >= 2:
            op = str(args[0]).upper()
            fields = args[1] if isinstance(args[1], list) else [args[1]]
            numbers = []
            for field in fields:
                for actual in expand(str(field)):
                    numbers.append(make_number(lookup_value(actual)) or 0.0)
            if not numbers:
                return 0.0
            if op == "SUM":
                return math.fsum(numbers)
            if op == "PRD":
                product = 1.0
                for n in numbers:
                    product *= n
                return product
            if op == "AVG":
                return math.fsum(numbers) / len(numbers)
            if op == "MIN":
                return min(numbers)
            if op == "MAX":
                return max(numbers)
            return None
        if name == "SFN":
            try:
                tree = parse_sfn(args[0])
            except Unsupported:
                return None
            return eval_sfn(tree, lambda f: math.fsum(make_number(lookup_value(a)) or 0.0 for a in expand(f)) if expand(f) else 0.0)
        return None


def _plain(number):
    if number is None:
        return ""
    if float(number).is_integer():
        return str(int(number))
    return repr(round(float(number), 10))


def calculate(logic, values, order, expand=None):
    """Run calculations (in calculation order) over `values` (name -> str).

    Returns {name: new raw value} for fields whose value changed.
    """
    expand = expand or (lambda name: [name] if name in values else [])
    updated = dict(values)
    changed = {}
    sequence = [n for n in order if n in logic and logic[n].calculate] + \
               [n for n, l in logic.items() if l.calculate and n not in order]
    for _ in range(2):  # a second pass settles out-of-order dependencies
        for name in sequence:
            result = logic[name].compute(lambda n: updated.get(n), expand)
            if result is None:
                continue
            text = _plain(result)
            if updated.get(name) != text:
                updated[name] = text
                changed[name] = text
    return changed
