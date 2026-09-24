# IRS Worksheet B fixture

Page 47 extracted from the public US government 2025 Form 1040 instructions.
Source: https://www.irs.gov/pub/irs-pdf/i1040gi.pdf
Downloaded 2026-09-19 according to zPDF-exporter/fixtures/manifest.json.
Source SHA-256: 482e9c487c608f1bbeaceef35bc3c0933e8b35443cfff447e4279d590468364a
Derived SHA-256: 1d0dd7b2d428ea250983631b3fc49f1165dab6514c5ba8ce352d1788543d63e7

Created 2026-09-20 with QPDF 12.4.1:
`qpdf source.pdf --pages . 47 -- --recompress-flate irs-1040-worksheet-b.pdf`
QPDF re-encodes the source's stream with trailing encoded bytes. The source was
not modified. The derived page contains no interactive fields; test expectations
are eleven blank amount boxes and two checkboxes.
