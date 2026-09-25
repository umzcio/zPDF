//
//  PrepareFormPanel.swift
//  zPDF
//
//  Purpose: Prepare Form — add every AcroForm field type by dragging on the
//  page (FormsCanvasInteraction), detect fields (vector rules or, on scanned
//  pages, Apple Vision), edit field properties, formats, validation and
//  calculations, tab and calculation order, duplicate across pages, and
//  delete. Every change is a native transform (one Undo step) that writes
//  standard AcroForm structures with appearance streams.
//

import PDFKit
import SwiftUI

/// Legacy PDFKit widget kinds, still referenced by AppState's armed-tool
/// plumbing and reading-presentation state. New fields are created by the
/// engine (`FormFieldKind`), not by PDFKit widgets.
struct DetectedFormField: Identifiable {
    enum Kind: String {
        case text, checkbox, radio, dropdown, signature, date

        var displayName: String {
            switch self {
            case .text: "Text"
            case .checkbox: "Checkbox"
            case .radio: "Radio"
            case .dropdown: "Dropdown"
            case .signature: "Signature"
            case .date: "Date"
            }
        }

        var formKind: FormFieldKind {
            switch self {
            case .text: .text
            case .checkbox: .checkbox
            case .radio: .radio
            case .dropdown: .combo
            case .signature: .signature
            case .date: .date
            }
        }

        func makeWidget(at point: CGPoint, named name: String, on page: PDFPage) -> PDFAnnotation {
            let size = formKind.defaultSize
            let widget = PDFAnnotation(bounds: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                                      width: size.width, height: size.height), forType: .widget, withProperties: nil)
            widget.widgetFieldType = self == .checkbox || self == .radio ? .button : self == .dropdown ? .choice : .text
            widget.fieldName = name
            return widget
        }
    }

    let id = UUID()
    var name: String
    var kind: Kind
    var pageIndex: Int
    let annotation: PDFAnnotation
}

struct PrepareFormPanel: View {
    @Environment(AppState.self) private var appState
    @State private var selectedName: String?
    @State private var filter = ""
    @State private var review: Review?
    @State private var showsTabOrder = false
    @State private var showsCalcOrder = false
    @State private var confirmFlatten = false
    @State private var error: String?
    private struct Review: Identifiable { let id = UUID(); let tab: DocumentTab; let page: PDFPage; let detect: Bool }

    private var tab: DocumentTab? { appState.activeTab }
    private var fields: [FormFieldInfo] { tab?.protection.formFields ?? [] }
    private var selected: FormFieldInfo? { fields.first { $0.name == selectedName } }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            addFieldSection
            fieldsSection
            if let selected, let tab {
                FieldPropertiesView(field: selected, tab: tab, allFields: fields) { renamed in selectedName = renamed }
                    .id(selected.name + "\(tab.editSource?.hash ?? "")")
            }
            orderSection
            if let error { PanelErrorText(message: error) }
        }
        .disabled(tab?.allowsSaveEdits != true)
        .sheet(item: $review) { review in
            FormFieldReviewView(tab: review.tab, page: review.page, detect: review.detect).environment(appState)
        }
        .sheet(isPresented: $showsTabOrder) {
            if let tab { TabOrderSheet(tab: tab).environment(appState) }
        }
        .sheet(isPresented: $showsCalcOrder) {
            if let tab { CalculationOrderSheet(tab: tab).environment(appState) }
        }
        .confirmationDialog("Flatten all form fields?", isPresented: $confirmFlatten) {
            Button("Flatten Fields", role: .destructive) { run { try await appState.flattenFormFields($0) } }
        } message: { Text("Fields become part of the page content and can no longer be edited.") }
        .onAppear {
            if let tab { appState.profileDocument(tab) }
            appState.signatureService.onFieldPlaced = { name in selectedName = name }
        }
    }

    // MARK: Sections

    private var addFieldSection: some View {
        PanelSection(title: "Add field") {
            PanelToolGrid {
                ForEach(FormFieldKind.toolbar) { kind in
                    PanelToolButton(title: kind.shortName, symbolName: kind.symbolName,
                                    isActive: appState.signatureService.armedTool == .field(kind)) {
                        appState.armedAnnotationTool = nil
                        appState.armedFormFieldTool = nil
                        appState.signatureService.arm(.field(kind))
                    }
                    .help("Add a \(kind.displayName.lowercased()): drag on the page, or click to place")
                }
            }
            ArmedToolBanner()
            HStack(spacing: 8) {
                PanelActionButton(title: "Detect fields", symbolName: "wand.and.rays",
                                  help: "Find boxes and lines on this page (including scans) and suggest fields to add") {
                    openReview(detect: true)
                }
                PanelActionButton(title: "Coordinates", symbolName: "ruler",
                                  help: "Place text fields and check boxes by exact position") {
                    openReview(detect: false)
                }
            }
        }
    }

    private var fieldsSection: some View {
        PanelSection(title: "Fields (\(fields.count))") {
            if fields.isEmpty {
                Text("No fields yet. Choose a field type above, then drag on the page.")
                    .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
            } else {
                TextField("Filter fields", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .accessibilityLabel("Filter fields by name")
                    .help("Show fields whose name contains this text")
                let shown = fields.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { field in fieldRow(field) }
                    }
                }
                .frame(maxHeight: 220)
                .background(DesignTokens.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.hairline))
            }
        }
    }

    private func fieldRow(_ field: FormFieldInfo) -> some View {
        let isSelected = field.name == selectedName
        return Button {
            selectedName = isSelected ? nil : field.name
            if !isSelected, let page = field.widgets.first?.page { tab?.goToPage(page + 1) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: field.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white : DesignTokens.Colors.accent)
                    .frame(width: 16)
                Text(field.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.white : DesignTokens.Colors.text)
                Spacer(minLength: 4)
                if field.required {
                    Text("Required").font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.orange)
                }
                Text("p. \((field.widgets.first?.page ?? 0) + 1)")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : DesignTokens.Colors.mutedText)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isSelected ? DesignTokens.Colors.controlAccent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(field.displayKind) on page \((field.widgets.first?.page ?? 0) + 1)")
        .accessibilityLabel("\(field.name), \(field.displayKind)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var orderSection: some View {
        PanelSection(title: "Form") {
            HStack(spacing: 8) {
                PanelActionButton(title: "Tab order…", symbolName: "arrow.right.to.line",
                                  help: "Choose the order Tab moves through fields on each page") { showsTabOrder = true }
                PanelActionButton(title: "Calc order…", symbolName: "function",
                                  help: "Choose the order calculated fields are computed") { showsCalcOrder = true }
                    .disabled(!fields.contains { $0.calculation.kind != "none" })
            }
            PanelActionButton(title: "Flatten form…", symbolName: "square.stack.3d.down.forward",
                              help: "Turn all fields into static page content") { confirmFlatten = true }
                .disabled(fields.isEmpty)
            PanelNote("Fields save as standard PDF form fields with their own appearance, so they stay fillable in zPDF, Preview and Acrobat.")
        }
    }

    private func openReview(detect: Bool) {
        guard let tab, tab.allowsSaveEdits, let page = tab.pdfDocument?.page(at: tab.currentPage - 1) else { return }
        review = Review(tab: tab, page: page, detect: detect)
    }

    private func run(_ action: @escaping @MainActor (DocumentTab) async throws -> Void) {
        guard let tab else { return }
        error = nil
        Task { do { try await action(tab) } catch { self.error = error.localizedDescription } }
    }
}

// MARK: - Field properties

struct FieldPropertiesView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance", options = "Options", format = "Format", calculate = "Calculate"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .appearance: "paintpalette"
            case .options: "list.bullet"
            case .format: "textformat.123"
            case .calculate: "function"
            }
        }
    }

    @Environment(AppState.self) private var appState
    let field: FormFieldInfo
    let tab: DocumentTab
    let allFields: [FormFieldInfo]
    let onRename: (String) -> Void

    @State private var draft: FormFieldInfo
    @State private var pane: Pane = .general
    @State private var applying = false
    @State private var error: String?
    @State private var showsDuplicate = false
    @State private var confirmDelete = false
    @State private var newOption = ""

    init(field: FormFieldInfo, tab: DocumentTab, allFields: [FormFieldInfo], pane: Pane = .general,
         onRename: @escaping (String) -> Void) {
        self.field = field
        self.tab = tab
        self.allFields = allFields
        self.onRename = onRename
        _draft = State(initialValue: field)
        _pane = State(initialValue: pane)
    }

    private var panes: [Pane] {
        switch field.kind {
        case "text", "combo": [.general, .appearance, .options, .format, .calculate]
        case "signature": [.general, .appearance]
        default: [.general, .appearance, .options]
        }
    }

    var body: some View {
        PanelSection(title: "Properties") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: field.symbolName).foregroundStyle(DesignTokens.Colors.accent)
                    Text(field.displayKind).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    PanelIconButton(symbolName: "square.on.square", label: "Duplicate across pages") { showsDuplicate = true }
                        .disabled(tab.pageCount < 2)
                    PanelIconButton(symbolName: "trash", label: "Delete field", role: .destructive) { confirmDelete = true }
                }
                HStack(spacing: 8) {
                    Picker("Section", selection: $pane) {
                        ForEach(panes) { item in
                            Image(systemName: item.symbol).tag(item).accessibilityLabel(item.rawValue).help(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Property section")
                    Text(pane.rawValue).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DesignTokens.Colors.mutedText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Group {
                    switch pane {
                    case .general: generalPane
                    case .appearance: appearancePane
                    case .options: optionsPane
                    case .format: formatPane
                    case .calculate: calculatePane
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                if !field.customScripts.isEmpty {
                    PanelNote("This field has custom JavaScript (\(field.customScripts.joined(separator: ", "))). zPDF keeps it but doesn’t run it.")
                }
                if let error { PanelErrorText(message: error) }
                HStack {
                    Button("Revert") { draft = field; error = nil }
                        .disabled(draft == field || applying)
                        .help("Discard property changes")
                    Spacer()
                    if applying { ProgressView().controlSize(.small) }
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == field || applying)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help("Apply property changes (⌘↩)")
                }
            }
            .padding(10)
            .background(DesignTokens.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.hairline))
        }
        .sheet(isPresented: $showsDuplicate) {
            DuplicateFieldSheet(field: field, tab: tab).environment(appState)
        }
        .confirmationDialog("Delete “\(field.name)”?", isPresented: $confirmDelete) {
            Button("Delete Field", role: .destructive) {
                Task {
                    do { try await appState.deleteFormField(field.name, in: tab); onRename("") }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("All of its widgets are removed. You can undo this.") }
    }

    // MARK: Panes

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelFormRow(label: "Name") {
                TextField("Name", text: $draft.name).accessibilityLabel("Field name")
                    .help("Unique name used for data export and calculations; no periods")
            }
            PanelFormRow(label: "Tooltip") {
                TextField("Shown on hover and read by VoiceOver", text: $draft.tooltip).accessibilityLabel("Tooltip")
            }
            if field.kind != "signature" && field.kind != "button" {
                Toggle("Required", isOn: $draft.required).help("The form can’t be submitted until this field has a value")
            }
            Toggle("Read only", isOn: $draft.readonly).help("People filling the form can’t change this field")
            Toggle("Hidden", isOn: $draft.hidden).help("Hide the field on screen and in print")
            Toggle("Printable", isOn: $draft.printable).help("Include the field when printing")
            if let widget = field.widgets.first {
                PanelFormRow(label: "Position") {
                    Text("x \(Int(widget.rect.minX))  y \(Int(widget.rect.minY))  \(Int(widget.rect.width))×\(Int(widget.rect.height)) pt")
                        .monospacedDigit().foregroundStyle(DesignTokens.Colors.mutedText)
                }
                .help("Page \(widget.page + 1). Drag a new field to change size, or use Duplicate for other pages.")
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            colorRow("Border", value: $draft.borderColor)
            colorRow("Fill", value: $draft.fillColor)
            PanelFormRow(label: "Line") {
                HStack {
                    Picker("Width", selection: $draft.borderWidth) {
                        Text("Thin").tag(1.0); Text("Medium").tag(2.0); Text("Thick").tag(3.0)
                    }.labelsHidden().accessibilityLabel("Border width")
                    Picker("Style", selection: $draft.borderStyle) {
                        ForEach(["solid", "dashed", "beveled", "inset", "underline"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden().accessibilityLabel("Border style")
                }
            }
            if field.kind != "signature" {
                PanelFormRow(label: "Font") {
                    HStack {
                        Picker("Font", selection: $draft.font) {
                            Text("Helvetica").tag("helvetica"); Text("Helvetica Bold").tag("helvetica-bold")
                            Text("Times").tag("times"); Text("Times Bold").tag("times-bold")
                            Text("Courier").tag("courier"); Text("Courier Bold").tag("courier-bold")
                        }.labelsHidden().accessibilityLabel("Font")
                        Picker("Size", selection: $draft.fontSize) {
                            Text("Auto").tag(0.0)
                            ForEach([6.0, 8, 9, 10, 11, 12, 14, 16, 18, 24], id: \.self) { Text("\(Int($0))").tag($0) }
                        }.labelsHidden().fixedSize().accessibilityLabel("Font size")
                    }
                }
                colorRow("Text", value: $draft.textColor, allowsNone: false)
                if ["text", "combo", "list"].contains(field.kind) {
                    PanelFormRow(label: "Align") {
                        Picker("Alignment", selection: $draft.alignment) {
                            Image(systemName: "text.alignleft").tag("left").accessibilityLabel("Left")
                            Image(systemName: "text.aligncenter").tag("center").accessibilityLabel("Center")
                            Image(systemName: "text.alignright").tag("right").accessibilityLabel("Right")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Text alignment")
                    }
                }
            }
        }
        .font(.system(size: 11))
    }

    private func colorRow(_ label: String, value: Binding<[Double]?>, allowsNone: Bool = true) -> some View {
        PanelFormRow(label: label) {
            HStack(spacing: 8) {
                ColorPicker(label, selection: Binding(get: { Color(components: value.wrappedValue ?? [0, 0, 0]) },
                                                      set: { value.wrappedValue = $0.components }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .disabled(value.wrappedValue == nil)
                    .accessibilityLabel("\(label) color")
                if allowsNone {
                    Toggle("None", isOn: Binding(get: { value.wrappedValue == nil },
                                                 set: { value.wrappedValue = $0 ? nil : [0, 0, 0] }))
                        .toggleStyle(.checkbox)
                        .help("No \(label.lowercased()) color")
                }
            }
        }
    }

    @ViewBuilder
    private var optionsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch field.kind {
            case "text", "barcode":
                PanelFormRow(label: "Default") { TextField("Default value", text: $draft.defaultValue).accessibilityLabel("Default value") }
                Toggle("Multi-line", isOn: $draft.multiline).disabled(draft.comb)
                Toggle("Scroll long text", isOn: $draft.scroll)
                Toggle("Check spelling", isOn: $draft.spellcheck)
                Toggle("Password (shows •••)", isOn: $draft.password).disabled(draft.comb)
                PanelFormRow(label: "Char limit") {
                    TextField("None", value: $draft.maxLength, format: .number).frame(width: 60)
                        .accessibilityLabel("Character limit")
                }
                Toggle("Comb of characters", isOn: $draft.comb)
                    .disabled(draft.maxLength == nil || draft.multiline)
                    .help("Space characters evenly into boxes; needs a character limit")
            case "combo", "list":
                optionsEditor
                if field.kind == "combo" {
                    Toggle("Allow custom text", isOn: $draft.editable).help("People can type a value that isn’t in the list")
                } else {
                    Toggle("Multiple selection", isOn: $draft.multiSelect)
                }
                Toggle("Sort items", isOn: $draft.sort)
                Toggle("Commit value immediately", isOn: $draft.commitOnSelect)
            case "checkbox", "radio":
                PanelFormRow(label: "Style") {
                    Picker("Check style", selection: $draft.checkStyle) {
                        ForEach(["check", "circle", "cross", "diamond", "square", "star"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden().accessibilityLabel("Check style")
                }
                PanelFormRow(label: "Export") {
                    TextField("Value when checked", text: Binding(get: { draft.exports.first ?? "" },
                                                                  set: { draft.exports = [$0] + draft.exports.dropFirst() }))
                        .accessibilityLabel("Export value")
                }
                if field.kind == "radio" {
                    Text("Choices: \(field.exports.joined(separator: ", "))")
                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                    Button("Add Choice to Group") {
                        appState.signatureService.arm(.field(.radio))
                        appState.signatureService.radioGroupTarget = field.name
                    }
                    .help("Drag or click on the page to add another button to “\(field.name)”")
                }
                Toggle("Checked by default", isOn: Binding(get: { !draft.defaultValue.isEmpty && draft.defaultValue != "Off" },
                                                           set: { draft.defaultValue = $0 ? (draft.exports.first ?? "Yes") : "" }))
            case "button":
                PanelFormRow(label: "Label") { TextField("Button label", text: $draft.caption).accessibilityLabel("Button label") }
                PanelFormRow(label: "Action") {
                    Picker("Action", selection: $draft.actionKind) {
                        Text("None").tag("none"); Text("Submit form").tag("submit"); Text("Reset form").tag("reset")
                        Text("Print").tag("print"); Text("Open web link").tag("url")
                    }.labelsHidden().accessibilityLabel("Button action")
                }
                if draft.actionKind == "submit" || draft.actionKind == "url" {
                    PanelFormRow(label: "URL") { TextField("https://", text: $draft.actionURL).accessibilityLabel("Action URL") }
                }
                if draft.actionKind == "submit" {
                    PanelFormRow(label: "Send as") {
                        Picker("Format", selection: $draft.actionFormat) {
                            Text("HTML form").tag("html"); Text("FDF").tag("fdf"); Text("XFDF").tag("xfdf"); Text("Whole PDF").tag("pdf")
                        }.labelsHidden().accessibilityLabel("Submit format")
                    }
                }
            default:
                EmptyView()
            }
            if field.kind == "barcode" {
                PanelFormRow(label: "Type") {
                    Picker("Symbology", selection: $draft.barcodeSymbology) {
                        Text("QR Code").tag("qr"); Text("PDF417").tag("pdf417")
                    }.labelsHidden().accessibilityLabel("Barcode type")
                }
                Text("Encodes (tab-separated):").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                fieldPicker(selection: $draft.barcodeFields)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                Text("Export").frame(width: 72, alignment: .leading)
                Color.clear.frame(width: 44, height: 1)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.mutedText)
            .textCase(.uppercase)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach($draft.options) { $option in
                        HStack(spacing: 4) {
                            TextField("Item", text: $option.label).accessibilityLabel("Option label")
                            TextField("Same as item", text: $option.export).frame(width: 72).accessibilityLabel("Option export value")
                                .help("Value saved in the form data (defaults to the item)")
                            PanelIconButton(symbolName: "arrow.up", label: "Move up") { move(option, by: -1) }
                                .disabled(draft.options.first == option)
                            PanelIconButton(symbolName: "minus.circle", label: "Remove item", role: .destructive) {
                                draft.options.removeAll { $0.id == option.id }
                            }
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(max(draft.options.count, 1)) * 26, 182))
            HStack(spacing: 4) {
                TextField("New item", text: $newOption)
                    .onSubmit(addOption)
                    .accessibilityLabel("New option")
                Button("Add", action: addOption).disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add this item to the list")
            }
        }
    }

    private func addOption() {
        let label = newOption.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        draft.options.append(FormFieldInfo.Option(label: label, export: label))
        newOption = ""
    }

    private func move(_ option: FormFieldInfo.Option, by offset: Int) {
        guard let index = draft.options.firstIndex(where: { $0.id == option.id }) else { return }
        let target = index + offset
        guard draft.options.indices.contains(target) else { return }
        draft.options.swapAt(index, target)
    }

    private var formatPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelFormRow(label: "Format") {
                Picker("Format", selection: $draft.format.kind) {
                    Text("None").tag("none"); Text("Number").tag("number"); Text("Percent").tag("percent")
                    Text("Date").tag("date"); Text("Time").tag("time"); Text("Special").tag("special")
                    if field.format.kind == "custom" { Text("Custom script").tag("custom") }
                }.labelsHidden().accessibilityLabel("Value format")
            }
            switch draft.format.kind {
            case "number", "percent":
                PanelFormRow(label: "Decimals") {
                    Stepper("\(draft.format.decimals)", value: $draft.format.decimals, in: 0...10).accessibilityLabel("Decimal places")
                }
                PanelFormRow(label: "Separator") {
                    Picker("Separator", selection: $draft.format.separator) {
                        Text("1,234.56").tag(0); Text("1234.56").tag(1); Text("1.234,56").tag(2); Text("1234,56").tag(3); Text("1'234.56").tag(4)
                    }.labelsHidden().accessibilityLabel("Digit grouping")
                }
                if draft.format.kind == "number" {
                    PanelFormRow(label: "Currency") {
                        HStack {
                            Picker("Currency", selection: $draft.format.currency) {
                                Text("None").tag(""); Text("$").tag("$"); Text("€").tag("€"); Text("£").tag("£"); Text("¥").tag("¥")
                            }.labelsHidden().accessibilityLabel("Currency symbol")
                            Toggle("Before", isOn: $draft.format.prepend).toggleStyle(.checkbox).help("Show the symbol before the number")
                        }
                    }
                    PanelFormRow(label: "Negative") {
                        Picker("Negative numbers", selection: $draft.format.negative) {
                            Text("-1,234").tag(0); Text("Red").tag(1); Text("(1,234)").tag(2); Text("(Red)").tag(3)
                        }.labelsHidden().accessibilityLabel("Negative number style")
                    }
                }
            case "date":
                PanelFormRow(label: "Pattern") {
                    Picker("Date pattern", selection: $draft.format.dateFormat) {
                        ForEach(["mm/dd/yyyy", "m/d/yy", "dd/mm/yyyy", "yyyy-mm-dd", "mmm d, yyyy", "mmmm d, yyyy", "d-mmm-yyyy", "mm/yy"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }.labelsHidden().accessibilityLabel("Date pattern")
                }
            case "time":
                PanelFormRow(label: "Pattern") {
                    Picker("Time pattern", selection: $draft.format.timeStyle) {
                        Text("HH:MM").tag(0); Text("h:MM tt").tag(1); Text("HH:MM:ss").tag(2); Text("h:MM:ss tt").tag(3)
                    }.labelsHidden().accessibilityLabel("Time pattern")
                }
            case "special":
                PanelFormRow(label: "Kind") {
                    Picker("Special format", selection: $draft.format.specialStyle) {
                        Text("ZIP code").tag(0); Text("ZIP + 4").tag(1); Text("Phone number").tag(2); Text("Social Security number").tag(3)
                    }.labelsHidden().accessibilityLabel("Special format")
                }
            default: EmptyView()
            }
            Divider()
            Toggle("Limit the value range", isOn: Binding(get: { draft.validateMin != nil || draft.validateMax != nil },
                                                          set: { on in if on { draft.validateMin = 0 } else { draft.validateMin = nil; draft.validateMax = nil } }))
                .toggleStyle(.checkbox)
                .help("Reject numbers outside a range")
            if draft.validateMin != nil || draft.validateMax != nil {
                PanelFormRow(label: "Between") {
                    HStack {
                        TextField("Min", value: $draft.validateMin, format: .number).accessibilityLabel("Minimum value")
                        Text("and")
                        TextField("Max", value: $draft.validateMax, format: .number).accessibilityLabel("Maximum value")
                    }
                }
            }
        }
        .font(.system(size: 11))
    }

    private var calculatePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelFormRow(label: "Value is") {
                Picker("Calculation", selection: $draft.calculation.kind) {
                    Text("Entered by user").tag("none")
                    Text("Sum (+)").tag("sum"); Text("Product (×)").tag("product"); Text("Average").tag("average")
                    Text("Minimum").tag("min"); Text("Maximum").tag("max")
                    Text("Simplified notation").tag("sfn")
                    if field.calculation.kind == "custom" { Text("Custom script").tag("custom") }
                }.labelsHidden().accessibilityLabel("Calculation")
            }
            switch draft.calculation.kind {
            case "sum", "product", "average", "min", "max":
                Text("Of these fields:").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                fieldPicker(selection: $draft.calculation.fields)
            case "sfn":
                TextField("e.g. (Price * Qty) - Discount", text: $draft.calculation.expression)
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityLabel("Calculation expression")
                Text("Use field names with + − × ÷ and parentheses. Escape spaces and periods in names with a backslash.")
                    .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
            default: EmptyView()
            }
        }
        .font(.system(size: 11))
    }

    private func fieldPicker(selection: Binding<[String]>) -> some View {
        let candidates = allFields.filter { $0.name != field.name && ["text", "combo", "list", "checkbox", "radio"].contains($0.kind) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(candidates) { candidate in
                    Toggle(candidate.name, isOn: Binding(get: { selection.wrappedValue.contains(candidate.name) },
                                                         set: { on in
                        if on { selection.wrappedValue.append(candidate.name) }
                        else { selection.wrappedValue.removeAll { $0 == candidate.name } }
                    }))
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .frame(height: min(CGFloat(candidates.count) * 20 + 12, 140))
        .background(DesignTokens.Colors.inset)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
    }

    // MARK: Apply

    private func apply() {
        var changes: [String: Any] = [:]
        let newName = draft.name.trimmingCharacters(in: .whitespaces)
        if newName != field.name {
            guard !newName.isEmpty, !newName.contains(".") else { error = "Field names can’t be empty or contain periods."; return }
            changes["new_name"] = newName
        }
        if draft.tooltip != field.tooltip { changes["tooltip"] = draft.tooltip }
        if draft.required != field.required { changes["required"] = draft.required }
        if draft.readonly != field.readonly { changes["readonly"] = draft.readonly }
        if draft.hidden != field.hidden { changes["hidden"] = draft.hidden }
        if draft.printable != field.printable { changes["print"] = draft.printable }
        if draft.borderColor != field.borderColor { changes["border_color"] = draft.borderColor.map { $0 as Any } ?? NSNull() }
        if draft.fillColor != field.fillColor { changes["fill_color"] = draft.fillColor.map { $0 as Any } ?? NSNull() }
        if draft.borderWidth != field.borderWidth { changes["border_width"] = draft.borderWidth }
        if draft.borderStyle != field.borderStyle { changes["border_style"] = draft.borderStyle }
        if draft.font != field.font { changes["font"] = draft.font }
        if draft.fontSize != field.fontSize { changes["font_size"] = draft.fontSize }
        if draft.textColor != field.textColor, let color = draft.textColor { changes["text_color"] = color }
        if draft.alignment != field.alignment { changes["alignment"] = draft.alignment }
        if draft.defaultValue != field.defaultValue { changes["default"] = draft.defaultValue }
        if draft.multiline != field.multiline { changes["multiline"] = draft.multiline }
        if draft.scroll != field.scroll { changes["scroll"] = draft.scroll }
        if draft.spellcheck != field.spellcheck { changes["spellcheck"] = draft.spellcheck }
        if draft.password != field.password { changes["password"] = draft.password }
        if draft.maxLength != field.maxLength { changes["max_length"] = draft.maxLength.map { $0 as Any } ?? NSNull() }
        if draft.comb != field.comb { changes["comb"] = draft.comb }
        if draft.options != field.options {
            changes["options"] = draft.options.map { ["label": $0.label, "export": $0.export.isEmpty ? $0.label : $0.export] }
        }
        if draft.editable != field.editable { changes["editable"] = draft.editable }
        if draft.multiSelect != field.multiSelect { changes["multi_select"] = draft.multiSelect }
        if draft.sort != field.sort { changes["sort"] = draft.sort }
        if draft.commitOnSelect != field.commitOnSelect { changes["commit_on_select"] = draft.commitOnSelect }
        if draft.checkStyle != field.checkStyle { changes["check_style"] = draft.checkStyle }
        if draft.exports.first != field.exports.first, let export = draft.exports.first, !export.isEmpty { changes["export_value"] = export }
        if draft.caption != field.caption { changes["caption"] = draft.caption }
        if draft.actionKind != field.actionKind || draft.actionURL != field.actionURL || draft.actionFormat != field.actionFormat {
            changes["action"] = ["kind": draft.actionKind, "url": draft.actionURL, "format": draft.actionFormat]
        }
        if draft.barcodeSymbology != field.barcodeSymbology || draft.barcodeFields != field.barcodeFields {
            changes["barcode"] = ["symbology": draft.barcodeSymbology, "fields": draft.barcodeFields]
            changes["matrix"] = BarcodeEncoder.matrix(for: barcodeData(), symbology: draft.barcodeSymbology) ?? []
        }
        if draft.format != field.format { changes["format"] = draft.format.json }
        if draft.validateMin != field.validateMin || draft.validateMax != field.validateMax {
            changes["validate"] = ["min": draft.validateMin.map { $0 as Any } ?? NSNull(), "max": draft.validateMax.map { $0 as Any } ?? NSNull()]
        }
        if draft.calculation != field.calculation { changes["calculate"] = draft.calculation.json }
        guard !changes.isEmpty else { return }
        applying = true
        error = nil
        Task {
            defer { applying = false }
            do {
                try await appState.updateFormField(field.name, changes: changes, in: tab)
                if let renamed = changes["new_name"] as? String { onRename(renamed) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func barcodeData() -> String {
        draft.barcodeFields.map { name in allFields.first { $0.name == name }?.value ?? "" }.joined(separator: "\t")
    }
}

// MARK: - Sheets

private struct DuplicateFieldSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let field: FormFieldInfo
    let tab: DocumentTab
    @State private var pages: Set<Int> = []
    @State private var error: String?

    var body: some View {
        FormsSheet(title: "Duplicate “\(field.name)”",
                   subtitle: "Copies share one value, like a name repeated in every page header.", width: 360) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("All pages") { pages = Set(0..<tab.pageCount) }
                    Button("None") { pages = [] }
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), alignment: .leading) {
                        ForEach(0..<tab.pageCount, id: \.self) { index in
                            Toggle("Page \(index + 1)", isOn: Binding(get: { pages.contains(index) },
                                                                      set: { if $0 { pages.insert(index) } else { pages.remove(index) } }))
                                .toggleStyle(.checkbox)
                                .disabled(field.widgets.contains { $0.page == index })
                        }
                    }
                }
                .frame(height: 160)
                if let error { PanelErrorText(message: error) }
            }
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Duplicate") {
                Task {
                    do { try await appState.duplicateFormField(field.name, pages: pages.sorted(), in: tab); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(pages.isEmpty)
        }
    }
}

private struct TabOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var page = 0
    @State private var mode = "manual"
    @State private var order: [String] = []
    @State private var error: String?

    var body: some View {
        FormsSheet(title: "Tab Order", subtitle: "Choose how Tab moves between fields on each page.", width: 420) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Page", selection: $page) {
                    ForEach(0..<tab.pageCount, id: \.self) { Text("Page \($0 + 1)").tag($0) }
                }
                Picker("Order", selection: $mode) {
                    Text("Manual (drag to reorder)").tag("manual"); Text("By rows").tag("row")
                    Text("By columns").tag("column"); Text("By document structure").tag("structure")
                }
                if mode == "manual" {
                    List {
                        ForEach(order, id: \.self) { name in
                            Label(name, systemImage: "line.3.horizontal").font(.system(size: 12))
                        }
                        .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(height: 220)
                    Text("Drag fields into the order Tab should follow.").font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                if let error { PanelErrorText(message: error) }
            }
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply") {
                Task {
                    do { try await appState.setTabOrder(page: page, mode: mode, order: mode == "manual" ? order : nil, in: tab); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .onAppear { page = max(0, tab.currentPage - 1); load() }
        .onChange(of: page) { _, _ in load() }
    }

    private func load() {
        mode = tab.protection.tabOrder.indices.contains(page) ? tab.protection.tabOrder[page] : "manual"
        order = tab.protection.formFields.filter { $0.widgets.contains { $0.page == page } }.map(\.name)
    }
}

private struct CalculationOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var order: [String] = []
    @State private var error: String?

    var body: some View {
        FormsSheet(title: "Calculation Order",
                   subtitle: "Fields are calculated top to bottom. Put fields that others depend on first.", width: 380) {
            VStack(alignment: .leading, spacing: 8) {
                List {
                    ForEach(order, id: \.self) { Label($0, systemImage: "function").font(.system(size: 12)) }
                        .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: 220)
                if let error { PanelErrorText(message: error) }
            }
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply") {
                Task {
                    do { try await appState.setCalculationOrder(order, in: tab); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(order.isEmpty)
        }
        .onAppear {
            let calculated = tab.protection.formFields.filter { $0.calculation.kind != "none" }.map(\.name)
            order = tab.protection.calculationOrder.filter(calculated.contains) + calculated.filter { !tab.protection.calculationOrder.contains($0) }
        }
    }
}
