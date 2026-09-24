import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Attachments panel: embedded files (name tree) and file-attachment
/// annotations. Add, open, save a copy, edit the description and delete.
/// Adding or deleting is one Undo step; Save writes it into the PDF.
struct AttachmentsSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var items: [AttachmentModel] = []
    @State private var selection: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""
    @State private var editingDescription: AttachmentModel?
    @State private var confirmDelete = false

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }
    private var selected: [AttachmentModel] { items.filter { selection.contains($0.id) } }
    private var visible: [AttachmentModel] {
        filter.isEmpty ? items : items.filter {
            $0.displayName.localizedCaseInsensitiveContains(filter) || ($0.description ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarActionBar {
                SidebarIconButton(title: "Add file", symbol: "plus") { addFiles() }.disabled(!canEdit)
                SidebarIconButton(title: "Open attachment", symbol: "arrow.up.forward.app") { openSelected() }
                    .disabled(selected.count != 1)
                SidebarIconButton(title: "Save attachment as…", symbol: "square.and.arrow.down") { saveSelected() }
                    .disabled(selected.isEmpty)
                SidebarIconButton(title: "Delete attachment", symbol: "trash", shortcutHint: "⌫", role: .destructive) {
                    confirmDelete = true
                }.disabled(!canEdit || selected.isEmpty)
            } trailing: {
                SidebarMoreMenu {
                    Button("Edit Description…") { editingDescription = selected.first }
                        .disabled(!canEdit || selected.count != 1 || selected.first?.id.hasPrefix("annot:") == true)
                    Button("Save All Attachments…") { saveAll() }.disabled(items.isEmpty)
                    Button("Go to Page") { if let page = selected.first?.page { tab.goToPage(page + 1) } }
                        .disabled(selected.first?.page == nil)
                }
            }
            if items.count > 3 || !filter.isEmpty {
                SidebarFilterField(prompt: "Find attachments", text: $filter)
            }
            content
        }
        .task(id: tab.editSource?.hash ?? tab.url?.path) { await reload() }
        .sheet(item: $editingDescription) { item in
            NamePromptSheet(title: "Attachment Description", message: "Shown with “\(item.displayName)” in PDF viewers.",
                            fieldLabel: "Description", text: item.description ?? "", confirmTitle: "Save") { value in
                Task {
                    await appState.performDocumentEdit([["op": "describe_attachment", "id": item.id, "description": value]],
                                                       actionName: "Edit Attachment Description", in: tab)
                }
            }
        }
        .alert(selected.count > 1 ? "Delete \(selected.count) attachments?" : "Delete “\(selected.first?.displayName ?? "")”?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: { Text("The embedded file is removed from this PDF when you save. You can undo this with ⌘Z.") }
    }

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            SidebarLoadingState(message: "Loading attachments…")
        } else if let error {
            SidebarEmptyState(symbolName: "exclamationmark.triangle", message: "Attachments couldn't be read.",
                              detail: error, actionTitle: "Try Again") { Task { await reload() } }
        } else if items.isEmpty {
            SidebarEmptyState(symbolName: "paperclip", message: "No attachments",
                              detail: canEdit ? "Embed files such as spreadsheets or source documents in this PDF." : nil,
                              actionTitle: canEdit ? "Add File…" : nil) { addFiles() }
        } else {
            List(visible, selection: $selection) { item in
                row(item).tag(item.id)
                    .contextMenu {
                        Button("Open") { selection = [item.id]; openSelected() }
                        Button("Save As…") { selection = [item.id]; saveSelected() }
                        if canEdit {
                            if !item.id.hasPrefix("annot:") {
                                Button("Edit Description…") { editingDescription = item }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { selection = [item.id]; confirmDelete = true }
                        }
                    }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { if canEdit && !selected.isEmpty { confirmDelete = true } }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                selection = ids
                openSelected()
            }
            .accessibilityLabel("Attachments")
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard canEdit else { return false }
                Task { await addDropped(providers) }
                return true
            }
        }
    }

    private func row(_ item: AttachmentModel) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.displayName as NSString).pathExtension) ?? .data))
                .resizable().frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.system(size: 12)).lineLimit(1)
                Text(detail(item)).font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                if let description = item.description, !description.isEmpty {
                    Text(description).font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(item.description ?? item.displayName)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ item: AttachmentModel) -> String {
        var parts: [String] = []
        if let size = item.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let page = item.page { parts.append("Comment on page \(page + 1)") }
        if let modified = PDFDateText.date(item.modified) { parts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func reload() async {
        guard appState.canQuery(tab) else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await appState.documentQuery("attachments", in: tab, as: AttachmentsResult.self).items
            selection = selection.filter { id in items.contains { $0.id == id } }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        Task { await attach(panel.urls) }
    }

    private func addDropped(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                urls.append(fileURL)
            }
        }
        await attach(urls)
    }

    private func attach(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            // Copy into a private work folder the engine can always read.
            let work = try NativeWorkDirectory()
            var ops: [[String: Any]] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let copy = work.url.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                ops.append(["op": "add_attachment", "path": copy.path, "name": url.lastPathComponent])
            }
            await appState.performDocumentEdit(ops, actionName: urls.count > 1 ? "Attach Files" : "Attach File", in: tab)
            withExtendedLifetime(work) {}
        } catch {
            appState.reportPanelError(error, in: tab)
        }
    }

    private func deleteSelected() {
        let ids = selected.map(\.id)
        guard !ids.isEmpty else { return }
        selection = []
        Task {
            await appState.performDocumentEdit([["op": "remove_attachments", "ids": ids]],
                                               actionName: ids.count > 1 ? "Delete Attachments" : "Delete Attachment", in: tab)
        }
    }

    private func extract(_ item: AttachmentModel) async throws -> Data {
        let result = try await appState.documentQuery("attachment_data", params: ["id": item.id], in: tab, as: AttachmentData.self)
        guard let data = Data(base64Encoded: result.data) else {
            throw NativeSaveError(code: "INVALID_DATA", message: "The attachment's data couldn't be read.")
        }
        return data
    }

    private func openSelected() {
        guard let item = selected.first else { return }
        Task {
            do {
                let data = try await extract(item)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-attachments-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(SafeFileName.make(item.displayName))
                try data.write(to: url)
                if item.isPDF { appState.openDocument(at: url) } else { NSWorkspace.shared.open(url) }
            } catch { appState.reportPanelError(error, in: tab) }
        }
    }

    private func saveSelected() {
        let chosen = selected
        guard !chosen.isEmpty else { return }
        if chosen.count == 1 {
            let panel = NSSavePanel()
            panel.title = "Save Attachment"
            panel.nameFieldStringValue = chosen[0].displayName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task {
                do { try await extract(chosen[0]).write(to: url, options: .atomic) }
                catch { appState.reportPanelError(error, in: tab) }
            }
        } else {
            save(chosen)
        }
    }

    private func saveAll() { save(items) }

    private func save(_ chosen: [AttachmentModel]) {
        let panel = NSOpenPanel()
        panel.title = "Save Attachments"
        panel.prompt = "Save Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            do {
                for item in chosen {
                    var target = folder.appendingPathComponent(SafeFileName.make(item.displayName))
                    var counter = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        let base = (item.displayName as NSString).deletingPathExtension
                        let ext = (item.displayName as NSString).pathExtension
                        target = folder.appendingPathComponent(SafeFileName.make("\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)")))
                        counter += 1
                    }
                    try await extract(item).write(to: target, options: .withoutOverwriting)
                }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { appState.reportPanelError(error, in: tab) }
        }
    }
}

enum SafeFileName {
    /// A file name without path separators or control characters.
    static func make(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "attachment" + cleaned : String(cleaned.prefix(200))
    }
}
