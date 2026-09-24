# App export integration

The app vendors the unchanged `zpdf_export` package from
umzcio/zPDF-exporter commit `2f0e4fd7e8574097344934628ed4b788804e4c2c`.
`exporter/provenance.json` records each source hash; the build verifies them.
Changes to reconstruction belong in that upstream repo and require an explicit
pin update here. No sibling checkout, installed Python, Office app, or network
service is required at runtime.

`exporter/wheels.json` pins CPython 3.13 macOS arm64-compatible dependencies by
URL and SHA256. Python/PDFium are shared with the existing Save runtime. New
runtime packages: python-docx 1.2.0 (MIT), lxml 6.1.3 (BSD-3-Clause with bundled
libxml2/libxslt notices), typing_extensions 4.16.0 (PSF-2.0), Pillow 12.3.0
(MIT-CMU and bundled library notices), openpyxl 3.1.5 and et-xmlfile 2.0.0 (MIT).
All wheel metadata/license directories are retained in the app. The upstream
THIRD_PARTY_NOTICES copy predates XLSX and incorrectly calls Pillow development
only; this file records the actual shipped set. Office fonts are not copied.
The worker can measure using macOS Supplemental fonts when Word is absent.

The app captures current edits into an isolated PDF through the native Save
bridge, reads worker capabilities, then speaks export protocol v1 over private
pipes. The editing facade is unchanged. Hashes and sizes are checked for the
primary artifact and every Markdown image. Extra staging entries, links outside
the expected folder and symlinks are rejected. The destination is never passed
to the worker. XFA/encrypted policy remains blocked. Source bytes, document
ownership, dirty state and Undo history are unchanged by export.

Limits: 512 MB snapshot; 500 selected pages; 15-minute worker wall/CPU limits;
1 GB per output file; 3 GB resident-memory watchdog; 32 MB maximum protocol
reply. Worker stderr is not logged. Cancel closes stdin and stops the child with
bounded TERM/KILL cleanup; app-owned staging is removed before returning. During
native snapshot preparation cancellation waits for that existing Save command
to finish, then prevents conversion/publication. Publication is guarded so a
late cancellation cannot report an already-published export as canceled.

Markdown uses a fresh destination-derived image folder for each export. The app
moves that folder first, then atomically replaces/moves the Markdown document;
if document publication fails it removes only the newly moved folder. Existing
asset folders are never deleted. Replacing a Markdown document can therefore
leave its old image folder; this avoids deleting shared/user-owned images.
Both items must travel together when sharing. A sudden machine/process crash
between the two moves can leave an unused image folder, but never a newly
published Markdown file with missing pictures. This is not a filesystem-wide
multi-file atomic transaction.

The upstream handoff has a stale failure-table row claiming HTML/Markdown are
unsupported. The pinned worker capabilities and actual format tests are the
source of truth. Known conversion/reader limits remain those of the pinned
exporter; integration is not an Acrobat-parity guarantee. Windows is unverified.
