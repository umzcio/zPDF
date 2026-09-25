import AppKit
import PDFKit
import SwiftUI

/// Page-level design tools in the Edit panel (header & footer, watermark,
/// background, Bates numbering). Each writes an app-tagged overlay into the
/// page content that can be updated or removed later.
enum PageDesignKind: String, Identifiable, CaseIterable {
    case headerFooter = "HeaderFooter"
    case watermark = "Watermark"
    case background = "Background"
    case bates = "Bates"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .headerFooter: "Header & Footer"
        case .watermark: "Watermark"
        case .background: "Background"
        case .bates: "Bates Numbering"
        }
    }

    var symbolName: String {
        switch self {
        case .headerFooter: "doc.text"
        case .watermark: "drop"
        case .background: "square.fill.on.square"
        case .bates: "number"
        }
    }

    var subtitle: String {
        switch self {
        case .headerFooter: "Page numbers, dates and text"
        case .watermark: "Text or image across pages"
        case .background: "Color or image behind pages"
        case .bates: "Legal index numbers"
        }
    }
}

struct PageDesignSection: View {
    @Environment(AppState.self) private var appState
    @Binding var design: PageDesignKind?

    var body: some View {
        PanelSection(title: "Page design") {
            ForEach(PageDesignKind.allCases) { kind in
                PanelRow(title: kind.title + "…", symbolName: kind.symbolName) { design = kind }
                    .help("\(kind.title): \(kind.subtitle.lowercased())")
                    .accessibilityHint(kind.subtitle)
            }
        }
    }
}

/// Existing overlay information from the `page_design` query.
struct PageDesignState {
    var pages: [Int] = []
    var settings: [String: Any]?
    var exists: Bool { !pages.isEmpty }
}

enum FontFamilyChoice: String, CaseIterable, Identifiable {
    case sans, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sans: "Sans Serif"
        case .serif: "Serif"
        case .mono: "Monospace"
        }
    }
}

enum AnchorChoice: String, CaseIterable, Identifiable {
    case topLeft = "top-left", topCenter = "top-center", topRight = "top-right"
    case centerLeft = "center-left", center = "center", centerRight = "center-right"
    case bottomLeft = "bottom-left", bottomCenter = "bottom-center", bottomRight = "bottom-right"
    var id: String { rawValue }
    var unit: CGPoint {
        let parts = rawValue.split(separator: "-")
        let vertical = parts.first == "top" ? 1.0 : parts.first == "bottom" ? 0.0 : 0.5
        let horizontal = rawValue.hasSuffix("left") ? 0.0 : rawValue.hasSuffix("right") ? 1.0 : 0.5
        return CGPoint(x: horizontal, y: vertical)
    }
    var title: String {
        rawValue.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

struct PageDesignSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let kind: PageDesignKind

    @State private var state = PageDesignState()
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var model: PageDesignModel
    @FocusState private var focusedField: String?
    @State private var result: String?

    private static let headerKeys = PageDesignModel.headerKeys
    private static let footerKeys = PageDesignModel.footerKeys

    init(kind: PageDesignKind) {
        self.kind = kind
        _model = State(initialValue: PageDesignModel(kind: kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.headline)
                    Text(state.exists ? "This document has a \(kind.title.lowercased()) on \(state.pages.count) page\(state.pages.count == 1 ? "" : "s"). Changes replace it."
                         : kind.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
            .padding(DesignTokens.Spacing.large)
            Divider()
            HStack(alignment: .top, spacing: DesignTokens.Spacing.large) {
                Form {
                    switch kind {
                    case .headerFooter: headerFooterForm
                    case .watermark: watermarkForm
                    case .background: backgroundForm
                    case .bates: batesForm
                    }
                    Section("Pages") {
                        EditPageScopePicker(choice: $model.scope, range: $model.range)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 420)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                        .textCase(.uppercase)
                    PageDesignPreview(page: previewPage, items: previewItems, background: previewBackground)
                        .frame(width: 200, height: 260)
                    if let result {
                        Text(result).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                }
                .padding(.top, DesignTokens.Spacing.large)
                .padding(.trailing, DesignTokens.Spacing.large)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, DesignTokens.Spacing.large)
            }
            Divider()
            HStack {
                if state.exists {
                    Button("Remove \(kind.title)", role: .destructive) { remove() }
                        .help("Remove the \(kind.title.lowercased()) from every page")
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(state.exists ? "Update" : "Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply || working)
            }
            .padding(DesignTokens.Spacing.large)
        }
        .frame(width: 680)
        .task { await load() }
    }

    // MARK: - Forms

    @ViewBuilder
    private var headerFooterForm: some View {
        Section("Header") { positionRow(Self.headerKeys) }
        Section("Footer") { positionRow(Self.footerKeys) }
        Section {
            HStack {
                Menu("Insert") {
                    Button("Page Number") { insert("<<page>>") }
                    Button("Total Pages") { insert("<<pages>>") }
                    Button("Date (MM/DD/YYYY)") { insert("<<date>>") }
                    Button("Date (YYYY-MM-DD)") { insert("<<isodate>>") }
                }
                .fixedSize()
                .help("Insert a page number or date into the selected box")
                Menu("Presets") {
                    Button("Page 1 of N (footer center)") { model.fields["bottom-center"] = "Page <<page>> of <<pages>>" }
                    Button("Page number (footer right)") { model.fields["bottom-right"] = "<<page>>" }
                    Button("Date (header right)") { model.fields["top-right"] = "<<date>>" }
                }
                .fixedSize()
                .help("Common header and footer layouts")
                Spacer()
                Stepper("Start at \(model.startNumber)", value: $model.startNumber, in: 0...99_999)
                    .help("Number shown on the first page")
            }
            textStyleRows
            HStack {
                marginField("Top", $model.margins.top)
                marginField("Bottom", $model.margins.bottom)
            }
            HStack {
                marginField("Left", $model.margins.left)
                marginField("Right", $model.margins.right)
            }
        }
    }

    private func positionRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                TextField(key.hasSuffix("left") ? "Left" : key.hasSuffix("right") ? "Right" : "Center",
                          text: Binding(get: { model.fields[key] ?? "" }, set: { model.fields[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(key.hasSuffix("left") ? .leading : key.hasSuffix("right") ? .trailing : .center)
                    .focused($focusedField, equals: key)
                    .accessibilityLabel("\(key.hasPrefix("top") ? "Header" : "Footer") \(key.hasSuffix("left") ? "left" : key.hasSuffix("right") ? "right" : "center")")
            }
        }
    }

    private func insert(_ token: String) {
        let key = focusedField ?? "bottom-center"
        model.fields[key, default: ""] += token
    }

    @ViewBuilder
    private var textStyleRows: some View {
        Picker("Font", selection: $model.family) {
            ForEach(FontFamilyChoice.allCases) { Text($0.title).tag($0) }
        }
        HStack {
            Toggle("Bold", isOn: $model.bold)
            Spacer()
            TextField("Size", value: $model.fontSize, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .accessibilityLabel("Font size")
            Stepper("Font size", value: $model.fontSize, in: 4...300).labelsHidden()
            Text("pt").foregroundStyle(DesignTokens.Colors.mutedText)
            ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.color) }, set: { model.color = NSColor($0) }), supportsOpacity: false)
                .labelsHidden()
                .help("Text color")
        }
    }

    private func marginField(_ label: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .accessibilityLabel("\(label) margin in points")
        }
    }

    @ViewBuilder
    private var watermarkForm: some View {
        Section("Source") {
            Picker("Source", selection: $model.useImage) {
                Text("Text").tag(false)
                Text("Image").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.useImage {
                imagePickerRow
                Toggle("Fit to page", isOn: $model.fit)
                if !model.fit {
                    LabeledContent("Scale") {
                        HStack {
                            Slider(value: $model.scale, in: 5...400)
                            Text("\(Int(model.scale))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            } else {
                TextField("Watermark text", text: $model.text, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityLabel("Watermark text")
                textStyleRows
            }
        }
        Section("Appearance") {
            LabeledContent("Opacity") {
                HStack {
                    Slider(value: $model.opacity, in: 0.05...1)
                        .accessibilityLabel("Opacity")
                    Text("\(Int(model.opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Picker("Rotation", selection: $model.angle) {
                Text("0°").tag(0.0)
                Text("45°").tag(45.0)
                Text("90°").tag(90.0)
                Text("−45°").tag(-45.0)
            }
            .pickerStyle(.segmented)
            LabeledContent("Position") { AnchorGrid(selection: $model.anchor) }
            Toggle("Behind page content", isOn: $model.under)
                .help("Place the watermark under text and images instead of on top")
        }
    }

    private var imagePickerRow: some View {
        HStack {
            Text(model.imageURL?.lastPathComponent ?? "No image chosen")
                .foregroundStyle(model.imageURL == nil ? DesignTokens.Colors.mutedText : DesignTokens.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                appState.contentEditing.chooseImage { url in
                    model.imageURL = try? appState.contentEditing.stageImage(url)
                }
            }
            .help("Choose an image file")
        }
    }

    @ViewBuilder
    private var backgroundForm: some View {
        Section("Source") {
            Picker("Source", selection: $model.useImage) {
                Text("Color").tag(false)
                Text("Image").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.useImage {
                imagePickerRow
                Toggle("Stretch to fill the page", isOn: $model.fit)
            } else {
                ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.color) }, set: { model.color = NSColor($0) }), supportsOpacity: false)
            }
            LabeledContent("Opacity") {
                HStack {
                    Slider(value: $model.opacity, in: 0.05...1).accessibilityLabel("Opacity")
                    Text("\(Int(model.opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var batesForm: some View {
        Section("Number") {
            TextField("Prefix", text: $model.prefix).accessibilityLabel("Prefix")
            TextField("Suffix", text: $model.suffix).accessibilityLabel("Suffix")
            Stepper("Start number: \(model.batesStart)", value: $model.batesStart, in: 0...999_999_999)
            Stepper("Digits: \(model.digits)", value: $model.digits, in: 1...15)
            LabeledContent("Example") {
                Text(model.batesNumber(model.batesStart)).font(.system(size: 12, design: .monospaced))
            }
        }
        Section("Appearance") {
            Picker("Position", selection: $model.batesAnchor) {
                ForEach([AnchorChoice.topLeft, .topCenter, .topRight, .bottomLeft, .bottomCenter, .bottomRight]) {
                    Text($0.title).tag($0)
                }
            }
            textStyleRows
        }
    }

    // MARK: - Preview

    private var previewPage: PDFPage? {
        guard let tab = appState.activeTab else { return nil }
        return tab.pdfDocument?.page(at: tab.currentPage - 1)
    }

    private var previewItems: [PageDesignPreview.Item] {
        let rgb = model.color
        let pageCount = appState.activeTab?.pageCount ?? 1
        switch kind {
        case .headerFooter:
            return (Self.headerKeys + Self.footerKeys).compactMap { key in
                guard let template = model.fields[key], !template.isEmpty else { return nil }
                return .init(text: model.expanded(template, pageCount: pageCount), anchor: AnchorChoice(rawValue: key) ?? .bottomCenter,
                             size: model.fontSize, color: rgb, opacity: 1, angle: 0, margins: model.margins, bold: model.bold)
            }
        case .watermark:
            guard !model.useImage, !model.text.isEmpty else { return [] }
            return [.init(text: model.text, anchor: model.anchor, size: model.fontSize, color: rgb, opacity: model.opacity,
                          angle: model.angle, margins: EdgeMargins(), bold: model.bold)]
        case .background:
            return []
        case .bates:
            return [.init(text: model.batesNumber(model.batesStart), anchor: model.batesAnchor, size: model.fontSize, color: rgb,
                          opacity: 1, angle: 0, margins: EdgeMargins(left: 36, bottom: 24, right: 36, top: 24), bold: model.bold)]
        }
    }

    private var previewBackground: (NSColor, Double)? {
        kind == .background && !model.useImage ? (model.color, model.opacity) : nil
    }

    // MARK: - Engine

    private var current: (page: Int, count: Int) {
        guard let tab = appState.activeTab else { return (0, 0) }
        return (tab.currentPage - 1, tab.pageCount)
    }

    private var canApply: Bool { appState.activeTab != nil && model.canApply(current: current.page, count: current.count) }

    private func load() async {
        guard !loaded, let tab = appState.activeTab else { return }
        loaded = true
        guard let result = try? await appState.queryDocument("page_design", in: tab),
              let entry = result[kind.rawValue] as? [String: Any] else { return }
        state.pages = entry["pages"] as? [Int] ?? []
        state.settings = entry["settings"] as? [String: Any]
        if let s = state.settings { model.restore(s) }
    }

    private func apply() {
        guard let tab = appState.activeTab else { return }
        let ops = model.operations(current: current.page, count: current.count)
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let results = try await appState.applyDocumentTransform(ops, to: tab, actionName: state.exists ? "Update \(kind.title)" : "Add \(kind.title)")
                appState.contentEditing.invalidateContent()
                if kind == .bates, let first = results.first?["first"] as? String, let last = results.first?["last"] as? String {
                    appState.contentEditing.notice = "Bates numbers \(first) – \(last) added. Next document starts at \(results.first?["next"] as? Int ?? model.batesStart)."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove() {
        guard let tab = appState.activeTab else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await appState.applyDocumentTransform([["op": "remove_overlays", "kind": kind.rawValue]], to: tab,
                                                          actionName: "Remove \(kind.title)")
                appState.contentEditing.invalidateContent()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// 3×3 position chooser.
struct AnchorGrid: View {
    @Binding var selection: AnchorChoice

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let anchor = AnchorChoice.allCases[row * 3 + column]
                        Button { selection = anchor } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selection == anchor ? DesignTokens.Colors.accent : DesignTokens.Colors.inset)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(DesignTokens.Colors.hairline, lineWidth: 1))
                                .frame(width: 16, height: 12)
                        }
                        .buttonStyle(.plain)
                        .help(anchor.title)
                        .accessibilityLabel(anchor.title)
                        .accessibilityAddTraits(selection == anchor ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// Schematic preview: the current page thumbnail with the overlay drawn on top.
struct PageDesignPreview: View {
    struct Item {
        let text: String
        let anchor: AnchorChoice
        let size: Double
        let color: NSColor
        let opacity: Double
        let angle: Double
        let margins: EdgeMargins
        let bold: Bool
    }

    let page: PDFPage?
    let items: [Item]
    let background: (NSColor, Double)?

    var body: some View {
        GeometryReader { proxy in
            let pageSize = page?.visualBounds.size ?? CGSize(width: 612, height: 792)
            let scale = min(proxy.size.width / pageSize.width, proxy.size.height / pageSize.height)
            let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white)
                if let (color, opacity) = background {
                    Rectangle().fill(Color(nsColor: color)).opacity(opacity)
                }
                if let page {
                    Image(nsImage: page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox))
                        .resizable()
                        .blendMode(background == nil ? .normal : .multiply)
                }
                Canvas { context, canvasSize in
                    for item in items {
                        let font = Font.system(size: max(3, item.size * scale), weight: item.bold ? .bold : .regular)
                        let text = Text(item.text).font(font).foregroundColor(Color(nsColor: item.color))
                        let resolved = context.resolve(text)
                        let measured = resolved.measure(in: canvasSize)
                        let u = item.anchor.unit
                        let mx = item.margins.left * scale, my = item.margins.bottom * scale
                        let x = mx + (canvasSize.width - 2 * mx) * u.x
                        let y = canvasSize.height - (my + (canvasSize.height - 2 * my) * u.y)
                        var copy = context
                        copy.opacity = item.opacity
                        copy.translateBy(x: x, y: y)
                        copy.rotate(by: .degrees(-item.angle))
                        let dx = u.x == 0 ? 0 : (u.x == 1 ? -measured.width : -measured.width / 2)
                        let dy = u.y == 1 ? 0 : (u.y == 0 ? -measured.height : -measured.height / 2)
                        copy.draw(resolved, at: CGPoint(x: item.angle == 0 ? dx : -measured.width / 2,
                                                        y: item.angle == 0 ? dy : -measured.height / 2), anchor: .topLeading)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(DesignTokens.Colors.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Preview of the current page")
        }
    }
}

// MARK: - Find & Replace

struct FindReplaceSection: View {
    @Environment(AppState.self) private var appState
    @State private var find = ""
    @State private var replace = ""
    @State private var matchCase = false
    @State private var wholeWords = false
    @State private var currentPageOnly = false
    @State private var count: Int?
    @FocusState private var findFocused: Bool

    var body: some View {
        let controller = appState.contentEditing
        PanelSection(title: "Find & replace") {
            TextField("Find", text: $find)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { countMatches() }
                .onChange(of: find) { _, _ in count = nil }
                .accessibilityLabel("Find text")
            TextField("Replace with", text: $replace)
                .textFieldStyle(.roundedBorder)
                .onSubmit { replaceAll() }
                .accessibilityLabel("Replacement text")
            HStack(spacing: 12) {
                Toggle("Match case", isOn: $matchCase)
                Toggle("Whole words", isOn: $wholeWords)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            Toggle("Current page only", isOn: $currentPageOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            HStack {
                if let count {
                    Text(count == 1 ? "1 match" : "\(count) matches")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
                Button("Find") { countMatches() }
                    .controlSize(.small)
                    .disabled(find.isEmpty)
                    .help("Count and highlight matches")
                Button("Replace All") { replaceAll() }
                    .controlSize(.small)
                    .disabled(find.isEmpty || controller.isBusy)
                    .help("Replace every match in the page text")
            }
        }
        .onChange(of: appState.contentEditing.findRequest) { _, _ in findFocused = true }
    }

    private func countMatches() {
        guard let tab = appState.activeTab, let document = tab.pdfDocument, !find.isEmpty else { return }
        var options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        options.insert(.literal)
        var matches = document.findString(find, withOptions: options)
        if wholeWords { matches = matches.filter { SearchWordBoundary.containsWholeWords($0) } }
        if currentPageOnly, let page = document.page(at: tab.currentPage - 1) { matches = matches.filter { $0.pages.contains(page) } }
        count = matches.count
        tab.searchCaseSensitive = matchCase
        tab.searchWholeWords = wholeWords
        tab.searchText = find
        tab.updateSearchResults()
    }

    private func replaceAll() {
        guard let tab = appState.activeTab, !find.isEmpty else { return }
        var op: [String: Any] = ["op": "replace_text", "find": find, "replace": replace, "match_case": matchCase,
                                 "whole_word": wholeWords]
        if currentPageOnly { op["pages"] = [tab.currentPage - 1] }
        let controller = appState.contentEditing
        controller.perform([op], name: "Replace Text") { _, _ in } completion: { results in
            let replaced = results.first?["replaced"] as? Int ?? 0
            let substituted = results.first?["substituted"] as? [String] ?? []
            count = nil
            var message = replaced == 0 ? "No matches were found in the page text." : "Replaced \(replaced) match\(replaced == 1 ? "" : "es")."
            if !substituted.isEmpty { message += " Some characters used a matching font from this Mac." }
            controller.notice = message
            tab.searchText = ""
            tab.updateSearchResults()
        }
    }
}
