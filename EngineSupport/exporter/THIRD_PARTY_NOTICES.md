# Third-party notices

Runtime dependencies (pinned in `pyproject.toml`). All are no-cost, permissively
licensed, and redistributable with notice retention. No AGPL, commercial, or
metered dependency is used. License texts ship inside each wheel's
`*.dist-info/licenses/` directory and must be retained when packaging.

| Package | Version | License | Notes |
|---|---|---|---|
| pypdfium2 | 5.13.0 | BSD-3-Clause OR Apache-2.0 (bindings); PDFium itself BSD-3-Clause; docs CC-BY-4.0 | Bundles `libpdfium.dylib` 153.0.7999.0 from pdfium-binaries (bblanchon). Same PDFium build the zPDF app pins. |
| python-docx | 1.2.0 | MIT | DOCX package writer. |
| lxml | 6.1.3 | BSD-3-Clause (bundles libxml2/libxslt, MIT) | Transitive via python-docx; native wheel per platform. |
| typing_extensions | 4.16.0 | PSF-2.0 | Transitive via python-docx. |

Development-only (not shipped): reportlab 4.4.3 (BSD) and pillow 12.3.0
(MIT-CMU) generate the synthetic fixtures; pytest 9.0.2 (MIT) runs tests.

Fixture provenance and usage rights are recorded in `fixtures/manifest.json`.
Microsoft Word is used only to verify output on the authorized Mac; it is not a
conversion backend.
