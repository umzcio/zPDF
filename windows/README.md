# zPDF for Windows (prototype)

A C# / WinUI 3 front end on the same engine as the Mac app
(`EngineSupport/`, PDFium + pikepdf/QPDF). Status: early prototype — open,
view, one engine edit (watermark) with undo, and Save As.

## Build and run

Requires Windows 10 1809 or later, the .NET 10 SDK and, for now, a
development Python with the engine's pinned libraries (the shipping app will
bundle its runtime as the Mac app does):

```powershell
py -3.13 -m venv C:\dev\venv-zpdf
C:\dev\venv-zpdf\Scripts\python -m pip install pikepdf==10.13.0.post1 pypdfium2==5.13.0 fonttools==4.66.0 cryptography==50.0.1 asn1crypto==1.5.1 pillow lxml
winget install QPDF.QPDF        # then set QPDF_BIN to qpdf.exe
cd windows\zPDF.Windows
dotnet build -p:Platform=x64
```

`ZPDF_PYTHON` and `ZPDF_ENGINE` override the Python and engine locations.

## Headless check

`zPDF.exe --selftest input.pdf outdir` renders page 1 with PDFium, adds a
watermark through the engine, renders again and saves a copy — no window
needed (used for checks over SSH).
