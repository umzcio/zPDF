"""Versioned, ordered intermediate representation (spec section 7).

Independent of OOXML. ``flow`` orders node ids; ``nodes`` holds every node by
stable id; ``assets`` holds binary image data referenced by figures. JSON
serialization is canonical (sorted keys, compact separators, 2-decimal floats)
and excludes asset bytes, which travel separately.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from typing import Any

SCHEMA_VERSION = 1


@dataclass
class PageInfo:
    source_index: int
    width: float
    height: float
    rotation: int
    user_unit: float
    media_box: list[float]
    crop_box: list[float]


@dataclass
class Node:
    id: str
    kind: str
    source_regions: list[dict]  # [{"page": int, "bbox": [x0, y0, x1, y1]}] normalized space


@dataclass
class TextNode(Node):
    text: str = ""
    runs: list[dict] = field(default_factory=list)  # {text,bold,italic,uri?,dest_page?}
    level: int | None = None
    marker: str | None = None
    line_count: int = 1
    choices: list[str] = field(default_factory=list)  # widget ids of check boxes embedded as ☒/☐ glyphs
    font: str | None = None      # the paragraph's dominant PDF font name (reading-order writers set it)
    size: float | None = None    # … and its dominant glyph size in points


@dataclass
class TableNode(Node):
    n_rows: int = 0
    n_cols: int = 0
    cells: list[dict] = field(default_factory=list)  # {row,col,rowspan,colspan,raw_text,bbox,bold}
    header_rows: list[int] = field(default_factory=list)
    header_inference: str = "none"
    row_inference: list[dict] = field(default_factory=list)


@dataclass
class FigureNode(Node):
    asset_id: str = ""
    width_px: int = 0
    height_px: int = 0
    origin: str = "image"       # image | vector
    objects: int = 1
    absorbed_text: str = ""


@dataclass
class FormValueNode(Node):
    field_name: str = ""
    label: str | None = None
    field_type: str = ""
    raw_value: str = ""
    checked: bool | None = None
    export_value: str | None = None
    widget_ids: list[str] = field(default_factory=list)
    paired: bool = False
    label_source: str = "none"     # visible_inside|visible_above|visible_left|visible_right|table_cell|field_tooltip|none
    placement: str = "fallback"    # inline | table_cell | fallback
    group_id: str | None = None
    table_id: str | None = None
    tooltip: str | None = None
    ambiguity: list[str] = field(default_factory=list)
    sentence_id: str | None = None  # TextNode carrying this box inline


@dataclass
class CommentNode(Node):
    comment_kind: str = ""
    text: str = ""
    author: str | None = None
    modified: str | None = None


@dataclass
class Asset:
    asset_id: str
    mime: str
    sha256: str
    width_px: int
    height_px: int
    data: bytes = field(default=b"", repr=False)


@dataclass
class Document:
    schema_version: int
    source_sha256: str
    backend: str
    pages: list[PageInfo]
    flow: list[str]
    nodes: dict[str, Node]
    assets: dict[str, Asset]
    warnings: list[dict]
    stats: dict[str, Any]
    language: str | None = None
    direction: str | None = None


_KINDS = {
    "paragraph": TextNode, "heading": TextNode, "list_item": TextNode, "unsupported": TextNode,
    "table": TableNode, "figure": FigureNode, "form_value": FormValueNode, "comment": CommentNode,
}


def make_asset(asset_id: str, png: bytes, width_px: int, height_px: int) -> Asset:
    return Asset(asset_id, "image/png", hashlib.sha256(png).hexdigest(), width_px, height_px, png)


def _round(obj: Any) -> Any:
    if isinstance(obj, float):
        return round(obj, 2)
    if isinstance(obj, list):
        return [_round(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _round(v) for k, v in obj.items()}
    return obj


def to_dict(doc: Document) -> dict:
    d = {
        "schema_version": doc.schema_version,
        "source_sha256": doc.source_sha256,
        "backend": doc.backend,
        "language": doc.language,
        "direction": doc.direction,
        "pages": [asdict(p) for p in doc.pages],
        "flow": list(doc.flow),
        "nodes": {nid: asdict(n) for nid, n in doc.nodes.items()},
        "assets": {aid: {"asset_id": a.asset_id, "mime": a.mime, "sha256": a.sha256,
                         "width_px": a.width_px, "height_px": a.height_px}
                   for aid, a in doc.assets.items()},
        "warnings": doc.warnings,
        "stats": doc.stats,
    }
    return _round(d)


def to_json(doc: Document) -> str:
    return json.dumps(to_dict(doc), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def from_json(text: str, assets: dict[str, bytes] | None = None) -> Document:
    d = json.loads(text)
    nodes: dict[str, Node] = {}
    for nid, nd in d["nodes"].items():
        cls = _KINDS[nd["kind"]]
        nodes[nid] = cls(**nd)
    assets_out = {aid: Asset(**ad, data=(assets or {}).get(aid, b"")) for aid, ad in d["assets"].items()}
    return Document(
        schema_version=d["schema_version"], source_sha256=d["source_sha256"], backend=d["backend"],
        pages=[PageInfo(**p) for p in d["pages"]], flow=d["flow"], nodes=nodes, assets=assets_out,
        warnings=d["warnings"], stats=d["stats"], language=d.get("language"), direction=d.get("direction"),
    )
