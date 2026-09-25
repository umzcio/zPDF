import PDFKit
import SwiftUI

/// Advanced Search window (⇧⌘F): current document, all open documents, a
/// folder, or an indexed folder; whole words, case, regular expressions,
/// stemming and proximity; bookmarks, comments and attachments.
struct AdvancedSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var scope: Scope = .current
    @State private var folder: URL?
    @State private var indexPath: String?
    @State private var options = SearchOptions()
    @State private var results: [SearchHit] = []
    @State private var searching = false
    @State private var searchedCount = 0
    @State private var status: String?
    @State private var task: Task<Void, Never>?
    @State private var selection: SearchHit.ID?
    @State private var index = SearchIndexStore.shared
    @FocusState private var queryFocused: Bool

    enum Scope: String, CaseIterable, Identifiable {
        case current = "Current Document", open = "All Open Documents", folder = "Folder", index = "Indexed Folder"
        var id: String { rawValue }
    }

    private var grouped: [(URL, [SearchHit])] {
        var order: [URL] = []
        var buckets: [URL: [SearchHit]] = [:]
        for hit in results {
            if buckets[hit.document] == nil { order.append(hit.document) }
            buckets[hit.document, default: []].append(hit)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(14)
            Divider()
            resultsList
            Divider()
            footer.padding(.horizontal, 14).frame(height: 30)
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear {
            let preferences = appState.preferences
            options.includeBookmarks = preferences.searchIncludeBookmarks
            options.includeComments = preferences.searchIncludeComments
            options.includeAttachments = preferences.searchIncludeAttachments
            options.ignoreDiacritics = preferences.searchIgnoreDiacritics
            options.maxResults = preferences.searchMaxResults
            options.contextWords = preferences.searchContextWords
            if appState.activeTab == nil { scope = appState.tabs.isEmpty ? .folder : .open }
            queryFocused = true
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(options.regex ? "Regular expression" : "Words or phrase to find", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit(search)
                    .accessibilityLabel("Search for")
                if searching {
                    Button("Stop") { task?.cancel() }.help("Stop searching")
                } else {
                    Button("Search", action: search)
                        .keyboardShortcut(.defaultAction)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || !scopeReady)
                }
            }
            HStack {
                Picker("Look in", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                switch scope {
                case .folder:
                    Button(folder?.lastPathComponent ?? "Choose Folder…") { chooseFolder() }
                        .help(folder?.path ?? "Choose a folder to search, including subfolders")
                    if let folder {
                        Button("Build Index") { buildIndex(folder) }
                            .disabled(index.building != nil)
                            .help("Index this folder so future searches are instant")
                    }
                case .index:
                    Picker("Index", selection: $indexPath) {
                        Text("Choose…").tag(String?.none)
                        ForEach(index.folders, id: \.path) { Text("\($0.name) (\($0.documentCount))").tag(Optional($0.path)) }
                    }
                    .labelsHidden().fixedSize()
                    if let indexPath, let entry = index.folders.first(where: { $0.path == indexPath }) {
                        Button("Refresh") { if let url = index.resolve(entry) { buildIndex(url) } }
                            .disabled(index.building != nil)
                            .help("Re-read PDFs that changed since \(entry.updated.formatted(date: .abbreviated, time: .shortened))")
                    }
                default:
                    EmptyView()
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Toggle("Whole words", isOn: $options.wholeWords).disabled(options.regex || options.stemming)
                Toggle("Case sensitive", isOn: $options.caseSensitive)
                Toggle("Regular expression", isOn: $options.regex)
                    .help("ICU regular expressions, for example \\b\\d{3}-\\d{4}\\b")
                Toggle("Stemming", isOn: $options.stemming).disabled(options.regex)
                    .help("Also find other forms of each word (run, runs, running)")
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 14) {
                Toggle("Words within", isOn: Binding(get: { options.proximity > 0 }, set: { options.proximity = $0 ? 10 : 0 }))
                    .disabled(options.regex)
                Stepper("\(max(options.proximity, 1)) words", value: $options.proximity, in: 1...200)
                    .disabled(options.proximity == 0 || options.regex)
                    .fixedSize()
                Divider().frame(height: 14)
                Toggle("Bookmarks", isOn: $options.includeBookmarks)
                Toggle("Comments", isOn: $options.includeComments)
                Toggle("Attachments", isOn: $options.includeAttachments).disabled(scope == .index)
            }
            .toggleStyle(.checkbox)
            if let building = index.building {
                ProgressView(value: index.progress) { Text("Indexing \(building)…").font(.caption) }
            }
        }
        .font(.system(size: 12))
    }

    private var scopeReady: Bool {
        switch scope {
        case .current: appState.activeTab != nil
        case .open: !appState.tabs.isEmpty
        case .folder: folder != nil
        case .index: indexPath != nil
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            ContentUnavailableView {
                Label(status == nil ? "Search PDFs" : "No matches", systemImage: "magnifyingglass")
            } description: {
                Text(status ?? "Results show each match in context. Double-click a result to open it.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(grouped, id: \.0) { document, hits in
                    Section {
                        ForEach(hits) { hit in
                            resultRow(hit).tag(hit.id)
                                .contextMenu { Button("Open") { open(hit) } }
                        }
                    } header: {
                        HStack {
                            Image(systemName: "doc.richtext")
                            Text(document.lastPathComponent)
                            Spacer()
                            Text("\(hits.count)").foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                        .help(document.path)
                    }
                }
            }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let hit = results.first(where: { $0.id == id }) { open(hit) }
            }
            .onKeyPress(.return) {
                if let id = selection, let hit = results.first(where: { $0.id == id }) { open(hit); return .handled }
                return .ignored
            }
        }
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.location.title).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
            (Text(hit.before.isEmpty ? "" : "…" + hit.before + " ")
             + Text(hit.match).bold().foregroundColor(DesignTokens.Colors.accent)
             + Text(hit.after.isEmpty ? "" : " " + hit.after + "…"))
                .font(.system(size: 12))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            if searching { ProgressView().controlSize(.small) }
            Text(summary).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
            Spacer()
        }
    }

    private var summary: String {
        if searching { return "Searching \(searchedCount) document\(searchedCount == 1 ? "" : "s")…" }
        guard !results.isEmpty else { return "" }
        let documents = Set(results.map(\.document)).count
        return "\(results.count)\(results.count >= options.maxResults ? "+" : "") match\(results.count == 1 ? "" : "es") in \(documents) document\(documents == 1 ? "" : "s")"
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Search"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK else { return }
        folder = panel.url
    }

    private func buildIndex(_ url: URL) {
        Task {
            do {
                try await index.build(url)
                indexPath = url.standardizedFileURL.path
                scope = .index
            } catch { status = error.localizedDescription }
        }
    }

    private func search() {
        task?.cancel()
        let matcher: SearchMatcher
        do { matcher = try SearchMatcher(query: query, options: options) }
        catch { status = error.localizedDescription; results = []; return }
        results = []
        status = nil
        searchedCount = 0
        searching = true
        let limit = options.maxResults
        let options = self.options
        // Sources: (file to read, URL to show/open).
        var sources: [(URL, URL)] = []
        switch scope {
        case .current:
            if let tab = appState.activeTab, let url = tab.url { sources = [(tab.editSource?.url ?? url, url)] }
        case .open:
            sources = appState.tabs.compactMap { tab in tab.url.map { (tab.editSource?.url ?? $0, $0) } }
        case .folder:
            sources = folder.map { BatchRun.collectPDFs([$0]).map { ($0, $0) } } ?? []
        case .index:
            break
        }
        let chosenIndex = scope == .index ? indexPath : nil
        let chosenFolder = folder
        task = Task {
            defer { searching = false }
            if let chosenIndex {
                let documents = await Task.detached { SearchIndexStore.documents(in: chosenIndex, options: options) }.value
                for document in documents {
                    if Task.isCancelled || results.count >= limit { break }
                    searchedCount += 1
                    let hits = matcher.search(document, limit: limit - results.count)
                    results.append(contentsOf: hits)
                }
            } else {
                let access = chosenFolder?.startAccessingSecurityScopedResource() ?? false
                defer { if access { chosenFolder?.stopAccessingSecurityScopedResource() } }
                for (file, display) in sources {
                    if Task.isCancelled || results.count >= limit { break }
                    let remaining = limit - results.count
                    let hits = await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
                        guard let document = SearchableDocument.load(file, options: options, displayURL: display) else { return [] }
                        return matcher.search(document, limit: remaining)
                    }.value
                    searchedCount += 1
                    results.append(contentsOf: hits)
                }
            }
            if results.isEmpty { status = Task.isCancelled ? "Search stopped." : "Nothing matched “\(query)” in \(searchedCount) document\(searchedCount == 1 ? "" : "s")." }
        }
    }

    private func open(_ hit: SearchHit) {
        var url = hit.document
        if scope == .index, let entry = index.folders.first(where: { $0.path == indexPath }), let root = index.resolve(entry) {
            _ = root.startAccessingSecurityScopedResource()
            url = URL(fileURLWithPath: hit.document.path)
        }
        appState.openDocument(at: url)
        guard let tab = appState.tabs.first(where: { $0.url.map { SaveDestination.sameFile($0, url) } == true }) else { return }
        appState.selectTab(tab)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        let page: Int
        switch hit.location {
        case .page(let index): page = index
        case .comment(let index, _): page = index
        default: return
        }
        tab.goToPage(page + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let view = appState.pdfViewStore.pdfView, view.document === tab.pdfDocument,
                  let pdfPage = tab.pdfDocument?.page(at: page) else { return }
            if case .page = hit.location, let selection = pdfPage.selection(for: hit.range) {
                view.setCurrentSelection(selection, animate: false)
                view.scrollSelectionToVisible(nil)
            } else {
                view.go(to: pdfPage)
            }
        }
    }
}
