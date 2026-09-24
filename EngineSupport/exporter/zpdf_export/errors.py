"""Structured export errors with stable codes (spec section 6.3)."""
from __future__ import annotations

from typing import Any

CODES = {
    "INVALID_REQUEST",
    "PROTOCOL_MISMATCH",
    "SOURCE_CHANGED",
    "POLICY_BLOCKED",
    "BAD_PDF",
    "UNSUPPORTED_FORMAT",
    "UNSUPPORTED_OPTION",
    "OCR_REQUIRED",
    "PARTIAL_CONTENT",
    "RESOURCE_LIMIT",
    "BACKEND_MISSING",
    "WORKER_FAILED",
    "OUTPUT_INVALID",
    "WRITE_FAILED",
    "CANCELLED",
}


class ExportError(Exception):
    """An error with a stable code, a message key, and safe arguments.

    ``args_`` must never contain document text or filesystem paths; the
    coordinator logs and localizes from the code and key alone.
    """

    def __init__(self, code: str, message_key: str, *, page: int | None = None,
                 object_id: str | None = None, **args_: Any) -> None:
        if code not in CODES:
            raise ValueError(f"unknown error code {code!r}")
        super().__init__(f"{code}:{message_key}")
        self.code = code
        self.message_key = message_key
        self.page = page
        self.object_id = object_id
        self.args_ = args_

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"code": self.code, "message_key": self.message_key}
        if self.args_:
            out["args"] = dict(self.args_)
        if self.page is not None:
            out["page"] = self.page
        if self.object_id is not None:
            out["object_id"] = self.object_id
        return out
