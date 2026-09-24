"""Whole-document transforms: one validated input file -> one validated output.

The frozen v0 facade (`engine/`) keeps ownership of form fills, its supported
comment edits and page composition. Everything else the app edits natively is
an operation here. Each call reads an immutable input, applies an ordered list
of operations with pikepdf (content, structure) and PDFium (text geometry,
rendering), serializes a private candidate and validates it before returning.
Nothing is published unless the whole list succeeds.
"""
from contextlib import contextmanager
from pathlib import Path
import hashlib
import importlib
import os
import tempfile

from engine.errors import EngineError, require

REGISTRY = {}
QUERIES = {}

# Every module in this package registers its operations/queries on import;
# adding a feature never requires editing this file.
_HELPERS = {"fonts"}


def op(name):
    def register(function):
        REGISTRY[name] = function
        return function
    return register


def query(name):
    """Read-only inspection returning plain data (never writes)."""
    def register(function):
        QUERIES[name] = function
        return function
    return register


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


class Context:
    """State shared by the operations of one transform call."""

    def __init__(self, pdf, source, workdir, password=None):
        self.pdf = pdf
        self.source = Path(source)
        self.workdir = Path(workdir)
        self.password = password
        self.results = []
        # Options consumed at serialization time (encryption, linearization...).
        self.save_options = {}
        self.expected_pages = None
        self._counter = 0

    def scratch(self, suffix=".pdf"):
        self._counter += 1
        return self.workdir / f"step-{self._counter}{suffix}"

    def snapshot(self):
        """Serialize the current state so PDFium can read it."""
        path = self.scratch()
        self.pdf.save(path)
        return path

    @contextmanager
    def pdfium(self):
        """A PDFium view of the current (possibly modified) document."""
        import pypdfium2 as pdfium
        path = self.snapshot()
        doc = pdfium.PdfDocument(str(path))
        try:
            yield doc
        finally:
            doc.close()

    def reload(self, path):
        """Replace the working document with a file produced by a helper."""
        import pikepdf
        replacement = pikepdf.open(path)
        self.pdf.close()
        self.pdf = replacement


def _load_modules():
    import pkgutil
    for info in pkgutil.iter_modules([str(Path(__file__).parent)]):
        if info.name not in _HELPERS and not info.name.startswith("_"):
            importlib.import_module(f"transforms.{info.name}")


def _validate(path, password, expected_pages):
    import pikepdf
    import pypdfium2 as pdfium
    try:
        with pikepdf.open(path, password=password or "") as check:
            count = len(check.pages)
    except pikepdf.PdfError as exc:
        raise EngineError("VALIDATION_FAILED", "The transformed PDF could not be read back.") from exc
    require(count > 0, "EMPTY_DOCUMENT", "A PDF must keep at least one page.")
    if expected_pages is not None:
        require(count == expected_pages, "VALIDATION_FAILED", "The transformed PDF has an unexpected page count.")
    doc = pdfium.PdfDocument(str(path), password=password)
    try:
        require(len(doc) == count, "VALIDATION_FAILED", "PDF readers disagree about the transformed page count.")
        for index in range(count):
            page = doc[index]
            page.get_textpage().close()
            page.close()
    finally:
        doc.close()
    return count


def run(source, destination, ops, password=None):
    """Apply `ops` to `source` and write a validated PDF to `destination`."""
    import pikepdf
    _load_modules()
    require(isinstance(ops, list) and ops, "INVALID_ARGUMENT", "At least one operation is required.")
    for item in ops:
        require(isinstance(item, dict) and item.get("op") in REGISTRY, "UNSUPPORTED_OPERATION",
                f"Unknown document operation: {item.get('op') if isinstance(item, dict) else item!r}.")
    destination = Path(destination)
    with tempfile.TemporaryDirectory(prefix="zpdf-transform-", dir=destination.parent) as workdir:
        try:
            pdf = pikepdf.open(source, password=password or "")
        except pikepdf.PasswordError as exc:
            raise EngineError("PASSWORD_REQUIRED", "This PDF needs its password.") from exc
        except pikepdf.PdfError as exc:
            raise EngineError("INVALID_PDF", "This file could not be read as a PDF.") from exc
        ctx = Context(pdf, source, workdir, password)
        try:
            for item in ops:
                params = {k: v for k, v in item.items() if k != "op"}
                try:
                    result = REGISTRY[item["op"]](ctx, **params)
                except TypeError as exc:
                    raise EngineError("INVALID_ARGUMENT", f"Invalid parameters for {item['op']}.") from exc
                ctx.results.append({"op": item["op"], **(result or {})})
            candidate = Path(workdir) / "candidate.pdf"
            options = dict(ctx.save_options)
            encryption = options.pop("encryption", None)
            if encryption is not None:
                options["encryption"] = encryption
            elif ctx.pdf.is_encrypted and options.pop("preserve_encryption", True):
                options["encryption"] = pikepdf.Encryption(owner=password or "", user=password or "", R=6) \
                    if password else False
            else:
                options.pop("preserve_encryption", None)
            ctx.pdf.save(candidate, **options)
        finally:
            ctx.pdf.close()
        validate_password = ctx.save_options.get("validate_password", password)
        if isinstance(encryption, pikepdf.Encryption):
            validate_password = encryption.user or encryption.owner
        pages = _validate(candidate, validate_password, ctx.expected_pages)
        os.replace(candidate, destination)
    return {"sha256": digest(destination), "bytes": destination.stat().st_size,
            "page_count": pages, "results": ctx.results}


def inspect(source, name, params=None, password=None):
    import pikepdf
    _load_modules()
    require(name in QUERIES, "UNSUPPORTED_OPERATION", f"Unknown document query: {name!r}.")
    try:
        pdf = pikepdf.open(source, password=password or "")
    except pikepdf.PasswordError as exc:
        raise EngineError("PASSWORD_REQUIRED", "This PDF needs its password.") from exc
    except pikepdf.PdfError as exc:
        raise EngineError("INVALID_PDF", "This file could not be read as a PDF.") from exc
    with tempfile.TemporaryDirectory(prefix="zpdf-query-") as workdir:
        ctx = Context(pdf, source, workdir, password)
        try:
            return QUERIES[name](ctx, **(params or {}))
        except TypeError as exc:
            raise EngineError("INVALID_ARGUMENT", f"Invalid parameters for {name}.") from exc
        finally:
            ctx.pdf.close()
