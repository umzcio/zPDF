import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EmbeddedFileInfo: Identifiable {
    let name: String
    let description: String
    let size: Int?
    let mime: String
    let modified: Date?
    var id: String { name }
}

@MainActor
enum PortfolioInspector {
    static func files(in tab: DocumentTab, appState: AppState) async -> (portfolio: Bool, files: [EmbeddedFileInfo])? {
        guard tab.editSource != nil, let result = try? await appState.queryDocument("embedded_files", in: tab) else { return nil }
        let iso = ISO8601DateFormatter()
        let files = (result["files"] as? [[String: Any]] ?? []).map {
            EmbeddedFileInfo(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "",
                             size: $0["size"] as? Int, mime: $0["mime"] as? String ?? "",
                             modified: ($0["modified"] as? String).flatMap(iso.date(from:)))
        }
        return (result["portfolio"] as? Bool ?? false, files)
    }
}

/// Contents of a PDF Portfolio (or any PDF with attachments): open PDFs in
/// a new tab or save any file elsewhere. The portfolio itself is unchanged.
struct PortfolioSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var files: [EmbeddedFileInfo]?
    @State private var portfolio = false
    @State private var selection: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(portfolio ? "PDF Portfolio" : "Attachments").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("\(tab.displayName) contains \(files?.count ?? 0) file\(files?.count == 1 ? "" : "s").")
                    .font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            if let files {
                Table(files, selection: $selection) {
                    TableColumn("Name") { file in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: file.mime)
                                                                   ?? UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data))
                                .resizable().frame(width: 16, height: 16)
                            Text(file.name).lineLimit(1)
                        }
                    }
                    TableColumn("Description") { Text($0.description).lineLimit(1).foregroundStyle(DesignTokens.Colors.mutedText) }
                    TableColumn("Size") { file in
                        Text(file.size.map(ByteCountFormatter.file) ?? "—").monospacedDigit()
                    }.width(80)
                    TableColumn("Modified") { file in
                        Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    }.width(150)
                }
                .frame(minHeight: 220)
                .contextMenu(forSelectionType: String.self) { names in
                    if let name = names.first {
                        Button("Open") { open(name) }
                        Button("Save As…") { save(name) }
                    }
                } primaryAction: { names in
                    if let name = names.first { open(name) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            }
            HStack {
                Button("Open") { selection.map(open) }
                    .disabled(selection == nil || busy)
                    .help("Open the selected file (PDFs open in a new tab; other files in their default app)")
                Button("Save As…") { selection.map(save) }
                    .disabled(selection == nil || busy)
                    .help("Save a copy of the selected file")
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.xLarge)
        .frame(width: 680)
        .task {
            let result = await PortfolioInspector.files(in: tab, appState: appState)
            files = result?.files ?? []
            portfolio = result?.portfolio ?? false
        }
    }

    private func extract(_ name: String) async throws -> (URL, NativeWorkDirectory) {
        let work = try NativeWorkDirectory()
        let result = try await appState.queryDocument("extract_embedded", params: ["name": name, "directory": work.url.path], in: tab)
        guard let path = result["path"] as? String else { throw NativeSaveError(code: "EXTRACT_FAILED", message: "The file could not be extracted.") }
        return (URL(fileURLWithPath: path), work)
    }

    private func open(_ name: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let (url, work) = try await extract(name)
                if PageFileKind.isPDF(url) {
                    dismiss()
                    _ = await appState.openCreatedDocument(at: url, name: name)
                } else {
                    // Other file types open read-only in their default app from a private copy.
                    let shared = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-attachment-\(UUID().uuidString.prefix(8))")
                    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
                    let copy = shared.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    NSWorkspace.shared.open(copy)
                }
                withExtendedLifetime(work) {}
            } catch {
                appState.saveError = OpenError(fileName: name, message: error.localizedDescription)
            }
        }
    }

    private func save(_ name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let (url, work) = try await extract(name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: url)
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                }
                withExtendedLifetime(work) {}
            } catch {
                appState.saveError = OpenError(fileName: name, message: error.localizedDescription)
            }
        }
    }
}
