"""Read-only snapshot access: identity verification and export policy.

The helper never writes to the snapshot. It verifies the coordinator-supplied
SHA-256 before touching PDFium and applies the engine's blocking policy:
XFA (full or hybrid) and encrypted documents are refused.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

import pypdfium2 as pdfium
import pypdfium2.raw as raw

from .errors import ExportError

_XFA_REASONS = {
    raw.FORMTYPE_XFA_FULL: "xfa_full",
    raw.FORMTYPE_XFA_FOREGROUND: "xfa_foreground",
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class Snapshot:
    path: Path
    sha256: str
    pdf: pdfium.PdfDocument
    form_type: int
    page_count: int = field(init=False)

    def __post_init__(self) -> None:
        self.page_count = len(self.pdf)

    @property
    def has_acroform(self) -> bool:
        return self.form_type == raw.FORMTYPE_ACRO_FORM

    def close(self) -> None:
        self.pdf.close()


def open_snapshot(path: Path, expected_sha256: str) -> Snapshot:
    path = Path(path)
    if not path.is_file():
        raise ExportError("BAD_PDF", "snapshot_missing")
    actual = sha256_file(path)
    if actual.lower() != expected_sha256.lower():
        raise ExportError("SOURCE_CHANGED", "snapshot_hash_mismatch")
    try:
        pdf = pdfium.PdfDocument(str(path))
    except pdfium.PdfiumError as exc:
        err = raw.FPDF_GetLastError()
        if err == raw.FPDF_ERR_PASSWORD:
            raise ExportError("POLICY_BLOCKED", "encrypted_export_blocked",
                              reason="encrypted") from exc
        raise ExportError("BAD_PDF", "snapshot_unparseable") from exc
    form_type = raw.FPDF_GetFormType(pdf)
    if form_type in _XFA_REASONS:
        pdf.close()
        raise ExportError("POLICY_BLOCKED", "xfa_export_blocked",
                          reason=_XFA_REASONS[form_type])
    if form_type == raw.FORMTYPE_ACRO_FORM:
        pdf.init_forms()
    return Snapshot(path=path, sha256=actual, pdf=pdf, form_type=form_type)
