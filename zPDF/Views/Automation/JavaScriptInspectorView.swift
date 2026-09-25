import SwiftUI

/// Document JavaScript inspector. zPDF deliberately never executes document
/// JavaScript (it can read files, submit data and run on open); instead every
/// script location is listed so it can be reviewed and deleted.
struct JavaScriptInspectorView: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var items: [JavaScriptItem] = []
    @State private var selection: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var confirmDelete = false

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }
    private var selectedItem: JavaScriptItem? { items.first { selection.count == 1 && selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Document JavaScript").font(.headline)
                    Text("zPDF never runs these scripts. Review them here, and delete any you don't trust.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
            }
            .padding(14)
            Divider()
            HSplitView {
                list.frame(minWidth: 260, idealWidth: 300)
                detail.frame(minWidth: 320)
            }
            Divider()
            HStack {
                Button("Delete Selected…", role: .destructive) { confirmDelete = true }
                    .disabled(!canEdit || selection.isEmpty)
                Button("Delete All…", role: .destructive) { selection = Set(items.map(\.id)); confirmDelete = true }
                    .disabled(!canEdit || items.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 520)
        .task(id: tab.editSource?.hash) { await load() }
        .alert(selection.count == items.count && items.count > 1 ? "Delete all \(items.count) scripts?" : "Delete \(selection.count) script\(selection.count == 1 ? "" : "s")?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete() }
        } message: { Text("Form calculations, validation and buttons that rely on these scripts will stop working in other viewers. You can undo this.") }
    }

    @ViewBuilder
    private var list: some View {
        if loading && items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Scripts unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if items.isEmpty {
            ContentUnavailableView("No JavaScript", systemImage: "checkmark.shield", description: Text("This document contains no scripts."))
        } else {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12)).lineLimit(1)
                    Text([item.locationTitle, item.event, item.page.map { "page \($0 + 1)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                .tag(item.id)
            }
            .onDeleteCommand { if canEdit && !selection.isEmpty { confirmDelete = true } }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(item.locationTitle): \(item.name)").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(item.length) characters").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.script, forType: .string)
                    }
                    .controlSize(.small)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(item.script.isEmpty ? "(empty script)" : item.script)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(DesignTokens.Colors.hairline)
                .accessibilityLabel("Script source")
            }
            .padding(12)
        } else {
            ContentUnavailableView("Select a script", systemImage: "curlybraces", description: Text("Choose a script to read its source."))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await appState.documentQuery("document_javascript", in: tab, as: JavaScriptResult.self).items
            selection = selection.filter { id in items.contains { $0.id == id } }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func delete() {
        let ids = Array(selection)
        selection = []
        Task {
            await appState.performDocumentEdit([["op": "remove_javascript", "ids": ids]],
                                               actionName: ids.count > 1 ? "Delete Scripts" : "Delete Script", in: tab)
        }
    }
}
