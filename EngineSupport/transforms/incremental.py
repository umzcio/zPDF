"""Append-only (incremental) PDF updates.

Signed PDFs must never be rewritten: a signature covers the exact bytes of
its revision. This writer snapshots every object of the opened document,
lets operations mutate the pikepdf model as usual, and then appends only
new or changed objects plus a cross-reference section whose /Prev points at
the previous one. The original bytes are copied verbatim, so every earlier
signature stays cryptographically intact.
"""
import hashlib
import os
import re
import zlib

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require

_SKIP_TYPES = ("/XRef", "/ObjStm")


def _fingerprint(obj):
    if isinstance(obj, pikepdf.Stream):
        h = hashlib.sha256(obj.stream_dict.unparse())
        h.update(obj.read_raw_bytes())
        return h.digest()
    return hashlib.sha256(obj.unparse(resolved=True)).digest()


def last_startxref(data):
    index = data.rfind(b"startxref")
    require(index >= 0, "INVALID_PDF", "The PDF has no cross-reference section.")
    match = re.match(rb"startxref\s+(\d+)", data[index:])
    require(match is not None, "INVALID_PDF", "The PDF cross-reference offset is unreadable.")
    return int(match.group(1))


def uses_xref_stream(data, offset):
    return not data[offset:offset + 4] == b"xref"


class Tracker:
    """Records the state of `pdf` (opened from `path`) before any edit."""

    def __init__(self, pdf, path):
        self.path = path
        self.pdf = pdf
        with open(path, "rb") as stream:
            self.base = stream.read()
        require(not pdf.is_encrypted, "UNSUPPORTED_OPERATION",
                "Encrypted signed documents cannot be updated incrementally.")
        self.prev = last_startxref(self.base)
        self.size = int(pdf.trailer.get("/Size", 0))
        self.snapshot = {}
        for obj in pdf.objects:
            if obj.is_indirect and not self._skipped(obj):
                try:
                    self.snapshot[obj.objgen] = _fingerprint(obj)
                except pikepdf.PdfError:
                    continue
        self.trailer_info = pdf.trailer.get("/Info")
        self.trailer_info_ref = self.trailer_info.objgen if self.trailer_info is not None and self.trailer_info.is_indirect else None
        self.root_ref = pdf.Root.objgen

    @staticmethod
    def _skipped(obj):
        return isinstance(obj, pikepdf.Stream) and str(obj.stream_dict.get("/Type", "")) in _SKIP_TYPES

    def changed_objects(self, pdf):
        changed = []
        for obj in pdf.objects:
            if not obj.is_indirect or self._skipped(obj):
                continue
            key = obj.objgen
            if key[0] == 0:
                continue
            before = self.snapshot.get(key)
            try:
                now = _fingerprint(obj)
            except pikepdf.PdfError:
                continue
            if before is None or before != now:
                changed.append(obj)
        return changed


def serialize(obj):
    number, generation = obj.objgen
    head = f"{number} {generation} obj\n".encode()
    if isinstance(obj, pikepdf.Stream):
        raw = obj.read_raw_bytes()
        info = pikepdf.Dictionary({k: v for k, v in obj.stream_dict.items()})
        info.Length = len(raw)
        return head + info.unparse() + b"\nstream\n" + raw + b"\nendstream\nendobj\n"
    return head + obj.unparse(resolved=True) + b"\nendobj\n"


def _subsections(numbers):
    groups = []
    for number in sorted(numbers):
        if groups and number == groups[-1][0] + groups[-1][1]:
            groups[-1][1] += 1
        else:
            groups.append([number, 1])
    return groups


def write(pdf, tracker, destination, overrides=None, extra_trailer=None):
    """Append changed objects of `pdf` to the tracked original bytes.

    `overrides` maps objgen -> exact serialized bytes (used for signature
    dictionaries whose /Contents and /ByteRange are patched afterwards).
    Returns {"offsets": {objgen: offset}, "length": total bytes}.
    """
    require(pdf is tracker.pdf, "SIGNED_DOCUMENT",
            "This change would rewrite a signed document and invalidate its signatures.")
    overrides = overrides or {}
    objects = tracker.changed_objects(pdf)
    require(all(obj.objgen[0] >= tracker.size or obj.objgen in tracker.snapshot for obj in objects),
            "VALIDATION_FAILED", "An incremental update would reuse an object number.")
    known = {obj.objgen for obj in objects}
    for key in overrides:
        if key not in known:
            objects.append(pdf.get_object(key))
    base = tracker.base
    out = bytearray(base)
    if not out.endswith(b"\n"):
        out += b"\n"
    offsets = {}
    for obj in sorted(objects, key=lambda o: o.objgen):
        offsets[obj.objgen] = len(out)
        out += overrides.get(obj.objgen) or serialize(obj)
    max_number = max([tracker.size - 1] + [n for n, _ in offsets])
    trailer = pikepdf.Dictionary()
    trailer.Root = pdf.Root
    info = pdf.trailer.get("/Info")
    if info is not None:
        trailer.Info = info
    original_id = pdf.trailer.get("/ID")
    first = bytes(original_id[0]) if original_id is not None and len(original_id) == 2 else os.urandom(16)
    trailer.ID = pikepdf.Array([pikepdf.String(first), pikepdf.String(os.urandom(16))])
    trailer.Prev = tracker.prev
    for key, value in (extra_trailer or {}).items():
        trailer[key] = value
    if uses_xref_stream(base, tracker.prev):
        xref_number = max_number + 1
        xref_offset = len(out)
        entries = dict(offsets)
        entries[(xref_number, 0)] = xref_offset
        rows = bytearray()
        numbers = sorted(n for n, _ in entries)
        by_number = {n: (g, off) for (n, g), off in entries.items()}
        for number in numbers:
            generation, offset = by_number[number]
            rows += bytes([1]) + offset.to_bytes(4, "big") + generation.to_bytes(2, "big")
        index = []
        for start, count in _subsections(numbers):
            index += [start, count]
        data = zlib.compress(bytes(rows))
        info = pikepdf.Dictionary(trailer)
        info.Type = Name.XRef
        info.Size = xref_number + 1
        info.W = pikepdf.Array([1, 4, 2])
        info.Index = pikepdf.Array(index)
        info.Filter = Name.FlateDecode
        info.Length = len(data)
        out += f"{xref_number} 0 obj\n".encode() + info.unparse() + b"\nstream\n" + data + b"\nendstream\nendobj\n"
        out += f"startxref\n{xref_offset}\n%%EOF\n".encode()
    else:
        xref_offset = len(out)
        out += b"xref\n"
        by_number = {n: (g, off) for (n, g), off in offsets.items()}
        for start, count in _subsections(by_number):
            out += f"{start} {count}\n".encode()
            for number in range(start, start + count):
                generation, offset = by_number[number]
                out += f"{offset:010d} {generation:05d} n\r\n".encode()
        trailer.Size = max_number + 1
        out += b"trailer\n" + trailer.unparse() + b"\n"
        out += f"startxref\n{xref_offset}\n%%EOF\n".encode()
    with open(destination, "wb") as stream:
        stream.write(out)
    return {"offsets": offsets, "length": len(out), "bytes": out}


def is_signed(pdf):
    """True when any signature field carries a signature value."""
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return False
    stack = list(acro.get("/Fields", []))
    seen = set()
    while stack:
        field = stack.pop()
        if not isinstance(field, pikepdf.Dictionary):
            continue
        key = field.objgen if field.is_indirect else id(field)
        if key in seen:
            continue
        seen.add(key)
        value = field.get("/V")
        if str(field.get("/FT", "")) == "/Sig" and isinstance(value, pikepdf.Dictionary) and "/ByteRange" in value:
            return True
        stack.extend(field.get("/Kids", []))
    return False
