# zPDF for Windows (prototype)

A C# / WinUI 3 front end on the same engine as the Mac app
(`EngineSupport/`, PDFium + pikepdf/QPDF). Status: preview — viewing, comments,
forms, pages, protection and redaction, signing, OCR, conversion and export,
accessibility, print production and batch processing; see `PARITY.md` for the
feature-by-feature state against the Mac app.

Each window holds document tabs; one tab is a `DocumentPane` (the
`DocumentPane*.cs` partials, grouped by area), and `MainWindow` only hosts them.

## Build and run

Requires Windows 10 1809 or later, the .NET 10 SDK and any Python 3.9+ (only
to run the build script):

```powershell
py windows\scripts\prepare_runtime.py      # once: bundled engine runtime
cd windows\zPDF.Windows
dotnet build -p:Platform=x64
```

`prepare_runtime.py` builds `windows\build\EngineRuntime` — the same
python-build-standalone CPython release and package versions as the Mac app
(`runtime-wheels.json`) plus QPDF's official Windows build, each checked against
its published SHA-256. The build copies it next to `zPDF.exe`; the app then
needs no Python or QPDF installed. Without it, the app falls back to a
development Python (`ZPDF_PYTHON`, `ZPDF_ENGINE`, `QPDF_BIN`).

## Checks

- `zPDF.exe --selftest input.pdf outdir` — headless (works over SSH): PDFium
  rendering, forms, a signature, text diff, Word export, OCR with scan cleanup,
  and an engine edit saved through the publish path. It prints whether the
  bundled engine ran.
- `zPDF.exe --printtest input.pdf out.pdf` — prints every page through
  "Microsoft Print to PDF" without a dialog.
- `zPDF.exe --uitest input.pdf log.txt` — opens a real window and drives it
  (edit, undo, redo, measure, checkbox keyboard focus, tabs, preflight), writing
  PASS/FAIL lines; the exit code is the number of failures. Needs a desktop
  session (WinUI can't start over SSH).

Unexpected errors are logged to `%APPDATA%\zPDF\errors.log`; settings, saved signatures and digital IDs live in the same folder (not `%LOCALAPPDATA%\zPDF`, which is the installed app).
