"""Minimal dependency-free PNG encoder for PDFium bitmaps."""
from __future__ import annotations

import struct
import zlib


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def encode_png(width: int, height: int, rows_rgb_or_rgba, has_alpha: bool) -> bytes:
    """rows: iterable of bytes-like rows, each width*channels bytes (RGB or RGBA)."""
    color_type = 6 if has_alpha else 2
    raw = bytearray()
    for row in rows_rgb_or_rgba:
        raw.append(0)  # filter: none
        raw.extend(row)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + _chunk(b"IEND", b""))


def bitmap_to_png(buffer, width: int, height: int, stride: int, fmt: str,
                  rev_byteorder: bool) -> bytes:
    """Convert a PDFium bitmap buffer to PNG.

    fmt is one of 'BGR', 'BGRA', 'BGRx', 'Gray' (pypdfium2 naming). With
    rev_byteorder the channel order is RGB(A/x) instead.
    """
    mv = memoryview(buffer).cast("B") if not isinstance(buffer, (bytes, bytearray)) else memoryview(buffer)
    rows = []
    if fmt == "Gray":
        for y in range(height):
            row = mv[y * stride:y * stride + width]
            out = bytearray(width * 3)
            out[0::3] = row; out[1::3] = row; out[2::3] = row
            rows.append(bytes(out))
        return encode_png(width, height, rows, False)
    nch = 3 if fmt == "BGR" else 4
    has_alpha = fmt == "BGRA"
    for y in range(height):
        row = mv[y * stride:y * stride + width * nch]
        if rev_byteorder:
            r, g, b = row[0::nch], row[1::nch], row[2::nch]
        else:
            b, g, r = row[0::nch], row[1::nch], row[2::nch]
        if has_alpha:
            out = bytearray(width * 4)
            out[0::4] = r; out[1::4] = g; out[2::4] = b; out[3::4] = row[3::nch]
        else:
            out = bytearray(width * 3)
            out[0::3] = r; out[1::3] = g; out[2::3] = b
        rows.append(bytes(out))
    return encode_png(width, height, rows, has_alpha)
