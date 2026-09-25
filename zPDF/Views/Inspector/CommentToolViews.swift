//
//  CommentToolViews.swift
//  zPDF
//
//  Purpose: Comment panel building blocks: the three-column tool grid, the
//  appearance inspector (for the armed tool's defaults or the selected
//  comment), the stamp picker with rendered stamp faces, and the review
//  tools (show/hide, on-page filter, import/export, summary, compare,
//  flatten). Built from the shared PanelSection/PanelRow/PanelNote parts.
//

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tool grid

struct CommentToolGrid: View {
    @Environment(AppState.self) private var appState
    let tools: [AnnotationTool]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(tools) { tool in
                PanelToolButton(title: tool.name, symbolName: tool.symbolName, isActive: appState.armedAnnotationTool == tool) {
                    appState.armCommentTool(tool)
                }
                .help(tool.helpText)
                .accessibilityHint(tool.usage)
            }
        }
    }
}

// MARK: - Appearance inspector

/// What the inspector edits: the defaults of an armed tool or one comment.
enum CommentStyleTarget: Equatable {
    case tool(AnnotationTool)
    case selection(ObjectIdentifier)
}

struct CommentStyleCapabilities {
    var color = true, fill = false, opacity = true, lineWidth = false, lineStyle = false, cloudy = false
    var endings = false, font = false

    init(tool: AnnotationTool) {
        switch tool {
        case .highlight, .underline, .strikethrough, .replaceText, .insertText, .stickyNote: break
        case .textBox: color = false; fill = true; lineWidth = true; lineStyle = true; font = true
        case .callout: fill = true; lineWidth = true; lineStyle = true; font = true
        case .drawing: lineWidth = true
        case .rectangle, .polygon: fill = true; lineWidth = true; lineStyle = true; cloudy = true
        case .cloud: fill = true; lineWidth = true; lineStyle = true; cloudy = true
        case .oval: fill = true; lineWidth = true; lineStyle = true
        case .line, .arrow, .polyline: lineWidth = true; lineStyle = true; endings = true; fill = true
        case .stamp: color = false
        case .eraser, .attachFile, .sound: opacity = false
        }
    }

    init(annotation: PDFAnnotation) {
        let drawn = annotation as? CommentAnnotation
        switch annotation.type ?? "" {
        case "Square": self.init(tool: .rectangle)
        case "Circle": self.init(tool: .oval)
        case "Polygon": self.init(tool: .polygon)
        case "PolyLine": self.init(tool: .polyline)
        case "Line": self.init(tool: .line)
        case "Ink": self.init(tool: .drawing)
        case "FreeText": self.init(tool: drawn?.design.shape == .callout || CommentRehydration.needsAppDrawing(annotation) ? .callout : .textBox)
        case "Stamp": self.init(tool: .stamp)
        case "FileAttachment", "Sound": self.init(tool: .attachFile); color = true
        case "Caret": self.init(tool: .insertText)
        default: self.init(tool: .highlight)
        }
    }

    var isEmpty: Bool { !(color || fill || opacity || lineWidth || lineStyle || endings || font) }
}

struct CommentPropertiesView: View {
    @Environment(AppState.self) private var appState
    let target: CommentStyleTarget
    let title: String
    @State private var style = CommentStyle()
    @State private var loadedFor: CommentStyleTarget?

    private var selection: CommentSelection? {
        guard case .selection = target else { return nil }
        return appState.comments.validSelection(in: appState.activeTab)
    }

    private var capabilities: CommentStyleCapabilities {
        switch target {
        case .tool(let tool): CommentStyleCapabilities(tool: tool)
        case .selection: selection.map { CommentStyleCapabilities(annotation: $0.annotation) } ?? CommentStyleCapabilities(tool: .eraser)
        }
    }

    var body: some View {
        let caps = capabilities
        if !caps.isEmpty {
            PanelSection(title: title) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                    if caps.color {
                        GridRow {
                            label("Color")
                            ColorSwatches(selection: Binding(get: { style.color }, set: { style.color = $0; push() }),
                                          allowsNone: false, accessibilityName: "Color")
                        }
                    }
                    if caps.font {
                        GridRow {
                            label("Text")
                            ColorSwatches(selection: Binding(get: { style.textColor }, set: { style.textColor = $0; push() }),
                                          allowsNone: false, accessibilityName: "Text color")
                        }
                    }
                    if caps.fill {
                        GridRow {
                            label("Fill")
                            ColorSwatches(selection: Binding(get: { style.fill }, set: { style.fill = $0; push() }),
                                          allowsNone: true, accessibilityName: "Fill color")
                        }
                    }
                    if caps.opacity {
                        GridRow {
                            label("Opacity")
                            HStack(spacing: 8) {
                                Slider(value: Binding(get: { style.opacity }, set: { style.opacity = ($0 * 100).rounded() / 100; push(commit: false) }),
                                       in: 0.1...1) { editing in if !editing { push() } }
                                    .controlSize(.small)
                                    .accessibilityLabel("Opacity")
                                    .accessibilityValue("\(Int(style.opacity * 100)) percent")
                                Text("\(Int((style.opacity * 100).rounded()))%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(DesignTokens.Colors.mutedText)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .help("Opacity of the comment")
                        }
                    }
                    if caps.lineWidth {
                        GridRow {
                            label("Line")
                            HStack(spacing: 6) {
                                Picker("Line width", selection: Binding(get: { style.lineWidth }, set: { style.lineWidth = $0; push() })) {
                                    if caps.font { Text("None").tag(0.0) }
                                    ForEach([0.5, 1, 1.5, 2, 3, 4, 6, 8, 12], id: \.self) { width in
                                        Text(width == floor(width) ? "\(Int(width)) pt" : String(format: "%.1f pt", width)).tag(width)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 76)
                                .help("Line width")
                                if caps.lineStyle {
                                    Picker("Line style", selection: Binding(get: { style.lineStyle }, set: { style.lineStyle = $0; push() })) {
                                        Text("Solid").tag(CommentLineStyle.solid)
                                        Text("Dashed").tag(CommentLineStyle.dashed)
                                        if caps.cloudy { Text("Cloudy").tag(CommentLineStyle.cloudy) }
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .help("Line style")
                                }
                            }
                        }
                    }
                    if caps.endings {
                        GridRow {
                            label("Ends")
                            HStack(spacing: 6) {
                                endingPicker("Start", Binding(get: { style.startEnding }, set: { style.startEnding = $0; push() }))
                                endingPicker("End", Binding(get: { style.endEnding }, set: { style.endEnding = $0; push() }))
                            }
                        }
                    }
                    if caps.font {
                        GridRow {
                            label("Font")
                            HStack(spacing: 6) {
                                Picker("Font", selection: Binding(get: { style.fontName }, set: { style.fontName = $0; push() })) {
                                    ForEach(Self.fonts, id: \.self) { name in Text(Self.fontTitle(name)).tag(name) }
                                    if !Self.fonts.contains(style.fontName) { Text(style.fontName).tag(style.fontName) }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .help("Font")
                                Stepper(value: Binding(get: { style.fontSize }, set: { style.fontSize = $0; push() }), in: 6...72, step: 1) {
                                    Text("\(Int(style.fontSize)) pt").font(.system(size: 11).monospacedDigit())
                                }
                                .controlSize(.small)
                                .fixedSize()
                                .help("Font size")
                                .accessibilityLabel("Font size")
                                .accessibilityValue("\(Int(style.fontSize)) points")
                            }
                        }
                    }
                }
                if case .tool(let tool) = target, appState.comments.styles.hasCustomColor(for: tool) {
                    Button("Restore Defaults") {
                        appState.comments.styles.reset(tool)
                        style = appState.annotationService.style(for: tool)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help("Use the standard look for \(tool.name.lowercased()) comments")
                }
            }
            .onAppear(perform: load)
            .onChange(of: target) { _, _ in load() }
            .onChange(of: appState.comments.selectionRevision) { _, _ in load() }
            .onChange(of: appState.annotationRevision) { _, _ in if case .selection = target { load() } }
        }
    }

    static let fonts = ["Helvetica", "Helvetica-Bold", "Times-Roman", "Courier", "ArialMT", "Georgia", "Menlo-Regular"]
    static func fontTitle(_ name: String) -> String {
        switch name {
        case "Helvetica": "Helvetica"
        case "Helvetica-Bold": "Helvetica Bold"
        case "Times-Roman": "Times"
        case "Courier": "Courier"
        case "ArialMT": "Arial"
        case "Georgia": "Georgia"
        case "Menlo-Regular": "Menlo"
        default: name
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.Colors.mutedText)
            .frame(width: 50, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    private func endingPicker(_ title: String, _ binding: Binding<CommentLineEnding>) -> some View {
        Picker(title, selection: binding) {
            ForEach(CommentLineEnding.allCases) { ending in Text(ending.title).tag(ending) }
        }
        .labelsHidden()
        .controlSize(.small)
        .help("\(title) of line")
        .accessibilityLabel("\(title) line ending")
    }

    private func load() {
        switch target {
        case .tool(let tool): style = appState.annotationService.style(for: tool)
        case .selection:
            if let selection { style = CommentRehydration.style(of: selection.annotation) }
        }
        loadedFor = target
    }

    private func push(commit: Bool = true) {
        switch target {
        case .tool(let tool):
            appState.comments.styles.set(style, for: tool)
        case .selection:
            guard let selection else { return }
            appState.applyCommentStyle(style, to: selection, commit: commit)
        }
    }
}

/// Palette swatches plus a system colour well for any other colour.
struct ColorSwatches: View {
    @Binding var selection: CommentColor?
    var allowsNone: Bool
    var accessibilityName: String

    init(selection: Binding<CommentColor>, allowsNone: Bool, accessibilityName: String) {
        self._selection = Binding(get: { selection.wrappedValue }, set: { if let value = $0 { selection.wrappedValue = value } })
        self.allowsNone = allowsNone
        self.accessibilityName = accessibilityName
    }

    init(selection: Binding<CommentColor?>, allowsNone: Bool, accessibilityName: String) {
        self._selection = selection
        self.allowsNone = allowsNone
        self.accessibilityName = accessibilityName
    }

    var body: some View {
        HStack(spacing: 4) {
            if allowsNone {
                swatch(nil)
            }
            ForEach(CommentColor.palette.prefix(allowsNone ? 6 : 7), id: \.self) { color in swatch(color) }
            Button {
                ColorPanelBridge.shared.present(initial: selection ?? .black) { selection = $0 }
            } label: {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .overlay(Circle().strokeBorder(DesignTokens.Colors.hairline, lineWidth: 1))
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .overlay(Circle().strokeBorder(isCustom ? DesignTokens.Colors.accent : .clear, lineWidth: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Other color…")
            .accessibilityLabel("Other \(accessibilityName.lowercased())")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }

    private var isCustom: Bool {
        guard let selection else { return false }
        return !CommentColor.palette.prefix(allowsNone ? 6 : 7).contains(selection.opaque)
    }

    private func swatch(_ color: CommentColor?) -> some View {
        let selected = selection?.opaque == color?.opaque && (selection == nil) == (color == nil)
        return Button { selection = color } label: {
            ZStack {
                Circle().fill(color.map { Color(nsColor: $0.nsColor) } ?? Color.white)
                if color == nil {
                    Path { path in path.move(to: CGPoint(x: 3, y: 13)); path.addLine(to: CGPoint(x: 13, y: 3)) }
                        .stroke(Color.red, lineWidth: 1.3)
                }
                Circle().strokeBorder(DesignTokens.Colors.hairline, lineWidth: 1)
            }
            .frame(width: 16, height: 16)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? DesignTokens.Colors.accent : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color?.name ?? "No fill")
        .accessibilityLabel(color?.name ?? "No fill")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Stamps

struct StampPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.comments
        PanelSection(title: "Stamp") {
            stampGrid(StampDesign.standard, selected: session.stampDesign)
            Text("With your name and the time")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .padding(.top, 2)
            stampGrid(StampDesign.dynamicTemplates.map { $0.filled(author: appState.preferences.commentAuthor, date: Date()) },
                      selected: session.stampDesign)
            HStack {
                Text("Custom")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button {
                    addCustomStamp()
                } label: {
                    Label("Add Image…", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Create a stamp from an image (PNG, JPEG, PDF…). It's saved for reuse.")
            }
            .padding(.top, 2)
            let custom = session.stamps.entries.compactMap { entry in session.stamps.design(for: entry).map { (entry, $0) } }
            if custom.isEmpty {
                Text("Add a signature, logo or seal image to reuse it as a stamp.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(custom, id: \.0.id) { entry, design in
                        stampButton(design, selected: session.stampDesign.kind == .image && session.stampDesign.label == design.label
                                    && session.stampDesign.imagePNG == design.imagePNG)
                            .contextMenu {
                                Button("Remove Stamp", role: .destructive) { session.stamps.remove(entry) }
                            }
                    }
                }
            }
        }
    }

    private func stampGrid(_ designs: [StampDesign], selected: StampDesign) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(designs, id: \.label) { design in
                stampButton(design, selected: selected.kind == design.kind && selected.name == design.name && selected.label == design.label)
            }
        }
    }

    private func stampButton(_ design: StampDesign, selected: Bool) -> some View {
        Button {
            appState.comments.stampDesign = design
            if appState.armedAnnotationTool != .stamp { appState.armCommentTool(.stamp) }
        } label: {
            Image(nsImage: StampPreview.image(design, size: CGSize(width: 116, height: 38)))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .stroke(selected ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .help("\(design.displayTitle) — click, then click the page to place it")
        .accessibilityLabel("\(design.displayTitle) stamp")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func addCustomStamp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Stamp Image"
        panel.allowedContentTypes = [.image, .pdf]
        panel.canChooseDirectories = false
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    let entry = try appState.comments.stamps.add(imageAt: url)
                    if let design = appState.comments.stamps.design(for: entry) {
                        appState.comments.stampDesign = design
                        if appState.armedAnnotationTool != .stamp { appState.armCommentTool(.stamp) }
                    }
                } catch {
                    appState.saveError = OpenError(fileName: url.lastPathComponent, message: error.localizedDescription)
                }
            }
        }
    }
}

@MainActor
enum StampPreview {
    private static var cache: [String: NSImage] = [:]

    static func image(_ design: StampDesign, size: CGSize) -> NSImage {
        let key = "\(design.kind.rawValue)|\(design.name)|\(design.label)|\(design.detail ?? "")|\(design.imagePNG?.count ?? 0)|\(size)"
        if let cached = cache[key] { return cached }
        let aspect = design.aspectRatio
        let drawSize = aspect > size.width / size.height ? CGSize(width: size.width, height: size.width / aspect)
                                                          : CGSize(width: size.height * aspect, height: size.height)
        let image = NSImage(size: drawSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            CommentDrawing.drawStamp(design, in: rect, context: context)
            return true
        }
        cache[key] = image
        return image
    }
}

// MARK: - Review tools

struct CommentReviewTools: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var session = appState.comments
        let hasTab = appState.activeTab != nil
        let editable = appState.canEditComments
        PanelSection(title: "Review") {
            VStack(spacing: 0) {
                switchRow("Show comments on page", symbol: "eye",
                          isOn: Binding(get: { session.showsComments }, set: { appState.setCommentsVisible($0) }),
                          help: "Hide or show every comment on the page (⇧⌘8). Hiding never changes the file.")
                switchRow("Filter page like the list", symbol: "line.3.horizontal.decrease.circle",
                          isOn: Binding(get: { session.filtersCanvas }, set: { session.filtersCanvas = $0; appState.refreshCommentVisibility() }),
                          help: "Only show comments that match the Comments list's type, reviewer and status filters.")
                    .disabled(!session.showsComments)
                Divider().padding(.vertical, 4)
                PanelRow(title: "Import Comments…", symbolName: "square.and.arrow.down") {
                    Task { await appState.importComments() }
                }
                .disabled(!editable)
                .help("Add comments from an FDF, XFDF or PDF file")
                PanelRow(title: "Export as XFDF…", symbolName: "square.and.arrow.up") {
                    Task { await appState.exportComments(format: "xfdf") }
                }
                .disabled(!hasTab || appState.activeTab?.editSource == nil)
                .help("Save the comments as XFDF (XML) for other PDF apps")
                PanelRow(title: "Export as FDF…", symbolName: "square.and.arrow.up.on.square") {
                    Task { await appState.exportComments(format: "fdf") }
                }
                .disabled(!hasTab || appState.activeTab?.editSource == nil)
                .help("Save the comments as FDF, keeping their exact appearance")
                PanelRow(title: "Summarize Comments…", symbolName: "doc.text.magnifyingglass") {
                    appState.summarizeComments(print: false)
                }
                .disabled(!hasTab)
                .help("Create a PDF listing every comment with its page")
                PanelRow(title: "Print Comment Summary…", symbolName: "printer") {
                    appState.summarizeComments(print: true)
                }
                .disabled(!hasTab)
                .help("Print a list of every comment with its page")
                PanelRow(title: "Compare Comments…", symbolName: "rectangle.split.2x1") {
                    Task { await appState.compareComments() }
                }
                .disabled(!hasTab || appState.activeTab?.editSource == nil)
                .help("See which comments were added, removed or changed compared with another version")
                PanelRow(title: "Flatten Comments…", symbolName: "square.3.layers.3d.down.right") {
                    Task { await appState.flattenComments() }
                }
                .disabled(!editable)
                .help("Draw comments into the page so they can't be edited")
            }
            if session.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
        }
        .sheet(item: $session.comparison) { comparison in
            CommentComparisonView(comparison: comparison)
        }
    }
}

@MainActor private func switchRow(_ title: String, symbol: String, isOn: Binding<Bool>, help: String) -> some View {
    HStack(spacing: 9) {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(DesignTokens.Colors.mutedText)
            .frame(width: 16)
            .accessibilityHidden(true)
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.Colors.text)
        Spacer(minLength: 8)
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .help(help)
}

/// Opens the shared system color panel and reports picks to one closure.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onPick: ((CommentColor) -> Void)?

    func present(initial: CommentColor, onPick: @escaping (CommentColor) -> Void) {
        self.onPick = onPick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = initial.nsColor
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        if let color = CommentColor(sender.color)?.opaque { onPick?(color) }
    }
}

struct CommentComparisonView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let comparison: CommentComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Comments").font(.headline)
                Text("This document compared with “\(comparison.otherName)”: \(comparison.added.count) added, \(comparison.removed.count) removed, \(comparison.changed.count) changed, \(comparison.unchanged) unchanged.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            List {
                section("Added in this document", comparison.added, symbol: "plus.circle.fill", tint: DesignTokens.Colors.readyGreen, navigable: true)
                section("Changed", comparison.changed, symbol: "pencil.circle.fill", tint: DesignTokens.Colors.accent, navigable: true)
                section("Removed from this document", comparison.removed, symbol: "minus.circle.fill", tint: .red, navigable: false)
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [CommentComparison.Item], symbol: String, tint: Color, navigable: Bool) -> some View {
        Section(title) {
            if items.isEmpty {
                Text("None").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.kind.singular).font(.system(size: 12, weight: .semibold))
                            Text(item.author.isEmpty ? "Unknown author" : item.author)
                                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                        if !item.contents.isEmpty {
                            Text(item.contents).font(.system(size: 12)).lineLimit(3)
                        }
                        if !item.changes.isEmpty {
                            Text("Changed: " + item.changes.joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                        if let before = item.before {
                            Text("Before — \(before)").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(3)
                        }
                    }
                    Spacer()
                    if navigable {
                        Button("Page \(item.page + 1)") {
                            appState.activeTab?.goToPage(item.page + 1)
                            dismiss()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("Go to page \(item.page + 1)")
                    } else {
                        Text("Page \(item.page + 1)").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
