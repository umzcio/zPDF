//
//  EditPanel.swift
//  zPDF
//
//  Purpose: Edit PDF inspector. Canvas tools (edit text & images, add text,
//  add image, link, crop) run through ContentEditingController; format and
//  object controls act on the canvas selection; page design (header &
//  footer, watermark, background, Bates) and Find & Replace are native
//  document transforms. Every change is one Undo step and saves natively.
//

import AppKit
import SwiftUI

struct EditPanel: View {
    @Environment(AppState.self) private var appState
    @State private var design: PageDesignKind?

    private var controller: ContentEditingController { appState.contentEditing }
    private var editable: Bool { appState.activeTab?.allowsSaveEdits == true }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            toolSection
            contextSection
            if let notice = controller.notice {
                NoticeView(text: notice) { controller.notice = nil }
            }
            PageDesignSection(design: $design)
            FindReplaceSection()
        }
        .disabled(!editable)
        .sheet(item: $design) { kind in
            PageDesignSheet(kind: kind)
                .environment(appState)
        }
        .onDisappear { if appState.activePanel != .edit { controller.deactivate() } }
        .onAppear(perform: consumeDesignRequest)
        .onChange(of: controller.designRequest) { _, _ in consumeDesignRequest() }
    }

    private func consumeDesignRequest() {
        guard let request = controller.designRequest else { return }
        controller.designRequest = nil
        design = request
    }

    // MARK: - Tools

    private var toolSection: some View {
        PanelSection(title: "Tools") {
            PanelToolGrid {
                ForEach([EditCanvasTool.edit, .addText, .addImage, .link, .crop]) { tool in
                    PanelToolButton(title: tool.shortTitle, symbolName: tool.symbolName,
                                    isActive: controller.isActive && controller.tool == tool) {
                        if tool == .addImage {
                            controller.beginAddImage()
                        } else {
                            controller.toggle(tool)
                        }
                    }
                    .help(tool.title + (tool == .edit ? " (⌥⌘E)" : tool == .addText ? " (⌥⌘T)" : ""))
                }
                if controller.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Updating…").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityElement(children: .combine)
                }
            }
            if controller.isActive, let tool = controller.tool {
                PanelNote(tool.hint)
            }
        }
    }

    // MARK: - Context

    @ViewBuilder
    private var contextSection: some View {
        if controller.isActive {
            switch controller.tool {
            case .edit?, .addText?:
                if controller.isEditingText || controller.selectedBlock != nil || controller.tool == .addText {
                    TextFormatSection()
                } else if !controller.selectedObjectsList.isEmpty {
                    ObjectSection()
                }
            case .crop?:
                CropSection()
            case .link?:
                LinksSection()
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Shared controls

/// Square icon button used in the panel's control rows (same metrics everywhere).
struct PanelIconButton: View {
    let title: String
    let symbolName: String
    var isOn = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(role == .destructive ? Color.red : (isOn ? DesignTokens.Colors.accent : DesignTokens.Colors.text))
                .background(isOn ? DesignTokens.Colors.accentTint : DesignTokens.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .stroke(DesignTokens.Colors.hairline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Labeled numeric field with stepper, aligned to a fixed label column.
struct PanelNumberField: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...10_000
    var step: Double = 1
    var unit: String? = nil
    var labelWidth: CGFloat = 54
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .frame(width: labelWidth, alignment: .leading)
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .onSubmit(onCommit)
                .accessibilityLabel(label)
            if let unit {
                Text(unit).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            Stepper(label, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound); onCommit() }),
                    in: range, step: step)
                .labelsHidden()
                .help("Adjust \(label.lowercased())")
        }
    }
}

struct NoticeView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(DesignTokens.Colors.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(DesignTokens.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.mutedText)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(DesignTokens.Colors.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
    }
}

// MARK: - Text format

private struct TextFormatSection: View {
    @Environment(AppState.self) private var appState
    private var controller: ContentEditingController { appState.contentEditing }
    @State private var families: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    @State private var sizeDraft: Double = 12
    @State private var spacingDraft: Double = 1.2

    var body: some View {
        let format = controller.format
        PanelSection(title: controller.isEditingText ? "Text" : (controller.selectedBlock != nil ? "Text box" : "New text")) {
            Picker("Font", selection: Binding(get: { format.family }, set: { family in
                controller.applyFormat { $0.family = family; $0.familyOverride = family }
            })) {
                if !families.contains(format.family) { Text(format.family).tag(format.family) }
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .help("Font")
            .accessibilityLabel("Font")
            HStack(spacing: 6) {
                TextField("Size", value: $sizeDraft, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5).monospacedDigit())
                    .frame(width: 52)
                    .onSubmit { commitSize(sizeDraft) }
                    .help("Font size in points")
                    .accessibilityLabel("Font size")
                Stepper("Font size", value: Binding(get: { sizeDraft }, set: { commitSize($0) }), in: 1...500, step: 1)
                    .labelsHidden()
                    .help("Font size")
                Spacer(minLength: 4)
                ColorPicker("Text color", selection: Binding(get: { Color(nsColor: format.color) }, set: { color in
                    let ns = NSColor(color)
                    controller.applyFormat { $0.color = ns; $0.colorOverride = ns }
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .help("Text color")
                PanelIconButton(title: "Bold (⌘B)", symbolName: "bold", isOn: format.bold) {
                    controller.applyFormat { $0.bold.toggle(); $0.boldOverride = $0.bold }
                }
                PanelIconButton(title: "Italic (⌘I)", symbolName: "italic", isOn: format.italic) {
                    controller.applyFormat { $0.italic.toggle(); $0.italicOverride = $0.italic }
                }
            }
            HStack(spacing: 6) {
                ForEach(TextAlignmentChoice.allCases) { choice in
                    PanelIconButton(title: "Align \(choice.title)", symbolName: choice.symbolName, isOn: format.alignment == choice) {
                        controller.applyFormat { $0.alignment = choice }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .help("Line spacing")
                    .accessibilityHidden(true)
                TextField("Line spacing", value: $spacingDraft, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5).monospacedDigit())
                    .frame(width: 44)
                    .onSubmit { let v = min(max(spacingDraft, 0.5), 4); controller.applyFormat { $0.lineSpacing = v } }
                    .help("Line spacing (multiple of the font size)")
                    .accessibilityLabel("Line spacing")
            }
            if controller.isEditingText {
                HStack {
                    Text("Esc cancels · ⌘↩ or click outside applies")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                    Spacer()
                    Button("Done") { controller.finishEditing(commit: true) }
                        .controlSize(.small)
                        .help("Apply the text changes (⌘↩)")
                }
            } else if let block = controller.selectedBlock {
                HStack(spacing: 6) {
                    Button("Edit Text") {
                        if let page = controller.selectionPage, let content = controller.content(for: page) {
                            controller.beginEditing(block, on: page, content: content, at: nil)
                        }
                    }
                    .controlSize(.small)
                    .help("Type in this text box (Return)")
                    Spacer()
                    PanelIconButton(title: "Rotate Counterclockwise", symbolName: "rotate.left") { controller.rotateSelection(degrees: -90) }
                    PanelIconButton(title: "Rotate Clockwise", symbolName: "rotate.right") { controller.rotateSelection(degrees: 90) }
                    PanelIconButton(title: "Delete Text (⌫)", symbolName: "trash", role: .destructive) { controller.deleteSelection() }
                }
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: controller.format) { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        sizeDraft = controller.format.size
        spacingDraft = controller.format.lineSpacing
    }

    private func commitSize(_ value: Double) {
        let size = min(max(value, 1), 500)
        sizeDraft = size
        controller.applyFormat { $0.size = size; $0.sizeOverride = size }
    }
}

// MARK: - Objects

private struct ObjectSection: View {
    @Environment(AppState.self) private var appState
    private var controller: ContentEditingController { appState.contentEditing }
    @State private var frame = CGRect.zero
    @State private var angle: Double = 0

    var body: some View {
        let objects = controller.selectedObjectsList
        let images = objects.filter(\.kind.isImage)
        let title = objects.count > 1 ? "\(objects.count) objects" : (objects.first?.kind.title ?? "Object")
        PanelSection(title: title) {
            if controller.isCroppingImage {
                PanelNote("Drag the crop handles, then press Return or choose Apply Crop.")
                HStack {
                    Button("Cancel") { controller.cancelImageCrop() }.controlSize(.small)
                    Spacer()
                    Button("Apply Crop") { controller.commitImageCrop() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 6) {
                    PanelIconButton(title: "Rotate Counterclockwise", symbolName: "rotate.left") { controller.rotateSelection(degrees: -90) }
                    PanelIconButton(title: "Rotate Clockwise", symbolName: "rotate.right") { controller.rotateSelection(degrees: 90) }
                    PanelIconButton(title: "Flip Horizontal", symbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        controller.flipSelection(horizontal: true)
                    }
                    PanelIconButton(title: "Flip Vertical", symbolName: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                        controller.flipSelection(horizontal: false)
                    }
                    Spacer(minLength: 0)
                    PanelIconButton(title: "Delete (⌫)", symbolName: "trash", role: .destructive) { controller.deleteSelection() }
                }
                HStack(spacing: 6) {
                    PanelIconButton(title: "Bring to Front", symbolName: "square.3.layers.3d.top.filled") { controller.arrangeSelection(toFront: true) }
                    PanelIconButton(title: "Bring Forward", symbolName: "square.2.layers.3d.top.filled") { controller.stepSelection(forward: true) }
                    PanelIconButton(title: "Send Backward", symbolName: "square.2.layers.3d.bottom.filled") { controller.stepSelection(forward: false) }
                    PanelIconButton(title: "Send to Back", symbolName: "square.3.layers.3d.bottom.filled") { controller.arrangeSelection(toFront: false) }
                    Spacer(minLength: 0)
                    if images.count == 1 && objects.count == 1 {
                        Button("Replace…") { controller.replaceSelectedImage() }
                            .controlSize(.small)
                            .help("Replace this image with another image file")
                        Button("Crop") { controller.beginImageCrop() }
                            .controlSize(.small)
                            .help("Crop this image")
                    }
                }
                if objects.count > 1 {
                    Text("Align")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                    HStack(spacing: 6) {
                        ForEach(ContentEditingController.Alignment.allCases) { alignment in
                            PanelIconButton(title: alignment.title, symbolName: alignment.symbolName) { controller.alignSelection(alignment) }
                        }
                    }
                    if objects.count > 2 {
                        HStack(spacing: 6) {
                            PanelIconButton(title: "Distribute Horizontally", symbolName: "distribute.horizontal") {
                                controller.distributeSelection(horizontal: true)
                            }
                            PanelIconButton(title: "Distribute Vertically", symbolName: "distribute.vertical") {
                                controller.distributeSelection(horizontal: false)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                positionFields
                HStack(spacing: 6) {
                    Text("Rotate")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                    TextField("Degrees", value: $angle, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .onSubmit { controller.rotateSelection(freeDegrees: angle); angle = 0 }
                        .help("Rotate by any angle, clockwise (press Return)")
                        .accessibilityLabel("Rotation angle in degrees")
                    Text("°").foregroundStyle(DesignTokens.Colors.mutedText)
                    Spacer()
                }
            }
        }
        .onAppear { syncFrame() }
        .onChange(of: controller.selection) { _, _ in syncFrame() }
        .onChange(of: controller.contentRevision) { _, _ in syncFrame() }
    }

    private var positionFields: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                compactField("X", value: $frame.origin.x)
                compactField("Y", value: $frame.origin.y)
            }
            HStack(spacing: 8) {
                compactField("W", value: $frame.size.width)
                compactField("H", value: $frame.size.height)
            }
        }
        .help("Position and size in points, measured from the page's bottom-left corner")
    }

    private func compactField(_ label: String, value: Binding<CGFloat>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .frame(width: 12, alignment: .leading)
            TextField(label, value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .onSubmit(commitFrame)
                .accessibilityLabel(["X": "Horizontal position", "Y": "Vertical position", "W": "Width", "H": "Height"][label] ?? label)
        }
    }

    private func syncFrame() {
        guard let page = controller.selectionPage else { return }
        let bounds = controller.selectionBounds(on: page)
        guard !bounds.isNull else { return }
        frame = bounds.applying(page.visualTransform).integralish
    }

    private func commitFrame() {
        guard let page = controller.selectionPage, frame.width > 0.5, frame.height > 0.5 else { return }
        controller.setSelectionFrame(frame.applying(page.visualTransform.inverted()))
    }
}

private extension CGRect {
    var integralish: CGRect {
        CGRect(x: (minX * 10).rounded() / 10, y: (minY * 10).rounded() / 10,
               width: (width * 10).rounded() / 10, height: (height * 10).rounded() / 10)
    }
}

// MARK: - Crop

private struct CropSection: View {
    @Environment(AppState.self) private var appState
    private var controller: ContentEditingController { appState.contentEditing }
    @State private var scope: ScopeChoice = .current
    @State private var range = ""
    @State private var margins = EdgeMargins()

    var body: some View {
        PanelSection(title: "Crop pages") {
            EditPageScopePicker(choice: $scope, range: $range)
            if controller.cropRect == nil {
                Text("Margins")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        marginField("Top", value: $margins.top)
                        marginField("Bottom", value: $margins.bottom)
                    }
                    GridRow {
                        marginField("Left", value: $margins.left)
                        marginField("Right", value: $margins.right)
                    }
                }
            } else if let rect = controller.cropRect, let page = controller.cropPage.flatMap({ appState.activeTab?.pdfDocument?.page(at: $0) }) {
                let visual = rect.applying(page.visualTransform)
                Text(String(format: "Crop area %.0f × %.0f pt", visual.width, visual.height))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
            }
            HStack(spacing: 6) {
                Button("Remove White Margins") {
                    controller.applyCrop(scope: resolvedScope, removeWhiteMargins: true)
                }
                .controlSize(.small)
                .help("Crop each page to its visible content")
                Spacer()
                Button("Reset") { controller.resetCrop(scope: resolvedScope) }
                    .controlSize(.small)
                    .help("Restore the full page area")
            }
            HStack {
                Spacer()
                Button("Apply Crop") {
                    if controller.cropRect != nil {
                        controller.applyCrop(scope: resolvedScope)
                    } else {
                        controller.applyCrop(scope: resolvedScope, margins: margins)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.cropRect == nil && margins == EdgeMargins() || resolvedPages.isEmpty)
                .help("Crop the chosen pages")
            }
        }
    }

    private var resolvedScope: EditPageScope { scope.scope(range: range) }
    private var resolvedPages: [Int] {
        guard let tab = appState.activeTab else { return [] }
        return resolvedScope.pages(current: tab.currentPage - 1, count: tab.pageCount)
    }

    private func marginField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .frame(width: 42, alignment: .leading)
            TextField(label, value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label) margin in points")
        }
    }
}

/// Current page / all pages / custom range, used by page-level tools.
enum ScopeChoice: String, CaseIterable, Identifiable {
    case current, all, range
    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: "This page"
        case .all: "All pages"
        case .range: "Pages"
        }
    }
    func scope(range: String) -> EditPageScope {
        switch self {
        case .current: .current
        case .all: .all
        case .range: .range(range)
        }
    }
}

struct EditPageScopePicker: View {
    @Binding var choice: ScopeChoice
    @Binding var range: String
    var allowsCurrent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Pages", selection: $choice) {
                ForEach(ScopeChoice.allCases.filter { allowsCurrent || $0 != .current }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Pages")
            if choice == .range {
                TextField("e.g. 1-3, 5", text: $range)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .help("Page numbers and ranges, separated by commas")
                    .accessibilityLabel("Page range")
            }
        }
    }
}

// MARK: - Links

private struct LinksSection: View {
    @Environment(AppState.self) private var appState
    private var controller: ContentEditingController { appState.contentEditing }

    var body: some View {
        let page = (appState.activeTab?.currentPage ?? 1) - 1
        let links = controller.links[page] ?? []
        PanelSection(title: "Links on this page (\(links.count))") {
            if links.isEmpty {
                Text("No links yet. Drag on the page to add one.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(links) { link in
                HStack(spacing: 8) {
                    Image(systemName: link.uri != nil ? "globe" : "doc.text")
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(link.summary)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    PanelIconButton(title: "Remove Link", symbolName: "trash", role: .destructive) {
                        controller.removeLink(link, page: page)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: appState.activeTab?.currentPage) { _, _ in controller.loadLinks(forCurrentPage: true) }
    }
}

#Preview {
    ScrollView { EditPanel().padding() }
        .frame(width: DesignTokens.Layout.inspectorWidth)
        .environment(AppState())
}
