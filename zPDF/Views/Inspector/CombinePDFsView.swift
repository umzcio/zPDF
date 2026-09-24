import AppKit
import SwiftUI

struct CombinePDFsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var order: [UUID] = []
    @State private var busy = false
    private var documents: [DocumentTab] { order.compactMap { id in appState.tabs.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine PDFs").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Files appear in this order. Current edits are included; originals stay unchanged.")
                .foregroundStyle(DesignTokens.Colors.mutedText)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, tab in
                        HStack {
                            Text("\(index + 1).").monospacedDigit()
                            VStack(alignment: .leading) {
                                Text(tab.displayName).lineLimit(1)
                                Text(tab.saveChecking ? "Checking…" : tab.saveBlock != nil ? "Read-only — remove this file to combine" : "\(tab.pageCount) pages")
                                    .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                            Spacer()
                            Button { order.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).help("Move \(tab.displayName) up")
                                .accessibilityLabel("Move \(tab.displayName) up")
                            Button { order.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == documents.count - 1).help("Move \(tab.displayName) down")
                                .accessibilityLabel("Move \(tab.displayName) down")
                            Button { order.removeAll { $0 == tab.id } } label: { Image(systemName: "minus.circle") }
                                .help("Remove \(tab.displayName) from this combination")
                                .accessibilityLabel("Remove \(tab.displayName)")
                        }.padding(10).background(DesignTokens.Colors.inset).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.frame(minHeight: 160, maxHeight: 300)
            HStack {
                Button("Add PDFs…", action: addFiles)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Combining…" : "Combine…") {
                    busy = true
                    let operation = appState.exportDocuments(.combine, tabs: documents)
                    Task { if await operation.value { dismiss() }; busy = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(documents.count < 2 || documents.contains { !$0.allowsSaveEdits })
            }
        }
        .padding(24).frame(width: 530)
        .disabled(busy)
        .onAppear { order = appState.tabs.map(\.id) }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            appState.openDocument(at: url)
            if let tab = appState.tabs.first(where: { $0.url.map { SaveDestination.sameFile($0, url) } == true }), !order.contains(tab.id) {
                order.append(tab.id)
            }
        }
    }
}
