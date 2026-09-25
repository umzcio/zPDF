import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a new PDF comes from (Acrobat's Create PDF sources).
enum CreatePDFSource: String, CaseIterable, Identifiable {
    case files, web, clipboard, scanner, blank, portfolio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: "Files"
        case .web: "Web Page"
        case .clipboard: "Clipboard"
        case .scanner: "Scanner"
        case .blank: "Blank Page"
        case .portfolio: "Portfolio"
        }
    }
    var symbolName: String {
        switch self {
        case .files: "doc.on.doc"
        case .web: "globe"
        case .clipboard: "doc.on.clipboard"
        case .scanner: "scanner"
        case .blank: "doc"
        case .portfolio: "folder"
        }
    }
    var help: String {
        switch self {
        case .files: "Images, Word/RTF/text documents, HTML, spreadsheets, presentations and PDFs"
        case .web: "Convert a web page or HTML file, paginated with its print styles"
        case .clipboard: "Use the image, PDF or text on the clipboard"
        case .scanner: "Scan paper with a scanner or your iPhone"
        case .blank: "A new PDF with blank pages"
        case .portfolio: "Bundle files of any type in one PDF Portfolio"
        }
    }
}

/// Tool panel: one entry per source; each opens the Create PDF dialog.
struct CreatePDFPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Create from") {
                PanelToolGrid {
                    ForEach(CreatePDFSource.allCases) { source in
                        PanelToolButton(title: source.title, symbolName: source.symbolName, isActive: false) {
                            if source == .clipboard {
                                Task { _ = await appState.createPDFFromClipboard() }
                            } else if source == .scanner {
                                appState.present(.scanner)
                            } else {
                                appState.present(.createPDF(source))
                            }
                        }
                        .help(source.help)
                    }
                }
            }
            PanelSection(title: "Import from iPhone or iPad") {
                ContinuityCameraButton { pasteboard in
                    Task { _ = await appState.createPDFFromClipboard(pasteboard) }
                }
                .frame(height: 24)
            }
            PanelNote("New PDFs open as untitled documents. Save chooses where they go; nothing is written until then.")
            PanelNote("Word, RTF and text documents convert with macOS's text engine (fonts, styles, tables and images; not headers, footers or footnotes). Spreadsheets and presentations become a picture of their first sheet or slide.")
        }
    }
}

/// Create PDF dialog for files, web pages, blank documents and portfolios.
struct CreatePDFSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var source: CreatePDFSource
    @State private var files: [URL] = []
    @State private var address = ""
    @State private var paper: PaperSize = .letter
    @State private var landscape = false
    @State private var pageCount = 1
    @State private var width = 612.0
    @State private var height = 792.0
    @State private var unit: MeasurementUnit = .inches
    @State private var imagePaper: PaperSize = .matchCurrent
    @State private var imageFit = "fit"
    @State private var title = "Portfolio"
    @State private var busy = false

    init(initialSource: CreatePDFSource) {
        _source = State(initialValue: initialSource == .clipboard || initialSource == .scanner ? .files : initialSource)
    }

    private static let sources: [CreatePDFSource] = [.files, .web, .blank, .portfolio]

    private var webURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "file"].contains(scheme.lowercased()) { return url }
        return URL(string: "https://" + trimmed)
    }

    private var ready: Bool {
        switch source {
        case .files: !files.isEmpty
        case .web: webURL != nil || !files.isEmpty
        case .portfolio: !files.isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty
        case .blank: pageCount >= 1
        default: false
        }
    }

    var body: some View {
        WorkflowSheetFrame(title: "Create PDF", subtitle: source.help, primaryTitle: "Create",
                           primaryDisabled: !ready, busy: busy, busyLabel: "Creating…", width: 540, primary: create) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                Picker("Source", selection: $source) {
                    ForEach(Self.sources) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: source) { _, _ in files = [] }
                switch source {
                case .files: filesContent
                case .web: webContent
                case .blank: blankContent
                case .portfolio: portfolioContent
                default: EmptyView()
                }
            }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(files.enumerated()), id: \.element) { index, url in
                HStack(spacing: 6) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(DesignTokens.Colors.mutedText)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { files.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("Move up").accessibilityLabel("Move \(url.lastPathComponent) up")
                    Button { files.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == files.count - 1).help("Move down").accessibilityLabel("Move \(url.lastPathComponent) down")
                    Button { files.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .help("Remove").accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .background(DesignTokens.Colors.inset)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .dropDestination(for: URL.self) { urls, _ in
            files += urls.filter { $0.isFileURL }
            return true
        }
    }

    private var filesContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            if files.isEmpty {
                Text("Choose or drop files. Each becomes pages of one new PDF, in this order.")
                    .font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            fileList
            HStack {
                Button("Add Files…") {
                    files += FilePicker.choose(types: SourceKind.allTypes, multiple: true, title: "Create PDF", prompt: "Add")
                }
                .help("Images, documents, spreadsheets, presentations, HTML or PDFs")
                Spacer()
            }
            if files.contains(where: PageFileKind.isImage) {
                WorkflowRow(label: "Image pages:", labelWidth: 100) {
                    HStack {
                        Picker("Image page size", selection: $imagePaper) {
                            Text("Size of each image").tag(PaperSize.matchCurrent)
                            ForEach(PaperSize.fixed.filter { $0 != .custom }) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                        if imagePaper != .matchCurrent {
                            Picker("Fit", selection: $imageFit) {
                                Text("Fit").tag("fit"); Text("Fill").tag("fill"); Text("Actual size").tag("actual")
                            }.labelsHidden().fixedSize()
                        }
                    }
                }
            }
            if files.contains(where: { SourceKind.of($0) == .preview }) {
                WorkflowStatus(text: "Spreadsheets and presentations are converted from their Quick Look preview (first sheet or slide, as an image).")
            }
        }
    }

    private var webContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            WorkflowRow(label: "Web address:", labelWidth: 100) {
                TextField("https://example.com", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if ready { create() } }
                    .accessibilityLabel("Web page address")
            }
            WorkflowRow(label: "Or HTML file:", labelWidth: 100) {
                HStack {
                    Text(files.first?.lastPathComponent ?? "None").foregroundStyle(DesignTokens.Colors.mutedText)
                    Button("Choose…") { files = FilePicker.choose(types: SourceKind.webTypes, multiple: false, title: "Convert HTML") }
                }
            }
            Text("Pages paginate with the site's print styles on US Letter paper. Pages that need a login may not convert.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private var blankContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            WorkflowRow(label: "Page size:", labelWidth: 100) {
                Picker("Page size", selection: $paper) {
                    ForEach(PaperSize.fixed) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }
            if paper == .custom {
                WorkflowRow(label: "Dimensions:", labelWidth: 100) {
                    HStack(spacing: 8) {
                        PointsField(label: "Width", points: $width, unit: unit)
                        Text("×").foregroundStyle(DesignTokens.Colors.mutedText)
                        PointsField(label: "Height", points: $height, unit: unit)
                        Picker("Unit", selection: $unit) { ForEach(MeasurementUnit.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                }
            }
            WorkflowRow(label: "Orientation:", labelWidth: 100) {
                Picker("Orientation", selection: $landscape) {
                    Label("Portrait", systemImage: "rectangle.portrait").tag(false)
                    Label("Landscape", systemImage: "rectangle").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            WorkflowRow(label: "Pages:", labelWidth: 100) {
                Stepper(value: $pageCount, in: 1...500) {
                    TextField("Pages", value: $pageCount, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                        .accessibilityLabel("Number of pages")
                }.fixedSize()
            }
        }
    }

    private var portfolioContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            WorkflowRow(label: "Title:", labelWidth: 100) {
                TextField("Portfolio", text: $title).textFieldStyle(.roundedBorder).frame(width: 260)
                    .accessibilityLabel("Portfolio title")
            }
            fileList
            Button("Add Files…") { files += FilePicker.choose(types: [.item], multiple: true, title: "Add to Portfolio", prompt: "Add") }
                .help("Any kind of file; each is embedded unchanged")
            Text("Files are embedded unchanged. Readers without portfolio support show a cover page listing them.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private func create() {
        busy = true
        Task {
            var tab: DocumentTab?
            switch source {
            case .files:
                var options: [String: Any] = [:]
                if let size = imagePaper.points { options = ["page_size": [Double(size.width), Double(size.height)], "fit": imageFit] }
                tab = await appState.createPDF(from: files, imageOptions: options)
            case .web:
                if let file = files.first { tab = await appState.createPDF(from: [file]) }
                else if let url = webURL { tab = await appState.createPDFFromWeb(url) }
            case .blank:
                var size = paper == .custom ? CGSize(width: width, height: height) : (paper.points ?? PDFCreation.letter)
                if landscape != (size.width > size.height) { size = CGSize(width: size.height, height: size.width) }
                tab = await appState.createBlankPDF(pages: pageCount, size: size)
            case .portfolio:
                tab = await appState.createPortfolio(files, title: title.trimmingCharacters(in: .whitespaces))
            default: break
            }
            busy = false
            if tab != nil { dismiss() }
        }
    }
}

/// Scanner dialog: choose a scanner, settings, scan pages, then create a PDF.
struct ScannerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = ScannerService()
    @State private var recognize = true
    @State private var busy = false

    var body: some View {
        WorkflowSheetFrame(title: "Scan to PDF",
                           subtitle: "Scan pages, then create one PDF from them. Use Continuity Camera to scan with a nearby iPhone or iPad.",
                           primaryTitle: scanner.scannedPages.isEmpty ? "Create PDF" : "Create PDF (\(scanner.scannedPages.count))",
                           primaryDisabled: scanner.scannedPages.isEmpty || scanner.isScanning,
                           busy: busy, busyLabel: "Creating…", width: 560, primary: create) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                WorkflowRow(label: "Scanner:", labelWidth: 100) {
                    if scanner.scanners.isEmpty {
                        HStack(spacing: 6) {
                            if scanner.isBrowsing { ProgressView().controlSize(.small) }
                            Text(scanner.status ?? "Looking for scanners…").font(.system(size: 12))
                                .foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                    } else {
                        Picker("Scanner", selection: $scanner.selectedID) {
                            ForEach(scanner.scanners) { item in
                                Label(item.name, systemImage: item.isNetwork ? "network" : "cable.connector").tag(Optional(item.id))
                            }
                        }.labelsHidden().fixedSize()
                    }
                }
                Group {
                    WorkflowRow(label: "Source:", labelWidth: 100) {
                        Picker("Source", selection: $scanner.source) {
                            ForEach(scanner.availableSources.isEmpty ? ScannerService.Source.allCases : scanner.availableSources) {
                                Text($0.title).tag($0)
                            }
                        }.labelsHidden().fixedSize()
                        if scanner.source == .feeder && scanner.supportsDuplex {
                            Toggle("Both sides", isOn: $scanner.duplex).help("Scan both sides of each sheet")
                        }
                    }
                    WorkflowRow(label: "Color:", labelWidth: 100) {
                        Picker("Color", selection: $scanner.colorMode) {
                            ForEach(ScannerService.ColorMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    WorkflowRow(label: "Resolution:", labelWidth: 100) {
                        Picker("Resolution", selection: $scanner.resolution) {
                            ForEach([150, 200, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                .disabled(scanner.selectedID == nil)
                HStack {
                    Button {
                        scanner.scan()
                    } label: { Label(scanner.scannedPages.isEmpty ? "Scan" : "Scan More", systemImage: "scanner") }
                    .disabled(scanner.selectedID == nil || scanner.isScanning || scanner.status == nil && scanner.availableSources.isEmpty)
                    .help("Scan with the selected settings")
                    if scanner.isScanning { ProgressView().controlSize(.small) }
                    if let status = scanner.status, !scanner.scanners.isEmpty {
                        Text(status).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    Spacer()
                    ContinuityCameraButton(title: "iPhone or iPad…") { pasteboard in
                        dismiss()
                        Task { _ = await appState.createPDFFromClipboard(pasteboard) }
                    }
                    .frame(width: 150, height: 24)
                }
                if !scanner.scannedPages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(scanner.scannedPages, id: \.self) { url in
                                VStack(spacing: 2) {
                                    if let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(height: 90)
                                            .overlay(Rectangle().stroke(DesignTokens.Colors.hairline))
                                    }
                                    Button { scanner.removePage(url) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("Remove this page")
                                        .accessibilityLabel("Remove scanned page")
                                }
                            }
                        }
                    }
                    .frame(height: 118)
                }
                Toggle("Recognize text after scanning (OCR)", isOn: $recognize)
                    .help("Make the scanned PDF searchable")
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    private func create() {
        busy = true
        let pages = scanner.scannedPages
        Task {
            let tab = await appState.createPDF(from: pages, name: "Scan")
            busy = false
            guard let tab else { return }
            dismiss()
            if recognize {
                try? await Task.sleep(for: .milliseconds(100))
                var options = OCROptions()
                options.languages = [Locale.current.identifier.replacingOccurrences(of: "_", with: "-")]
                    .filter { OCRService.supportedLanguages.contains($0) }
                if options.languages.isEmpty { options.languages = ["en-US"] }
                await appState.recognizeText(in: tab, options: options)
            }
        }
    }
}
