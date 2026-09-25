import AppKit
import PDFKit
import SwiftUI

/// One side of a comparison: an open document or a chosen file.
enum CompareInput: Hashable {
    case tab(UUID)
    case file(URL)
}

/// Compare Files: choose an older and a newer version, then review results.
struct ComparePanel: View {
    @Environment(AppState.self) private var appState
    @State private var older: CompareInput?
    @State private var newer: CompareInput?
    @State private var files: [URL] = []
    @State private var progress: Double?
    @State private var message: String?
    @State private var lastResult: ComparisonResult?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Documents") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    picker("Older version", selection: $older)
                    picker("Newer version", selection: $newer)
                    Button {
                        swap(&older, &newer)
                    } label: { Label("Swap", systemImage: "arrow.up.arrow.down") }
                    .controlSize(.small)
                    .disabled(older == nil && newer == nil)
                    .help("Swap older and newer")
                }
            }
            PanelSection(title: "Compare") {
                if let progress {
                    ProgressView(value: progress) { Text("Comparing…").font(.system(size: 11)) }
                } else {
                    PanelActionButton(title: "Compare", symbolName: "rectangle.split.2x1",
                                      help: "Find text and visual differences", prominent: true, action: compare)
                        .disabled(older == nil || newer == nil || older == newer)
                }
                if let message { WorkflowStatus(text: message) }
                if let lastResult {
                    PanelActionButton(title: "Show Results", symbolName: "list.bullet.rectangle",
                                      help: "Review the differences side by side") {
                        appState.present(.compareResults(lastResult))
                    }
                }
            }
            PanelNote("Text changes are found word by word and mapped to pages. Visual differences compare the rendered pages, so they also catch images, drawings and scanned content.")
        }
        .onAppear {
            if newer == nil, let tab = appState.activeTab { newer = .tab(tab.id) }
            if older == nil, let other = appState.tabs.last(where: { $0.id != appState.activeTabID }) { older = .tab(other.id) }
        }
    }

    private func picker(_ title: String, selection: Binding<CompareInput?>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
            Menu {
                if !appState.tabs.isEmpty {
                    Section("Open documents") {
                        ForEach(appState.tabs) { tab in
                            Button(tab.displayName) { selection.wrappedValue = .tab(tab.id) }
                        }
                    }
                }
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files, id: \.self) { url in
                            Button(url.lastPathComponent) { selection.wrappedValue = .file(url) }
                        }
                    }
                }
                Divider()
                Button("Choose File…") {
                    if let url = FilePicker.choose(types: [.pdf], multiple: false, title: title).first {
                        if !files.contains(url) { files.append(url) }
                        selection.wrappedValue = .file(url)
                    }
                }
            } label: {
                Text(name(of: selection.wrappedValue) ?? "Choose…").lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Choose the \(title.lowercased())")
            .accessibilityLabel(title)
            .accessibilityValue(name(of: selection.wrappedValue) ?? "None")
        }
    }

    private func name(of input: CompareInput?) -> String? {
        switch input {
        case .tab(let id)?: appState.tabs.first { $0.id == id }?.displayName
        case .file(let url)?: url.lastPathComponent
        case nil: nil
        }
    }

    private func document(_ input: CompareInput) -> PDFDocument? {
        switch input {
        case .tab(let id): return appState.tabs.first { $0.id == id }?.pdfDocument
        case .file(let url):
            _ = url.startAccessingSecurityScopedResource()
            return PDFDocument(url: url)
        }
    }

    private func compare() {
        guard let older, let newer, let a = document(older), let b = document(newer) else {
            message = "One of the documents could not be read."
            return
        }
        if a.isLocked || b.isLocked { message = "Unlock both documents before comparing."; return }
        message = nil
        progress = 0
        Task {
            let result = await CompareService.compare(old: a, oldName: name(of: older) ?? "Older", new: b,
                                                      newName: name(of: newer) ?? "Newer") { value in progress = value }
            progress = nil
            lastResult = result
            message = result.summary
            appState.present(.compareResults(result))
        }
    }
}

/// Results: change list with navigation and side-by-side pages.
struct ComparisonResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let result: ComparisonResult

    enum Filter: String, CaseIterable, Identifiable {
        case all, text, visual
        var id: String { rawValue }
        var title: String { self == .all ? "All" : self == .text ? "Text" : "Visual" }
    }

    struct Item: Identifiable, Hashable {
        let id: UUID
        let isText: Bool
        let oldPage: Int?
        let newPage: Int?
        let title: String
        let detail: String
    }

    @State private var filter: Filter = .all
    @State private var selection: UUID?

    private var items: [Item] {
        var out: [Item] = []
        if filter != .visual {
            out += result.textChanges.map { change in
                let title: String
                switch change.kind {
                case .inserted: title = "Inserted"
                case .deleted: title = "Deleted"
                case .replaced: title = "Replaced"
                }
                let detail = change.kind == .replaced ? "“\(change.oldText.prefix(60))” → “\(change.newText.prefix(60))”"
                    : "“\((change.kind == .inserted ? change.newText : change.oldText).prefix(100))”"
                return Item(id: change.id, isText: true, oldPage: change.oldPage, newPage: change.newPage, title: title, detail: detail)
            }
        }
        if filter != .text {
            out += result.visualChanges.map {
                Item(id: $0.id, isText: false, oldPage: $0.oldPage, newPage: $0.newPage,
                     title: "Visual difference", detail: "\($0.regions.count) region\($0.regions.count == 1 ? "" : "s") changed")
            }
        }
        return out.sorted { ($0.newPage ?? $0.oldPage ?? 0, $0.isText ? 0 : 1) < ($1.newPage ?? $1.oldPage ?? 0, $1.isText ? 0 : 1) }
    }

    private var selectedItem: Item? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider()
                if let item = selectedItem { sideBySide(item) } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 32)).foregroundStyle(DesignTokens.Colors.readyGreen)
                        Text("No differences found.").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 1060, height: 700)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Comparison").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("\(result.oldName) → \(result.newName) · \(result.summary)")
                    .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
            }
            Spacer()
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Filter the list of differences")
            ControlGroup {
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Previous difference (⌘↑)")
                    .accessibilityLabel("Previous difference")
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .help("Next difference (⌘↓)")
                    .accessibilityLabel("Next difference")
            }
            .fixedSize()
            Button("Create Report…", action: report)
                .help("Save a PDF report summarizing the changes, with pages side by side")
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(DesignTokens.Spacing.medium)
    }

    private var list: some View {
        List(items, selection: $selection) { item in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.isText ? (item.title == "Inserted" ? "plus.circle" : item.title == "Deleted" ? "minus.circle" : "arrow.left.arrow.right.circle")
                      : "photo.on.rectangle.angled")
                    .foregroundStyle(item.title == "Inserted" ? DesignTokens.Colors.readyGreen : item.title == "Deleted" ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("p. \((item.newPage ?? item.oldPage).map { "\($0 + 1)" } ?? "–")")
                            .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(2)
                }
            }
            .tag(item.id)
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func sideBySide(_ item: Item) -> some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            pageView(document: result.oldDocument, index: item.oldPage ?? result.pagePairs.first { $0.new == item.newPage }?.old,
                     title: "Older · \(result.oldName)", side: 0, item: item)
            pageView(document: result.newDocument, index: item.newPage ?? result.pagePairs.first { $0.old == item.oldPage }?.new,
                     title: "Newer · \(result.newName)", side: 1, item: item)
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.canvasBackground)
    }

    private func pageView(document: PDFDocument, index: Int?, title: String, side: Int, item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                if let index { Text("Page \(index + 1)").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText) }
            }
            if let index, let page = document.page(at: index) {
                let bounds = page.bounds(for: .cropBox)
                let visual = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / visual.width, geometry.size.height / visual.height)
                    let size = CGSize(width: visual.width * scale, height: visual.height * scale)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox))
                            .resizable().frame(width: size.width, height: size.height)
                        ForEach(highlights(page: page, index: index, side: side, item: item, visual: visual), id: \.self) { rect in
                            Rectangle()
                                .fill((side == 0 ? Color.red : Color.green).opacity(item.isText ? 0.25 : 0))
                                .overlay(Rectangle().stroke(item.isText ? (side == 0 ? Color.red : Color.green) : Color.orange, lineWidth: 1.5))
                                .frame(width: rect.width * scale, height: rect.height * scale)
                                .offset(x: rect.minX * scale, y: rect.minY * scale)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("No matching page").foregroundStyle(DesignTokens.Colors.mutedText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Highlight rects in visual space with a top-left origin (points).
    private func highlights(page: PDFPage, index: Int, side: Int, item: Item, visual: CGSize) -> [CGRect] {
        if item.isText, let change = result.textChanges.first(where: { $0.id == item.id }) {
            return (side == 0 ? change.oldRects : change.newRects).map {
                let v = CompareService.visualRect($0, page: page)
                return CGRect(x: v.minX, y: visual.height - v.maxY, width: v.width, height: v.height).insetBy(dx: -1, dy: -1)
            }
        }
        if let change = result.visualChanges.first(where: { $0.id == item.id }) {
            return change.regions.map { CGRect(x: $0.minX * visual.width, y: $0.minY * visual.height,
                                               width: $0.width * visual.width, height: $0.height * visual.height) }
        }
        return []
    }

    private func step(_ delta: Int) {
        let list = items
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedItem?.id } ?? 0
        selection = list[(current + delta + list.count) % list.count].id
    }

    private func report() {
        guard let destination = FilePicker.saveDestination(title: "Save Comparison Report",
                                                           name: "Comparison of \((result.newName as NSString).deletingPathExtension).pdf")
        else { return }
        do {
            let work = try NativeWorkDirectory()
            let temp = work.url.appendingPathComponent("report.pdf")
            try CompareService.writeReport(result, to: temp)
            if FileManager.default.fileExists(atPath: destination.url.path) {
                _ = try FileManager.default.replaceItemAt(destination.url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination.url)
            }
            dismiss()
            appState.exportMessage = "Saved the comparison report as \(destination.url.lastPathComponent)."
            appState.exportedURL = destination.url
        } catch {
            appState.saveError = OpenError(fileName: "Comparison Report", message: error.localizedDescription)
        }
    }
}
