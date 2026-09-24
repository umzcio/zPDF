# zPDF

Native macOS PDF application built with Swift 6, SwiftUI, AppKit and PDFKit.
PDFium and QPDF provide the bundled Save engine. A pinned local export worker
supports DOCX, XLSX, HTML (preserved layout or responsive reading), and Markdown.

## Build and test

Requires an Apple Silicon Mac, macOS 15 or later, Xcode, and XcodeGen.

```sh
brew install xcodegen gitleaks
python3 scripts/install_git_hooks.py
xcodegen generate
xcodebuild -project zPDF.xcodeproj -scheme zPDF -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/SaveSlice test
```

`project.yml` is the source of truth; the Xcode project is generated and ignored.
The first build downloads checksum-pinned Python/PDFium and exporter dependencies;
subsequent builds reuse the local cache. The running app uses its bundled runtime.
See [engine packaging](EngineSupport/README.md) and
[export integration](EngineSupport/EXPORTER.md) for dependencies and limitations.

## Current scope

Document navigation, search, annotations, existing form filling, reviewed field
detection/manual field creation, page organization, combine/extract/split,
lossless compression, recovery, and document exports are implemented.
True editing of existing page text/images and permanent redaction are not yet
supported. Hybrid XFA editing and encrypted writes remain blocked.

Exports have format-specific limitations; they are not guaranteed 1:1 conversions.
Windows is unverified; packaging currently targets macOS arm64.

## Repository privacy

Read [PRIVACY.md](PRIVACY.md) before adding files. Local documents, internal
planning notes, screenshots, test evidence, credentials, generated output, and
legacy development history are excluded from publication. Only reviewed public
or synthetic fixture PDFs belong in the repository.
