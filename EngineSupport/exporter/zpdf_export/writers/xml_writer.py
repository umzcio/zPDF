"""Structured XML writer (schema: ``schemas/zpdf-document-1.xsd``, documented in
docs/xml-format.md).

The document's selected pages in order; on each page its content in reading
order: text blocks (paragraphs, headings, list items, a scan's invisible text
layer) with their text and their lines of words (box, font, size, bold,
italic, link); tables with their cells (row, column, spans, header flag, text,
lines of words); images (box, pixel size, origin, the labels they keep, the
picture as base64 unless omitted); form fields (name, type, value, checked,
label and where it came from, widget ids); comments. Every item has an id
unique in the document and a document-wide reading-order number.

Coordinates are points on the page as displayed, origin top-left, y down: the
IR's normalized space. Word geometry needs ``keep_geometry`` when the
document is built (the worker sets it for XML).
"""
from __future__ import annotations

import base64
import re
from importlib import resources
from pathlib import Path

from lxml import etree

from ..ir import CommentNode, FigureNode, FormValueNode, TableNode, TextNode
from .docx_layout_writer import MAX_PICTURE_DPI, _fit_picture
from .. import BACKEND_ID

NS = "urn:zpdf:export:document:1"
_E = "{%s}" % NS
# characters XML 1.0 cannot hold: C0 controls other than tab/newline/return, lone surrogates, U+FFFE/U+FFFF
_INVALID = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff￾￿]")
# libxml2 (lxml, xmllint, most XML tools) refuses a text node over 10,000,000
# characters unless told otherwise: an image's base64 stays under it
_MAX_BASE64 = 9_500_000
_KIND = {"paragraph": "paragraph", "heading": "heading", "list_item": "list-item", "invisible": "invisible",
         "unsupported": "unsupported"}


def schema() -> etree.XMLSchema:
    """The XSD every output is validated against (shipped with the package)."""
    xsd = resources.files("zpdf_export").joinpath("schemas/zpdf-document-1.xsd").read_bytes()
    return etree.XMLSchema(etree.fromstring(xsd))


class _Writer:
    def __init__(self, doc, images: str):
        self.doc, self.images = doc, images
        self.geometry = getattr(doc, "geometry", {}) or {}
        self.order = 0
        self.stats = {"pages": 0, "blocks": 0, "lines": 0, "words": 0, "tables": 0, "cells": 0, "images": 0,
                      "image_bytes": 0, "fields": 0, "comments": 0, "chars_replaced": 0, "images_mode": images}

    def clean(self, text: str | None) -> str:
        text = text or ""
        cleaned, n = _INVALID.subn("�", text)
        self.stats["chars_replaced"] += n
        return cleaned

    @staticmethod
    def box(el, bbox) -> None:
        x0, y0, x1, y1 = (bbox or [0, 0, 0, 0])[:4]
        for k, v in zip(("x0", "y0", "x1", "y1"), (x0, y0, x1, y1)):
            el.set(k, f"{float(v):.2f}")

    def item(self, parent, tag: str, node) -> etree._Element:
        self.order += 1
        el = etree.SubElement(parent, _E + tag)
        el.set("id", node.id)
        el.set("order", str(self.order))
        # a paragraph joined across lines has one region per line: its box covers them all
        regions = [r["bbox"] for r in (node.source_regions or [])
                   if r.get("page") == node.source_regions[0].get("page")] if node.source_regions else []
        if regions and tag in ("block", "comment"):
            box = [min(r[0] for r in regions), min(r[1] for r in regions),
                   max(r[2] for r in regions), max(r[3] for r in regions)]
        else:
            box = regions[0] if regions else None
        self.box(el, box)
        return el

    def lines(self, parent, key: str) -> None:
        for ln in self.geometry.get(key, []):
            words = [w for w in ln["words"] if self.clean(w["text"]).strip()]
            if not words:
                continue
            le = etree.SubElement(parent, _E + "line")
            self.box(le, ln["bbox"])
            for w in words:
                we = etree.SubElement(le, _E + "word")
                self.box(we, w["bbox"])
                we.set("font", self.clean(w.get("font", "")))
                we.set("size", f"{float(w.get('size') or 0):.2f}")
                if w.get("bold"):
                    we.set("bold", "true")
                if w.get("italic"):
                    we.set("italic", "true")
                if w.get("uri"):
                    we.set("href", self.clean(w["uri"]))
                we.text = self.clean(w["text"])
                self.stats["words"] += 1
            self.stats["lines"] += 1

    def block(self, page_el, node: TextNode) -> None:
        el = self.item(page_el, "block", node)
        el.set("kind", _KIND.get(node.kind, "paragraph"))
        if node.kind == "heading" and node.level:
            el.set("level", str(min(max(int(node.level), 1), 9)))
        if node.marker:
            el.set("marker", self.clean(node.marker))
        if node.font:
            el.set("font", self.clean(node.font))
        if node.size:
            el.set("size", f"{float(node.size):.2f}")
        etree.SubElement(el, _E + "text").text = self.clean(node.text)
        self.lines(el, node.id)
        self.stats["blocks"] += 1

    def table(self, page_el, node: TableNode) -> None:
        el = self.item(page_el, "table", node)
        el.set("rows", str(node.n_rows))
        el.set("cols", str(node.n_cols))
        if node.header_rows:
            el.set("header-rows", " ".join(str(r) for r in node.header_rows))
        header = set(node.header_rows)
        for c in sorted(node.cells, key=lambda c: (c["row"], c["col"])):
            ce = etree.SubElement(el, _E + "cell")
            self.box(ce, c.get("bbox"))
            ce.set("row", str(c["row"]))
            ce.set("col", str(c["col"]))
            if c.get("rowspan", 1) != 1:
                ce.set("rowspan", str(c["rowspan"]))
            if c.get("colspan", 1) != 1:
                ce.set("colspan", str(c["colspan"]))
            if c["row"] in header:
                ce.set("header", "true")
            if c.get("bold"):
                ce.set("bold", "true")
            etree.SubElement(ce, _E + "text").text = self.clean(c.get("raw_text", ""))
            self.lines(ce, f"{node.id}:{c['row']}:{c['col']}")
            self.stats["cells"] += 1
        self.stats["tables"] += 1

    def image(self, page_el, node: FigureNode) -> None:
        asset = self.doc.assets.get(node.asset_id)
        data = getattr(asset, "data", b"") if asset is not None else b""
        el = self.item(page_el, "image", node)
        el.set("width-px", str(max(int(node.width_px or 1), 1)))
        el.set("height-px", str(max(int(node.height_px or 1), 1)))
        el.set("origin", node.origin if node.origin in ("image", "vector") else "image")
        el.set("mime-type", "image/jpeg" if data[:3] == b"\xff\xd8\xff" else "image/png")
        if node.absorbed_text:
            etree.SubElement(el, _E + "description").text = self.clean(node.absorbed_text)
        if self.images == "embed" and data:
            bbox = node.source_regions[0]["bbox"] if node.source_regions else [0, 0, 72, 72]
            data = _fit_picture(data, max(bbox[2] - bbox[0], 1.0), max(bbox[3] - bbox[1], 1.0), self.stats)
            if len(data) * 4 // 3 > _MAX_BASE64:
                data = _as_jpeg(data)
            if data and len(data) * 4 // 3 <= _MAX_BASE64:
                from PIL import Image
                import io
                pic = Image.open(io.BytesIO(data))
                el.set("width-px", str(pic.width))
                el.set("height-px", str(pic.height))
                el.set("mime-type", "image/jpeg" if data[:3] == b"\xff\xd8\xff" else "image/png")
                de = etree.SubElement(el, _E + "data")
                de.set("encoding", "base64")
                de.text = base64.b64encode(data).decode("ascii")
                self.stats["image_bytes"] += len(data)
            else:
                self.stats["images_too_large"] = self.stats.get("images_too_large", 0) + 1
        self.stats["images"] += 1

    def field(self, page_el, v: FormValueNode) -> None:
        el = self.item(page_el, "field", v)
        el.set("name", self.clean(v.field_name))
        el.set("type", self.clean(v.field_type or "unknown"))
        if v.label:
            el.set("label", self.clean(v.label))
        el.set("label-source", v.label_source or "none")
        el.set("placement", v.placement or "fallback")
        if v.checked is not None:
            el.set("checked", "true" if v.checked else "false")
        if v.export_value:
            el.set("export-value", self.clean(v.export_value))
        if v.tooltip:
            el.set("tooltip", self.clean(v.tooltip))
        if v.table_id:
            el.set("table", v.table_id)
        etree.SubElement(el, _E + "value").text = self.clean(v.raw_value)
        self.lines(el, f"{v.id}:label")                # the visible label's words
        for wid in v.widget_ids:
            etree.SubElement(el, _E + "widget").set("id", wid)
        self.stats["fields"] += 1

    def comment(self, page_el, node: CommentNode) -> None:
        el = self.item(page_el, "comment", node)
        el.set("kind", self.clean(node.comment_kind or "note"))
        if node.author:
            el.set("author", self.clean(node.author))
        if node.modified:
            el.set("modified", self.clean(node.modified))
        el.text = self.clean(node.text)
        self.stats["comments"] += 1

    def write(self, path: Path) -> dict:
        root = etree.Element(_E + "document", nsmap={None: NS})
        root.set("schema-version", "1")
        root.set("source-sha256", self.doc.source_sha256)
        root.set("generator", f"zPDF Export {BACKEND_ID}")
        root.set("units", "pt")
        root.set("origin", "top-left")
        pages = {}
        for p in self.doc.pages:
            pe = etree.SubElement(root, _E + "page")
            pe.set("number", str(p.source_index))
            pe.set("width", f"{p.width:.2f}")
            pe.set("height", f"{p.height:.2f}")
            pe.set("rotation", str(p.rotation if p.rotation in (0, 90, 180, 270) else 0))
            pages[p.source_index] = pe
        first = next(iter(pages.values()), None)
        position = {num: k + 1 for k, num in enumerate(pages)}   # 1-based position in the selection
        for nid in self.doc.flow:
            node = self.doc.nodes[nid]
            page_no = node.source_regions[0]["page"] if node.source_regions else None
            pe = pages.get(page_no, first)
            self.stats["pages"] = position.get(page_no, 1)       # the downsampling disclosure's page
            if pe is None:
                continue
            if isinstance(node, TextNode):
                self.block(pe, node)
            elif isinstance(node, TableNode):
                self.table(pe, node)
            elif isinstance(node, FigureNode):
                self.image(pe, node)
            elif isinstance(node, FormValueNode):
                self.field(pe, node)
            elif isinstance(node, CommentNode):
                self.comment(pe, node)
        self.stats["pages"] = len(pages)
        etree.ElementTree(root).write(str(path), xml_declaration=True, encoding="UTF-8", pretty_print=True)
        warnings = []
        if self.stats["chars_replaced"]:
            warnings.append({"code": "XML_CHARS_REPLACED", "count": self.stats["chars_replaced"],
                             "detail": "characters XML 1.0 cannot hold (control characters) became U+FFFD"})
        if self.stats.get("images_too_large"):
            warnings.append({"code": "XML_IMAGE_TOO_LARGE", "count": self.stats["images_too_large"],
                             "detail": "an image too large for one XML text node even as JPEG is described without its pixels"})
        if self.images == "omit" and self.stats["images"]:
            warnings.append({"code": "XML_IMAGE_DATA_OMITTED", "count": self.stats["images"],
                             "detail": "images are described (box, size, labels) without their pixels"})
        stats = dict(self.stats)
        stats["max_picture_dpi"] = MAX_PICTURE_DPI        # images_downsampled_*: disclosed per page by the worker
        stats["warnings"] = warnings
        return stats


def _as_jpeg(data: bytes, quality: int = 85) -> bytes:
    from PIL import Image
    import io
    try:
        im = Image.open(io.BytesIO(data)).convert("RGB")
    except Exception:  # noqa: BLE001
        return b""
    out = io.BytesIO()
    im.save(out, "JPEG", quality=quality, optimize=True)
    return out.getvalue()


def write_xml(doc, path: Path, images: str = "embed") -> dict:
    if images not in ("embed", "omit"):
        raise ValueError(f"unknown XML image mode {images!r}")
    return _Writer(doc, images).write(Path(path))
