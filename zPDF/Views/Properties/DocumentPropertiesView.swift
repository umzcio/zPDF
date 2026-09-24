import PDFKit
import SwiftUI

/// Document Properties (⌘D): Description, Security, Fonts, Initial View,
/// Custom and Advanced, like Acrobat. OK applies every change as one Undo
/// step on the working revision (Info and XMP stay in sync); Save writes it.
struct DocumentPropertiesView: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var pane: DocumentPropertiesPane
    @State private var original: DocumentPropertiesModel?
    @State private var draft = PropertiesDraft()
    @State private var baseline = PropertiesDraft()
    @State private var fonts: [FontModel] = []
    @State private var fontsLoading = false
    @State private var loadError: String?
    @State private var applying = false
    @State private var showingXMP = false

    init(tab: DocumentTab, pane: DocumentPropertiesPane) {
        self.tab = tab
        _pane = State(initialValue: pane)
    }

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }
    private var hasChanges: Bool { draft != baseline }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $pane) {
                ForEach(DocumentPropertiesPane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            Group {
                if let original {
                    switch pane {
                    case .description: DescriptionPane(tab: tab, model: original, draft: $draft, canEdit: canEdit)
                    case .security: SecurityPane(tab: tab, model: original)
                    case .fonts: FontsPane(fonts: fonts, loading: fontsLoading)
                    case .initialView: InitialViewPane(draft: $draft, pageCount: original.pageCount, canEdit: canEdit)
                    case .custom: CustomPane(draft: $draft, canEdit: canEdit, showXMP: { showingXMP = true })
                    case .advanced: AdvancedPane(model: original, draft: $draft, canEdit: canEdit)
                    }
                } else if let loadError {
                    ContentUnavailableView("Properties unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(loadError))
                } else {
                    ProgressView("Reading document properties…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if !canEdit {
                    Label(tab.saveBlock != nil ? "This document is read-only." : "Properties can be edited once the document is ready.",
                          systemImage: "lock")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                } else if hasChanges {
                    Text("Changes apply when you click OK and are saved with the document.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(applying || (hasChanges && !canEdit))
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .task { await load() }
        .sheet(isPresented: $showingXMP) {
            XMPEditorView(tab: tab, xmp: original?.xmp ?? "", canEdit: canEdit) { dismiss() }
        }
    }

    private func load() async {
        do {
            let json = try await appState.documentQueryJSON("document_properties", in: tab)
            let model = try DocumentPropertiesModel.load(json)
            original = model
            draft = PropertiesDraft(model)
            baseline = draft
            fontsLoading = true
            fonts = (try? await appState.documentQuery("fonts", in: tab, as: FontsResult.self).items) ?? []
            fontsLoading = false
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply() {
        guard hasChanges else { dismiss(); return }
        let ops = draft.operations(from: baseline)
        guard !ops.isEmpty else { dismiss(); return }
        applying = true
        Task {
            let ok = await appState.performDocumentEdit(ops, actionName: "Change Document Properties", in: tab)
            applying = false
            if ok { dismiss() }
        }
    }
}

/// Editable copy of the properties the dialog changes.
struct PropertiesDraft: Equatable {
    var title = "", author = "", subject = "", keywords = ""
    var custom: [CustomEntry] = []
    var pageLayout = "default", pageMode = "default", fullScreen = false
    var openPage = 1, magnification = "default"
    var fitWindow = false, centerWindow = false, displayDocTitle = false
    var hideMenubar = false, hideToolbar = false, hideWindowUI = false
    var direction = "default", printScaling = "default", duplex = "default", copies = 0
    var language = ""

    struct CustomEntry: Equatable, Identifiable {
        var id = UUID()
        var name: String
        var value: String
    }

    init() {}

    init(_ model: DocumentPropertiesModel) {
        title = model.info.title ?? ""
        author = model.info.author ?? ""
        subject = model.info.subject ?? ""
        keywords = model.info.keywords ?? ""
        custom = model.custom.sorted { $0.key < $1.key }.map { CustomEntry(name: $0.key, value: $0.value) }
        let view = model.initialView
        pageLayout = view.pageLayout ?? "default"
        let prefs = view.viewerPreferences
        if view.pageMode == "FullScreen" {
            fullScreen = true
            pageMode = prefs["NonFullScreenPageMode"]?.string ?? "default"
        } else {
            pageMode = view.pageMode ?? "default"
        }
        openPage = (view.open.page ?? 0) + 1
        switch view.open.zoom {
        case .named(let name)?: magnification = name
        case .percent(let value)?: magnification = value == 100 ? "100" : String(Int(value.rounded()))
        case nil: magnification = "default"
        }
        fitWindow = prefs["FitWindow"]?.bool ?? false
        centerWindow = prefs["CenterWindow"]?.bool ?? false
        displayDocTitle = prefs["DisplayDocTitle"]?.bool ?? false
        hideMenubar = prefs["HideMenubar"]?.bool ?? false
        hideToolbar = prefs["HideToolbar"]?.bool ?? false
        hideWindowUI = prefs["HideWindowUI"]?.bool ?? false
        direction = prefs["Direction"]?.string ?? "default"
        printScaling = prefs["PrintScaling"]?.string ?? "default"
        duplex = prefs["Duplex"]?.string ?? "default"
        copies = prefs["NumCopies"]?.int ?? 0
        language = model.lang ?? ""
    }

    private func nullable(_ value: String) -> Any { value == "default" ? NSNull() : value }

    /// Engine operations turning `old` into this draft.
    func operations(from old: PropertiesDraft) -> [[String: Any]] {
        var ops: [[String: Any]] = []
        var info: [String: Any] = [:]
        if title != old.title { info["title"] = title }
        if author != old.author { info["author"] = author }
        if subject != old.subject { info["subject"] = subject }
        if keywords != old.keywords { info["keywords"] = keywords }
        let newCustom = Dictionary(custom.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, last in last })
        let oldCustom = Dictionary(old.custom.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        let changedCustom = newCustom.filter { oldCustom[$0.key] != $0.value }
        let removed = oldCustom.keys.filter { newCustom[$0] == nil }
        if !info.isEmpty || !changedCustom.isEmpty || !removed.isEmpty {
            var op: [String: Any] = ["op": "set_metadata"]
            if !info.isEmpty { op["info"] = info }
            if !changedCustom.isEmpty { op["custom"] = changedCustom }
            if !removed.isEmpty { op["remove_custom"] = Array(removed) }
            ops.append(op)
        }
        var view: [String: Any] = ["op": "set_initial_view"]
        var viewChanged = false
        if pageLayout != old.pageLayout {
            view["page_layout"] = nullable(pageLayout)
            viewChanged = true
        }
        let mode = fullScreen ? "FullScreen" : pageMode
        let oldMode = old.fullScreen ? "FullScreen" : old.pageMode
        if mode != oldMode || (fullScreen && pageMode != old.pageMode) {
            view["page_mode"] = nullable(mode)
            viewChanged = true
        }
        if openPage != old.openPage || magnification != old.magnification {
            view["open_page"] = max(0, openPage - 1)
            view["open_zoom"] = Double(magnification).map { $0 as Any } ?? magnification
            viewChanged = true
        }
        var prefs: [String: Any] = [:]
        if fitWindow != old.fitWindow { prefs["FitWindow"] = fitWindow }
        if centerWindow != old.centerWindow { prefs["CenterWindow"] = centerWindow }
        if displayDocTitle != old.displayDocTitle { prefs["DisplayDocTitle"] = displayDocTitle }
        if hideMenubar != old.hideMenubar { prefs["HideMenubar"] = hideMenubar }
        if hideToolbar != old.hideToolbar { prefs["HideToolbar"] = hideToolbar }
        if hideWindowUI != old.hideWindowUI { prefs["HideWindowUI"] = hideWindowUI }
        if direction != old.direction { prefs["Direction"] = nullable(direction) }
        if printScaling != old.printScaling { prefs["PrintScaling"] = nullable(printScaling) }
        if duplex != old.duplex { prefs["Duplex"] = nullable(duplex) }
        if copies != old.copies { prefs["NumCopies"] = copies }
        if fullScreen, pageMode != old.pageMode || fullScreen != old.fullScreen {
            prefs["NonFullScreenPageMode"] = nullable(pageMode)
        }
        if !prefs.isEmpty { view["viewer_preferences"] = prefs; viewChanged = true }
        if viewChanged {
            if view["page_layout"] == nil { view["page_layout"] = "keep" }
            if view["page_mode"] == nil { view["page_mode"] = "keep" }
            ops.append(view)
        }
        let lang = language.trimmingCharacters(in: .whitespaces)
        if lang != old.language, !lang.isEmpty { ops.append(["op": "set_language", "lang": lang]) }
        return ops
    }
}

// MARK: - Panes

private struct DescriptionPane: View {
    let tab: DocumentTab
    let model: DocumentPropertiesModel
    @Binding var draft: PropertiesDraft
    let canEdit: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Description") {
                LabeledContent("File", value: tab.displayName)
                TextField("Title", text: $draft.title).disabled(!canEdit)
                HStack {
                    TextField("Author", text: $draft.author).disabled(!canEdit)
                    Button("Use My Name") { draft.author = appState.preferences.commentAuthor }
                        .controlSize(.small)
                        .disabled(!canEdit || appState.preferences.commentAuthor.isEmpty)
                        .help("Fill in the name from Settings ▸ Identity")
                }
                TextField("Subject", text: $draft.subject).disabled(!canEdit)
                TextField("Keywords", text: $draft.keywords, prompt: Text("Separate with commas")).disabled(!canEdit)
            }
            Section("Details") {
                LabeledContent("Created", value: PDFDateText.display(model.info.creationdate))
                LabeledContent("Modified", value: PDFDateText.display(model.info.moddate))
                LabeledContent("Application", value: model.info.creator ?? "—")
            }
            Section("Advanced") {
                LabeledContent("PDF Producer", value: model.info.producer ?? "—")
                LabeledContent("PDF Version", value: model.version)
                if let url = tab.url {
                    LabeledContent("Location") {
                        Button(url.deletingLastPathComponent().path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.link)
                        .help("Show in Finder")
                        .lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("File Size", value: fileSize(url))
                }
                LabeledContent("Page Size", value: pageSize)
                LabeledContent("Number of Pages", value: "\(model.pageCount)")
                LabeledContent("Tagged PDF", value: model.tagged ? "Yes" : "No")
                LabeledContent("Fast Web View", value: model.linearized ? "Yes" : "No")
                if let pdfa = model.pdfa { LabeledContent("Conformance", value: pdfa + (model.pdfua ? ", PDF/UA-1" : "")) }
                else if model.pdfua { LabeledContent("Conformance", value: "PDF/UA-1") }
            }
        }
        .formStyle(.grouped)
    }

    private var pageSize: String {
        guard model.pageSize.count == 2 else { return "—" }
        let unit = appState.preferences.pageUnits
        return "\(unit.format(model.pageSize[0])) × \(unit.format(model.pageSize[1])) \(unit.symbol)"
    }

    private func fileSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " (\(size.formatted()) bytes)"
    }
}

private struct SecurityPane: View {
    let tab: DocumentTab
    let model: DocumentPropertiesModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Document Security") {
                LabeledContent("Security Method", value: model.encrypted || tab.pdfDocument?.isEncrypted == true ? "Password Security" : "No Security")
                if let encryption = model.encryption {
                    LabeledContent("Encryption", value: "\(encryption.method ?? "Standard") \(encryption.bits.map { "\($0)-bit" } ?? "") (R\(encryption.R ?? 0))")
                }
                if ToolID.protect.isImplemented {
                    Button("Change Security Settings…") {
                        dismiss()
                        appState.openTool(.protect)
                    }
                    .disabled(!tab.allowsSaveEdits)
                }
            }
            Section("Document Restrictions Summary") {
                row("Printing", permissions.print, detail: permissions.printHigh ? "High resolution" : permissions.print ? "Low resolution" : nil)
                row("Changing the Document", permissions.modify)
                row("Document Assembly", permissions.assemble)
                row("Content Copying", permissions.copy)
                row("Content Copying for Accessibility", permissions.accessibility)
                row("Commenting", permissions.annotate)
                row("Filling of Form Fields", permissions.fill)
                row("Signing", permissions.fill)
                row("Creation of Template Pages", permissions.assemble)
            }
            Section {
                Text("Restrictions come from the PDF's own security settings. zPDF never runs document JavaScript.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
        .formStyle(.grouped)
    }

    private struct Permissions {
        var print = true, printHigh = true, modify = true, assemble = true, copy = true, accessibility = true
        var annotate = true, fill = true
    }

    /// PDFKit reflects the permissions for the opened password; the engine
    /// reply covers files without an encryption password.
    private var permissions: Permissions {
        if let document = tab.pdfDocument, document.isEncrypted {
            return Permissions(print: document.allowsPrinting, printHigh: document.allowsPrinting,
                               modify: document.allowsDocumentChanges, assemble: document.allowsDocumentAssembly,
                               copy: document.allowsCopying, accessibility: document.allowsContentAccessibility,
                               annotate: document.allowsCommenting, fill: document.allowsFormFieldEntry)
        }
        let p = model.permissions
        return Permissions(print: p["print"] ?? true, printHigh: p["printHigh"] ?? true, modify: p["modify"] ?? true,
                           assemble: p["assemble"] ?? true, copy: p["extract"] ?? true, accessibility: p["accessibility"] ?? true,
                           annotate: p["annotate"] ?? true, fill: p["fillForms"] ?? true)
    }

    private func row(_ title: String, _ allowed: Bool, detail: String? = nil) -> some View {
        LabeledContent(title) {
            Text(allowed ? (detail ?? "Allowed") : "Not Allowed")
                .foregroundStyle(allowed ? DesignTokens.Colors.text : Color.red)
        }
    }
}

private struct FontsPane: View {
    let fonts: [FontModel]
    let loading: Bool

    var body: some View {
        if loading && fonts.isEmpty {
            ProgressView("Reading fonts…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if fonts.isEmpty {
            ContentUnavailableView("No fonts", systemImage: "textformat", description: Text("This document doesn't use any fonts."))
        } else {
            Table(fonts) {
                TableColumn("Font") { font in
                    Text(font.name).help(font.name)
                }
                .width(min: 150, ideal: 200)
                TableColumn("Type") { font in Text(font.type) }
                    .width(min: 80, ideal: 110)
                TableColumn("Encoding") { font in Text(font.encoding) }
                    .width(min: 80, ideal: 110)
                TableColumn("Embedded") { font in
                    Text(font.embedded ? (font.subset ? "Embedded Subset" : "Embedded") : "Not Embedded")
                        .foregroundStyle(font.embedded ? DesignTokens.Colors.text : Color.orange)
                        .help(font.embedded ? (font.embeddedType.map { "Embedded as \($0)" } ?? "") :
                                "Viewers substitute a similar font when this one isn't installed.")
                }
                .width(min: 100, ideal: 120)
                TableColumn("Pages") { font in
                    Text(font.pages.prefix(6).map { "\($0 + 1)" }.joined(separator: ", ") + (font.pages.count > 6 ? "…" : ""))
                }
                .width(min: 50, ideal: 70)
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct InitialViewPane: View {
    @Binding var draft: PropertiesDraft
    let pageCount: Int
    let canEdit: Bool

    var body: some View {
        Form {
            Section("Layout and Magnification") {
                Picker("Navigation tab", selection: $draft.pageMode) {
                    Text("Page Only").tag("default")
                    Text("Bookmarks Panel and Page").tag("UseOutlines")
                    Text("Pages Panel and Page").tag("UseThumbs")
                    Text("Attachments Panel and Page").tag("UseAttachments")
                    Text("Layers Panel and Page").tag("UseOC")
                    if draft.pageMode == "UseNone" { Text("Page Only").tag("UseNone") }
                }
                Picker("Page layout", selection: $draft.pageLayout) {
                    Text("Default").tag("default")
                    Text("Single Page").tag("SinglePage")
                    Text("Single Page Continuous").tag("OneColumn")
                    Text("Two-Up (Facing)").tag("TwoPageLeft")
                    Text("Two-Up Continuous (Facing)").tag("TwoColumnLeft")
                    Text("Two-Up (Cover Page)").tag("TwoPageRight")
                    Text("Two-Up Continuous (Cover Page)").tag("TwoColumnRight")
                }
                Picker("Magnification", selection: $draft.magnification) {
                    Text("Default").tag("default")
                    Text("Actual Size").tag("100")
                    Text("Fit Page").tag("fit_page")
                    Text("Fit Width").tag("fit_width")
                    Text("Fit Height").tag("fit_height")
                    Text("Fit Visible").tag("fit_visible")
                    Divider()
                    ForEach(["25", "50", "75", "125", "150", "200", "400"], id: \.self) { Text("\($0)%").tag($0) }
                    if !["default", "100", "fit_page", "fit_width", "fit_height", "fit_visible", "25", "50", "75", "125", "150", "200", "400"].contains(draft.magnification) {
                        Text("\(draft.magnification)%").tag(draft.magnification)
                    }
                }
                Stepper("Open to page: \(draft.openPage) of \(pageCount)", value: $draft.openPage, in: 1...max(1, pageCount))
            }
            Section("Window Options") {
                Toggle("Resize window to initial page", isOn: $draft.fitWindow)
                Toggle("Center window on screen", isOn: $draft.centerWindow)
                Toggle("Open in Full Screen mode", isOn: $draft.fullScreen)
                Picker("Show", selection: $draft.displayDocTitle) {
                    Text("File Name").tag(false)
                    Text("Document Title").tag(true)
                }
            }
            Section("User Interface Options") {
                Toggle("Hide menu bar", isOn: $draft.hideMenubar)
                Toggle("Hide tool bars", isOn: $draft.hideToolbar)
                Toggle("Hide window controls", isOn: $draft.hideWindowUI)
                Text("These options are stored in the PDF for the viewer that opens it. zPDF applies the navigation tab, page layout and opening page when “Use the document's initial view” is on in Settings ▸ Documents.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
        .formStyle(.grouped)
        .disabled(!canEdit)
    }
}

private struct CustomPane: View {
    @Binding var draft: PropertiesDraft
    let canEdit: Bool
    let showXMP: () -> Void
    @State private var selection: UUID?

    var body: some View {
        Form {
            Section {
                if draft.custom.isEmpty {
                    Text("No custom properties.").foregroundStyle(DesignTokens.Colors.mutedText)
                }
                ForEach($draft.custom) { $entry in
                    HStack {
                        TextField("Name", text: $entry.name)
                            .frame(width: 170)
                            .accessibilityLabel("Property name")
                        TextField("Value", text: $entry.value)
                            .accessibilityLabel("Property value")
                        Button {
                            draft.custom.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Delete this property")
                            .accessibilityLabel("Delete \(entry.name)")
                    }
                }
                Button {
                    draft.custom.append(.init(name: "", value: ""))
                } label: { Label("Add Property", systemImage: "plus") }
            } header: {
                Text("Custom Properties")
            } footer: {
                Text("Names use letters, numbers, - and _. Custom properties are written to the document information dictionary and mirrored in XMP.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            Section("XMP Metadata") {
                Button("Additional Metadata…", action: showXMP)
                    .help("View or edit the document's XMP metadata packet")
            }
        }
        .formStyle(.grouped)
        .disabled(!canEdit)
    }
}

private struct AdvancedPane: View {
    let model: DocumentPropertiesModel
    @Binding var draft: PropertiesDraft
    let canEdit: Bool

    var body: some View {
        Form {
            Section("Reading Options") {
                Picker("Binding", selection: $draft.direction) {
                    Text("Default (Left Edge)").tag("default")
                    Text("Left Edge").tag("L2R")
                    Text("Right Edge").tag("R2L")
                }
                TextField("Language", text: $draft.language, prompt: Text("e.g. en-US"))
                    .help("Primary language used by screen readers and Read Out Loud (BCP 47 tag such as en-US or fr-CA)")
            }
            Section("Print Dialog Presets") {
                Picker("Page Scaling", selection: $draft.printScaling) {
                    Text("Default").tag("default")
                    Text("App Default").tag("AppDefault")
                    Text("None").tag("None")
                }
                Picker("Duplex Mode", selection: $draft.duplex) {
                    Text("Default").tag("default")
                    Text("Simplex").tag("Simplex")
                    Text("Duplex Flip Short Edge").tag("DuplexFlipShortEdge")
                    Text("Duplex Flip Long Edge").tag("DuplexFlipLongEdge")
                }
                Picker("Number of Copies", selection: $draft.copies) {
                    Text("Default").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("Document") {
                LabeledContent("Form fields", value: model.formFields == 0 ? "None" : "\(model.formFields)")
                LabeledContent("XFA form", value: model.hasXfa ? (model.xfaOnly ? "Dynamic (XFA only)" : "Hybrid (XFA and AcroForm)") : "No")
                LabeledContent("Embedded files", value: "\(model.attachments)")
                LabeledContent("Page labels", value: model.pageLabels ? "Yes" : "No")
            }
        }
        .formStyle(.grouped)
        .disabled(!canEdit)
    }
}

/// Raw XMP viewer/editor. Saving replaces the packet and refreshes Info.
struct XMPEditorView: View {
    let tab: DocumentTab
    @State var xmp: String
    let canEdit: Bool
    let onApplied: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var original = ""
    @State private var applying = false

    init(tab: DocumentTab, xmp: String, canEdit: Bool, onApplied: @escaping () -> Void) {
        self.tab = tab
        _xmp = State(initialValue: xmp)
        _original = State(initialValue: xmp)
        self.canEdit = canEdit
        self.onApplied = onApplied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("XMP Metadata").font(.headline)
            Text(xmp.isEmpty ? "This document has no XMP metadata. Title, author and other properties you set are also written as XMP."
                 : "Edit with care: the packet must remain valid XML. Title, author, subject and keywords are read back into the document information.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            TextEditor(text: $xmp)
                .font(.system(size: 11, design: .monospaced))
                .border(DesignTokens.Colors.hairline)
                .disabled(!canEdit)
                .accessibilityLabel("XMP metadata")
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(xmp, forType: .string)
                }
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    applying = true
                    Task {
                        let ok = await appState.performDocumentEdit([["op": "set_xmp", "xmp": xmp]], actionName: "Edit XMP Metadata", in: tab)
                        applying = false
                        if ok { dismiss(); onApplied() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canEdit || xmp == original || xmp.isEmpty || applying)
            }
        }
        .padding(16)
        .frame(width: 640, height: 520)
    }
}
