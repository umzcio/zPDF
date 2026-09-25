import SwiftUI

/// Both entry points use the same export dialog.
struct ExportPanel: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        Button("Export PDF…") { appState.showConversionExport() }
            .disabled(appState.activeTab?.allowsSaveEdits != true)
    }
}

struct ConversionExportView: View {
    @Environment(AppState.self) private var appState
    @Bindable var request: ConversionExport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.result == nil ? "Export PDF" : "Export complete")
                    .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(request.tab.displayName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let result = request.result {
                Label("\(result.fileCount) \(result.fileCount == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: result.byteCount, countStyle: .file))", systemImage: "checkmark.circle")
                Text(result.url.path).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                if !result.pagesWithoutText.isEmpty {
                    Text("No page text was found on pages \(result.pagesWithoutText.map(String.init).joined(separator: ", ")). OCR was not performed.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                if !result.notices.isEmpty {
                    DisclosureGroup("Export notes (\(result.notices.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(result.notices) { note in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(note.message)
                                        if !note.pages.isEmpty {
                                            Text("Pages " + note.pages.map(String.init).joined(separator: ", "))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 220)
                    }
                }
                HStack {
                    Button("Open") { NSWorkspace.shared.open(result.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                    Spacer()
                    Button("Done") { appState.conversionExport = nil }.keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    Picker("Format", selection: $request.format) {
                        ForEach(ConversionFormat.allCases) { Text($0.title).tag($0) }
                    }.accessibilityLabel("Export format")
                    Picker("Pages", selection: $request.selection) {
                        Text("All pages (\(request.tab.pageCount))").tag("all")
                        Text("Current page (\(request.tab.currentPage))").tag("current")
                        Text("Page range").tag("range")
                    }.accessibilityLabel("Export pages")
                    if request.selection == "range" {
                        TextField("Range", text: $request.range, prompt: Text("1, 3–5"))
                            .accessibilityLabel("Export page range")
                            .help("Separate page numbers and ranges with commas. Pages export in document order.")
                    }
                    if request.format.hasLayout {
                        Picker("Layout", selection: $request.layoutMode) {
                            Text("Preserve layout").tag("preserve")
                            Text(request.format == .html ? "Responsive reading" : "Reflow text").tag("reflow")
                        }.accessibilityLabel("Export layout")
                    }
                    if request.format == .pptx {
                        Picker("Slides", selection: $request.pptxMode) {
                            Text("Editable").tag("editable")
                            Text("Page image + editable text").tag("page_image")
                        }.accessibilityLabel("PowerPoint mode")
                            .help("Editable rebuilds text, pictures and shapes. Page image keeps each page's drawing as a background picture under editable text.")
                    }
                    if request.format.isImage {
                        Picker("Resolution", selection: $request.dpi) {
                            Text("72 dpi — screen").tag(72)
                            Text("150 dpi — standard").tag(150)
                            Text("300 dpi — high").tag(300)
                        }.accessibilityLabel("Image resolution")
                        if request.format == .jpeg {
                            Picker("Quality", selection: $request.quality) {
                                Text("Medium").tag(0.6)
                                Text("High").tag(0.85)
                                Text("Maximum").tag(1.0)
                            }.accessibilityLabel("JPEG quality")
                        }
                    }
                }.disabled(request.isRunning)
                Text(request.format.explanation)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if request.isRunning {
                    ProgressView().controlSize(.small)
                    Text(request.isCanceling ? "Canceling…" : request.stage + (request.completedPages > 0 ? " · \(request.completedPages) of \(request.totalPages)" : "…"))
                        .font(.callout)
                }
                if let error = request.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                HStack {
                    Button(request.isCanceling ? "Canceling…" : "Cancel") { cancel() }
                        .keyboardShortcut(.cancelAction).disabled(request.isCanceling)
                    Spacer()
                    Button("Export…") { appState.runConversionExport(request) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(request.isRunning || request.tab.allowsSaveEdits == false)
                }
            }
        }
        .padding(24).frame(width: 480)
        .tint(DesignTokens.Colors.accent)
        .interactiveDismissDisabled(request.isRunning)
        .onExitCommand { cancel() }
    }

    private func cancel() {
        if request.isRunning { request.cancel() }
        else { appState.conversionExport = nil }
    }
}
