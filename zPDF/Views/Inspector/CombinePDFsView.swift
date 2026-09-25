import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Combine open PDFs and other files (images, Office/text documents, HTML)
/// into one PDF, in the listed order.
struct CombinePDFsView: View {
    enum Item: Hashable, Identifiable {
        case tab(UUID)
        case file(URL)
        var id: String {
            switch self { case .tab(let id): id.uuidString; case .file(let url): url.path }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Item] = []
    @State private var busy = false

    private var tabs: [DocumentTab] {
        order.compactMap { item in
            if case .tab(let id) = item { return appState.tabs.first { $0.id == id } }
            return nil
        }
    }
    private var hasFiles: Bool { order.contains { if case .file = $0 { return true }; return false } }
    private var ready: Bool {
        order.count >= 2 && tabs.allSatisfy(\.allowsSaveEdits)
            && order.allSatisfy { if case .tab(let id) = $0 { return appState.tabs.contains { $0.id == id } }; return true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine Files").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Files appear in this order. Current edits are included; originals stay unchanged. Images and documents are converted to PDF pages.")
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, item in
                        row(index: index, item: item)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)
            .dropDestination(for: URL.self) { urls, _ in
                add(urls.filter(\.isFileURL))
                return true
            }
            HStack {
                Button("Add Files…") {
                    add(FilePicker.choose(types: SourceKind.allTypes, multiple: true, title: "Combine Files", prompt: "Add"))
                }
                .help("Add PDFs, images, Word/RTF/text documents, HTML, spreadsheets or presentations")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Combining…" : "Combine…", action: combine)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || busy)
            }
        }
        .padding(24).frame(width: 560)
        .disabled(busy)
        .onAppear { order = appState.tabs.map { .tab($0.id) } }
    }

    private func describe(_ item: Item) -> (name: String, detail: String, icon: NSImage?) {
        switch item {
        case .tab(let id):
            guard let tab = appState.tabs.first(where: { $0.id == id }) else { return ("Closed document", "Closed", nil) }
            let detail = tab.saveChecking ? "Checking…" : tab.saveBlock != nil ? "Read-only — remove this file to combine" : "\(tab.pageCount) pages"
            return (tab.displayName, detail, nil)
        case .file(let url):
            let detail: String
            switch SourceKind.of(url) {
            case .image?: detail = "Image — one page"
            case .text?: detail = "Document — converted with macOS text layout"
            case .web?: detail = "Web page — paginated with print styles"
            case .preview?: detail = "Preview of the first sheet or slide"
            default: detail = "PDF"
            }
            return (url.lastPathComponent, detail, NSWorkspace.shared.icon(forFile: url.path))
        }
    }

    private func row(index: Int, item: Item) -> some View {
        let (name, detail, icon) = describe(item)
        return HStack {
            Text("\(index + 1).").monospacedDigit()
            if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
            VStack(alignment: .leading) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            Spacer()
            Button { order.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0).help("Move \(name) up")
                .accessibilityLabel("Move \(name) up")
            Button { order.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                .disabled(index == order.count - 1).help("Move \(name) down")
                .accessibilityLabel("Move \(name) down")
            Button { order.remove(at: index) } label: { Image(systemName: "minus.circle") }
                .help("Remove \(name) from this combination")
                .accessibilityLabel("Remove \(name)")
        }
        .padding(10).background(DesignTokens.Colors.inset).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            if PageFileKind.isPDF(url) {
                appState.openDocument(at: url)
                if let tab = appState.tabs.first(where: { $0.url.map { SaveDestination.sameFile($0, url) } == true }),
                   !order.contains(.tab(tab.id)) {
                    order.append(.tab(tab.id))
                }
            } else if SourceKind.of(url) != nil, !order.contains(.file(url)) {
                order.append(.file(url))
            }
        }
    }

    private func combine() {
        busy = true
        if !hasFiles {
            let operation = appState.exportDocuments(.combine, tabs: tabs)
            Task { if await operation.value { dismiss() }; busy = false }
            return
        }
        let items = order
        Task {
            if await appState.combineMixed(items) { dismiss() }
            busy = false
        }
    }
}

@MainActor
extension AppState {
    /// Combines open documents (with their pending edits) and other files
    /// into a new PDF at a destination the user chooses.
    func combineMixed(_ items: [CombinePDFsView.Item], destination: SaveDestination? = nil) async -> Bool {
        guard let target = destination ?? FilePicker.saveDestination(title: "Combine Files", name: "Combined.pdf") else { return false }
        guard !tabs.contains(where: { $0.url.map { SaveDestination.sameFile($0, target.url) } == true }) else {
            saveError = OpenError(fileName: "Combine Files", message: "Choose a destination that is not open in a tab.")
            return false
        }
        do {
            let work = try NativeWorkDirectory()
            var inputs: [URL] = []
            var snapshots: [NativeTransformOutput] = []
            for item in items {
                switch item {
                case .tab(let id):
                    guard let tab = tabs.first(where: { $0.id == id }), let source = tab.editSource,
                          let baseline = tab.saveBaseline, let document = tab.pdfDocument else {
                        throw NativeSaveError(code: "DOCUMENT_NOT_READY", message: "Wait until every document is ready.")
                    }
                    let snapshot = try await NativeDocumentBridge.transform(source: source.url, hash: source.hash,
                                                                            changes: try baseline.changes(in: document),
                                                                            ops: NativeOps([["op": "finalize"]]))
                    snapshots.append(snapshot)
                    inputs.append(snapshot.url)
                case .file(let url):
                    inputs += try await PDFCreation.engineInputs(for: [url], in: work.url)
                }
            }
            let seed = try PDFCreation.seed(in: work.url)
            var ops = try AppState.insertionOps(inputs, pages: nil, at: 0, imageOptions: [:], work: work.url)
            let total = inputs.reduce(0) { count, url in
                PageFileKind.isImage(url) ? count + 1 : count + (CGPDFDocument(url as CFURL)?.numberOfPages ?? 0)
            }
            ops.append(["op": "delete_pages", "pages": [total]])
            let created = try await NativeWorkflowBridge.create(seed: seed, ops: NativeOps(ops), in: work)
            let access = target.url.startAccessingSecurityScopedResource()
            defer { if access { target.url.stopAccessingSecurityScopedResource() } }
            _ = try await NativeWorkflowBridge.publish(created.url, to: target.url, overwrite: target.overwrite)
            withExtendedLifetime(snapshots) {}
            exportMessage = "Combined \(items.count) files into \(target.url.lastPathComponent)."
            exportedURL = target.url
            return true
        } catch {
            saveError = OpenError(fileName: "Combine Files", message: error.localizedDescription)
            return false
        }
    }
}
