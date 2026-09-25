import SwiftUI

/// Named destinations: list, sort, go, create at the current view, rename
/// (outline and link references follow) and delete.
struct DestinationsSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var items: [DestinationModel] = []
    @State private var selection: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""
    @State private var sortByPage = false
    @State private var creating = false
    @State private var renaming: DestinationModel?

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }
    private var visible: [DestinationModel] {
        let filtered = filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return sortByPage ? filtered.sorted { ($0.page ?? .max, $0.name) < ($1.page ?? .max, $1.name) } : filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarActionBar {
                SidebarIconButton(title: "New destination at current view", symbol: "plus") { creating = true }
                    .disabled(!canEdit)
                SidebarIconButton(title: "Rename destination", symbol: "pencil") {
                    renaming = items.first { selection.contains($0.id) }
                }.disabled(!canEdit || selection.count != 1)
                SidebarIconButton(title: "Delete destination", symbol: "trash", shortcutHint: "⌫", role: .destructive) {
                    delete()
                }.disabled(!canEdit || selection.isEmpty)
            } trailing: {
                SidebarMoreMenu {
                    Picker("Sort By", selection: $sortByPage) {
                        Text("Name").tag(false)
                        Text("Page").tag(true)
                    }
                    Button("Refresh") { Task { await reload() } }
                }
            }
            if items.count > 5 || !filter.isEmpty {
                SidebarFilterField(prompt: "Find destinations", text: $filter)
            }
            content
        }
        .task(id: tab.editSource?.hash ?? tab.url?.path) { await reload() }
        .sheet(isPresented: $creating) {
            NamePromptSheet(title: "New Destination",
                            message: "Links and bookmarks can jump to this view of page \(tab.currentPage) by name.",
                            fieldLabel: "Destination name", text: suggestedName(), confirmTitle: "Create") { create($0) }
        }
        .sheet(item: $renaming) { item in
            NamePromptSheet(title: "Rename Destination", message: "Bookmarks and links that use “\(item.name)” are updated.",
                            fieldLabel: "Destination name", text: item.name, confirmTitle: "Rename") { value in
                Task {
                    await appState.performDocumentEdit([["op": "rename_destination", "old": item.name, "new": value]],
                                                       actionName: "Rename Destination", in: tab)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            SidebarLoadingState(message: "Loading destinations…")
        } else if let error {
            SidebarEmptyState(symbolName: "exclamationmark.triangle", message: "Destinations couldn't be read.", detail: error,
                              actionTitle: "Try Again") { Task { await reload() } }
        } else if items.isEmpty {
            SidebarEmptyState(symbolName: "mappin.and.ellipse", message: "No named destinations",
                              detail: canEdit ? "Create one to link to this view from other documents or web pages." : nil,
                              actionTitle: canEdit ? "New Destination…" : nil) { creating = true }
        } else {
            List(visible, selection: $selection) { item in
                HStack {
                    Image(systemName: "mappin").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                    Text(item.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(item.page.map { "p. \($0 + 1)" } ?? "—")
                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText).monospacedDigit()
                }
                .tag(item.id)
                .help("\(item.name) — \(item.page.map { "page \($0 + 1)" } ?? "missing page")")
                .contextMenu {
                    Button("Go to Destination") { go(item) }
                    if canEdit {
                        Button("Rename…") { renaming = item }
                        Button("Delete", role: .destructive) { selection = [item.id]; delete() }
                    }
                    Divider()
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.name, forType: .string)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, ids in
                if ids.count == 1, let item = items.first(where: { ids.contains($0.id) }) { go(item) }
            }
            .onDeleteCommand { if canEdit { delete() } }
            .accessibilityLabel("Named destinations")
        }
    }

    private func reload() async {
        guard appState.canQuery(tab) else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await appState.documentQuery("destinations", in: tab, as: DestinationsResult.self).items
            selection = selection.filter { id in items.contains { $0.id == id } }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggestedName() -> String {
        var index = items.count + 1
        while items.contains(where: { $0.name == "Destination \(index)" }) { index += 1 }
        return "Destination \(index)"
    }

    private func go(_ item: DestinationModel) {
        guard let page = item.page else { return }
        PDFKitViewHelpers.go(to: page, top: item.top, left: item.left, in: appState, tab: tab)
    }

    private func create(_ name: String) {
        let view = PDFKitViewHelpers.currentView(in: appState, tab: tab)
        var op: [String: Any] = ["op": "add_destination", "name": name, "page": view.page]
        if let top = view.top { op["top"] = top; op["fit"] = "XYZ" }
        if let left = view.left { op["left"] = left }
        Task { await appState.performDocumentEdit([op], actionName: "New Destination", in: tab) }
    }

    private func delete() {
        let names = items.filter { selection.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return }
        selection = []
        Task {
            await appState.performDocumentEdit([["op": "remove_destinations", "names": names]],
                                               actionName: names.count > 1 ? "Delete Destinations" : "Delete Destination", in: tab)
        }
    }
}
