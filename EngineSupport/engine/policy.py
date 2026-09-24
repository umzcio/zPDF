"""Catalog plus native XFA guards, evaluated on each private revision."""

import pypdfium2.raw as raw

from .errors import EngineError


def inspect(doc, structure, diagnostics):
    try:
        acro, encrypted = structure.catalog()
    except (KeyError, TypeError, ValueError) as exc:
        raise EngineError("POLICY_INSPECTION_FAILED", "No usable document catalog.") from exc
    form_type = raw.FPDF_GetFormType(doc)
    xfa = "/XFA" in acro or form_type not in (raw.FORMTYPE_NONE, raw.FORMTYPE_ACRO_FORM)
    permissions = int(raw.FPDF_GetDocPermissions(doc))
    allowed = not xfa and not encrypted
    return {
        "catalog_has_xfa": "/XFA" in acro, "pdfium_form_type": form_type,
        "xfa_layout_supported": False, "encrypted": encrypted,
        "permissions": permissions, "form_edit_allowed": allowed,
        "allowed_operations": ["inspect_policy", "render", "search", "close"] +
                              (["fill", "annotate", "organize_pages", "save"] if allowed else []),
        "rendering_limitation": "Existing PDF fallback pages only; dynamic XFA layout unsupported." if xfa else None,
        "diagnostics": diagnostics,
        "write_block": "XFA_EDIT_BLOCKED" if xfa else ("UNSUPPORTED_ENCRYPTED_WRITE" if encrypted else None),
    }


def guard(verdict):
    if verdict["write_block"]:
        raise EngineError(verdict["write_block"], "This document is read-only under the v0 engine policy.")
