import PDFKit
import SwiftUI

/// Scan & OCR: recognize text (languages, pages, cleanup), review suspects,
/// export text, and scan new documents.
struct ScanOCRPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let tab = appState.activeTab {
            ScanOCRControls(tab: tab, session: OCRSession.session(for: tab)).id(tab.id)
        } else {
            PanelNote("Open a document to recognize text.")
        }
    }
}

private struct ScanOCRControls: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    @Bindable var session: OCRSession
    @State private var language = "en-US"
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var force = false
    @State private var deskew = true
    @State private var despeckle = false
    @State private var cleanBackground = false
    @State private var output: OCROptions.Output = .searchable
    @State private var corrections: [UUID: String] = [:]

    private static let languages: [String] = OCRService.supportedLanguages

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Recognize text") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    Picker("Language", selection: $language) {
                        ForEach(Self.languages, id: \.self) { code in
                            Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                        }
                    }
                    .help("The main language of the document")
                    Picker("Pages", selection: $scope) {
                        Text("All pages").tag(PageScope.all)
                        Text("Current page").tag(PageScope.current)
                        Text("Page range").tag(PageScope.range)
                    }
                    .help("Which pages to recognize")
                    if scope == .range {
                        TextField("e.g. 1, 3–5", text: $rangeText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Pages to recognize")
                            .help("Page numbers or ranges from 1 to \(tab.pageCount)")
                    }
                    Picker("Output", selection: $output) {
                        ForEach(OCROptions.Output.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Searchable keeps the scan and adds invisible text; editable draws real text over the scanned words")
                    Toggle("Include pages that already have text", isOn: $force)
                        .help("Recognize pages even if they contain text (replaces an earlier OCR layer)")
                    DisclosureGroup("Scan cleanup") {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Straighten (deskew)", isOn: $deskew)
                                .help("Rotate slightly tilted scans so lines are level")
                            Toggle("Remove specks (despeckle)", isOn: $despeckle)
                                .help("Smooth isolated dots from dust or noise")
                            Toggle("Whiten background", isOn: $cleanBackground)
                                .help("Push off-white paper tones to white")
                            Text("Cleanup replaces the page image of scanned pages only.")
                                .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                        }.padding(.top, 4)
                    }
                    .font(.system(size: 12))
                    if let progress = session.progress {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                            HStack {
                                Text("Page \(min(progress.done + 1, progress.total)) of \(progress.total)")
                                    .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                                Spacer()
                                Button("Stop") { session.cancelRequested = true }
                                    .controlSize(.small)
                                    .help("Stop after the current page; nothing is changed")
                            }
                        }
                    } else {
                        PanelActionButton(title: "Recognize Text", symbolName: "text.viewfinder",
                                          help: "Run OCR and add a text layer (⇧⌘O)", prominent: true, action: run)
                            .disabled(!tab.allowsSaveEdits || !PageScopePicker.isValid(scope, range: rangeText, count: tab.pageCount))
                    }
                    if let message = session.message {
                        WorkflowStatus(text: message, kind: session.message?.hasPrefix("Recognized") == true ? .success : .info)
                    }
                }
            }
            if !session.suspects.isEmpty { suspectsSection }
            PanelSection(title: "Recognized text") {
                PanelActionButton(title: "Export Text…", symbolName: "doc.plaintext",
                                  help: "Save all document text, including recognized text, as a .txt file") {
                    appState.exportRecognizedText(tab)
                }
                PanelActionButton(title: "Remove Text Layer", symbolName: "eraser",
                                  help: "Remove text added by OCR (keeps the scan)") {
                    appState.runDocumentTransform([["op": "remove_ocr_layer"]], actionName: "Remove Recognized Text", in: tab)
                    session.pages = [:]; session.suspects = []; session.message = nil
                }
                .disabled(!tab.allowsSaveEdits)
            }
            PanelSection(title: "Scan") {
                PanelActionButton(title: "Scan to PDF…", symbolName: "scanner",
                                  help: "Scan paper with a connected or network scanner") { appState.present(.scanner) }
                ContinuityCameraButton { pasteboard in
                    Task { _ = await appState.createPDFFromClipboard(pasteboard) }
                }
                .frame(height: 24)
            }
            PanelNote("Recognition runs on this Mac with Apple Vision. Undo removes the text layer; Save keeps it.")
        }
    }

    private var suspectsSection: some View {
        PanelSection(title: "Review suspects (\(session.suspects.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.suspects.prefix(60)) { suspect in
                    SuspectRow(tab: tab, suspect: suspect, page: session.pages[suspect.page],
                               correction: Binding(get: { corrections[suspect.id] ?? suspect.text },
                                                   set: { corrections[suspect.id] = $0 }))
                }
                if session.suspects.count > 60 {
                    Text("Showing the first 60 suspects.").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                HStack {
                    Button("Apply Corrections") {
                        Task {
                            if await appState.applyOCRCorrections(corrections, in: tab) { corrections = [:] }
                        }
                    }
                    .disabled(corrections.isEmpty || !tab.allowsSaveEdits)
                    .help("Rewrite the text layer with your corrections")
                    Button("Accept All") { session.suspects = []; corrections = [:] }
                        .help("Keep the recognized words as they are")
                }
                .controlSize(.small)
            }
        }
    }

    private func run() {
        guard let pages = try? PageScopePicker.pages(scope, range: rangeText, current: tab.currentPage, count: tab.pageCount) else { return }
        var options = OCROptions()
        options.languages = [language]
        options.pages = pages
        options.force = force
        options.deskew = deskew
        options.despeckle = despeckle
        options.cleanBackground = cleanBackground
        options.output = output
        corrections = [:]
        Task { await appState.recognizeText(in: tab, options: options, session: session) }
    }
}

private struct SuspectRow: View {
    let tab: DocumentTab
    let suspect: OCRSuspect
    let page: OCRPageText?
    @Binding var correction: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                tab.goToPage(suspect.page + 1)
            } label: {
                crop.frame(width: 72, height: 26)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DesignTokens.Colors.hairline))
            }
            .buttonStyle(.plain)
            .help("Go to page \(suspect.page + 1)")
            .accessibilityLabel("Show on page \(suspect.page + 1)")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Word", text: $correction)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .accessibilityLabel("Correct “\(suspect.text)” on page \(suspect.page + 1)")
                Text("p. \(suspect.page + 1) · \(suspect.reason)")
                    .font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
    }

    @MainActor private static var cache: [String: CGImage] = [:]

    @MainActor static func pageImage(_ tab: DocumentTab, _ index: Int) -> CGImage? {
        let key = "\(tab.id)-\(tab.pageRevision)-\(index)"
        if let cached = cache[key] { return cached }
        guard let page = tab.pdfDocument?.page(at: index), let image = OCRService.render(page, dpi: 150) else { return nil }
        if cache.count > 12 { cache.removeAll() }
        cache[key] = image
        return image
    }

    @ViewBuilder private var crop: some View {
        if let page, let word = page.lines[safe: suspect.line]?.words[safe: suspect.word],
           let image = SuspectRow.pageImage(tab, suspect.page) {
            let r = word.box.insetBy(dx: -0.01, dy: -0.006)
            let rect = CGRect(x: r.minX * CGFloat(image.width), y: (1 - r.maxY) * CGFloat(image.height),
                              width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral
            if let cropped = image.cropping(to: rect) {
                Image(decorative: cropped, scale: 1).resizable().scaledToFit()
            }
        } else {
            Image(systemName: "text.magnifyingglass").foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Non-blocking banner offering OCR when a newly opened document looks scanned.
struct ScanDetectionBanner: View {
    @Environment(AppState.self) private var appState
    @State private var visibleFor: UUID?

    var body: some View {
        Group {
            if let tab = appState.activeTab, visibleFor == tab.id, !ScanDetector.dismissed.contains(tab.id) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.viewfinder").foregroundStyle(DesignTokens.Colors.accent)
                    Text("This document looks scanned. Recognize text to make it searchable and selectable.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Recognize Text") {
                        ScanDetector.dismissed.insert(tab.id)
                        visibleFor = nil
                        appState.openTool(.scanAndOCR)
                    }
                    .controlSize(.small)
                    .help("Open Scan & OCR for this document")
                    Button {
                        ScanDetector.dismissed.insert(tab.id)
                        visibleFor = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss scanned document suggestion")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(DesignTokens.Colors.accentTint)
                .overlay(alignment: .bottom) { Divider() }
                .transition(.opacity)
            }
        }
        .task(id: appState.activeTab.map { "\($0.id)-\($0.editSource != nil)" }) {
            guard let tab = appState.activeTab, tab.editSource != nil, !ScanDetector.dismissed.contains(tab.id),
                  let document = tab.pdfDocument else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if appState.activeTab === tab, ScanDetector.looksScanned(document), appState.activePanel != .scanOCR {
                visibleFor = tab.id
            }
        }
    }
}
