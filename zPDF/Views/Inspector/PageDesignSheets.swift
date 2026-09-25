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
    @State private var scope: ScopeChoice = .all
    @State private var range = ""
    // Shared text styling
    @State private var family: FontFamilyChoice = .sans
    @State private var bold = false
    @State private var fontSize: Double = 10
    @State private var color: Color = .black
    // Header & footer
    @State private var fields: [String: String] = [:]
    @State private var margins = EdgeMargins(left: 36, bottom: 30, right: 36, top: 30)
    @State private var startNumber = 1
    @FocusState private var focusedField: String?
    // Watermark / background
    @State private var useImage = false
    @State private var text = "CONFIDENTIAL"
    @State private var imageURL: URL?
    @State private var opacity: Double = 0.3
    @State private var angle: Double = 45
    @State private var anchor: AnchorChoice = .center
    @State private var under = false
    @State private var fit = false
    @State private var scale: Double = 100
    // Bates
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var batesStart = 1
    @State private var digits = 6
    @State private var batesAnchor: AnchorChoice = .bottomRight
    @State private var result: String?

    private static let headerKeys = ["top-left", "top-center", "top-right"]
    private static let footerKeys = ["bottom-left", "bottom-center", "bottom-right"]

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
                        PageScopePicker(choice: $scope, range: $range)
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
                    Button("Page 1 of N (footer center)") { fields["bottom-center"] = "Page <<page>> of <<pages>>" }
                    Button("Page number (footer right)") { fields["bottom-right"] = "<<page>>" }
                    Button("Date (header right)") { fields["top-right"] = "<<date>>" }
                }
                .fixedSize()
                .help("Common header and footer layouts")
                Spacer()
                Stepper("Start at \(startNumber)", value: $startNumber, in: 0...99_999)
                    .help("Number shown on the first page")
            }
            textStyleRows
            HStack {
                marginField("Top", $margins.top)
                marginField("Bottom", $margins.bottom)
            }
            HStack {
                marginField("Left", $margins.left)
                marginField("Right", $margins.right)
            }
        }
    }

    private func positionRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                TextField(key.hasSuffix("left") ? "Left" : key.hasSuffix("right") ? "Right" : "Center",
                          text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(key.hasSuffix("left") ? .leading : key.hasSuffix("right") ? .trailing : .center)
                    .focused($focusedField, equals: key)
                    .accessibilityLabel("\(key.hasPrefix("top") ? "Header" : "Footer") \(key.hasSuffix("left") ? "left" : key.hasSuffix("right") ? "right" : "center")")
            }
        }
    }

    private func insert(_ token: String) {
        let key = focusedField ?? "bottom-center"
        fields[key, default: ""] += token
    }

    @ViewBuilder
    private var textStyleRows: some View {
        Picker("Font", selection: $family) {
            ForEach(FontFamilyChoice.allCases) { Text($0.title).tag($0) }
        }
        HStack {
            Toggle("Bold", isOn: $bold)
            Spacer()
            TextField("Size", value: $fontSize, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .accessibilityLabel("Font size")
            Stepper("Font size", value: $fontSize, in: 4...300).labelsHidden()
            Text("pt").foregroundStyle(DesignTokens.Colors.mutedText)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
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
            Picker("Source", selection: $useImage) {
                Text("Text").tag(false)
                Text("Image").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if useImage {
                imagePickerRow
                Toggle("Fit to page", isOn: $fit)
                if !fit {
                    LabeledContent("Scale") {
                        HStack {
                            Slider(value: $scale, in: 5...400)
                            Text("\(Int(scale))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            } else {
                TextField("Watermark text", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityLabel("Watermark text")
                textStyleRows
            }
        }
        Section("Appearance") {
            LabeledContent("Opacity") {
                HStack {
                    Slider(value: $opacity, in: 0.05...1)
                        .accessibilityLabel("Opacity")
                    Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Picker("Rotation", selection: $angle) {
                Text("0°").tag(0.0)
                Text("45°").tag(45.0)
                Text("90°").tag(90.0)
                Text("−45°").tag(-45.0)
            }
            .pickerStyle(.segmented)
            LabeledContent("Position") { AnchorGrid(selection: $anchor) }
            Toggle("Behind page content", isOn: $under)
                .help("Place the watermark under text and images instead of on top")
        }
    }

    private var imagePickerRow: some View {
        HStack {
            Text(imageURL?.lastPathComponent ?? "No image chosen")
                .foregroundStyle(imageURL == nil ? DesignTokens.Colors.mutedText : DesignTokens.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                appState.contentEditing.chooseImage { url in
                    imageURL = try? appState.contentEditing.stageImage(url)
                }
            }
            .help("Choose an image file")
        }
    }

    @ViewBuilder
    private var backgroundForm: some View {
        Section("Source") {
            Picker("Source", selection: $useImage) {
                Text("Color").tag(false)
                Text("Image").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if useImage {
                imagePickerRow
                Toggle("Stretch to fill the page", isOn: $fit)
            } else {
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            }
            LabeledContent("Opacity") {
                HStack {
                    Slider(value: $opacity, in: 0.05...1).accessibilityLabel("Opacity")
                    Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var batesForm: some View {
        Section("Number") {
            TextField("Prefix", text: $prefix).accessibilityLabel("Prefix")
            TextField("Suffix", text: $suffix).accessibilityLabel("Suffix")
            Stepper("Start number: \(batesStart)", value: $batesStart, in: 0...999_999_999)
            Stepper("Digits: \(digits)", value: $digits, in: 1...15)
            LabeledContent("Example") {
                Text(batesNumber(batesStart)).font(.system(size: 12, design: .monospaced))
            }
        }
        Section("Appearance") {
            Picker("Position", selection: $batesAnchor) {
                ForEach([AnchorChoice.topLeft, .topCenter, .topRight, .bottomLeft, .bottomCenter, .bottomRight]) {
                    Text($0.title).tag($0)
                }
            }
            textStyleRows
        }
    }

    private func batesNumber(_ n: Int) -> String {
        prefix + String(format: "%0\(digits)d", n) + suffix
    }

    // MARK: - Preview

    private var previewPage: PDFPage? {
        guard let tab = appState.activeTab else { return nil }
        return tab.pdfDocument?.page(at: tab.currentPage - 1)
    }

    private var previewItems: [PageDesignPreview.Item] {
        let rgb = NSColor(color)
        switch kind {
        case .headerFooter:
            return (Self.headerKeys + Self.footerKeys).compactMap { key in
                guard let template = fields[key], !template.isEmpty else { return nil }
                let text = template.replacingOccurrences(of: "<<page>>", with: "\(startNumber)")
                    .replacingOccurrences(of: "<<pages>>", with: "\(max(1, appState.activeTab?.pageCount ?? 1))")
                    .replacingOccurrences(of: "<<date>>", with: Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))
                    .replacingOccurrences(of: "<<isodate>>", with: Date().formatted(.iso8601.year().month().day()))
                return .init(text: text, anchor: AnchorChoice(rawValue: key) ?? .bottomCenter, size: fontSize, color: rgb,
                             opacity: 1, angle: 0, margins: margins, bold: bold)
            }
        case .watermark:
            guard !useImage, !text.isEmpty else { return [] }
            return [.init(text: text, anchor: anchor, size: fontSize, color: rgb, opacity: opacity, angle: angle,
                          margins: EdgeMargins(), bold: bold)]
        case .background:
            return []
        case .bates:
            return [.init(text: batesNumber(batesStart), anchor: batesAnchor, size: fontSize, color: rgb, opacity: 1, angle: 0,
                          margins: EdgeMargins(left: 36, bottom: 24, right: 36, top: 24), bold: bold)]
        }
    }

    private var previewBackground: (NSColor, Double)? {
        kind == .background && !useImage ? (NSColor(color), opacity) : nil
    }

    // MARK: - Engine

    private var canApply: Bool {
        guard pages != nil else { return false }
        switch kind {
        case .headerFooter: return fields.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .watermark: return useImage ? imageURL != nil : !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .background: return useImage ? imageURL != nil : true
        case .bates: return true
        }
    }

    /// nil when the range is invalid; empty array = all pages.
    private var pages: [Int]? {
        guard let tab = appState.activeTab else { return nil }
        if scope == .all { return [] }
        let list = scope.scope(range: range).pages(current: tab.currentPage - 1, count: tab.pageCount)
        return list.isEmpty ? nil : list
    }

    private var fontSpec: [String: Any] { ["family": family.rawValue, "bold": bold] }

    private var settings: [String: Any] {
        var s: [String: Any] = ["family": family.rawValue, "bold": bold, "size": fontSize, "color": NSColor(color).engineRGB,
                                "scope": scope.rawValue, "range": range]
        switch kind {
        case .headerFooter:
            s["fields"] = fields
            s["margins"] = [margins.left, margins.bottom, margins.right, margins.top]
            s["start"] = startNumber
        case .watermark:
            s["text"] = text; s["image"] = useImage; s["opacity"] = opacity; s["angle"] = angle
            s["anchor"] = anchor.rawValue; s["under"] = under; s["fit"] = fit; s["scale"] = scale
        case .background:
            s["image"] = useImage; s["opacity"] = opacity; s["fit"] = fit
        case .bates:
            s["prefix"] = prefix; s["suffix"] = suffix; s["start"] = batesStart; s["digits"] = digits
            s["anchor"] = batesAnchor.rawValue
        }
        return s
    }

    private func operation() -> [String: Any] {
        var op: [String: Any]
        let rgb = NSColor(color).engineRGB
        switch kind {
        case .headerFooter:
            let items = fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            op = ["op": "header_footer", "items": items, "font": fontSpec, "size": fontSize, "color": rgb,
                  "margins": [margins.left, margins.bottom, margins.right, margins.top], "start": startNumber]
        case .watermark:
            op = ["op": "watermark", "opacity": opacity, "angle": angle, "anchor": anchor.rawValue, "under": under]
            if useImage, let imageURL {
                op["image"] = imageURL.path
                op["fit"] = fit
                op["scale"] = scale / 100
            } else {
                op["text"] = text
                op["font"] = fontSpec
                op["size"] = fontSize
                op["color"] = rgb
            }
        case .background:
            op = ["op": "background", "opacity": opacity]
            if useImage, let imageURL { op["image"] = imageURL.path; op["scale_to_fit"] = fit } else { op["color"] = rgb }
        case .bates:
            let vertical = batesAnchor.rawValue.hasPrefix("top")
            op = ["op": "bates", "prefix": prefix, "suffix": suffix, "start": batesStart, "digits": digits,
                  "anchor": batesAnchor.rawValue, "font": fontSpec, "size": fontSize, "color": rgb,
                  "margins": [36, vertical ? 24 : 24, 36, 24]]
        }
        if let pages, !pages.isEmpty { op["pages"] = pages }
        return op
    }

    private func load() async {
        guard !loaded, let tab = appState.activeTab else { return }
        loaded = true
        applyDefaults()
        guard let result = try? await appState.queryDocument("page_design", in: tab),
              let entry = result[kind.rawValue] as? [String: Any] else { return }
        state.pages = entry["pages"] as? [Int] ?? []
        state.settings = entry["settings"] as? [String: Any]
        if let s = state.settings { restore(s) }
    }

    private func applyDefaults() {
        switch kind {
        case .headerFooter:
            fontSize = 10
            fields = ["bottom-center": "Page <<page>> of <<pages>>"]
        case .watermark:
            fontSize = 60; color = Color(nsColor: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)); bold = true
        case .background:
            color = Color(nsColor: NSColor(srgbRed: 1, green: 0.98, blue: 0.9, alpha: 1)); opacity = 1
        case .bates:
            fontSize = 10
        }
    }

    private func restore(_ s: [String: Any]) {
        if let v = s["family"] as? String, let f = FontFamilyChoice(rawValue: v) { family = f }
        if let v = s["bold"] as? Bool { bold = v }
        if let v = s["size"] as? Double { fontSize = v }
        if let v = NSColor(components: s["color"]) { color = Color(nsColor: v) }
        if let v = s["scope"] as? String, let c = ScopeChoice(rawValue: v) { scope = c }
        if let v = s["range"] as? String { range = v }
        switch kind {
        case .headerFooter:
            if let v = s["fields"] as? [String: String] { fields = v }
            if let m = s["margins"] as? [Double], m.count == 4 { margins = EdgeMargins(left: m[0], bottom: m[1], right: m[2], top: m[3]) }
            if let v = s["start"] as? Int { startNumber = v }
        case .watermark:
            if let v = s["text"] as? String { text = v }
            if let v = s["image"] as? Bool { useImage = v && imageURL != nil }
            if let v = s["opacity"] as? Double { opacity = v }
            if let v = s["angle"] as? Double { angle = v }
            if let v = s["anchor"] as? String, let a = AnchorChoice(rawValue: v) { anchor = a }
            if let v = s["under"] as? Bool { under = v }
            if let v = s["fit"] as? Bool { fit = v }
            if let v = s["scale"] as? Double { scale = v }
        case .background:
            if let v = s["opacity"] as? Double { opacity = v }
            if let v = s["fit"] as? Bool { fit = v }
        case .bates:
            if let v = s["prefix"] as? String { prefix = v }
            if let v = s["suffix"] as? String { suffix = v }
            if let v = s["start"] as? Int { batesStart = v }
            if let v = s["digits"] as? Int { digits = v }
            if let v = s["anchor"] as? String, let a = AnchorChoice(rawValue: v) { batesAnchor = a }
        }
    }

    private func apply() {
        guard let tab = appState.activeTab else { return }
        let ops: [[String: Any]] = [operation(), ["op": "tag_overlay_settings", "kind": kind.rawValue, "settings": settings]]
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let results = try await appState.applyDocumentTransform(ops, to: tab, actionName: state.exists ? "Update \(kind.title)" : "Add \(kind.title)")
                appState.contentEditing.invalidateContent()
                if kind == .bates, let first = results.first?["first"] as? String, let last = results.first?["last"] as? String {
                    appState.contentEditing.notice = "Bates numbers \(first) – \(last) added. Next document starts at \(results.first?["next"] as? Int ?? batesStart)."
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
