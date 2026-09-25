# Document transforms (native editing layer)

Everything the app edits that the frozen v0 facade (`engine/`) does not own is
a **transform**: an ordered list of JSON operations applied to an immutable
input PDF, producing a new validated PDF. The facade still owns form fills,
its supported comment edits and page composition.

## How edits flow

```
PDFKit display copy ──(SaveBaseline.changes)──► NativeSaveChanges
                                                  ├─ annotationItems (generic, via scratch PDF)
                                                  └─ facade edits (fields, notes, pages…)
DocumentTab.editSource (immutable working revision on disk)

Immediate operation (redact, watermark, edit text…):
  AppState.applyDocumentTransform(ops, to: tab, actionName:)
    = materialize pending edits + run ops  → new revision → PDFKit reload
    → one Undo step (Undo restores the previous revision) → tab is dirty

Save:
  NativeSaveBridge.save(editSource, changes) → user's file (atomic, coordinated)
```

* Never write the user's file outside Save/Save As/export destinations.
* Every op fails closed: an `EngineError` aborts the whole list; nothing is
  published. Validation re-opens the candidate with pikepdf and PDFium.
* Transforms run in the bundled sandboxed helper (`serve.py`, commands
  `transform`, `query`, `publish`). The bundled interpreter cannot run outside
  the app sandbox; develop/test engine code with a dev venv that has the same
  pinned wheels (`pikepdf`, `pypdfium2`, `fonttools`, `Pillow`, `lxml`):

  ```sh
  uv venv --python 3.13 .venv-dev   # any location outside the repo is fine
  uv pip install --python .venv-dev/bin/python pikepdf==10.13.0.post1 pypdfium2==5.13.0 fonttools==4.66.0 pillow lxml
  .venv-dev/bin/python scripts/test_transforms.py
  ```

## Writing an operation

Create or extend a module in `EngineSupport/transforms/` (auto-discovered):

```python
from transforms import op, query
from engine.errors import require

@op("my_operation")           # {"op": "my_operation", ...params}
def my_operation(ctx, pages=None, text="x"):
    pdf = ctx.pdf             # pikepdf.Pdf, mutate in place
    ...
    return {"changed": 3}     # JSON-safe; returned to Swift in results

@query("my_query")            # read-only; returns JSON-safe dict
def my_query(ctx, page=0):
    return {"items": [...]}
```

Useful context helpers: `ctx.pdfium()` (context manager → PDFium view of the
current state, for text geometry/rendering), `ctx.reload(path)` (replace the
working document with a file you produced), `ctx.save_options` (pikepdf save
kwargs such as `encryption`, `linearize`), `ctx.expected_pages`.

Shared helpers: `transforms.content` (page boxes, rotation-aware
`visual_matrix`, `add_content`, `form_xobject`, `place_form`,
`remove_overlays`, `stamp_appearances`, `image_xobject`, `text_form`,
`select_pages`, `anchored`), `transforms.fonts.EmbeddedFont` (Unicode text
with subset embedding + ToUnicode; call `.finish()` once before save).

Overlays the app adds are Form XObjects tagged `/ZPDFKind` in their own
content stream so they can be removed/replaced later.

Private dictionary keys start with `/ZPDF` and are stripped by `finalize`.

## Swift side

```swift
// Immediate edit with Undo:
try await appState.applyDocumentTransform([["op": "watermark", "text": "DRAFT"]],
                                           to: tab, actionName: "Add Watermark")
// Fire-and-forget with standard error alert:
appState.runDocumentTransform(ops, actionName: "…")
// Read-only:
let info = try await appState.queryDocument("bookmarks", in: tab)
```

Tests: engine regressions in `scripts/test_transforms.py` (fast, dev venv);
app integration tests in `zPDFTests/` using `TestSupport` (real bundled
engine). Editable fixture: `uscis-i9` (AcroForm), `ordinary-edge`,
`irs-1040-worksheet-b`. `irs-w9` is hybrid XFA and therefore read-only in the
app (transforms themselves can still read it).

## Forms, security and signatures

* `forms.py` — AcroForm authoring (`add_form_field`, `update_form_field`,
  `delete_form_field`, `duplicate_form_field`, `set_tab_order`,
  `set_calculation_order`), filling (`fill_fields` by name, `fill_widgets` by
  PDFKit page/annotation index), `reset_form`, `recalculate`,
  `flatten_form_fields`, `convert_xfa_form`, `prune_fields`, and the queries
  `form_fields`, `form_calculate`, `widget_kinds`. Appearances come from
  `appearance.py`; format/validate/calculate scripts are interpreted by
  `formcalc.py` (Acrobat AF* functions and Simplified Field Notation only —
  no JavaScript is executed).
* `security.py` — encrypted PDFs are edited through a decrypted private
  revision carrying a non-secret `/ZPDFSecurity` marker; `apply_security`
  (run by `ProtectedSaveBridge` when writing a destination) preserves the
  original encryption, applies new AES-256/128 password security, or removes it.
* `signatures.py` + `cms.py` — PAdES/CMS signing (`sign`), `add_ltv`,
  `extract_signed_revision`, `clear_signature`, validation query `signatures`.
* `incremental.py` — ops declared `@op(..., incremental=True)`, and every op
  run on an already signed input, are appended as an incremental update so
  existing signatures keep covering their bytes. Ops declared `rewrite=True`
  (encryption, signature removal) opt out. An op may also install
  `ctx.save_options["writer"]` to write the candidate itself.
* `fill_sign.py` — signature/initials image stamps and simple notes used by
  append-only saves of signed documents.
