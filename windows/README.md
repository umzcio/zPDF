# zPDF for Windows (prototype)

A C# / WinUI 3 front end on the same engine as the Mac app
(`EngineSupport/`, PDFium + pikepdf/QPDF). Status: early prototype — open,
view (zoom, page thumbnails), one engine edit (watermark) with undo, and
Save As.

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

## Headless check

`zPDF.exe --selftest input.pdf outdir` renders page 1 with PDFium, adds a
watermark through the engine, renders again and saves a copy — no window
needed (used for checks over SSH). It prints whether the bundled engine ran.
