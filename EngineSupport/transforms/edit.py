"""Editing page content: text blocks, text boxes, images and vector objects,
find and replace.

Text blocks are paragraphs reconstructed from the interpreter's glyphs
(lines by baseline/advance continuity, paragraphs by spacing and overlap).
Editing a block removes exactly its glyphs (other text keeps its position)
and draws the replacement in a new content stream:
  * with `runs` (text + style), the text is laid out and wrapped to the block
    width; runs that keep the original font are written in that font when it
    can encode them, otherwise in the matching system font (reported as
    substituted);
  * without `runs` (move / resize / rotate), the original glyphs are written
    again unchanged, reflowed word by word to the new width.
Objects (images, paths, shadings, forms) are addressed by the stream and
instruction range reported by `page_content`, guarded by a content digest.
"""
import math
import re
from pathlib import Path

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require
from transforms import op, query
from transforms.content import (add_content, add_resource, fmt, image_xobject, multiply, apply, invert, page_box,
                                resources, rotation, visual_matrix, select_pages, INVOCATION)
from transforms.fonts import EmbeddedFont, STYLE_FONTS
from transforms.interpret import (Plan, walk_page, rewrite_page, page_digest, quad_bbox, safe_invert, instr,
                                  full_state_ops, num, IDENTITY)

OVERLAY_KINDS = ("Watermark", "HeaderFooter", "Background", "Bates")


# ---------------------------------------------------------------- geometry helpers

def unit_vec(x, y):
    n = math.hypot(x, y)
    return (x / n, y / n) if n > 1e-12 else (1.0, 0.0)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def rgb255(color):
    if color is None:
        return (0.0, 0.0, 0.0)
    values = [float(v) for v in color][:3]
    if any(v > 1 for v in values):
        values = [v / 255 for v in values]
    while len(values) < 3:
        values.append(values[-1] if values else 0.0)
    return tuple(max(0.0, min(1.0, v)) for v in values)


# ---------------------------------------------------------------- blocks

class Line:
    def __init__(self, glyph):
        trm = glyph.trm
        self.u = unit_vec(trm[0], trm[1])
        self.v = unit_vec(trm[2], trm[3])
        self.origin = glyph.origin
        self.size = glyph.size
        self.glyphs = []
        self.x0 = 0.0
        self.x1 = 0.0
        self.add(glyph)

    def local_x(self, glyph):
        return dot(sub(glyph.origin, self.origin), self.u)

    def add(self, glyph):
        x = self.local_x(glyph)
        width = dot(sub(glyph.end, glyph.origin), self.u)
        if not self.glyphs:
            self.x0, self.x1 = x, x + width
        else:
            self.x0 = min(self.x0, x)
            self.x1 = max(self.x1, x + width)
        self.glyphs.append(glyph)
        self.size = max(self.size, glyph.size) if glyph.text.strip() else self.size

    def accepts(self, glyph):
        trm = glyph.trm
        u = unit_vec(trm[0], trm[1])
        v = unit_vec(trm[2], trm[3])
        if dot(u, self.u) < 0.995 or dot(v, self.v) < 0.95:
            return False
        s = max(self.size, glyph.size)
        if abs(dot(sub(glyph.origin, self.origin), self.v)) > 0.3 * s:
            return False
        ratio = glyph.size / self.size if self.size else 1
        if not 0.5 <= ratio <= 2.0:
            return False
        x = self.local_x(glyph)
        return self.x1 - 0.35 * s <= x <= self.x1 + 1.1 * s

    def ordered(self):
        return sorted(self.glyphs, key=lambda g: (self.local_x(g), g.id))

    def text(self):
        out = []
        prev = None
        for g in self.ordered():
            if prev is not None and g.text.strip() and prev.text.strip():
                gap = self.local_x(g) - (self.local_x(prev) + dot(sub(prev.end, prev.origin), self.u))
                if gap > 0.22 * self.size:
                    out.append(" ")
            out.append(g.text or "�")
            prev = g
        return "".join(out)

    @property
    def y(self):
        return dot(self.origin, self.v)


def build_lines(glyphs):
    lines = []
    for g in glyphs:
        if g.render in (3, 7) or g.size < 0.5:
            continue
        if not g.text.strip():
            # Spaces join a line in progress but never start one.
            for line in reversed(lines[-4:]):
                if line.accepts(g):
                    line.add(g)
                    break
            continue
        placed = False
        for line in reversed(lines[-40:]):
            if line.accepts(g):
                line.add(g)
                placed = True
                break
        if not placed:
            lines.append(Line(g))
    for line in lines:
        # Strip trailing spaces from the extent.
        pass
    return lines


class Block:
    def __init__(self, line):
        self.lines = [line]
        self.u, self.v = line.u, line.v
        self.spacing = None

    def gx(self, line):
        """Line extent in the block's u coordinate (absolute)."""
        base = dot(line.origin, self.u)
        return base + line.x0, base + line.x1

    def accepts(self, line):
        last = self.lines[-1]
        if dot(line.u, self.u) < 0.995 or dot(line.v, self.v) < 0.95:
            return None
        d = last.y - line.y
        s = max(last.size, line.size)
        ratio = line.size / last.size if last.size else 1
        if not 0.8 <= ratio <= 1.25:
            return None
        if not 0.8 * s <= d <= 1.9 * s:
            return None
        if self.spacing is not None and abs(d - self.spacing) > 0.25 * s:
            return None
        a0, a1 = self.gx(last)
        b0, b1 = self.gx(line)
        overlap = min(a1, b1) - max(a0, b0)
        if overlap < 0.4 * min(a1 - a0, b1 - b0) and abs(a0 - b0) > s:
            return None
        return d


def build_blocks(glyphs):
    lines = build_lines(glyphs)
    groups = {}
    for line in lines:
        key = (round(math.degrees(math.atan2(line.u[1], line.u[0]))), dot(line.v, (-line.u[1], line.u[0])) > 0)
        groups.setdefault(key, []).append(line)
    blocks = []
    for key, members in groups.items():
        members.sort(key=lambda l: (-l.y, dot(l.origin, l.u) + l.x0))
        open_blocks = []
        for line in members:
            best, best_d = None, None
            for block in open_blocks:
                d = block.accepts(line)
                if d is not None and (best_d is None or d < best_d):
                    best, best_d = block, d
            if best is not None:
                if best.spacing is None:
                    best.spacing = best_d
                best.lines.append(line)
            else:
                block = Block(line)
                open_blocks.append(block)
                blocks.append(block)
            # Blocks far above can no longer grow.
            open_blocks = [b for b in open_blocks if b.lines[-1].y - line.y < 3 * line.size]
    blocks.sort(key=lambda b: (-dot(b.lines[0].origin, (0, 1)), dot(b.lines[0].origin, (1, 0))))
    return blocks


def _join_lines(texts):
    out = ""
    for i, t in enumerate(texts):
        t = t.strip()
        if i == 0:
            out = t
        elif out.endswith("-") and t[:1].islower() and len(out) > 1 and out[-2].isalpha():
            out = out[:-1] + t
        else:
            out = out + " " + t
    return out


def describe_block(block, index):
    first = block.lines[0]
    u, v = block.u, block.v
    base_u = min(dot(l.origin, u) + l.x0 for l in block.lines)
    right_u = max(dot(l.origin, u) + l.x1 for l in block.lines)
    base_v = first.y
    origin = (u[0] * base_u + v[0] * base_v, u[1] * base_u + v[1] * base_v)
    frame = (u[0], u[1], v[0], v[1], origin[0], origin[1])
    glyphs = [g for line in block.lines for g in line.ordered()]
    ascent = max(g.font.ascent * g.size for g in glyphs if g.font) if glyphs else first.size * 0.8
    last = block.lines[-1]
    descent = min(g.font.descent * g.size for g in last.glyphs if g.font) if last.glyphs else -first.size * 0.2
    bottom = (last.y - base_v) + descent
    width = right_u - base_u
    quad = [apply(frame, 0, bottom), apply(frame, width, bottom), apply(frame, width, ascent), apply(frame, 0, ascent)]
    sizes = sorted(g.size for g in glyphs if g.text.strip())
    size = sizes[len(sizes) // 2] if sizes else first.size
    # Alignment from line extents.
    lefts = [dot(l.origin, u) + l.x0 - base_u for l in block.lines]
    rights = [right_u - (dot(l.origin, u) + l.x1) for l in block.lines]
    align = "left"
    if len(block.lines) > 1:
        tol = size * 0.6
        body = block.lines[:-1]
        if all(abs(r) < tol for r in rights) and all(abs(lf) < tol for lf in lefts[:-1]) and len(block.lines) > 2:
            align = "justify"
        elif all(abs(r) < tol for r in rights) and any(lf > tol for lf in lefts):
            align = "right"
        elif any(lf > tol for lf in lefts) and all(abs(lf - r) < tol for lf, r in zip(lefts, rights)):
            align = "center"
    spacing = (block.spacing / size) if block.spacing and size else 1.2
    runs = []
    for li, line in enumerate(block.lines):
        prev = None
        for g in line.ordered():
            piece = ""
            if prev is not None and g.text.strip() and prev.text.strip():
                gap = line.local_x(g) - (line.local_x(prev) + dot(sub(prev.end, prev.origin), line.u))
                if gap > 0.22 * line.size:
                    piece = " "
            piece += g.text or ""
            prev = g
            style = g.font.style() if g.font else {"base": "Unknown", "family": "Helvetica", "bold": False,
                                                     "italic": False, "mono": False, "serif": False}
            color = [round(c, 3) for c in g.fill.rgb()] if g.fill else [0, 0, 0]
            key = (g.font.key if g.font else "", round(g.size, 1), tuple(color))
            if runs and runs[-1]["_key"] == key:
                runs[-1]["text"] += piece
            else:
                runs.append({"_key": key, "text": piece, "font": g.font.key if g.font else "",
                             "style": style, "size": round(g.size, 2), "color": color})
        if li < len(block.lines) - 1 and runs:
            text = runs[-1]["text"]
            nxt = block.lines[li + 1].text().strip()
            if text.endswith("-") and nxt[:1].islower() and len(text) > 1 and text[-2].isalpha():
                runs[-1]["text"] = text[:-1]
            else:
                runs[-1]["text"] = text.rstrip() + " "
    for r in runs:
        del r["_key"]
    text = _join_lines([l.text() for l in block.lines])
    editable = all(g.text for g in glyphs)
    dominant = max(runs, key=lambda r: len(r["text"])) if runs else None
    return {
        "id": index, "text": text, "lines": [l.text() for l in block.lines], "runs": runs,
        "frame": [round(v, 5) for v in frame], "width": round(width, 3), "ascent": round(ascent, 3),
        "bottom": round(bottom, 3), "quad": [[round(x, 3), round(y, 3)] for x, y in quad],
        "bbox": [round(v, 3) for v in quad_bbox(quad)], "size": round(size, 2), "align": align,
        "line_spacing": round(spacing, 3), "editable": editable,
        "font": dominant["style"] if dominant else None, "color": dominant["color"] if dominant else [0, 0, 0],
        "_glyphs": [g.id for g in glyphs],
    }


def page_walk(pdf, index, cache=None):
    page = pdf.pages[index]
    walker = walk_page(pdf, page, None, cache if cache is not None else {}, exclude_kinds=OVERLAY_KINDS)
    return page, walker


def object_id(item):
    return f"{item.kind}:{item.stream}:{item.start}:{item.end}"


def describe_objects(walker, limit=4000):
    out = []
    for item in walker.items:
        if not item.top_level or item.bbox is None:
            continue
        if item.kind == "form" and item.extra in OVERLAY_KINDS:
            continue
        if item.kind == "path" and item.paint == "n":
            continue
        x0, y0, x1, y1 = item.bbox
        if x1 - x0 < 0.2 and y1 - y0 < 0.2:
            continue
        entry = {"id": object_id(item), "kind": item.kind, "bbox": [round(v, 3) for v in item.bbox]}
        if item.quad:
            entry["quad"] = [[round(x, 3), round(y, 3)] for x, y in item.quad]
        if item.kind in ("image", "inline_image"):
            xobj = item.xobject
            if xobj is not None:
                entry["pixels"] = [int(num(xobj.get("/Width", 0))), int(num(xobj.get("/Height", 0)))]
            entry["matrix"] = [round(v, 5) for v in item.ctm]
        entry["movable"] = not item.has_clip
        out.append(entry)
        if len(out) >= limit:
            break
    return out


@query("page_content")
def page_content(ctx, pages=None):
    """Text blocks and editable objects of `pages` (default: all)."""
    pdf = ctx.pdf
    targets = select_pages(pdf, pages)
    cache = {}
    result = []
    for index in targets:
        page, walker = page_walk(pdf, index, cache)
        blocks = [describe_block(b, i) for i, b in enumerate(build_blocks(walker.glyphs))]
        for b in blocks:
            del b["_glyphs"]
        result.append({"page": index, "digest": page_digest(page), "rotation": rotation(page),
                       "crop": list(page_box(page)), "blocks": blocks, "objects": describe_objects(walker)})
    return {"pages": result}


@query("document_fonts")
def document_fonts(ctx):
    """Distinct fonts used by page text: base name and style."""
    cache = {}
    seen = {}
    for index in range(len(ctx.pdf.pages)):
        _, walker = page_walk(ctx.pdf, index, cache)
        for g in walker.glyphs:
            if g.font is not None and g.font.base_font not in seen:
                seen[g.font.base_font] = g.font.style()
    return {"fonts": list(seen.values())}


# ---------------------------------------------------------------- fonts for new text

def resolve_font_spec(spec):
    """{"path", "postscript"?, "index"?} | {"family", "bold", "italic"} -> EmbeddedFont spec."""
    if not isinstance(spec, dict):
        return None
    path = spec.get("path")
    if path:
        if not Path(path).exists():
            return None
        index = int(spec.get("index", 0))
        postscript = spec.get("postscript")
        if postscript and str(path).lower().endswith((".ttc", ".otc")):
            try:
                from fontTools.ttLib import TTCollection
                collection = TTCollection(path, lazy=True)
                for i, font in enumerate(collection.fonts):
                    if font["name"].getDebugName(6) == postscript:
                        index = i
                        break
                collection.close()
            except Exception:
                pass
        return {"path": path, "index": index}
    family = spec.get("family", "sans")
    if family not in ("sans", "serif", "mono"):
        family = "serif" if spec.get("serif") else ("mono" if spec.get("mono") else "sans")
    return {"family": family, "bold": bool(spec.get("bold")), "italic": bool(spec.get("italic"))}


def style_spec(style):
    style = style or {}
    family = "mono" if style.get("mono") else ("serif" if style.get("serif") else "sans")
    return {"family": family, "bold": bool(style.get("bold")), "italic": bool(style.get("italic"))}


class FontPool:
    """EmbeddedFonts (one per face) and original fonts used by new text."""

    def __init__(self, pdf, page):
        self.pdf = pdf
        self.page = page
        self.embedded = {}
        self.names = {}
        self.substituted = []

    def embedded_font(self, spec):
        resolved = resolve_font_spec(spec) or {"family": "sans"}
        key = repr(sorted(resolved.items()))
        if key not in self.embedded:
            try:
                self.embedded[key] = EmbeddedFont(self.pdf, resolved)
            except Exception:
                self.embedded[key] = EmbeddedFont(self.pdf, {"family": resolved.get("family", "sans")
                                                              if resolved.get("family") in ("sans", "serif", "mono") else "sans",
                                                              "bold": resolved.get("bold", False),
                                                              "italic": resolved.get("italic", False)})
        return self.embedded[key]

    def fallback(self):
        """A broad-coverage face for characters the chosen font lacks."""
        key = "fallback"
        if key not in self.embedded:
            self.embedded[key] = EmbeddedFont(self.pdf, None)
        return self.embedded[key]

    def name_for(self, font_obj, prefix):
        key = font_obj.objgen if font_obj.is_indirect else id(font_obj)
        if key not in self.names:
            self.names[key] = add_resource(self.page, "Font", font_obj, prefix)
        return self.names[key]

    def finish(self):
        for font in self.embedded.values():
            if font.used:
                font.finish()


class Face:
    """A font usable for layout: either an original FontInfo or an EmbeddedFont."""

    def __init__(self, pool, info=None, embedded=None):
        self.pool = pool
        self.info = info
        self.embedded = embedded

    def width(self, text, size):
        if self.embedded is not None:
            return self.embedded.width(text, size)
        return sum(self.info.width(code) for code, _ in self.info.split(self.info.encode(text))) * size

    def operand(self, text):
        if self.embedded is not None:
            return self.embedded.encode(text)
        data = self.info.encode(text)
        return "<" + data.hex().upper() + ">"

    def resource(self):
        if self.embedded is not None:
            return self.pool.name_for(self.embedded.ref, "ZPDFe")
        return self.pool.name_for(self.info.obj, "ZPDFo")

    @property
    def ascent(self):
        return self.embedded.ascent if self.embedded is not None else self.info.ascent

    @property
    def descent(self):
        return self.embedded.descent if self.embedded is not None else self.info.descent


def face_for_run(pool, run, fonts_by_key, text):
    font = run.get("font") or {}
    if isinstance(font, dict) and font.get("original"):
        info = fonts_by_key.get(font["original"])
        if info is not None and info.can_encode(text.replace("\n", "")):
            return Face(pool, info=info)
        if info is not None:
            pool.substituted.append(info.base_font)
        fallback = font.get("fallback") or (style_spec(info.style()) if info is not None else {"family": "sans"})
        return Face(pool, embedded=pool.embedded_font(fallback))
    return Face(pool, embedded=pool.embedded_font(font if isinstance(font, dict) else {}))


# ---------------------------------------------------------------- layout

def layout_runs(pool, runs, fonts_by_key, width, align, line_spacing):
    """Returns (lines, height) where lines = [(baseline_y, [(x, face, size, color, text)])]."""
    tokens = []  # (text, face, size, color)
    for run in runs:
        text = str(run.get("text", ""))
        if not text:
            continue
        size = float(run.get("size") or 12)
        require(0.5 <= size <= 1000, "INVALID_ARGUMENT", "Choose a text size between 1 and 1000 points.")
        color = rgb255(run.get("color"))
        face = face_for_run(pool, run, fonts_by_key, text)
        for piece in re.findall(r"\n|[ \t]+|[^ \t\n]+", text):
            if face.embedded is not None and piece.strip() and not face.embedded.has_glyphs(piece):
                # Split into covered / uncovered characters.
                fallback = Face(pool, embedded=pool.fallback())
                chunk, chunk_face = "", None
                for ch in piece:
                    f = face if face.embedded.has_glyphs(ch) else fallback
                    if chunk_face is not None and f is not chunk_face:
                        tokens.append((chunk, chunk_face, size, color, True))
                        chunk = ""
                    chunk += ch
                    chunk_face = f
                if chunk:
                    tokens.append((chunk, chunk_face, size, color, False))
                continue
            tokens.append((piece, face, size, color, False))
    lines = [[]]
    widths = [0.0]
    hard = [False]
    glued = False
    for piece, face, size, color, glue_next in tokens:
        if piece == "\n":
            hard[-1] = True
            lines.append([])
            widths.append(0.0)
            hard.append(False)
            continue
        w = face.width(piece.replace("\t", "    "), size)
        is_space = not piece.strip()
        continuing = glued
        glued = glue_next
        if width and not is_space and not continuing and widths[-1] + w > width + 0.01 and any(t[0].strip() for t in lines[-1]):
            # Wrap: drop trailing spaces.
            while lines[-1] and not lines[-1][-1][0].strip():
                widths[-1] -= lines[-1][-1][4]
                lines[-1].pop()
            lines.append([])
            widths.append(0.0)
            hard.append(False)
        if is_space and not lines[-1]:
            continue
        if width and not is_space and w > width and not lines[-1]:
            # A single word wider than the box: break it by characters.
            chunk = ""
            for ch in piece:
                if chunk and face.width(chunk + ch, size) > width:
                    lines[-1].append((chunk, face, size, color, face.width(chunk, size)))
                    widths[-1] += face.width(chunk, size)
                    lines.append([])
                    widths.append(0.0)
                    hard.append(False)
                    chunk = ""
                chunk += ch
            piece, w = chunk, face.width(chunk, size)
        lines[-1].append((piece.replace("\t", "    "), face, size, color, w))
        widths[-1] += w
    for i, line in enumerate(lines):
        while line and not line[-1][0].strip():
            widths[i] -= line[-1][4]
            line.pop()
    box_width = width or max(widths + [1.0])
    placed = []
    y = 0.0
    default = float(runs[0].get("size") or 12) if runs else 12.0
    for i, line in enumerate(lines):
        line_size = max((t[2] for t in line), default=default)
        if i > 0:
            y -= line_spacing * line_size
        slack = box_width - widths[i]
        x = {"center": slack / 2, "right": slack}.get(align, 0.0)
        spaces = sum(1 for t in line if not t[0].strip())
        extra = slack / spaces if align == "justify" and spaces and not hard[i] and i < len(lines) - 1 else 0.0
        items = []
        for text, face, size, color, w in line:
            if text.strip():
                items.append((x, face, size, color, text))
            x += w + (extra if not text.strip() else 0)
        placed.append((y, items, line_size))
    return placed, box_width


def emit_layout(placed, frame):
    ops = ["q", f"{fmt(*[float(v) for v in frame])} cm", "BT"]
    last = None
    for y, items, _ in placed:
        for x, face, size, color, text in items:
            key = (face.resource(), size)
            if key != last:
                ops.append(f"{key[0]} {fmt(float(size))} Tf")
                last = key
            ops.append(f"{fmt(*color)} rg")
            ops.append(f"1 0 0 1 {fmt(float(x), float(y))} Tm {face.operand(text)} Tj")
    ops.append("ET")
    ops.append("Q")
    return ("\n".join(ops) + "\n").encode()


# ---------------------------------------------------------------- plans

class RemoveGlyphs(Plan):
    def __init__(self, ids):
        self.ids = set(ids)

    def glyph(self, g):
        return "remove" if g.id in self.ids else None


def _locate_block(pdf, page_index, digest, block_id):
    require(isinstance(page_index, int) and 0 <= page_index < len(pdf.pages), "STALE_PAGE",
            "That page no longer exists.")
    cache = {}
    page, walker = page_walk(pdf, page_index, cache)
    if digest is not None:
        require(page_digest(page) == digest, "STALE_CONTENT", "The page changed. Select the text again.")
    blocks = build_blocks(walker.glyphs)
    require(isinstance(block_id, int) and 0 <= block_id < len(blocks), "STALE_CONTENT",
            "The page changed. Select the text again.")
    info = describe_block(blocks[block_id], block_id)
    glyphs = {g.id: g for g in walker.glyphs}
    return page, walker, info, [glyphs[i] for i in info["_glyphs"]], cache


def _fonts_by_key(glyphs):
    return {g.font.key: g.font for g in glyphs if g.font is not None}


def _frame_with(frame, offset=None, matrix=None):
    frame = tuple(float(v) for v in frame)
    if offset:
        frame = multiply(frame, (1, 0, 0, 1, float(offset[0]), float(offset[1])))
    if matrix:
        frame = multiply(frame, tuple(float(v) for v in matrix))
    return frame


def _glyph_layout(glyphs, info, width=None):
    """Original glyphs in the block frame: unchanged positions, or regrouped
    into words and reflowed to `width`. Returns [(glyph, x, y)]."""
    inv = invert(tuple(info["frame"]))
    if width is None or abs(width - info["width"]) < 0.5:
        return [(g, *apply(inv, *g.origin)) for g in glyphs if g.text.strip() or g.width > 0]
    words, current = [], []
    size = info["size"] or 12
    for g in glyphs:
        if not g.text.strip():
            if current:
                words.append(current)
                current = []
            continue
        if current:
            px, py = apply(inv, *current[-1].end)
            gx, gy = apply(inv, *g.origin)
            if abs(gy - py) > 0.3 * size or gx < px - 0.3 * size or gx > px + 0.22 * size:
                words.append(current)
                current = []
        current.append(g)
    if current:
        words.append(current)
    placed = []
    spacing = info["line_spacing"] * info["size"]
    space_w = info["size"] * 0.28
    x, y = 0.0, 0.0
    for word in words:
        start = apply(inv, *word[0].origin)
        end = apply(inv, *word[-1].end)
        w = end[0] - start[0]
        if x > 0 and x + w > width + 0.01:
            x = 0.0
            y -= spacing
        for g in word:
            gx, gy = apply(inv, *g.origin)
            placed.append((g, x + (gx - start[0]), y + (gy - start[1])))
        x += w + space_w
    return placed


def emit_glyphs(pool, placements, frame_old, frame_new):
    """Re-emit original glyphs at new frame positions, exactly as painted."""
    inv_old = invert(tuple(frame_old))
    ops = ["q", "BT"]
    last_font = None
    last_color = None
    for g, x, y in placements:
        # Glyph rendering matrix relative to the old frame, moved to (x, y) in the new frame.
        local = multiply(g.trm, inv_old)
        local = (local[0], local[1], local[2], local[3], x, y)
        m = multiply(local, tuple(frame_new))
        name = pool.name_for(g.font.obj, "ZPDFo")
        if name != last_font:
            ops.append(f"{name} 1 Tf 0 Tc 0 Tw 100 Tz 0 Ts")
            last_font = name
        color = tuple(round(c, 4) for c in g.fill.rgb()) if g.fill else (0, 0, 0)
        if (color, g.render) != last_color:
            ops.append(f"{fmt(*color)} rg {int(g.render)} Tr")
            if g.render in (1, 2, 5, 6) and g.stroke is not None:
                ops.append(f"{fmt(*g.stroke.rgb())} RG")
            last_color = (color, g.render)
        code = g.code.to_bytes(g.nbytes, "big").hex().upper()
        ops.append(f"{fmt(*[float(v) for v in m])} Tm <{code}> Tj")
    ops += ["ET", "Q"]
    return ("\n".join(ops) + "\n").encode()


# ---------------------------------------------------------------- text ops

@op("edit_text_block")
def edit_text_block(ctx, page, block, digest=None, runs=None, align=None, line_spacing=None, width=None,
                    offset=None, matrix=None, delete=False):
    pdf = ctx.pdf
    page_obj, walker, info, glyphs, cache = _locate_block(pdf, page, digest, block)
    rewrite_page(pdf, page_obj, RemoveGlyphs(info["_glyphs"]), cache, exclude_kinds=OVERLAY_KINDS)
    if delete:
        return {"removed": len(glyphs)}
    pool = FontPool(pdf, page_obj)
    frame = _frame_with(info["frame"], offset, matrix)
    new_width = float(width) if width else info["width"]
    require(new_width > 1, "INVALID_ARGUMENT", "The text box is too narrow.")
    if runs is None:
        placements = _glyph_layout(glyphs, info, float(width) if width else None)
        add_content(pdf, page_obj, emit_glyphs(pool, placements, info["frame"], frame))
        return {"glyphs": len(placements), "substituted": []}
    require(isinstance(runs, list), "INVALID_ARGUMENT", "Text runs are required.")
    fonts = _fonts_by_key(glyphs)
    placed, box_width = layout_runs(pool, runs, fonts, new_width, align or info["align"],
                                    float(line_spacing or info["line_spacing"]))
    add_content(pdf, page_obj, emit_layout(placed, frame))
    pool.finish()
    return {"lines": len(placed), "substituted": sorted(set(pool.substituted))}


@op("add_text")
def add_text(ctx, page, point, runs, width=None, align="left", line_spacing=1.2):
    """New page text (not an annotation). `point` is the user-space top-left
    of the box in the page's visual orientation."""
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "That page no longer exists.")
    require(isinstance(runs, list) and any(str(r.get("text", "")).strip() for r in runs), "INVALID_ARGUMENT",
            "Type some text first.")
    page_obj = pdf.pages[page]
    pool = FontPool(pdf, page_obj)
    placed, box_width = layout_runs(pool, runs, {}, float(width) if width else None, align, float(line_spacing))
    vm = visual_matrix(page_obj)
    ux, uy = unit_vec(vm[0], vm[1])
    vx, vy = unit_vec(vm[2], vm[3])
    first_size = placed[0][2] if placed else 12
    ascent = max((item[1].ascent for item in placed[0][1]), default=0.8) if placed else 0.8
    px, py = float(point[0]), float(point[1])
    ox, oy = px - vx * ascent * first_size, py - vy * ascent * first_size
    add_content(pdf, page_obj, emit_layout(placed, (ux, uy, vx, vy, ox, oy)))
    pool.finish()
    return {"lines": len(placed), "width": box_width}


# ---------------------------------------------------------------- find and replace

class ReplacePlan(Plan):
    def __init__(self, decisions, pool, fonts):
        self.decisions = decisions
        self.pool = pool
        self.fonts = fonts
        self.subs = {}

    def glyph(self, g):
        return self.decisions.get(g.id)

    def substitute_font(self, unit, g, text):
        style = g.font.style() if g.font else {}
        spec = self.fonts.get(style.get("base", "")) or style_spec(style)
        font = self.pool.embedded_font(spec)
        if not font.has_glyphs(text):
            font = self.pool.fallback()
        key = (id(unit), id(font))
        if key not in self.subs:
            self.subs[key] = self.walker.add_font(unit, font.ref, "ZPDFs")
        if g.font:
            self.pool.substituted.append(g.font.base_font)
        return self.subs[key], font


@op("replace_text")
def replace_text(ctx, find, replace="", match_case=False, whole_word=False, regex=False, pages=None, fonts=None):
    pdf = ctx.pdf
    require(isinstance(find, str) and find, "INVALID_ARGUMENT", "Enter text to find.")
    flags = 0 if match_case else re.IGNORECASE
    try:
        pattern = re.compile(find if regex else re.escape(find), flags)
    except re.error as exc:
        raise EngineError("INVALID_ARGUMENT", "The search pattern is not a valid regular expression.") from exc
    targets = select_pages(pdf, pages)
    total = 0
    substituted = []
    for index in targets:
        page = pdf.pages[index]
        cache = {}
        walker = walk_page(pdf, page, None, cache, exclude_kinds=OVERLAY_KINDS)
        decisions = {}
        for line in build_lines(walker.glyphs):
            chars, owners = [], []
            prev = None
            for g in line.ordered():
                if prev is not None and g.text.strip() and prev.text.strip():
                    gap = line.local_x(g) - (line.local_x(prev) + dot(sub(prev.end, prev.origin), line.u))
                    if gap > 0.22 * line.size:
                        chars.append(" ")
                        owners.append(None)
                for ch in (g.text or "�"):
                    chars.append(ch)
                    owners.append(g)
                prev = g
            text = "".join(chars)
            for match in pattern.finditer(text):
                if match.end() == match.start():
                    continue
                if whole_word:
                    before = text[match.start() - 1] if match.start() > 0 else " "
                    after = text[match.end()] if match.end() < len(text) else " "
                    if before.isalnum() or before == "_" or after.isalnum() or after == "_":
                        continue
                span = []
                for g in owners[match.start():match.end()]:
                    if g is not None and (not span or span[-1] is not g):
                        span.append(g)
                if not span or any(g.id in decisions for g in span):
                    continue
                replacement = match.expand(replace) if regex else replace
                first = span[0]
                decisions[first.id] = ("text", replacement) if replacement else "remove"
                for g in span[1:]:
                    decisions[g.id] = "drop" if g.op == first.op else "remove"
                total += 1
        if decisions:
            pool = FontPool(pdf, page)
            plan = ReplacePlan(decisions, pool, fonts or {})
            rewrite_page(pdf, page, plan, cache, exclude_kinds=OVERLAY_KINDS)
            pool.finish()
            substituted += pool.substituted
    return {"replaced": total, "substituted": sorted(set(substituted))}


# ---------------------------------------------------------------- objects

class ObjectPlan(Plan):
    def __init__(self, actions):
        self.actions = actions
        self.found = {}

    def _action(self, item):
        if not item.top_level:
            return None
        key = object_id(item)
        if key in self.actions:
            self.found[key] = item
            return self.actions[key](item)
        return None

    def path(self, item):
        return self._action(item)

    def image(self, item):
        return self._action(item)

    def form(self, item):
        action = self._action(item)
        return action if action is not None else "keep"


def _check(pdf, page, digest):
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "That page no longer exists.")
    page_obj = pdf.pages[page]
    if digest is not None:
        require(page_digest(page_obj) == digest, "STALE_CONTENT", "The page changed. Select the object again.")
    return page_obj


def _run_objects(ctx, page, digest, ids, make_action):
    pdf = ctx.pdf
    page_obj = _check(pdf, page, digest)
    require(isinstance(ids, list) and ids, "INVALID_ARGUMENT", "Select an object first.")
    plan = ObjectPlan({i: make_action for i in ids})
    walker, _ = rewrite_page(pdf, page_obj, plan, {}, exclude_kinds=OVERLAY_KINDS)
    missing = [i for i in ids if i not in plan.found]
    require(not missing, "STALE_CONTENT", "The page changed. Select the object again.")
    return page_obj, plan, walker


def _conjugate(ctm, t):
    inv = safe_invert(ctm)
    require(inv is not None, "INVALID_ARGUMENT", "That object cannot be transformed.")
    return multiply(multiply(ctm, t), inv)


@op("object_transform")
def object_transform(ctx, page, ids, matrix, digest=None):
    """Apply a user-space affine `matrix` to objects (move/resize/rotate/flip)."""
    t = tuple(float(v) for v in matrix)
    require(len(t) == 6 and abs(t[0] * t[3] - t[1] * t[2]) > 1e-9, "INVALID_ARGUMENT", "Invalid transform.")

    def action(item):
        require(not item.has_clip, "INVALID_ARGUMENT", "That object also clips other content and cannot be moved.")
        m = _conjugate(item.ctm if item.kind != "path" else item.state.ctm, t)
        return ("wrap", [instr([], "q"), instr([round(v, 6) for v in m], "cm")], [instr([], "Q")])
    _, plan, _ = _run_objects(ctx, page, digest, ids, action)
    return {"objects": len(plan.found)}


@op("object_delete")
def object_delete(ctx, page, ids, digest=None):
    _, plan, _ = _run_objects(ctx, page, digest, ids, lambda item: "remove")
    return {"objects": len(plan.found)}


@op("object_arrange")
def object_arrange(ctx, page, ids, to="front", digest=None):
    require(to in ("front", "back"), "INVALID_ARGUMENT", "Choose front or back.")
    pdf = ctx.pdf
    page_obj, plan, walker = _run_objects(ctx, page, digest, ids, lambda item: "omit")
    chunks = []
    for key in ids:
        item = plan.found[key]
        source = walker.parsed[item.stream if not walker.joined else 0]
        ops = [instr([], "q")] + full_state_ops(item.state) + list(source[item.start:item.end + 1]) + [instr([], "Q")]
        chunks.append(pikepdf.unparse_content_stream(ops))
    data = b"\n".join(chunks) + b"\n"
    if to == "front":
        add_content(pdf, page_obj, data)
    else:
        from transforms.content import _wrap_existing
        stream = pdf.make_indirect(pikepdf.Stream(pdf, b"q\n" + data + b"Q\n"))
        _wrap_existing(pdf, page_obj)
        contents = page_obj.obj.get("/Contents")
        streams = list(contents) if isinstance(contents, pikepdf.Array) else [contents] if contents is not None else []
        xobjects = resources(page_obj).get("/XObject", pikepdf.Dictionary())
        position = 0
        for i, s in enumerate(streams):
            try:
                raw = s.read_bytes()
            except pikepdf.PdfError:
                break
            match = INVOCATION.match(raw) if len(raw) < 256 else None
            if match and str(xobjects.get(Name("/" + match.group(1).decode()), {}).get("/ZPDFKind", "")) == "/Background":
                position = i + 1
            else:
                break
        streams.insert(position, stream)
        page_obj.obj.Contents = pikepdf.Array(streams)
    return {"objects": len(ids)}


def _image_fit(old_ctm, width, height):
    ax = math.hypot(old_ctm[0], old_ctm[1])
    ay = math.hypot(old_ctm[2], old_ctm[3])
    box_aspect = ax / ay if ay else 1
    aspect = width / height if height else 1
    if aspect > box_aspect:
        sy = box_aspect / aspect
        return (1, 0, 0, sy, 0, (1 - sy) / 2)
    sx = aspect / box_aspect
    return (sx, 0, 0, 1, (1 - sx) / 2, 0)


@op("image_replace")
def image_replace(ctx, page, id, image, digest=None, fit=True):
    pdf = ctx.pdf
    xobj, w, h = image_xobject(pdf, image)

    def action(item):
        require(item.kind in ("image", "inline_image"), "INVALID_ARGUMENT", "Select an image to replace.")
        return ("replace", xobj, [round(v, 6) for v in _image_fit(item.ctm, w, h)] if fit else None)
    _run_objects(ctx, page, digest, [id], action)
    return {"pixels": [w, h]}


@op("image_crop")
def image_crop(ctx, page, id, rect, digest=None):
    """Clip an image to the user-space `rect`."""
    x0, y0, x1, y1 = [float(v) for v in rect]

    def action(item):
        require(item.kind in ("image", "inline_image"), "INVALID_ARGUMENT", "Select an image to crop.")
        inv = safe_invert(item.ctm)
        require(inv is not None, "INVALID_ARGUMENT", "That image cannot be cropped.")
        pts = [apply(inv, x, y) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))]
        us, vs = [p[0] for p in pts], [p[1] for p in pts]
        u0, u1 = max(0.0, min(us)), min(1.0, max(us))
        v0, v1 = max(0.0, min(vs)), min(1.0, max(vs))
        require(u1 - u0 > 0.005 and v1 - v0 > 0.005, "INVALID_ARGUMENT", "The crop area is empty.")
        return ("wrap", [instr([], "q"), instr([round(u0, 6), round(v0, 6), round(u1 - u0, 6), round(v1 - v0, 6)], "re"),
                         instr([], "W"), instr([], "n")], [instr([], "Q")])
    _run_objects(ctx, page, digest, [id], action)
    return {"cropped": 1}


@op("image_add")
def image_add(ctx, page, image, rect):
    """Place an image file in the user-space `rect`, upright in the page's visual orientation."""
    pdf = ctx.pdf
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "STALE_PAGE", "That page no longer exists.")
    page_obj = pdf.pages[page]
    xobj, w, h = image_xobject(pdf, image)
    x0, y0, x1, y1 = [float(v) for v in rect]
    require(abs(x1 - x0) > 1 and abs(y1 - y0) > 1, "INVALID_ARGUMENT", "The image area is too small.")
    vm = visual_matrix(page_obj)
    inv = invert(vm)
    corners = [apply(inv, x, y) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))]
    vx0, vy0 = min(p[0] for p in corners), min(p[1] for p in corners)
    vx1, vy1 = max(p[0] for p in corners), max(p[1] for p in corners)
    m = multiply((vx1 - vx0, 0, 0, vy1 - vy0, vx0, vy0), vm)
    name = add_resource(page_obj, "XObject", xobj, "ZPDFim")
    add_content(pdf, page_obj, f"q {fmt(*[float(v) for v in m])} cm {name} Do Q\n".encode())
    return {"pixels": [w, h]}
