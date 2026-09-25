import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Fill & Sign: fill existing fields in PDFKit's widgets, add text and marks
/// anywhere (flat PDFs too), place saved signatures/initials, auto-fill from
/// the profile, and finish (flatten / clear). Every mark saves natively.
struct FillSignPanel: View {
    @Environment(AppState.self) private var appState
    @State private var capture: SavedSignature.Kind?
    @State private var showsAutofill = false
    @State private var editingList: FormFieldInfo?
    @State private var confirmFlatten = false
    @State private var confirmClear = false
    @State private var error: String?

    private var tab: DocumentTab? { appState.activeTab }
    private var service: SignatureService { appState.signatureService }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            statusSection
            ArmedToolBanner()
            addToPageSection
            signSection
            formSection
            if let error { PanelErrorText(message: error) }
        }
        .disabled(tab?.allowsSaveEdits != true)
        .sheet(item: $capture) { kind in
            SignatureCaptureSheet(kind: kind) { signature in
                service.arm(.signature(signature))
            }
            .environment(appState)
        }
        .sheet(isPresented: $showsAutofill) {
            if let tab { AutofillSheet(tab: tab).environment(appState) }
        }
        .sheet(item: $editingList) { field in
            if let tab { ListSelectionSheet(field: field, tab: tab).environment(appState) }
        }
        .confirmationDialog("Flatten all form fields?", isPresented: $confirmFlatten) {
            Button("Flatten Fields", role: .destructive) { run { try await appState.flattenFormFields($0) } }
        } message: {
            Text("Field values become part of the page and can no longer be edited. You can undo this until you close the document.")
        }
        .confirmationDialog("Clear the form?", isPresented: $confirmClear) {
            Button("Clear Form", role: .destructive) { run { try await appState.resetForm($0) } }
        } message: { Text("Every field returns to its default value.") }
        .onAppear { if let tab { appState.profileDocument(tab) } }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        let fields = tab?.protection.formFields ?? []
        let fillable = fields.filter { !["signature", "button"].contains($0.kind) && !$0.readonly }
        if fillable.isEmpty {
            PanelStatusCard(symbolName: "text.cursor", title: "No fillable fields",
                            detail: "Use the tools below to type text and add marks anywhere on the page.")
        } else {
            let required = fillable.filter(\.required)
            PanelStatusCard(symbolName: "list.bullet.rectangle", title: "\(fillable.count) fillable field\(fillable.count == 1 ? "" : "s")",
                            detail: required.isEmpty ? "Click a field to type. Tab moves to the next field."
                                : "\(required.count) required. Click a field to type; Tab moves to the next field.")
        }
    }

    private var addToPageSection: some View {
        PanelSection(title: "Add to page") {
            PanelToolGrid {
                tool("Add text", "textformat", .addText, "Click to type text anywhere on the page")
                tool("Date", "calendar", .date, "Place today’s date")
                tool("Check", "checkmark", .check, "Place a check mark")
                tool("Cross", "xmark", .cross, "Place an X")
                tool("Dot", "smallcircle.filled.circle", .dot, "Place a dot")
                tool("Line", "line.diagonal", .line, "Drag to draw a line")
            }
            HStack(spacing: 8) {
                Text("Size").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                Stepper(value: Binding(get: { Double(service.fillTextSize) }, set: { service.fillTextSize = CGFloat($0) }),
                        in: 6...36, step: 1) {
                    Text("\(Int(service.fillTextSize)) pt").font(.system(size: 11)).monospacedDigit()
                }
                .help("Text and mark size")
                .accessibilityLabel("Text and mark size")
                Spacer()
                ForEach(Array([NSColor.black, NSColor(srgbRed: 0.05, green: 0.2, blue: 0.65, alpha: 1),
                               NSColor(srgbRed: 0.75, green: 0.1, blue: 0.1, alpha: 1)].enumerated()), id: \.offset) { index, color in
                    let name = ["Black", "Blue", "Red"][index]
                    Button { service.fillColor = color } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(service.fillColor == color ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline,
                                                     lineWidth: service.fillColor == color ? 2 : 1).padding(-2))
                    }
                    .buttonStyle(.plain)
                    .help("\(name) ink")
                    .accessibilityLabel("\(name) ink")
                    .accessibilityAddTraits(service.fillColor == color ? .isSelected : [])
                }
            }
            Text("Double-click text you added to edit it.")
                .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private func tool(_ title: String, _ symbol: String, _ tool: FormsCanvasTool, _ help: String) -> some View {
        PanelToolButton(title: title, symbolName: symbol, isActive: service.armedTool == tool) {
            appState.armedAnnotationTool = nil
            service.arm(tool)
        }
        .help(help)
    }

    private var signSection: some View {
        PanelSection(title: "Sign") {
            signatureMenu(kind: .signature, title: "Add signature", symbol: "signature")
            signatureMenu(kind: .initials, title: "Add initials", symbol: "character.cursor.ibeam")
            Text("Signatures you create are saved on this Mac for reuse. To sign with a certificate, use Certificates.")
                .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private func signatureMenu(kind: SavedSignature.Kind, title: String, symbol: String) -> some View {
        let saved = service.signatures(of: kind)
        return Group {
            if saved.isEmpty {
                PanelActionButton(title: title + "…", symbolName: symbol,
                                  help: kind == .signature ? "Draw, type, or import your signature" : "Draw, type, or import your initials") {
                    capture = kind
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(saved) { signature in
                        HStack(spacing: 6) {
                            Button { service.arm(.signature(signature)) } label: {
                                HStack {
                                    if let image = signature.image {
                                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                            .frame(maxWidth: .infinity, maxHeight: 34)
                                    } else {
                                        Text(signature.name).font(.system(size: 12))
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .padding(.horizontal, 6)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                                    .stroke(service.armedTool == .signature(signature) ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline,
                                            lineWidth: service.armedTool == .signature(signature) ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help("Place this \(kind == .initials ? "initials" : "signature"): click or drag on the page")
                            .accessibilityLabel("Place \(kind == .initials ? "initials" : "signature") \(signature.name)")
                            PanelIconButton(symbolName: "trash", label: "Delete saved \(kind == .initials ? "initials" : "signature")",
                                            role: .destructive) { service.remove(signature) }
                        }
                    }
                    Button { capture = kind } label: {
                        Label(kind == .signature ? "New signature…" : "New initials…", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .help(kind == .signature ? "Create another signature" : "Create other initials")
                }
            }
        }
    }

    @ViewBuilder
    private var formSection: some View {
        let fields = tab?.protection.formFields ?? []
        let lists = fields.filter { $0.kind == "list" && $0.multiSelect && !$0.readonly }
        PanelSection(title: "Form") {
            PanelActionButton(title: "Auto-fill from profile…", symbolName: "person.text.rectangle",
                              help: service.profile.isEmpty ? "Add your details in Settings › Forms to auto-fill matching fields"
                                  : "Suggest values from your profile for matching empty fields") {
                showsAutofill = true
            }
            ForEach(lists) { field in
                PanelActionButton(title: "Choose \(field.name)…", symbolName: "checklist",
                                  help: "Select one or more options in the list box “\(field.name)”") { editingList = field }
            }
            if fields.contains(where: { $0.kind == "barcode" }) {
                PanelActionButton(title: "Update barcodes", symbolName: "qrcode",
                                  help: "Encode the current field values into the form’s barcodes") {
                    run { try await appState.updateBarcodes(in: $0) }
                }
            }
            if tab?.protection.hasFormLogic == true {
                PanelActionButton(title: "Recalculate", symbolName: "function",
                                  help: "Update calculated fields and formats now") {
                    if let tab { Task { await FormLogic.recalculate(tab, state: appState) } }
                }
            }
            if !fields.isEmpty {
                HStack(spacing: 8) {
                    PanelActionButton(title: "Clear form", symbolName: "arrow.uturn.backward",
                                      help: "Reset every field to its default value") { confirmClear = true }
                    PanelActionButton(title: "Flatten", symbolName: "square.stack.3d.down.forward",
                                      help: "Make field values part of the page so they can’t be changed") { confirmFlatten = true }
                }
            }
        }
    }

    private func run(_ action: @escaping @MainActor (DocumentTab) async throws -> Void) {
        guard let tab else { return }
        error = nil
        Task {
            do { try await action(tab) } catch { self.error = error.localizedDescription }
        }
    }
}

extension SavedSignature.Kind: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Signature capture

struct SignatureCaptureSheet: View {
    enum Mode: String, CaseIterable, Identifiable { case type = "Type", draw = "Draw", image = "Image"; var id: String { rawValue } }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let kind: SavedSignature.Kind
    let onCreate: (SavedSignature) -> Void

    @State private var mode: Mode = .type
    @State private var typed = ""
    @State private var fontName = SignatureRendering.typedFonts[0].name
    @State private var pad = SignaturePadController()
    @State private var inkBlue = false
    @State private var imageURL: URL?
    @State private var removeBackground = true
    @State private var importedImage: NSImage?

    private var noun: String { kind == .initials ? "initials" : "signature" }

    var body: some View {
        FormsSheet(title: kind == .initials ? "Create Initials" : "Create Signature",
                   subtitle: "Your \(noun) is saved on this Mac so you can place it again.", width: 520) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Method", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("How to create your \(noun)")
                switch mode {
                case .type: typeView
                case .draw: drawView
                case .image: imageView
                }
            }
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save & Place") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(currentImage == nil)
                .help("Save this \(noun) and place it on the page")
        }
        .onAppear {
            let profile = appState.signatureService.profile
            let name = profile.fullName.isEmpty ? [profile.firstName, profile.lastName].filter { !$0.isEmpty }.joined(separator: " ")
                : profile.fullName
            typed = kind == .initials ? name.split(separator: " ").compactMap(\.first).map(String.init).joined() : name
        }
    }

    private var typeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(kind == .initials ? "Your initials" : "Your full name", text: $typed)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(kind == .initials ? "Initials" : "Name")
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(SignatureRendering.typedFonts, id: \.name) { font in
                        Button { fontName = font.name } label: {
                            Text(typed.isEmpty ? (kind == .initials ? "AB" : "Your Name") : typed)
                                .font(.custom(font.name, size: 26))
                                .lineLimit(1).minimumScaleFactor(0.4)
                                .foregroundStyle(Color.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 58)
                                .clipped()
                                .padding(.horizontal, 8)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
                                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                                    .stroke(fontName == font.name ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline,
                                            lineWidth: fontName == font.name ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(font.title)
                        .accessibilityLabel("Style \(font.title)")
                        .accessibilityAddTraits(fontName == font.name ? .isSelected : [])
                    }
                }
            }
            .frame(height: 210)
        }
    }

    private var drawView: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignaturePadRepresentable(controller: pad)
                .frame(height: 170)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.hairline))
            HStack {
                Text("Draw with your trackpad or mouse.").font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Toggle("Blue ink", isOn: $inkBlue)
                    .toggleStyle(.checkbox)
                    .onChange(of: inkBlue) { _, blue in
                        pad.inkColor = blue ? NSColor(srgbRed: 0.05, green: 0.2, blue: 0.65, alpha: 1) : .black
                    }
                    .help("Draw in blue instead of black")
                Button("Undo") { pad.undo() }.disabled(pad.isEmpty).help("Remove the last stroke")
                Button("Clear") { pad.clear() }.disabled(pad.isEmpty).help("Start over")
            }
        }
    }

    private var imageView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).fill(Color.white)
                if let importedImage {
                    Image(nsImage: importedImage).resizable().scaledToFit().padding(10)
                } else {
                    Text("Choose a photo or scan of your \(noun)").foregroundStyle(Color.gray)
                }
            }
            .frame(height: 170)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.hairline))
            HStack {
                Button("Choose Image…") { chooseImage() }.help("Import a PNG, JPEG, or HEIC image")
                Toggle("Remove white background", isOn: $removeBackground)
                    .toggleStyle(.checkbox)
                    .onChange(of: removeBackground) { _, _ in reloadImage() }
                    .help("Make the paper around your signature transparent")
                Spacer()
            }
        }
    }

    private var currentImage: NSImage? {
        switch mode {
        case .type: SignatureRendering.typedImage(typed, fontName: fontName)
        case .draw: pad.isEmpty ? nil : pad.captureImage()
        case .image: importedImage
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageURL = url
        reloadImage()
    }

    private func reloadImage() {
        guard let imageURL else { return }
        importedImage = SignatureRendering.importedImage(from: imageURL, removeBackground: removeBackground)
    }

    private func save() {
        guard let image = currentImage else { return }
        let source: SavedSignature.Source = mode == .type ? .typed : mode == .draw ? .drawn : .image
        let name = typed.isEmpty ? (kind == .initials ? "Initials" : "Signature") : typed
        if let signature = appState.signatureService.addSignature(name: name, kind: kind, image: image, source: source) {
            onCreate(signature)
        }
        dismiss()
    }
}

// MARK: - Auto-fill

private struct AutofillSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let tab: DocumentTab
    @State private var suggestions: [ProfileSuggestion] = []

    var body: some View {
        FormsSheet(title: "Auto-fill from Profile",
                   subtitle: "Review the suggested values. Only empty fields are filled.", width: 480) {
            if appState.signatureService.profile.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your profile is empty.").font(.headline)
                    Text("Add your name, address, and contact details in Settings › Forms. They stay on this Mac.")
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                    Button("Open Settings…") { openSettings(); dismiss() }
                }
            } else if suggestions.isEmpty {
                Text("No empty fields match your profile.").foregroundStyle(DesignTokens.Colors.mutedText)
            } else {
                List {
                    ForEach($suggestions) { $item in
                        Toggle(isOn: $item.include) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.value).font(.system(size: 12, weight: .medium))
                                Text("\(item.label) → \(item.fieldName)").font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(height: 260)
            }
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Fill \(suggestions.filter(\.include).count) Fields") {
                for item in suggestions where item.include { item.annotation.widgetStringValue = item.value }
                appState.refreshUnsavedChanges(tab)
                appState.noteAnnotationsChanged()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!suggestions.contains(where: \.include))
        }
        .onAppear {
            if let document = tab.pdfDocument {
                suggestions = FormProfileMatcher.suggestions(in: document, profile: appState.signatureService.profile)
            }
        }
    }
}

// MARK: - Multi-select list boxes

private struct ListSelectionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let field: FormFieldInfo
    let tab: DocumentTab
    @State private var selection: Set<String> = []
    @State private var error: String?

    var body: some View {
        FormsSheet(title: field.name, subtitle: field.tooltip.isEmpty ? "Select one or more options." : field.tooltip, width: 380) {
            VStack(alignment: .leading, spacing: 8) {
                List(field.options) { option in
                    Toggle(option.label, isOn: Binding(get: { selection.contains(option.export) },
                                                        set: { on in if on { selection.insert(option.export) } else { selection.remove(option.export) } }))
                        .toggleStyle(.checkbox)
                }
                .frame(height: 220)
                if let error { PanelErrorText(message: error) }
            }
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply") {
                Task {
                    do {
                        let ordered = field.options.map(\.export).filter { selection.contains($0) }
                        try await appState.fillFields([field.name: ordered], in: tab, actionName: "Select \(field.name)")
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .onAppear { selection = Set(field.values) }
    }
}
