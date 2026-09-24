"""Markdown writer: GitHub Flavored Markdown (CommonMark + tables,
strikethrough, task lists) from the IR in reading order.

Kept: reading order, headings (`#`…`######`), paragraphs with bold, italic,
strikethrough and links, bulleted and numbered lists (start numbers kept),
tables as pipe tables (unruled bodies recovered as for XLSX), pictures,
form values (check boxes as task-list items), comments as block quotes and
invisible page markers (`<!-- page N -->`).

Markdown cannot hold everything, and what it cannot hold is reported
(warnings with counts), never silently dropped: page layout, fonts, sizes,
colours and underline (MD_FORMATTING_NOT_KEPT), multi-row table headers
(flattened per column: MD_TABLE_HEADER_FLATTENED), cells spanning rows or
columns (MD_TABLE_SPANS_NOT_KEPT), and pictures, which a single file can
only carry as data URIs that some renderers do not display
(MD_PICTURES_AS_DATA_URI).

All text is escaped so that it never becomes markup.
"""
from __future__ import annotations

import re
from pathlib import Path

from ..ir import CommentNode, FigureNode, FormValueNode, TableNode, TextNode
from .docx_layout_writer import MAX_PICTURE_DPI, _fit_picture
from .html_writer import _data_uri

_INLINE_SPECIAL = re.compile(r"([\\`*_\[\]<>|~])")


def _esc(text: str) -> str:
    """Escape characters that Markdown reads as inline markup."""
    return _INLINE_SPECIAL.sub(r"\\\1", text or "")


_LINE_START = re.compile(r"^(\s*)(#{1,6}(?=\s|$)|[-+](?=\s)|>|(\d{1,9})([.)])(?=\s|$)|=+\s*$|-{3,}\s*$)")


def _esc_line_start(line: str) -> str:
    """Escape a line start that Markdown would read as a heading, list item,
    quote or rule."""
    m = _LINE_START.match(line)
    if not m:
        return line
    lead, tok = m.group(1), m.group(2)
    if m.group(3):                                 # "1." → "1\."
        return lead + m.group(3) + "\\" + m.group(4) + line[m.end():]
    return lead + "\\" + tok + line[m.end():]


def _url(uri: str) -> str:
    if re.search(r"[\s()<>]", uri):
        return "<" + uri.replace("<", "%3C").replace(">", "%3E") + ">"
    return uri


def _wrap(text: str, mark: str) -> str:
    """Emphasis must hug its text: spaces go outside the delimiters."""
    core = text.strip()
    if not core:
        return text
    lead = text[: len(text) - len(text.lstrip())]
    trail = text[len(text.rstrip()):]
    return f"{lead}{mark}{core}{mark}{trail}"


def _inline(runs: list[dict], fallback: str, stats: dict) -> str:
    if not runs:
        return _esc(fallback)
    groups: list[tuple[tuple, str]] = []
    for r in runs:
        t = r.get("text", "")
        if not t:
            continue
        key = (bool(r.get("bold")), bool(r.get("italic")), bool(r.get("strike")), r.get("uri"))
        if groups and groups[-1][0] == key:
            groups[-1] = (key, groups[-1][1] + t)
        else:
            groups.append((key, t))
        _note_lost(r, stats)
    out = []
    for (bold, italic, strike, uri), t in groups:
        s = _esc(t)
        if strike:
            s = _wrap(s, "~~")
        if italic:
            s = _wrap(s, "*")
        if bold:
            s = _wrap(s, "**")
        if uri:
            core = s.strip()
            s = s[: len(s) - len(s.lstrip())] + f"[{core}]({_url(uri)})" + s[len(s.rstrip()):]
            stats["links"] += 1
        out.append(s)
    return re.sub(r"\s+", " ", "".join(out)).strip() or _esc(fallback)


def _note_lost(r: dict, stats: dict) -> None:
    lost = stats["_lost"]
    color = r.get("color")
    if color and sum(color) > 90:
        lost["colours"] = lost.get("colours", 0) + 1
    if r.get("underline") and not r.get("uri"):
        lost["underline"] = lost.get("underline", 0) + 1
    if r.get("highlight"):
        lost["highlight"] = lost.get("highlight", 0) + 1


def _table(node: TableNode, stats: dict) -> str:
    """A pipe table: one header row (a multi-row header is flattened per
    column), spans written in their first cell with the covered cells empty."""
    n_cols = max(node.n_cols, 1)
    grid: dict[tuple[int, int], str] = {}
    owner: dict[tuple[int, int], tuple[int, int]] = {}
    spans = 0
    for c in sorted(node.cells, key=lambda c: (c["row"], c["col"])):
        cover = [(r, k) for r in range(c["row"], c["row"] + c["rowspan"]) for k in range(c["col"], c["col"] + c["colspan"])]
        taken = [owner[p] for p in cover if p in owner]
        text = c["raw_text"] or ""
        if taken:
            if text.strip():
                grid[taken[0]] = (grid.get(taken[0], "") + "\n" + text).strip("\n")
            continue
        for p in cover:
            owner[p] = (c["row"], c["col"])
        grid[(c["row"], c["col"])] = text
        if (c["rowspan"] > 1 or c["colspan"] > 1) and c["row"] not in node.header_rows:
            spans += 1

    def cell_md(text: str) -> str:
        parts = [_esc(p.strip()) for p in text.split("\n") if p.strip()]
        return "<br>".join(parts)

    head_rows = sorted(r for r in node.header_rows if r < node.n_rows)
    if head_rows:
        header = []
        for k in range(n_cols):
            pieces: list[str] = []
            for r in head_rows:
                o = owner.get((r, k))
                if o is None:
                    continue
                t = " ".join(grid.get(o, "").split())
                if t and (not pieces or pieces[-1] != t):
                    pieces.append(t)
            header.append(_esc(" / ".join(pieces)))
        if len(head_rows) > 1 or any(c["colspan"] > 1 or c["rowspan"] > 1 for c in node.cells if c["row"] in head_rows):
            stats["_header_flattened"] += 1
    else:
        header = [""] * n_cols
        stats["_no_header"] += 1
    body = []
    for r in range(node.n_rows):
        if r in head_rows:
            continue
        row = [cell_md(grid[(r, k)]) if (r, k) in grid else "" for k in range(n_cols)]
        if any(row):
            body.append(row)
    stats["_spans"] += spans
    stats["tables"] += 1

    def line(cells):
        return "| " + " | ".join(cells) + " |"

    return "\n".join([line(header), "|" + "|".join(" --- " for _ in range(n_cols)) + "|"] + [line(r) for r in body])


def _list_marker(node: TextNode, counter: dict) -> tuple[str, str]:
    m = re.match(r"^\(?(\d+)[.)]$", (node.marker or "").strip())
    if m:
        return "ol", f"{int(m.group(1))}."
    m = re.match(r"^\(?([a-zA-Z]|[ivxlcdmIVXLCDM]+)[.)]$", (node.marker or "").strip())
    if m:
        counter["n"] = counter.get("n", 0) + 1
        return "ol-lettered", f"{counter['n']}."   # Markdown numbers lists with digits only
    return "ul", "-"


def _image_link(folder: str, name: str) -> str:
    target = f"{folder}/{name}"
    return f"<{target}>" if re.search(r"[\s()<>]", target) else target


def write_markdown(doc, path: Path, images: str = "folder", asset_folder: str | None = None) -> dict:
    """``images="folder"`` (default): each picture is a file in ``asset_folder``
    (default ``<stem>_images``) beside the Markdown, linked relatively; the
    written files are listed in ``stats["files"]``. ``images="embed"``: pictures
    are data URIs inside the one file."""
    import hashlib
    path = Path(path)
    folder = asset_folder or f"{path.stem}_images"
    written: list[dict] = []
    stats = {"pages": 0, "headings": 0, "paragraphs": 0, "list_items": 0, "tables": 0, "images": 0,
             "links": 0, "comments": 0, "form_values": 0, "warnings": [],
             "_lost": {}, "_header_flattened": 0, "_spans": 0, "_no_header": 0, "_lettered": 0}
    blocks: list[str] = []
    listing: list[str] = []
    list_kind = None
    counter: dict = {}
    fields: list[str] = []
    page_now = None

    def close_list():
        nonlocal list_kind
        if listing:
            blocks.append("\n".join(listing))
            listing.clear()
        list_kind = None
        counter.clear()

    def flush_fields():
        if fields:
            blocks.append("\n".join(fields))
            fields.clear()

    for nid in doc.flow:
        node = doc.nodes[nid]
        page = node.source_regions[0]["page"] if node.source_regions else None
        if page is not None and page != page_now:
            close_list(); flush_fields()
            stats["pages"] += 1                  # the section index the downsampling disclosure uses
            blocks.append(f"<!-- page {page} -->")
            page_now = page
        if isinstance(node, FormValueNode):
            if node.placement in ("table_cell", "inline_sentence"):
                continue
            close_list()
            label = _esc(node.label or node.field_name or "")
            if node.checked is not None:
                fields.append(f"- [{'x' if node.checked else ' '}] {label}")
            else:
                fields.append(f"- **{label}:** {_esc(node.raw_value)}" if node.raw_value.strip() else f"- **{label}:**")
            stats["form_values"] += 1
            continue
        flush_fields()
        if isinstance(node, TextNode):
            if node.kind == "list_item":
                kind = _list_marker(node, {})[0]
                if kind.startswith("ol") != (list_kind or "").startswith("ol") or list_kind is None:
                    close_list(); list_kind = kind
                _kind, marker = _list_marker(node, counter)
                if _kind == "ol-lettered":
                    stats["_lettered"] += 1
                # item text starting '1. ' or '# ' would nest a list or heading in the item
                listing.append(f"{marker} {_esc_line_start(_inline(node.runs, node.text, stats))}")
                stats["list_items"] += 1
                continue
            close_list()
            if node.kind == "invisible":
                body = "\n".join(_esc_line_start(_esc(t)) + "  " for t in node.text.split("\n")).rstrip()
                blocks.append(f"<details><summary>Invisible text layer, page {page}</summary>\n\n{body}\n\n</details>")
                stats["invisible_layers"] = stats.get("invisible_layers", 0) + 1
                continue
            if node.kind == "heading":
                lvl = min(max(node.level or 1, 1), 6)
                text = " ".join(_esc(node.text).split())
                blocks.append(f"{'#' * lvl} {text}")
                stats["headings"] += 1
            elif node.kind == "unsupported":
                blocks.append(f"*{_esc(node.text)}*")
            else:
                blocks.append(_esc_line_start(_inline(node.runs, node.text, stats)))
                stats["paragraphs"] += 1
            continue
        close_list()
        if isinstance(node, TableNode):
            blocks.append(_table(node, stats))
        elif isinstance(node, FigureNode):
            asset = doc.assets.get(node.asset_id)
            if asset is not None and asset.data:
                b = node.source_regions[0]["bbox"] if node.source_regions else [0, 0, 400, 300]
                data = _fit_picture(asset.data, b[2] - b[0], b[3] - b[1], stats)
                alt = " ".join((node.absorbed_text or f"Picture from page {page}").split())
                if images == "embed":
                    blocks.append(f"![{_esc(alt)}]({_data_uri(data)})")
                else:
                    ext = "jpg" if data[:3] == b"\xff\xd8\xff" else "png"
                    name = f"page-{page:03d}-{sum(1 for w in written if w['page'] == page) + 1:02d}.{ext}"
                    target = path.parent / folder / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    written.append({"page": page, "relative_path": f"{folder}/{name}",
                                    "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
                    blocks.append(f"![{_esc(alt)}]({_image_link(folder, name)})")
                stats["images"] += 1
        elif isinstance(node, CommentNode):
            who = f" by {_esc(node.author)}" if node.author else ""
            when = f" ({_esc(node.modified)})" if node.modified else ""
            text = " ".join(_esc(node.text).split())
            blocks.append(f"> **{_esc(node.comment_kind.capitalize())}**{who}{when}: {text}")
            stats["comments"] += 1
    close_list(); flush_fields()
    Path(path).write_text("\n\n".join(blocks) + "\n", encoding="utf-8")
    # what Markdown could not hold, said explicitly
    w = stats["warnings"]
    # Markdown never keeps these, whatever the document: said on every result
    kinds = ["page_layout", "fonts_and_sizes", "colours", "underline_and_highlight", "alignment", "rules_and_shading"]
    w.append({"code": "MD_FORMATTING_NOT_KEPT", "kinds": kinds, "counts": dict(stats["_lost"]),
              "detail": "Markdown keeps structure, bold, italic, strikethrough and links; page layout, fonts, sizes, colours, underline, highlighting, alignment, rules and shading are not kept"})
    if stats["_header_flattened"]:
        w.append({"code": "MD_TABLE_HEADER_FLATTENED", "count": stats["_header_flattened"],
                  "detail": "a pipe table has one header row: multi-row or spanning headers are joined per column with ' / '"})
    if stats["_spans"]:
        w.append({"code": "MD_TABLE_SPANS_NOT_KEPT", "count": stats["_spans"],
                  "detail": "cells spanning rows or columns are written in their first cell; the covered cells are empty"})
    if stats["_no_header"]:
        w.append({"code": "MD_TABLE_NO_HEADER", "count": stats["_no_header"],
                  "detail": "a table without a header row gets an empty header row (pipe tables require one)"})
    if stats["images"] and images == "embed":
        w.append({"code": "MD_PICTURES_AS_DATA_URI", "count": stats["images"],
                  "detail": "pictures are embedded as data URIs so the file is self-contained; some renderers (GitHub among them) do not display them"})
    if stats["comments"]:
        w.append({"code": "MD_COMMENTS_AS_QUOTES", "count": stats["comments"],
                  "detail": "annotations are block quotes in reading order, not attached to the text they mark"})
    if stats["_lettered"]:
        w.append({"code": "MD_LIST_MARKERS_AS_DIGITS", "count": stats["_lettered"],
                  "detail": "Markdown numbers lists with digits: lettered or roman markers (a., ii.) are written as 1., 2., …"})
    for k in ("_lost", "_header_flattened", "_spans", "_no_header", "_lettered"):
        stats.pop(k)
    stats.setdefault("images_downsampled", 0)
    stats.setdefault("images_downsampled_pages", [])
    stats["max_picture_dpi"] = MAX_PICTURE_DPI
    stats["dialect"] = "gfm"
    stats["images_mode"] = images
    stats["files"] = sorted(({k: v for k, v in f.items() if k != "page"} for f in written),
                            key=lambda f: f["relative_path"])
    return stats
