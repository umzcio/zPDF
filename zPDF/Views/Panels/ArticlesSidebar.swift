import SwiftUI

/// Content panel: article threads (read a thread bead by bead), 3D model
/// annotations (listed; 3D rendering is not supported) and the current
/// page's content objects in drawing order.
struct ArticlesSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var threads: [ArticleThread] = []
    @State private var models: [Model3DItem] = []
    @State private var objects: [ContentObjectModel] = []
    @State private var objectTotal = 0
    @State private var loading = false
    @State private var error: String?
    @State private var reading: (thread: Int, bead: Int)?
    @State private var section: Section = .articles

    enum Section: String, CaseIterable, Identifiable {
        case articles = "Articles", page = "Page Content", models = "3D Models"
        var id: String { rawValue }
    }

    private var sections: [Section] { models.isEmpty ? [.articles, .page] : Section.allCases }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Content", selection: $section) {
                ForEach(sections) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(8)
            .accessibilityLabel("Content view")
            Divider()
            switch section {
            case .articles: articles
            case .page: pageContent
            case .models: modelList
            }
        }
        .task(id: tab.editSource?.hash ?? tab.url?.path) { await reloadDocument() }
        .task(id: "\(tab.editSource?.hash ?? "")-\(tab.currentPage)-\(section.rawValue)") {
            if section == .page { await reloadPage() }
        }
    }

    // MARK: - Articles

    @ViewBuilder
    private var articles: some View {
        if loading && threads.isEmpty {
            SidebarLoadingState(message: "Loading articles…")
        } else if let error {
            SidebarEmptyState(symbolName: "exclamationmark.triangle", message: "Content couldn't be read.", detail: error)
        } else if threads.isEmpty {
            SidebarEmptyState(symbolName: "text.justify.leading", message: "No article threads",
                              detail: "Article threads connect columns of a story across pages. This document doesn't define any.")
        } else {
            if let reading, threads.indices.contains(reading.thread) {
                readingBar(threads[reading.thread], bead: reading.bead)
            }
            List {
                ForEach(threads) { thread in
                    DisclosureGroup {
                        ForEach(Array(thread.beads.enumerated()), id: \.offset) { index, bead in
                            Button { read(thread.index, bead: index) } label: {
                                HStack {
                                    Text("Part \(index + 1)").font(.system(size: 11.5))
                                    Spacer()
                                    Text(bead.page.map { "p. \($0 + 1)" } ?? "—")
                                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Go to part \(index + 1) of “\(thread.title)”")
                        }
                    } label: {
                        HStack {
                            Label(thread.title, systemImage: "text.justify.leading").font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Button("Read") { read(thread.index, bead: 0) }
                                .controlSize(.mini)
                                .help("Read this article from the beginning")
                        }
                        .help([thread.author, thread.subject].compactMap { $0 }.joined(separator: " — "))
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func readingBar(_ thread: ArticleThread, bead: Int) -> some View {
        HStack(spacing: 4) {
            SidebarIconButton(title: "Previous part", symbol: "chevron.up") { read(thread.index, bead: bead - 1) }
                .disabled(bead == 0)
            SidebarIconButton(title: "Next part", symbol: "chevron.down") { read(thread.index, bead: bead + 1) }
                .disabled(bead + 1 >= thread.beads.count)
            Text("\(thread.title) · \(bead + 1) of \(thread.beads.count)")
                .font(.system(size: 11)).lineLimit(1)
            Spacer()
            SidebarIconButton(title: "Stop reading", symbol: "xmark") { reading = nil }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(DesignTokens.Colors.accentTint)
    }

    private func read(_ threadIndex: Int, bead: Int) {
        guard let thread = threads.first(where: { $0.index == threadIndex }), thread.beads.indices.contains(bead),
              let page = thread.beads[bead].page else { return }
        reading = (threadIndex, bead)
        let rect = thread.beads[bead].rect.map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) }
        PDFKitViewHelpers.go(to: page, rect: rect?.insetBy(dx: -12, dy: -12), in: appState, tab: tab)
    }

    // MARK: - Page content

    @ViewBuilder
    private var pageContent: some View {
        if objects.isEmpty {
            SidebarEmptyState(symbolName: "square.stack.3d.up", message: loading ? "Reading page…" : "No content objects on this page.")
        } else {
            List(Array(objects.enumerated()), id: \.offset) { index, object in
                Button {
                    let r = object.rect
                    PDFKitViewHelpers.go(to: tab.currentPage - 1,
                                         rect: CGRect(x: r[0], y: r[1], width: max(1, r[2] - r[0]), height: max(1, r[3] - r[1])).insetBy(dx: -20, dy: -20),
                                         in: appState, tab: tab)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(object.type)).frame(width: 16).foregroundStyle(DesignTokens.Colors.mutedText)
                        Text(object.text?.isEmpty == false ? object.text! : object.type.capitalized)
                            .font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(object.type.capitalized) object \(index + 1) — click to show it on the page")
            }
            .listStyle(.sidebar)
            if objectTotal > objects.count {
                SidebarNotice(symbol: "info.circle", text: "Showing the first \(objects.count) of \(objectTotal) objects.")
            }
        }
    }

    private func symbol(_ type: String) -> String {
        switch type {
        case "text": "textformat"
        case "image": "photo"
        case "path": "scribble"
        case "shading": "circle.lefthalf.filled"
        case "form": "square.on.square"
        default: "questionmark.square"
        }
    }

    // MARK: - 3D

    private var modelList: some View {
        VStack(spacing: 0) {
            SidebarNotice(symbol: "cube", text: "zPDF lists 3D models but can't display or rotate them. Open the file in a 3D-capable viewer to interact with them.")
            List(models) { model in
                Button {
                    let rect = model.rect.map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) }
                    PDFKitViewHelpers.go(to: model.page, rect: rect, in: appState, tab: tab)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(model.name, systemImage: "cube").font(.system(size: 12))
                        Text("Page \(model.page + 1) · \(model.format ?? model.subtype)\(model.views.isEmpty ? "" : " · \(model.views.count) views")")
                            .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                        ForEach(model.views, id: \.self) { view in
                            Text("• \(view)").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Loading

    private func reloadDocument() async {
        guard appState.canQuery(tab) else { return }
        loading = true
        defer { loading = false }
        do {
            threads = try await appState.documentQuery("articles", in: tab, as: ArticlesResult.self).threads
            models = try await appState.documentQuery("models_3d", in: tab, as: Models3DResult.self).items
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reloadPage() async {
        guard appState.canQuery(tab) else { return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            let result = try await appState.documentQuery("content_objects", params: ["page": tab.currentPage - 1], in: tab,
                                                          as: ContentObjectsResult.self)
            objects = result.objects
            objectTotal = result.total
        } catch is CancellationError {
        } catch {
            objects = []
        }
    }
}
