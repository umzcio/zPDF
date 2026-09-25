import PDFKit
import SwiftUI

/// zPDF's print dialog (⌘P): pages, comments & forms, page sizing & handling
/// (fit, actual, shrink, custom scale, poster, multiple per sheet, booklet),
/// auto-rotate, presets and a live preview. The prepared copy always
/// includes current edits; the macOS print panel then picks the printer.
struct PrintSheetView: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var options = PrintOptions()
    @State private var prepared: PreparedPrint?
    @State private var preparedFor: PrintOptions?
    @State private var preparing = false
    @State private var error: String?
    @State private var previewPage = 0
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var paper = NSPrintInfo.shared.paperSize

    private var presets: PrintPresetStore { PrintPresetStore.shared }
    private var area: (page: Int, rect: CGRect)? {
        guard let area = appState.features.printArea, area.tabID == tab.id else { return nil }
        return (area.page, area.rect)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Form { formContent }
                    .formStyle(.grouped)
                    .frame(width: 400)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(14)
        }
        .frame(width: 720, height: 600)
        .onAppear {
            if let initial = appState.features.printInitialOptions {
                options = initial
                appState.features.printInitialOptions = nil
            }
            if area != nil { options.scope = .area }
        }
        .task(id: optionsKey) { await refresh() }
        .sheet(isPresented: $savingPreset) {
            NamePromptSheet(title: "Save Print Preset", message: "Presets remember these print settings. They're also listed in Settings ▸ Print.",
                            fieldLabel: "Preset name", text: presetName, confirmTitle: "Save") { name in
                presets.save(options, as: name)
            }
        }
    }

    private var optionsKey: String {
        "\(options.hashValue)-\(paper.width)x\(paper.height)-\(area?.rect.debugDescription ?? "")"
    }

    @ViewBuilder
    private var formContent: some View {
        Section("Pages to Print") {
            Picker("Pages", selection: $options.scope) {
                Text("All \(tab.pageCount) pages").tag(PrintOptions.PageScope.all)
                Text("Current page (\(tab.currentPage))").tag(PrintOptions.PageScope.current)
                Text("Pages").tag(PrintOptions.PageScope.range)
                Text("Selected area").tag(PrintOptions.PageScope.area).disabled(area == nil)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if options.scope == .range {
                TextField("Pages", text: $options.range, prompt: Text("e.g. 1-3, 5"))
                    .help("Page numbers and ranges separated by commas")
            }
            if options.scope == .area, let area {
                LabeledContent("Area", value: "Page \(area.page + 1), \(Int(area.rect.width)) × \(Int(area.rect.height)) pt")
            }
            Button("Select an Area on the Page…") {
                dismiss()
                appState.beginPrintAreaSelection()
            }
            .buttonStyle(.link)
            .help("Drag a rectangle on the page to print just that area")
        }
        Section("Comments & Forms") {
            Picker("Print", selection: $options.content) {
                ForEach(PrintOptions.Content.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        Section("Page Sizing & Handling") {
            Picker("Sizing", selection: $options.sizing) {
                ForEach(PrintOptions.Sizing.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch options.sizing {
            case .custom:
                Stepper("Scale: \(Int(options.customScale))%", value: $options.customScale, in: 10...400, step: 5)
            case .poster:
                Stepper("Tile scale: \(Int(options.posterScale))%", value: $options.posterScale, in: 50...1000, step: 25)
                Stepper("Overlap: \(appState.preferences.pageUnits.format(options.posterOverlap)) \(appState.preferences.pageUnits.symbol)",
                        value: $options.posterOverlap, in: 0...144, step: 9)
                Toggle("Cut marks", isOn: $options.posterCutMarks)
                Toggle("Labels (row, column, page)", isOn: $options.posterLabels)
            case .multiple:
                Picker("Pages per sheet", selection: Binding(get: { "\(options.columns)x\(options.rows)" }, set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { options.columns = parts[0]; options.rows = parts[1] }
                })) {
                    Text("2").tag("2x1"); Text("4").tag("2x2"); Text("6").tag("3x2"); Text("9").tag("3x3"); Text("16").tag("4x4")
                }
                Picker("Page order", selection: $options.order) {
                    Text("Horizontal").tag("horizontal")
                    Text("Horizontal Reversed").tag("horizontal_reversed")
                    Text("Vertical").tag("vertical")
                    Text("Vertical Reversed").tag("vertical_reversed")
                }
                Toggle("Print page border", isOn: $options.borders)
            case .booklet:
                Picker("Binding", selection: $options.bookletBinding) {
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                Text("Print double-sided, flipping on the short edge, then fold and staple.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            default:
                EmptyView()
            }
            Toggle("Auto-rotate and center", isOn: $options.autoRotate)
        }
        Section("Paper") {
            LabeledContent("Paper size", value: "\(appState.preferences.pageUnits.format(paper.width)) × \(appState.preferences.pageUnits.format(paper.height)) \(appState.preferences.pageUnits.symbol)")
            Button("Page Setup…") {
                let layout = NSPageLayout()
                if layout.runModal(with: NSPrintInfo.shared) == NSApplication.ModalResponse.OK.rawValue {
                    paper = NSPrintInfo.shared.paperSize
                }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                if let prepared, let page = prepared.document.page(at: min(previewPage, prepared.document.pageCount - 1)) {
                    Image(nsImage: page.thumbnail(of: NSSize(width: 520, height: 520), for: .cropBox))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                        .accessibilityLabel("Preview of sheet \(previewPage + 1)")
                } else if let error {
                    ContentUnavailableView("Can't preview", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
                if preparing && prepared != nil { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            if let prepared {
                HStack {
                    Button { previewPage = max(0, previewPage - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(previewPage == 0).help("Previous sheet").accessibilityLabel("Previous sheet")
                    Text("Sheet \(min(previewPage, prepared.document.pageCount - 1) + 1) of \(prepared.document.pageCount)")
                        .font(.system(size: 11)).monospacedDigit()
                    Button { previewPage = min(prepared.document.pageCount - 1, previewPage + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(previewPage >= prepared.document.pageCount - 1).help("Next sheet").accessibilityLabel("Next sheet")
                }
                .buttonStyle(.borderless)
                .padding(.bottom, 12)
            }
        }
        .background(DesignTokens.Colors.canvasBackground)
    }

    private var footer: some View {
        HStack {
            Menu("Presets") {
                Button("Save Current Settings…") { presetName = ""; savingPreset = true }
                if !presets.names.isEmpty {
                    Divider()
                    ForEach(presets.names, id: \.self) { name in
                        Button(name) { if let preset = presets.presets[name] { options = preset } }
                    }
                    Divider()
                    Menu("Delete Preset") {
                        ForEach(presets.names, id: \.self) { name in Button(name, role: .destructive) { presets.remove(name) } }
                    }
                }
            }
            .fixedSize()
            .help("Save or apply named print settings")
            Button("Save as PDF…") { saveAsPDF() }
                .disabled(prepared == nil || preparedFor != options)
                .help("Save the print layout (with current edits) as a new PDF")
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Print…") { print() }
                .keyboardShortcut(.defaultAction)
                .disabled(prepared == nil || preparing || preparedFor != options)
        }
    }

    private func refresh() async {
        error = nil
        preparing = true
        defer { preparing = false }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let snapshot = options
            let result = try await PrintService.prepare(tab, options: snapshot, paper: paper, area: area)
            guard snapshot == options else { return }
            prepared = result
            preparedFor = snapshot
            previewPage = min(previewPage, max(0, result.document.pageCount - 1))
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            prepared = nil
        }
    }

    private func print() {
        guard let prepared else { return }
        do {
            let operation = try PrintService.operation(for: prepared, title: tab.displayName)
            dismiss()
            DispatchQueue.main.async {
                if let window = NSApp.mainWindow { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
                else { operation.run() }
                withExtendedLifetime(prepared) {}
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveAsPDF() {
        guard let prepared else { return }
        let panel = NSSavePanel()
        panel.title = "Save Print Layout as PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (tab.displayName as NSString).deletingPathExtension + " (print).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !appState.tabs.contains(where: { $0.url.map { SaveDestination.sameFile($0, url) } == true }) else {
            error = "Choose a file that isn't open in zPDF."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: prepared.url, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = error.localizedDescription
        }
    }
}
