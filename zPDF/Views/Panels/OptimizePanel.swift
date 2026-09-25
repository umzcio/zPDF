import AppKit
import SwiftUI

/// Reduce File Size presets (Acrobat's quality levels) plus lossless.
enum ReducePreset: String, CaseIterable, Identifiable {
    case lossless, high, medium, low
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lossless: "Lossless"
        case .high: "High quality"
        case .medium: "Medium"
        case .low: "Smallest file"
        }
    }
    var detail: String {
        switch self {
        case .lossless: "Recompresses streams and removes unused objects. Images are untouched."
        case .high: "Images above 225 dpi are downsampled; JPEG quality 85. Good for printing."
        case .medium: "Images above 150 dpi are downsampled; JPEG quality 70. Good for sharing."
        case .low: "Images above 96 dpi are downsampled; JPEG quality 50. Good for screens and email."
        }
    }
    var ops: [[String: Any]] {
        switch self {
        case .lossless: [["op": "optimize", "images": false, "fonts": ["subset": true]]]
        default: [["op": "optimize", "preset": rawValue, "fonts": ["subset": true],
                   "remove": ["thumbnails": true, "private_data": true]]]
        }
    }
}

@MainActor
extension AppState {
    /// Applies pending edits + `ops` and saves the result as a new file the
    /// user chooses. Reports measured before/after sizes.
    @discardableResult
    func saveTransformedCopy(of tab: DocumentTab, ops: [[String: Any]], title: String, suffix: String,
                             destination: SaveDestination? = nil) async -> Bool {
        guard tab.allowsSaveEdits, saves[tab.id] == nil, commitFieldEditing(),
              let source = tab.editSource, let baseline = tab.saveBaseline, let document = tab.pdfDocument else {
            saveError = OpenError(fileName: tab.displayName, message: "Wait until the document is ready.")
            return false
        }
        let name = (tab.displayName as NSString).deletingPathExtension + " " + suffix + ".pdf"
        guard let target = destination ?? FilePicker.saveDestination(title: title, name: name,
                                                                      directory: tab.requiresSaveAs ? nil : tab.url?.deletingLastPathComponent())
        else { return false }
        if let url = tab.url, SaveDestination.sameFile(url, target.url) {
            saveError = OpenError(fileName: title, message: "Choose a different file name. The open document is not replaced; you can open the new copy afterwards.")
            return false
        }
        guard !tabs.contains(where: { $0.url.map { SaveDestination.sameFile($0, target.url) } == true }) else {
            saveError = OpenError(fileName: title, message: "That file is open in another tab. Choose a different destination.")
            return false
        }
        tab.isSaving = true
        tab.operationLabel = title + "…"
        exportMessage = nil
        defer { tab.isSaving = false; tab.operationLabel = nil; refreshUnsavedChanges(tab) }
        do {
            let changes = try baseline.changes(in: document)
            let access = target.url.startAccessingSecurityScopedResource()
            defer { if access { target.url.stopAccessingSecurityScopedResource() } }
            guard try await allowStaging(in: target.url.deletingLastPathComponent(), for: tab) else { return false }
            let before = (try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            _ = try await NativeWorkflowBridge.exportTransform(source: source.url, hash: source.hash, changes: changes,
                                                              ops: NativeOps(ops), destination: target.url, overwrite: target.overwrite)
            let after = (try? target.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let percent = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            exportMessage = after < before
                ? "\(ByteCountFormatter.file(before)) → \(ByteCountFormatter.file(after)) (\(percent)% smaller). Saved as \(target.url.lastPathComponent)."
                : "\(ByteCountFormatter.file(before)) → \(ByteCountFormatter.file(after)). This file was already compact; saved as \(target.url.lastPathComponent)."
            exportedURL = target.url
            return true
        } catch {
            saveError = OpenError(fileName: title, message: error.localizedDescription)
            return false
        }
    }
}

/// One-click Reduce File Size (the Compress tool).
struct ReduceFileSizeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var preset: ReducePreset = .medium
    @State private var busy = false

    var body: some View {
        WorkflowSheetFrame(title: "Reduce File Size",
                           subtitle: "Saves a smaller copy. Current edits are included; the open document is unchanged.",
                           primaryTitle: "Save Copy…", busy: busy, busyLabel: "Reducing…", primary: save) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ReducePreset.allCases) { item in
                    Button { preset = item } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: preset == item ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(preset == item ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13, weight: .medium))
                                Text(item.detail).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(preset == item ? DesignTokens.Colors.accentTint : DesignTokens.Colors.inset)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preset == item ? .isSelected : [])
                    .help(item.detail)
                }
            }
        }
    }

    private func save() {
        busy = true
        Task {
            let ok = await appState.saveTransformedCopy(of: tab, ops: preset.ops, title: "Reduce File Size", suffix: "reduced")
            busy = false
            if ok { dismiss() }
        }
    }
}

/// PDF Optimizer: detailed image, font and cleanup settings, and a space audit.
struct OptimizePanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let tab = appState.activeTab {
            OptimizeControls(tab: tab).id(tab.id)
        } else {
            PanelNote("Open a document to optimize it.")
        }
    }
}

private struct OptimizeControls: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    @State private var downsample = true
    @State private var colorDPI = 150
    @State private var threshold = 1.5
    @State private var jpeg = true
    @State private var quality = 70.0
    @State private var recompressJPEG = false
    @State private var grayscale = false
    @State private var subset = true
    @State private var unembed = false
    @State private var remove: Set<String> = ["thumbnails", "private_data"]
    @State private var fastWebView = true
    @State private var audit: [(String, Int)] = []
    @State private var auditTotal = 0
    @State private var auditing = false
    @State private var inventory: String?

    private static let removals: [(String, String, String)] = [
        ("metadata", "Document information and metadata", "Title is kept; author, dates, XMP and other metadata are removed"),
        ("thumbnails", "Embedded page thumbnails", "Readers generate thumbnails themselves"),
        ("private_data", "Private data of other applications", "PieceInfo data left by editing apps"),
        ("javascript", "JavaScript and actions", "Removes scripts; form calculations stop working"),
        ("bookmarks", "Bookmarks", "Removes the document outline"),
        ("links", "Links", "Removes link annotations"),
        ("embedded_files", "Attachments and portfolio files", "Removes embedded files"),
        ("structure", "Tags (structure tree)", "Makes the file inaccessible to screen readers; not recommended"),
    ]

    private var ops: [[String: Any]] {
        var images: Any = false
        if downsample || jpeg || grayscale {
            var settings: [String: Any] = ["threshold": threshold, "grayscale": grayscale, "recompress_jpeg": recompressJPEG]
            settings["color_dpi"] = downsample ? colorDPI : NSNull()
            settings["gray_dpi"] = downsample ? colorDPI : NSNull()
            settings["jpeg_quality"] = jpeg ? Int(quality) : NSNull()
            images = settings
        }
        return [["op": "optimize", "images": images, "fonts": ["subset": subset, "unembed_standard14": unembed],
                 "remove": Dictionary(uniqueKeysWithValues: remove.map { ($0, true) }), "linearize": fastWebView]]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Reduce file size") {
                PanelActionButton(title: "Reduce File Size…", symbolName: "arrow.down.right.and.arrow.up.left",
                                  help: "Choose a quality level and save a smaller copy", prominent: true) {
                    appState.present(.reduceFileSize)
                }
                .disabled(!tab.allowsSaveEdits)
            }
            PanelSection(title: "Images") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Downsample images above", isOn: $downsample)
                        .help("Resample images whose effective resolution is higher than needed")
                    HStack {
                        Stepper(value: $colorDPI, in: 72...600, step: 24) {
                            Text("\(colorDPI) dpi").monospacedDigit()
                        }
                        .accessibilityLabel("Target resolution")
                        .accessibilityValue("\(colorDPI) dpi")
                    }
                    .disabled(!downsample)
                    .padding(.leading, 20)
                    Text("Only images above \(Int(Double(colorDPI) * threshold)) dpi are resampled.")
                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText).padding(.leading, 20)
                    Toggle("JPEG compression", isOn: $jpeg)
                        .help("Encode resampled or uncompressed photos as JPEG")
                    HStack {
                        Slider(value: $quality, in: 20...95, step: 5) { Text("Quality") }
                            .accessibilityValue("\(Int(quality))")
                        Text("\(Int(quality))").monospacedDigit().frame(width: 26)
                    }
                    .disabled(!jpeg).padding(.leading, 20)
                    .help("JPEG quality: higher keeps more detail")
                    Toggle("Recompress existing JPEGs", isOn: $recompressJPEG).disabled(!jpeg).padding(.leading, 20)
                        .help("Re-encode JPEG images even when not downsampling (smaller, some quality loss)")
                    Toggle("Convert images to grayscale", isOn: $grayscale)
                        .help("Useful for black-and-white printing and archiving scans")
                }
                .font(.system(size: 12))
            }
            PanelSection(title: "Fonts") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Subset embedded fonts", isOn: $subset)
                        .help("Keep only the characters the document uses")
                    Toggle("Unembed standard 14 fonts", isOn: $unembed)
                        .help("Helvetica, Times, Courier, Symbol and ZapfDingbats are available in every reader")
                }.font(.system(size: 12))
            }
            PanelSection(title: "Discard") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.removals, id: \.0) { key, title, help in
                        Toggle(title, isOn: Binding(get: { remove.contains(key) },
                                                    set: { if $0 { remove.insert(key) } else { remove.remove(key) } }))
                            .help(help)
                    }
                }.font(.system(size: 12))
            }
            PanelSection(title: "Save") {
                Toggle("Fast Web View (linearize)", isOn: $fastWebView)
                    .font(.system(size: 12))
                    .help("Lets browsers show the first page before the whole file downloads")
                PanelActionButton(title: "Save Optimized Copy…", symbolName: "square.and.arrow.down",
                                  help: "Save a new, optimized PDF; the open document is unchanged", prominent: true) {
                    Task { await appState.saveTransformedCopy(of: tab, ops: ops, title: "Optimize PDF", suffix: "optimized") }
                }
                .disabled(!tab.allowsSaveEdits)
                PanelActionButton(title: "Apply to Document", symbolName: "checkmark.circle",
                                  help: "Optimize the open document (Undo available); Fast Web View applies only to saved copies") {
                    var edit = ops
                    edit[0]["linearize"] = false
                    appState.runDocumentTransform(edit, actionName: "Optimize PDF", in: tab)
                }
                .disabled(!tab.allowsSaveEdits)
            }
            auditSection
        }
    }

    private var auditSection: some View {
        PanelSection(title: "Audit space usage") {
            VStack(alignment: .leading, spacing: 6) {
                PanelActionButton(title: auditing ? "Analyzing…" : "Analyze", symbolName: "chart.bar.xaxis",
                                  help: "Show how many bytes images, fonts, content and other data use", action: runAudit)
                    .disabled(auditing || tab.editSource == nil)
                if !audit.isEmpty {
                    Text("Total \(ByteCountFormatter.file(auditTotal))").font(.system(size: 11, weight: .medium))
                    ForEach(audit, id: \.0) { name, bytes in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(name).font(.system(size: 11))
                                Spacer()
                                Text(ByteCountFormatter.file(bytes)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(DesignTokens.Colors.accent.opacity(0.7))
                                    .frame(width: max(2, geometry.size.width * CGFloat(bytes) / CGFloat(max(1, auditTotal))))
                            }
                            .frame(height: 4)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let inventory { Text(inventory).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText) }
                }
            }
        }
    }

    private func runAudit() {
        auditing = true
        Task {
            defer { auditing = false }
            guard let result = try? await appState.queryDocument("space_audit", in: tab),
                  let categories = result["categories"] as? [String: Int] else { return }
            let names = ["images": "Images", "content": "Page content", "fonts": "Fonts", "forms": "Form fields",
                         "annotations": "Comments", "bookmarks": "Bookmarks", "structure": "Tags (structure)",
                         "metadata": "Metadata", "embedded_files": "Attachments", "color": "Color profiles",
                         "thumbnails": "Thumbnails", "other": "Document overhead"]
            audit = categories.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { (names[$0.key] ?? $0.key, $0.value) }
            auditTotal = result["total"] as? Int ?? categories.values.reduce(0, +)
            if let images = try? await appState.queryDocument("image_inventory", in: tab),
               let list = images["images"] as? [[String: Any]], !list.isEmpty {
                let dpis = list.compactMap { $0["dpi"] as? Int }
                inventory = "\(list.count) image\(list.count == 1 ? "" : "s")" + (dpis.isEmpty ? "" : ", \(dpis.min()!)–\(dpis.max()!) dpi effective")
            } else { inventory = "No images." }
        }
    }
}
