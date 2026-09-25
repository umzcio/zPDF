"""PDF Portfolios (collections): embedded files plus a /Collection dictionary,
with a readable cover page for viewers without portfolio support."""
from datetime import datetime, timezone
import mimetypes
from pathlib import Path

import pikepdf
from pikepdf import Name

from engine.errors import require
from transforms import op, query
from transforms.content import form_xobject, place_form, visual_matrix, visual_size
from transforms.fonts import EmbeddedFont


@op("create_portfolio")
def create_portfolio(ctx, files, title="Portfolio", view="D", cover=True):
    """files: [{"path", "name"?, "description"?}]. Embeds each file and marks
    the document as a portfolio. The first page becomes a cover sheet."""
    pdf = ctx.pdf
    require(isinstance(files, list) and files, "INVALID_ARGUMENT", "Choose files for the portfolio.")
    require(view in ("D", "T", "H"), "INVALID_ARGUMENT", "Unknown portfolio view.")
    names = []
    for item in files:
        spec = item if isinstance(item, dict) else {"path": item}
        path = Path(spec.get("path", ""))
        require(path.is_file(), "INVALID_ARGUMENT", "A portfolio file could not be found.")
        name = spec.get("name") or path.name
        base, n = name, 2
        while name in pdf.attachments:
            stem, dot, ext = base.rpartition(".")
            name = f"{stem or base} ({n}){dot}{ext}" if dot else f"{base} ({n})"
            n += 1
        mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
        attached = pikepdf.AttachedFileSpec(pdf, path.read_bytes(), description=spec.get("description", ""),
                                            filename=name, mime_type=mime,
                                            mod_date=datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
                                            .strftime("D:%Y%m%d%H%M%SZ"))
        pdf.attachments[name] = attached
        names.append(name)
    pdf.Root.Collection = pikepdf.Dictionary(Type=Name.Collection, View=Name("/" + view))
    if pdf.attachments:
        pdf.Root.Collection.D = pikepdf.String(names[0])
    if cover and len(pdf.pages):
        page = pdf.pages[0]
        font = EmbeddedFont(pdf, {"family": "sans"})
        vw, vh = visual_size(page)
        lines = [(str(title), 22), ("", 10), (f"This PDF Portfolio contains {len(names)} file(s):", 12)]
        lines += [("•  " + n, 11) for n in names[:40]]
        if len(names) > 40:
            lines.append((f"…and {len(names) - 40} more", 11))
        lines += [("", 10), ("Open the Attachments list to view each file.", 10)]
        ops, y = ["0.1 0.1 0.1 rg", "BT"], vh - 72
        for text, size in lines:
            if text:
                ops.append(f"/F1 {size} Tf 1 0 0 1 72 {y:.2f} Tm {font.encode(text)} Tj")
            y -= size * 1.5
        ops.append("ET")
        form = form_xobject(pdf, "\n".join(ops).encode(), (0, 0, vw, vh),
                            pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font.ref)), "PortfolioCover")
        place_form(pdf, page, form, visual_matrix(page), prefix="ZPDFpc")
        font.finish()
    return {"files": names}


@query("embedded_files")
def embedded_files(ctx):
    pdf = ctx.pdf
    out = []
    for name, spec in pdf.attachments.items():
        try:
            file = spec.get_file()
            size = file.size
            mime = file.mime_type
            modified = file.mod_date.astimezone(timezone.utc).isoformat() if file.mod_date else None
        except (pikepdf.PdfError, ValueError, AttributeError):
            size, mime, modified = None, None, None
        out.append({"name": name, "description": spec.description or "", "size": size, "mime": mime or "",
                    "modified": modified})
    collection = pdf.Root.get("/Collection")
    return {"files": out, "portfolio": isinstance(collection, pikepdf.Dictionary),
            "view": str(collection.get("/View", "/D"))[1:] if isinstance(collection, pikepdf.Dictionary) else None}


@query("extract_embedded")
def extract_embedded(ctx, name, directory):
    """Write one embedded file into the app's private `directory`."""
    pdf = ctx.pdf
    require(name in pdf.attachments, "NOT_FOUND", "That embedded file is no longer in this document.")
    target = Path(directory)
    require(target.is_dir(), "INVALID_ARGUMENT", "The destination folder is unavailable.")
    safe = "".join(c for c in Path(name).name if c not in "/\\:\0") or "attachment"
    path = target / safe
    path.write_bytes(pdf.attachments[name].get_file().read_bytes())
    return {"path": str(path)}
