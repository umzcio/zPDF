"""Content-stream interpreter and rewriter shared by redaction and editing.

`Walker` runs a page's content streams (and the Form XObjects they invoke)
through a PDF graphics/text state machine and reports every painted thing:
glyphs (codes, Unicode, user-space quads, advances), paths, images, inline
images, shadings and form invocations. A `Plan` answers what to do with each
of them, keyed by traversal counters, so a first pass can collect geometry
and decide, and a second identical pass can rewrite.

Rewriting (`rewrite_page`) keeps the page's stream structure: each content
stream is parsed and emitted separately, only changed streams are replaced
by new stream objects, and forms that change are copied under a new resource
name (shared forms stay intact elsewhere). Removed glyphs are replaced by TJ
displacement so remaining text keeps its position; replaced resources are
dropped from the page's own resource dictionaries so the original data is no
longer reachable from the page.
"""
import hashlib
import math

import pikepdf
from pikepdf import Name, Operator

from transforms.content import multiply, apply, invert
from transforms.pdffonts import font_info

IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
PATH_OPS = {"m", "l", "c", "v", "y", "h", "re"}
PAINT_OPS = {"S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"}
SHOW_OPS = {"Tj", "TJ", "'", '"'}
COLOR_SPACE_COMPONENTS = {"/DeviceGray": 1, "/DeviceRGB": 3, "/DeviceCMYK": 4, "/CalGray": 1, "/CalRGB": 3,
                          "/Lab": 3, "/G": 1, "/RGB": 3, "/CMYK": 4}


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def matrix_of(values):
    try:
        m = tuple(float(v) for v in values)
        return m if len(m) == 6 else IDENTITY
    except (TypeError, ValueError):
        return IDENTITY


def safe_invert(m):
    a, b, c, d, e, f = m
    if abs(a * d - b * c) < 1e-12:
        return None
    return invert(m)


def quad_bbox(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (min(xs), min(ys), max(xs), max(ys))


def rect_intersects(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def point_in_rect(p, r):
    return r[0] <= p[0] <= r[2] and r[1] <= p[1] <= r[3]


def instr(operands, operator):
    return pikepdf.ContentStreamInstruction(list(operands), Operator(operator))


def page_digest(page):
    """Identity of a page's content, used to reject stale object references."""
    h = hashlib.sha256()
    contents = page.obj.get("/Contents")
    streams = [] if contents is None else (list(contents) if isinstance(contents, pikepdf.Array) else [contents])
    for stream in streams:
        try:
            h.update(stream.read_bytes())
        except pikepdf.PdfError:
            h.update(b"?")
        h.update(b"\x00")
    return h.hexdigest()[:24]


# ---------------------------------------------------------------- colors

def cmyk_to_rgb(c, m, y, k):
    return ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))


class Color:
    """A fill or stroke color with the operators that reproduce it."""
    __slots__ = ("space", "components", "space_obj")

    def __init__(self, space="/DeviceGray", components=(0.0,), space_obj=None):
        self.space = space
        self.components = tuple(components)
        self.space_obj = space_obj

    def copy(self):
        return Color(self.space, self.components, self.space_obj)

    def rgb(self):
        comps = [c for c in self.components if isinstance(c, float)]
        n = len(comps)
        if n == 1:
            return (comps[0],) * 3
        if n == 3:
            return tuple(comps)
        if n == 4:
            return cmyk_to_rgb(*comps)
        return (0.0, 0.0, 0.0)

    def ops(self, stroke=False, resources=None):
        """Operators recreating this color (device spaces directly)."""
        comps = [c for c in self.components if isinstance(c, float)]
        family = self.space
        if family in ("/DeviceGray", "/G") and len(comps) == 1:
            return [instr([comps[0]], "G" if stroke else "g")]
        if family in ("/DeviceRGB", "/RGB") and len(comps) == 3:
            return [instr(comps, "RG" if stroke else "rg")]
        if family in ("/DeviceCMYK", "/CMYK") and len(comps) == 4:
            return [instr(comps, "K" if stroke else "k")]
        r, g, b = self.rgb()
        return [instr([r, g, b], "RG" if stroke else "rg")]


# ---------------------------------------------------------------- state

class GState:
    __slots__ = ("ctm", "fill", "stroke", "line_width", "line_cap", "line_join", "miter", "dash", "intent",
                 "flatness", "gs", "font", "font_name", "font_res", "size", "char_spacing", "word_spacing",
                 "scale", "leading", "render", "rise", "clips")

    def __init__(self):
        self.ctm = IDENTITY
        self.fill = Color()
        self.stroke = Color()
        self.line_width = 1.0
        self.line_cap = None
        self.line_join = None
        self.miter = None
        self.dash = None
        self.intent = None
        self.flatness = None
        self.gs = []           # ExtGState names applied, in order: (name, resources)
        self.font = None       # FontInfo
        self.font_name = None  # resource Name
        self.font_res = None   # resources dict the name resolves in
        self.size = 0.0
        self.char_spacing = 0.0
        self.word_spacing = 0.0
        self.scale = 1.0
        self.leading = 0.0
        self.render = 0
        self.rise = 0.0
        self.clips = []        # [(ctm, [instructions], rule)]

    def copy(self):
        s = GState.__new__(GState)
        for name in GState.__slots__:
            setattr(s, name, getattr(self, name))
        s.fill = self.fill.copy()
        s.stroke = self.stroke.copy()
        s.gs = list(self.gs)
        s.clips = list(self.clips)
        return s


# ---------------------------------------------------------------- records

class Glyph:
    __slots__ = ("id", "code", "nbytes", "text", "quad", "origin", "end", "advance", "size", "font", "font_name",
                 "unit", "render", "fill", "trm", "tm", "ctm", "tfs", "scale", "rise", "char_spacing",
                 "word_spacing", "object", "top_level", "width", "stroke", "font_res", "marked", "op")

    def center(self):
        q = self.quad
        return ((q[0][0] + q[2][0]) / 2, (q[0][1] + q[2][1]) / 2)

    def bbox(self):
        return quad_bbox(self.quad)


class Painted:
    """A path, image, inline image, shading or form invocation."""
    __slots__ = ("id", "kind", "quad", "bbox", "ctm", "unit", "name", "xobject", "state", "top_level",
                 "stream", "start", "end", "has_clip", "paint", "inline", "end_state", "glyphs", "extra")

    def __init__(self, kind):
        self.kind = kind
        self.quad = None
        self.bbox = None
        self.ctm = IDENTITY
        self.unit = None
        self.name = None
        self.xobject = None
        self.state = None
        self.end_state = None
        self.top_level = False
        self.stream = None
        self.start = None
        self.end = None
        self.has_clip = False
        self.paint = None
        self.inline = None
        self.glyphs = None
        self.extra = None


class Plan:
    """Decides what happens to painted content. Subclass and override."""

    def glyph(self, glyph):
        """None (keep), "remove" (keep positions), "drop" (collapse),
        ("text", replacement) or ("codes", bytes)."""
        return None

    def path(self, item):
        """None, "remove", ("exclude", [rects]) or ("wrap", pre, post)."""
        return None

    def image(self, item):
        """None, "remove", ("replace", xobject, matrix|None) or ("wrap", pre, post)."""
        return None

    def form(self, item):
        """None (recurse), "remove", "keep" (do not descend) or ("wrap", pre, post)."""
        return None

    def text_object(self, item):
        """Called at BT for top-level text objects: None, "remove" or ("wrap", pre, post)."""
        return None

    def marked(self, tag, properties, counter):
        """Replacement instruction for a BDC/BMC, or None."""
        return None

    def substitute_font(self, unit, glyph, text):
        """(resource Name, EmbeddedFont) for text the glyph's font cannot encode."""
        return None


# ---------------------------------------------------------------- walker

class Unit:
    """One content stream owner: the page, or one invocation of a form."""

    def __init__(self, walker, resources, path, owner):
        self.walker = walker
        self.resources = resources if isinstance(resources, pikepdf.Dictionary) else pikepdf.Dictionary()
        self.path = path
        self.owner = owner
        self.own_resources = None
        self.added = {}
        self.dropped = set()

    def lookup(self, category, name):
        group = self.resources.get(category)
        if isinstance(group, pikepdf.Dictionary):
            return group.get(name)
        return None


class Walker:
    """Interprets content streams, reporting painted items to a Plan and
    (when `rewrite` is set) producing replacement instruction lists."""

    def __init__(self, pdf, plan=None, rewrite=False, font_cache=None, include_forms=True,
                 exclude_kinds=()):
        self.pdf = pdf
        self.plan = plan or Plan()
        self.plan.walker = self
        self.current_op = None
        self.rewrite = rewrite
        self.fonts = font_cache if font_cache is not None else {}
        self.include_forms = include_forms
        self.exclude_kinds = set(exclude_kinds)
        self.glyphs = []
        self.items = []
        self.text_objects = []
        self.glyph_counter = 0
        self.item_counter = 0
        self.text_counter = 0
        self.marked_counter = 0
        self.form_depth = 0
        self.marked_stack = []
        self.changed_forms = 0
        self.errors = []

    # -------------------------------------------------------------- entry
    def run_page(self, page):
        """Walk every content stream of `page`. Returns replacement stream
        instruction lists (None when a stream is unchanged) when rewriting."""
        obj = page.obj
        from transforms.content import resources as page_resources
        res = obj.get("/Resources")
        if res is None:
            res = page_resources(page)
        contents = obj.get("/Contents")
        streams = [] if contents is None else (list(contents) if isinstance(contents, pikepdf.Array) else [contents])
        unit = Unit(self, res, "page", page)
        self.page_unit = unit
        state = GState()
        stack = []
        outputs = []
        parsed = []
        try:
            for stream in streams:
                parsed.append(pikepdf.parse_content_stream(stream))
            self.joined = False
        except pikepdf.PdfError:
            parsed = [pikepdf.parse_content_stream(page)]
            self.joined = True
        self.parsed = parsed
        self.streams = streams
        text = TextState()
        for index, instructions in enumerate(parsed):
            out = self._run(instructions, unit, state, stack, text, stream_index=index, top_level=True)
            outputs.append(out)
        return streams, parsed, outputs, unit

    # -------------------------------------------------------------- core loop
    def _run(self, instructions, unit, state, stack, text, stream_index=None, top_level=False):
        plan = self.plan
        rewrite = self.rewrite
        out = [] if rewrite else None
        changed = False
        path_ops = []          # instructions of the current path
        path_points = []
        path_start = None
        path_clip = False
        text_item = None
        text_buffer_start = None
        text_action = None
        marked = []            # stack of (index in out, properties changed?)

        def emit(i):
            if out is not None:
                out.append(i)

        for index, ins in enumerate(instructions):
            op = str(ins.operator)
            operands = list(ins.operands)
            # ---------------------------------------------------- path objects
            if op in PATH_OPS:
                if path_start is None:
                    path_start = index
                    path_points = []
                    path_clip = False
                path_ops.append(ins)
                self._path_points(op, operands, state.ctm, path_points)
                continue
            if op in ("W", "W*"):
                if path_start is None:
                    path_start = index
                    path_points = []
                path_ops.append(ins)
                path_clip = op
                continue
            if op in PAINT_OPS:
                item = Painted("path")
                item.paint = op
                item.has_clip = bool(path_clip)
                width = state.line_width * math.sqrt(abs(state.ctm[0] * state.ctm[3] - state.ctm[1] * state.ctm[2]) or 1)
                stroked = op in ("S", "s", "B", "B*", "b", "b*")
                if path_points:
                    x0, y0, x1, y1 = quad_bbox(path_points)
                    pad = width / 2 if stroked else 0
                    item.bbox = (x0 - pad, y0 - pad, x1 + pad, y1 + pad)
                else:
                    item.bbox = None
                item.ctm = state.ctm
                item.unit = unit
                item.top_level = top_level and self.form_depth == 0
                item.stream, item.start, item.end = stream_index, path_start if path_start is not None else index, index
                item.state = state.copy()
                clip_ops = list(path_ops)
                action = None
                if op != "n" and item.bbox is not None:
                    item.id = self.item_counter
                    self.item_counter += 1
                    self.items.append(item)
                    action = plan.path(item)
                if path_clip:
                    state.clips = state.clips + [(state.ctm, clip_ops, path_clip)]
                if rewrite:
                    if action in ("remove", "omit") and not path_clip:
                        changed = True
                    elif action == "remove" and path_clip:
                        # Keep the clip, drop the painting.
                        out.extend(path_ops)
                        emit(instr([], "n"))
                        changed = True
                    elif isinstance(action, tuple) and action[0] == "exclude" and not path_clip:
                        clip = exclusion_clip(action[1], state.ctm, unit.walker.page_box)
                        if clip:
                            out.append(instr([], "q"))
                            out.extend(clip)
                            out.extend(path_ops)
                            emit(ins)
                            out.append(instr([], "Q"))
                            changed = True
                        else:
                            out.extend(path_ops)
                            emit(ins)
                    elif isinstance(action, tuple) and action[0] == "wrap" and not path_clip:
                        out.extend(action[1])
                        out.extend(path_ops)
                        emit(ins)
                        out.extend(action[2])
                        changed = True
                    else:
                        out.extend(path_ops)
                        emit(ins)
                path_ops = []
                path_points = []
                path_start = None
                path_clip = False
                continue
            if path_start is not None:
                # Malformed: a path not ended by a painting operator.
                if rewrite:
                    out.extend(path_ops)
                path_ops, path_points, path_start, path_clip = [], [], None, False

            # ---------------------------------------------------- state
            if op == "q":
                stack.append(state.copy())
                emit(ins)
                continue
            if op == "Q":
                if stack:
                    restored = stack.pop()
                    state.__init__()
                    for name in GState.__slots__:
                        setattr(state, name, getattr(restored, name))
                emit(ins)
                continue
            if op == "cm":
                state.ctm = multiply(matrix_of(operands), state.ctm)
                emit(ins)
                continue
            if op == "w":
                state.line_width = num(operands[0], 1.0) if operands else 1.0
            elif op == "J":
                state.line_cap = operands
            elif op == "j":
                state.line_join = operands
            elif op == "M":
                state.miter = operands
            elif op == "d":
                state.dash = operands
            elif op == "ri":
                state.intent = operands
            elif op == "i":
                state.flatness = operands
            elif op == "gs" and operands:
                state.gs = state.gs + [(operands[0], unit)]
                gs = unit.lookup("/ExtGState", operands[0])
                if isinstance(gs, pikepdf.Dictionary):
                    if "/LW" in gs:
                        state.line_width = num(gs.LW, state.line_width)
                    font = gs.get("/Font")
                    if isinstance(font, pikepdf.Array) and len(font) == 2 and isinstance(font[0], pikepdf.Dictionary):
                        state.font = font_info(self.fonts, font[0])
                        state.size = num(font[1])
            elif op in ("g", "G", "rg", "RG", "k", "K"):
                target = Color({"g": "/DeviceGray", "G": "/DeviceGray", "rg": "/DeviceRGB", "RG": "/DeviceRGB",
                                "k": "/DeviceCMYK", "K": "/DeviceCMYK"}[op], tuple(num(v) for v in operands))
                if op.islower():
                    state.fill = target
                else:
                    state.stroke = target
            elif op in ("cs", "CS") and operands:
                space = operands[0]
                name = str(space)
                obj = None
                if name not in COLOR_SPACE_COMPONENTS and name != "/Pattern":
                    obj = unit.lookup("/ColorSpace", space)
                    family = name
                    if isinstance(obj, pikepdf.Array) and len(obj):
                        family = str(obj[0])
                        if family == "/ICCBased":
                            try:
                                n = int(obj[1].get("/N", 3))
                                family = {1: "/DeviceGray", 3: "/DeviceRGB", 4: "/DeviceCMYK"}.get(n, family)
                            except (AttributeError, TypeError, ValueError):
                                pass
                    elif isinstance(obj, Name):
                        family = str(obj)
                    name = family
                n = COLOR_SPACE_COMPONENTS.get(name, 1)
                default = (1.0,) if name in ("/Separation", "/DeviceN") else (0.0,) * n
                color = Color(name, default if name not in ("/DeviceCMYK", "/CMYK") else (0.0, 0.0, 0.0, 1.0), space)
                if op == "cs":
                    state.fill = color
                else:
                    state.stroke = color
            elif op in ("sc", "scn", "SC", "SCN"):
                target = state.fill if op.islower() else state.stroke
                values = tuple(num(v) if not isinstance(v, Name) else v for v in operands)
                if target.space in ("/Separation", "/DeviceN", "/Indexed", "/Pattern"):
                    # Tint/index/pattern: approximate as black for display purposes.
                    new = Color(target.space, values, target.space_obj)
                else:
                    new = Color(target.space, values, target.space_obj)
                if op.islower():
                    state.fill = new
                else:
                    state.stroke = new
            # ---------------------------------------------------- text state
            elif op == "Tc":
                state.char_spacing = num(operands[0]) if operands else 0.0
            elif op == "Tw":
                state.word_spacing = num(operands[0]) if operands else 0.0
            elif op == "Tz":
                state.scale = num(operands[0], 100.0) / 100 if operands else 1.0
            elif op == "TL":
                state.leading = num(operands[0]) if operands else 0.0
            elif op == "Tr":
                state.render = int(num(operands[0])) if operands else 0
            elif op == "Ts":
                state.rise = num(operands[0]) if operands else 0.0
            elif op == "Tf" and len(operands) >= 2:
                font = unit.lookup("/Font", operands[0])
                state.font = font_info(self.fonts, font) if isinstance(font, pikepdf.Dictionary) else None
                state.font_name = operands[0]
                state.font_res = unit
                state.size = num(operands[1])
            elif op == "BT":
                text.begin()
                if top_level and self.form_depth == 0:
                    text_item = Painted("text")
                    text_item.id = self.text_counter
                    self.text_counter += 1
                    text_item.unit = unit
                    text_item.stream, text_item.start = stream_index, index
                    text_item.state = state.copy()
                    text_item.glyphs = []
                    text_item.top_level = True
                    text_item.ctm = state.ctm
                    self.text_objects.append(text_item)
                    text_action = plan.text_object(text_item)
                    if rewrite and isinstance(text_action, tuple) and text_action[0] == "wrap":
                        out.extend(text_action[1])
                        changed = True
                emit(ins)
                continue
            elif op == "ET":
                emit(ins)
                if text_item is not None:
                    text_item.end = index
                    text_item.end_state = state.copy()
                    if text_item.glyphs:
                        text_item.bbox = union_bbox([self.glyphs[g].bbox() for g in text_item.glyphs])
                    if rewrite and isinstance(text_action, tuple) and text_action[0] == "wrap":
                        out.extend(text_action[2])
                        out.extend(restore_ops(text_item.end_state, text_item.state))
                    text_item = None
                    text_action = None
                continue
            elif op == "Td" and len(operands) >= 2:
                text.move(num(operands[0]), num(operands[1]))
            elif op == "TD" and len(operands) >= 2:
                state.leading = -num(operands[1])
                text.move(num(operands[0]), num(operands[1]))
            elif op == "Tm" and len(operands) >= 6:
                text.set(matrix_of(operands))
            elif op == "T*":
                text.move(0, -state.leading)
            elif op in SHOW_OPS:
                prefix = []
                if op == "'":
                    text.move(0, -state.leading)
                    prefix = [instr([], "T*")]
                    items = [operands[0]] if operands else []
                elif op == '"':
                    if len(operands) >= 3:
                        state.word_spacing = num(operands[0])
                        state.char_spacing = num(operands[1])
                        prefix = [instr([operands[0]], "Tw"), instr([operands[1]], "Tc"), instr([], "T*")]
                        items = [operands[2]]
                    else:
                        items = []
                    text.move(0, -state.leading)
                elif op == "Tj":
                    items = [operands[0]] if operands else []
                else:
                    items = list(operands[0]) if operands and isinstance(operands[0], pikepdf.Array) else []
                remove_all = text_action == "remove"
                self.current_op = (unit.path, id(unit), stream_index, index)
                result = self._show(items, state, text, unit, top_level, text_item, remove_all)
                if rewrite:
                    if result is None:
                        emit(ins)
                    else:
                        out.extend(prefix)
                        out.extend(result)
                        changed = True
                continue
            # ---------------------------------------------------- painting
            elif op == "Do" and operands:
                name = operands[0]
                xobj = unit.lookup("/XObject", name)
                replacement = self._do(ins, name, xobj, state, unit, top_level, stream_index, index)
                if rewrite:
                    if replacement is None:
                        emit(ins)
                    else:
                        out.extend(replacement)
                        changed = True
                continue
            elif op == "INLINE IMAGE":
                replacement = self._inline(ins, state, unit, top_level, stream_index, index)
                if rewrite:
                    if replacement is None:
                        emit(ins)
                    else:
                        out.extend(replacement)
                        changed = True
                continue
            elif op == "sh" and operands:
                item = Painted("shading")
                item.id = self.item_counter
                self.item_counter += 1
                item.ctm = state.ctm
                item.unit = unit
                item.name = operands[0]
                item.bbox = clip_bbox(state) or self.page_box
                item.quad = rect_quad(item.bbox)
                item.state = state.copy()
                item.top_level = top_level and self.form_depth == 0
                item.stream, item.start, item.end = stream_index, index, index
                self.items.append(item)
                action = plan.path(item)
                if rewrite:
                    if action in ("remove", "omit"):
                        changed = True
                    elif isinstance(action, tuple) and action[0] == "exclude":
                        clip = exclusion_clip(action[1], state.ctm, self.page_box)
                        out.append(instr([], "q"))
                        out.extend(clip or [])
                        emit(ins)
                        out.append(instr([], "Q"))
                        changed = True
                    elif isinstance(action, tuple) and action[0] == "wrap":
                        out.extend(action[1])
                        emit(ins)
                        out.extend(action[2])
                        changed = True
                    else:
                        emit(ins)
                continue
            elif op in ("BDC", "BMC"):
                props = operands[1] if op == "BDC" and len(operands) > 1 else None
                if isinstance(props, Name):
                    props = unit.lookup("/Properties", props)
                counter = self.marked_counter
                self.marked_counter += 1
                self.marked_stack.append(counter)
                decision = plan.marked(str(operands[0]) if operands else "", props, counter)
                if rewrite and decision is not None:
                    out.append(decision)
                    changed = True
                else:
                    emit(ins)
                continue
            elif op == "EMC":
                if self.marked_stack:
                    self.marked_stack.pop()
            emit(ins)
        if path_ops and rewrite:
            out.extend(path_ops)
        if rewrite:
            return out if changed else None
        return None

    # -------------------------------------------------------------- paths
    @staticmethod
    def _path_points(op, operands, ctm, points):
        values = [num(v) for v in operands]
        if op == "re" and len(values) == 4:
            x, y, w, h = values
            for px, py in ((x, y), (x + w, y), (x + w, y + h), (x, y + h)):
                points.append(apply(ctm, px, py))
        elif op in ("m", "l") and len(values) == 2:
            points.append(apply(ctm, values[0], values[1]))
        elif op in ("c", "v", "y"):
            for k in range(0, len(values) - 1, 2):
                points.append(apply(ctm, values[k], values[k + 1]))

    # -------------------------------------------------------------- text
    def _show(self, items, state, text, unit, top_level, text_item, remove_all):
        plan = self.plan
        font = state.font
        tfs, th = state.size, state.scale
        pieces = []            # ("s", bytes) | ("n", number) | ("sub", name, font, text)
        changed = remove_all
        for item in items:
            if isinstance(item, pikepdf.String):
                data = bytes(item)
                if font is None:
                    # Unknown font: keep the bytes, advance nothing we can measure.
                    pieces.append(("s", data))
                    continue
                for code, nbytes in font.split(data):
                    raw = code.to_bytes(nbytes, "big")
                    w0 = font.width(code)
                    space = font.is_space(code, nbytes)
                    adv = (w0 * tfs + state.char_spacing + (state.word_spacing if space else 0.0)) * th
                    trm = multiply((tfs * th, 0, 0, tfs, 0, state.rise), multiply(text.tm, state.ctm))
                    g = Glyph()
                    g.id = self.glyph_counter
                    self.glyph_counter += 1
                    g.code, g.nbytes = code, nbytes
                    g.text = font.unicode(code)
                    g.width = w0
                    w_box = w0 if w0 > 0 else 0.5
                    asc, desc = font.ascent, font.descent
                    g.quad = [apply(trm, 0, desc), apply(trm, w_box, desc), apply(trm, w_box, asc), apply(trm, 0, asc)]
                    g.origin = apply(trm, 0, 0)
                    g.end = apply(trm, w0, 0)
                    g.advance = adv
                    g.trm = trm
                    g.tm = text.tm
                    g.ctm = state.ctm
                    g.tfs, g.scale, g.rise = tfs, th, state.rise
                    g.char_spacing, g.word_spacing = state.char_spacing, state.word_spacing
                    g.size = math.hypot(trm[2], trm[3])
                    g.font = font
                    g.font_name = state.font_name
                    g.font_res = state.font_res
                    g.unit = unit
                    g.render = state.render
                    g.fill = state.fill
                    g.stroke = state.stroke
                    g.object = text_item.id if text_item is not None else None
                    g.marked = tuple(self.marked_stack)
                    g.op = self.current_op
                    g.top_level = top_level and self.form_depth == 0
                    self.glyphs.append(g)
                    if text_item is not None:
                        text_item.glyphs.append(g.id)
                    action = "drop" if remove_all else plan.glyph(g)
                    if action is None:
                        pieces.append(("s", raw))
                    else:
                        changed = True
                        if action == "remove":
                            if abs(tfs) > 1e-9:
                                pieces.append(("n", -adv / th * 1000 / tfs if th else 0))
                        elif action == "drop":
                            pass
                        elif isinstance(action, tuple) and action[0] == "codes":
                            pieces.append(("s", action[1]))
                        elif isinstance(action, tuple) and action[0] == "text":
                            replacement = action[1]
                            if replacement:
                                if font.can_encode(replacement):
                                    pieces.append(("s", font.encode(replacement)))
                                else:
                                    sub = plan.substitute_font(unit, g, replacement)
                                    if sub is not None:
                                        pieces.append(("sub", sub[0], sub[1], replacement))
                    text.advance(adv)
            else:
                n = num(item)
                pieces.append(("n", n))
                text.advance(-n / 1000 * tfs * th)
        if not self.rewrite or not changed:
            return None
        return emit_pieces(pieces, state)

    # -------------------------------------------------------------- xobjects
    def _do(self, ins, name, xobj, state, unit, top_level, stream_index, index):
        plan = self.plan
        if not isinstance(xobj, pikepdf.Stream):
            return None
        subtype = str(xobj.get("/Subtype", ""))
        if subtype == "/Image":
            item = Painted("image")
            item.id = self.item_counter
            self.item_counter += 1
            item.ctm = state.ctm
            item.quad = [apply(state.ctm, 0, 0), apply(state.ctm, 1, 0), apply(state.ctm, 1, 1), apply(state.ctm, 0, 1)]
            item.bbox = quad_bbox(item.quad)
            item.unit = unit
            item.name = name
            item.xobject = xobj
            item.state = state.copy()
            item.top_level = top_level and self.form_depth == 0
            item.stream, item.start, item.end = stream_index, index, index
            self.items.append(item)
            action = plan.image(item)
            if not self.rewrite or action is None:
                return None
            if action == "remove":
                self.own(unit)
                unit.dropped.add(str(name))
                return []
            if action == "omit":
                return []
            if action[0] == "replace":
                new_name = self._add_resource(unit, "/XObject", action[1], str(name).lstrip("/") + "r")
                unit.dropped.add(str(name))
                if action[2] is not None:
                    return [instr([], "q"), instr(action[2], "cm"), instr([new_name], "Do"), instr([], "Q")]
                return [instr([new_name], "Do")]
            if action[0] == "wrap":
                return list(action[1]) + [ins] + list(action[2])
            return None
        if subtype != "/Form":
            return None
        kind = str(xobj.get("/ZPDFKind", "")).lstrip("/")
        item = Painted("form")
        item.id = self.item_counter
        self.item_counter += 1
        matrix = matrix_of(xobj.get("/Matrix", IDENTITY))
        ctm = multiply(matrix, state.ctm)
        bbox = xobj.get("/BBox")
        box = tuple(num(v) for v in bbox) if isinstance(bbox, pikepdf.Array) and len(bbox) == 4 else (0, 0, 0, 0)
        item.quad = [apply(ctm, box[0], box[1]), apply(ctm, box[2], box[1]), apply(ctm, box[2], box[3]), apply(ctm, box[0], box[3])]
        item.bbox = quad_bbox(item.quad)
        item.ctm = state.ctm
        item.unit = unit
        item.name = name
        item.xobject = xobj
        item.state = state.copy()
        item.extra = kind
        item.top_level = top_level and self.form_depth == 0
        item.stream, item.start, item.end = stream_index, index, index
        self.items.append(item)
        action = plan.form(item) if kind not in self.exclude_kinds else "keep"
        if action == "remove":
            if self.rewrite:
                self.own(unit)
                unit.dropped.add(str(name))
                return []
            return None
        if action == "omit":
            return [] if self.rewrite else None
        if isinstance(action, tuple) and action[0] == "wrap":
            return (list(action[1]) + [ins] + list(action[2])) if self.rewrite else None
        if action == "keep" or not self.include_forms or self.form_depth > 12:
            return None
        # Descend.
        key = (xobj.objgen if xobj.is_indirect else id(xobj))
        res = xobj.get("/Resources")
        form_unit = Unit(self, res if isinstance(res, pikepdf.Dictionary) else unit.resources,
                         unit.path + f"/{str(name)}", xobj)
        form_unit.inherited = not isinstance(res, pikepdf.Dictionary)
        try:
            instructions = pikepdf.parse_content_stream(xobj)
        except pikepdf.PdfError:
            return None
        inner = state.copy()
        inner.ctm = ctm
        box_clip = [instr([box[0], box[1], box[2] - box[0], box[3] - box[1]], "re"), instr([], "W"), instr([], "n")]
        inner.clips = inner.clips + [(ctm, box_clip[:1], "W")]
        self.form_depth += 1
        try:
            out = self._run(instructions, form_unit, inner, [], TextState(), None, top_level=False)
        finally:
            self.form_depth -= 1
        if not self.rewrite or out is None:
            return None
        copy = self._copy_form(xobj, out, form_unit)
        prefix = str(name).lstrip("/")
        new_name = self._add_resource(unit, "/XObject", copy, prefix + "r")
        unit.dropped.add(str(name))
        self.changed_forms += 1
        return [instr([new_name], "Do")]

    def _copy_form(self, xobj, instructions, form_unit):
        data = pikepdf.unparse_content_stream(instructions)
        copy = pikepdf.Stream(self.pdf, data)
        for key, value in xobj.items():
            if key in ("/Length", "/Filter", "/DecodeParms", "/Resources"):
                continue
            copy[key] = value
        res = form_unit.own_resources if form_unit.own_resources is not None else xobj.get("/Resources")
        if form_unit.own_resources is not None:
            prune_resources(form_unit, [instructions])
        if res is not None:
            copy.Resources = res
        return self.pdf.make_indirect(copy)

    def _inline(self, ins, state, unit, top_level, stream_index, index):
        item = Painted("inline_image")
        item.id = self.item_counter
        self.item_counter += 1
        item.ctm = state.ctm
        item.quad = [apply(state.ctm, 0, 0), apply(state.ctm, 1, 0), apply(state.ctm, 1, 1), apply(state.ctm, 0, 1)]
        item.bbox = quad_bbox(item.quad)
        item.unit = unit
        item.inline = ins
        item.state = state.copy()
        item.top_level = top_level and self.form_depth == 0
        item.stream, item.start, item.end = stream_index, index, index
        self.items.append(item)
        action = self.plan.image(item)
        if not self.rewrite or action is None:
            return None
        if action in ("remove", "omit"):
            return []
        if action[0] == "replace":
            new_name = self._add_resource(unit, "/XObject", action[1], "ZPDFim")
            if action[2] is not None:
                return [instr([], "q"), instr(action[2], "cm"), instr([new_name], "Do"), instr([], "Q")]
            return [instr([new_name], "Do")]
        if action[0] == "wrap":
            return list(action[1]) + [ins] + list(action[2])
        return None

    # -------------------------------------------------------------- resources
    def own(self, unit):
        """Give `unit` private resource dictionaries it may edit."""
        if unit.own_resources is None:
            copy = pikepdf.Dictionary()
            for key, value in unit.resources.items():
                if key in ("/XObject", "/Font", "/ColorSpace", "/ExtGState") and isinstance(value, pikepdf.Dictionary):
                    copy[key] = pikepdf.Dictionary({k: v for k, v in value.items()})
                else:
                    copy[key] = value
            unit.own_resources = copy
            unit.resources = copy
        return unit.own_resources

    def _add_resource(self, unit, category, obj, prefix):
        res = self.own(unit)
        if category not in res:
            res[category] = pikepdf.Dictionary()
        group = res[category]
        prefix = "".join(ch for ch in prefix if ch.isalnum() or ch in "_.-")[:40] or "R"
        n = 1
        while Name(f"/{prefix}{n}") in group:
            n += 1
        name = Name(f"/{prefix}{n}")
        group[name] = obj
        unit.added[str(name)] = category
        return name

    def add_font(self, unit, font_obj, prefix="ZPDFf"):
        return self._add_resource(unit, "/Font", font_obj, prefix)


class TextState:
    __slots__ = ("tm", "tlm")

    def __init__(self):
        self.tm = IDENTITY
        self.tlm = IDENTITY

    def begin(self):
        self.tm = IDENTITY
        self.tlm = IDENTITY

    def move(self, tx, ty):
        self.tlm = multiply((1, 0, 0, 1, tx, ty), self.tlm)
        self.tm = self.tlm

    def set(self, m):
        self.tm = m
        self.tlm = m

    def advance(self, tx):
        self.tm = multiply((1, 0, 0, 1, tx, 0), self.tm)


# ---------------------------------------------------------------- emission helpers

def emit_pieces(pieces, state):
    """Rebuild show operators from kept strings, displacements and
    substituted-font runs, restoring the original font afterwards."""
    out = []
    array = []

    def flush():
        nonlocal array
        # Merge adjacent numbers and strings.
        merged = []
        for kind, value in array:
            if merged and merged[-1][0] == kind == "n":
                merged[-1] = ("n", merged[-1][1] + value)
            elif merged and merged[-1][0] == kind == "s":
                merged[-1] = ("s", merged[-1][1] + value)
            else:
                merged.append((kind, value))
        merged = [(k, v) for k, v in merged if not (k == "n" and abs(v) < 1e-6)]
        if merged:
            if len(merged) == 1 and merged[0][0] == "s":
                out.append(instr([pikepdf.String(merged[0][1])], "Tj"))
            else:
                values = [pikepdf.String(v) if k == "s" else round(v, 4) for k, v in merged]
                out.append(instr([pikepdf.Array(values)], "TJ"))
        array = []

    for piece in pieces:
        if piece[0] in ("s", "n"):
            array.append(piece)
        else:
            flush()
            _, name, font, text = piece
            out.append(instr([name, state.size], "Tf"))
            out.append(pikepdf.ContentStreamInstruction([pikepdf.String(bytes.fromhex(font.encode(text)[1:-1]))],
                                                        Operator("Tj")))
            if state.font_name is not None:
                out.append(instr([state.font_name, state.size], "Tf"))
    flush()
    return out


def restore_ops(end_state, start_state):
    """Re-establish state an object changed, after its enclosing q/Q."""
    out = []
    s = end_state
    if s.font_name is not None:
        out.append(instr([s.font_name, s.size], "Tf"))
    out.append(instr([s.char_spacing], "Tc"))
    out.append(instr([s.word_spacing], "Tw"))
    out.append(instr([s.scale * 100], "Tz"))
    out.append(instr([s.leading], "TL"))
    out.append(instr([s.render], "Tr"))
    out.append(instr([s.rise], "Ts"))
    out.extend(color_state_ops(s))
    return out


def color_state_ops(s):
    out = []
    for color, stroke in ((s.fill, False), (s.stroke, True)):
        if color.space in COLOR_SPACE_COMPONENTS or color.space_obj is None:
            out.extend(color.ops(stroke))
        else:
            out.append(instr([color.space_obj], "CS" if stroke else "cs"))
            if color.components:
                out.append(instr(list(color.components), "SCN" if stroke else "scn"))
    return out


def full_state_ops(s):
    """Operators recreating state `s` from the default state (for moving an
    object to another place in the page): clips, CTM, gstate, text state."""
    out = []
    current = IDENTITY
    for ctm, ops, rule in s.clips:
        inv = safe_invert(current)
        if inv is None:
            continue
        m = multiply(ctm, inv)
        out.append(instr(list(m), "cm"))
        current = ctm
        out.extend(ops)
        out.append(instr([], rule))
        out.append(instr([], "n"))
    inv = safe_invert(current)
    if inv is not None:
        m = multiply(s.ctm, inv)
        if any(abs(a - b) > 1e-9 for a, b in zip(m, IDENTITY)):
            out.append(instr(list(m), "cm"))
    for name, _ in s.gs:
        out.append(instr([name], "gs"))
    out.append(instr([s.line_width], "w"))
    for value, op in ((s.line_cap, "J"), (s.line_join, "j"), (s.miter, "M"), (s.dash, "d"), (s.intent, "ri"),
                      (s.flatness, "i")):
        if value is not None:
            out.append(instr(value, op))
    out.extend(restore_ops(s, s))
    return out


def rect_quad(r):
    return [(r[0], r[1]), (r[2], r[1]), (r[2], r[3]), (r[0], r[3])]


def union_bbox(boxes):
    boxes = [b for b in boxes if b is not None]
    if not boxes:
        return None
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def clip_bbox(state):
    box = None
    for ctm, ops, _ in state.clips:
        points = []
        for ins in ops:
            Walker._path_points(str(ins.operator), list(ins.operands), ctm, points)
        if points:
            b = quad_bbox(points)
            box = b if box is None else (max(box[0], b[0]), max(box[1], b[1]), min(box[2], b[2]), min(box[3], b[3]))
    return box


def exclusion_clip(rects, ctm, page_box):
    """Clip operators (under `ctm`) that keep everything except `rects`."""
    inv = safe_invert(ctm)
    if inv is None:
        return None
    x0, y0, x1, y1 = page_box
    pad = max(x1 - x0, y1 - y0)
    outer = [(x0 - pad, y0 - pad), (x1 + pad, y0 - pad), (x1 + pad, y1 + pad), (x0 - pad, y1 + pad)]
    ops = []
    for poly in [outer] + [rect_quad(r) for r in rects]:
        pts = [apply(inv, x, y) for x, y in poly]
        ops.append(instr([round(pts[0][0], 4), round(pts[0][1], 4)], "m"))
        for x, y in pts[1:]:
            ops.append(instr([round(x, 4), round(y, 4)], "l"))
        ops.append(instr([], "h"))
    ops.append(instr([], "W*"))
    ops.append(instr([], "n"))
    return ops


def prune_resources(unit, instruction_lists):
    """Drop replaced XObject names no longer used by the unit's streams."""
    if unit.own_resources is None or not unit.dropped:
        return
    used = set()
    for instructions in instruction_lists:
        for ins in instructions:
            if str(ins.operator) == "Do" and ins.operands:
                used.add(str(ins.operands[0]))
    group = unit.own_resources.get("/XObject")
    if not isinstance(group, pikepdf.Dictionary):
        return
    for name in list(unit.dropped):
        if name not in used and Name(name) in group:
            del group[Name(name)]


# ---------------------------------------------------------------- page driver

def page_box(page):
    from transforms.content import page_box as box
    return box(page, "/MediaBox")


def walk_page(pdf, page, plan=None, font_cache=None, include_forms=True, exclude_kinds=()):
    """Read-only walk. Returns the Walker with glyphs/items populated."""
    walker = Walker(pdf, plan, rewrite=False, font_cache=font_cache, include_forms=include_forms,
                    exclude_kinds=exclude_kinds)
    walker.page_box = page_box(page)
    walker.run_page(page)
    return walker


def rewrite_page(pdf, page, plan, font_cache=None, include_forms=True, exclude_kinds=(), extra_streams=()):
    """Rewrite `page` according to `plan`. Returns the Walker (with counts)
    and whether anything changed."""
    walker = Walker(pdf, plan, rewrite=True, font_cache=font_cache, include_forms=include_forms,
                    exclude_kinds=exclude_kinds)
    walker.page_box = page_box(page)
    streams, parsed, outputs, unit = walker.run_page(page)
    changed = any(out is not None for out in outputs) or unit.own_resources is not None
    if not changed:
        return walker, False
    final = [out if out is not None else parsed[i] for i, out in enumerate(outputs)]
    if walker.joined:
        page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, pikepdf.unparse_content_stream(final[0])))
    else:
        new_streams = []
        for i, stream in enumerate(streams):
            if outputs[i] is None:
                new_streams.append(stream)
            else:
                new_streams.append(pdf.make_indirect(pikepdf.Stream(pdf, pikepdf.unparse_content_stream(outputs[i]))))
        page.obj.Contents = pikepdf.Array(new_streams) if len(new_streams) != 1 or isinstance(
            page.obj.get("/Contents"), pikepdf.Array) else new_streams[0]
    if unit.own_resources is not None:
        prune_resources(unit, final)
        page.obj.Resources = unit.own_resources
    return walker, True


# ---------------------------------------------------------------- hidden text (sanitize hook)

class _HiddenText(Plan):
    def __init__(self, crop):
        self.crop = crop
        self.count = 0

    def glyph(self, glyph):
        hidden = glyph.render in (3, 7)
        if not hidden:
            box = glyph.bbox()
            c = self.crop
            hidden = box[2] < c[0] or box[0] > c[2] or box[3] < c[1] or box[1] > c[3]
        if hidden:
            self.count += 1
            return "remove"
        return None


def count_hidden_text(ctx):
    from transforms.content import page_box as box
    cache = {}
    total = 0
    for page in ctx.pdf.pages:
        plan = _HiddenText(box(page))
        walk_page(ctx.pdf, page, plan, cache)
        total += plan.count
    return total


def remove_hidden_text(ctx):
    """Remove invisible (render mode 3/7) glyphs and glyphs outside the crop box."""
    from transforms.content import page_box as box
    cache = {}
    total = 0
    for page in ctx.pdf.pages:
        plan = _HiddenText(box(page))
        walk_page(ctx.pdf, page, plan, cache)
        if plan.count:
            plan = _HiddenText(box(page))
            rewrite_page(ctx.pdf, page, plan, cache)
            total += plan.count
    return total
