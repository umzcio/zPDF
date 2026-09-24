//
//  PrepareFormPanel.swift
//  zPDF
//
//  Purpose: Prepare Form inspector. The detected-fields list scans the
//  document's widget annotations (/FT field-type key) and is editable —
//  inline rename persists to the annotation's fieldName, delete removes
//  the widget from its page. The six add-field tools (text, checkbox,
//  radio, dropdown, signature, date) are armed tools: arming sets
//  AppState.armedFormFieldTool and the next click on the page places a
//  real widget PDFAnnotation (see PDFViewRepresentable's hit-testing).
//  Phase: 3 — REAL. Limitations: signature fields are bordered text-widget
//  placeholders (PDFKit exposes PDFAnnotationWidgetSubtype.signature for
//  parsing but cannot create working signature fields), and radio buttons
//  are individual radio widgets — true groups (shared field name plus
//  per-button on-state strings) have no UI yet.
//  TODO(phase-3+): preview & distribute flow; radio-button grouping UI;
//  required-flag editing; date-format enforcement on date fields.
//

import PDFKit
import SwiftUI

/// A form field row in the panel: a widget annotation detected in (or
/// added to) the document. Named `DetectedFormField` to stay clear of the
/// engine contract's `FormField` value type (Services/PDFEngine.swift).
struct DetectedFormField: Identifiable {
    enum Kind: String {
        case text
        case checkbox
        case radio
        case dropdown
        case signature
        case date

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

        var symbolName: String {
            switch self {
            case .text: "character"
            case .checkbox: "checkmark.square"
            case .radio: "circle.inset.filled"
            case .dropdown: "chevron.up.chevron.down"
            case .signature: "signature"
            case .date: "calendar"
            }
        }

        /// Default widget size in page points (centered on the click).
        var fieldSize: CGSize {
            switch self {
            case .text: CGSize(width: 140, height: 22)
            case .checkbox, .radio: CGSize(width: 16, height: 16)
            case .dropdown: CGSize(width: 140, height: 22)
            case .signature: CGSize(width: 160, height: 40)
            case .date: CGSize(width: 100, height: 22)
            }
        }
    }

    let id = UUID()
    var name: String
    var kind: Kind
    /// Zero-based page index where the field lives.
    var pageIndex: Int
    /// The backing widget annotation; rename and delete act on it directly.
    let annotation: PDFAnnotation
}

extension DetectedFormField.Kind {
    /// Build the widget annotation this tool places at a page-space point,
    /// bounds clamped to the page's media box. Checkbox and radio share
    /// the /Btn field type and differ by widget control type; the dropdown
    /// is a /Ch pop-up with starter options; signature is a dashed-border
    /// text-widget placeholder (see the file header).
    func makeWidget(at point: CGPoint, named name: String, on page: PDFPage) -> PDFAnnotation {
        let size = fieldSize
        let pageBounds = page.bounds(for: .mediaBox)
        let origin = CGPoint(
            x: min(max(point.x - size.width / 2, pageBounds.minX), pageBounds.maxX - size.width),
            y: min(max(point.y - size.height / 2, pageBounds.minY), pageBounds.maxY - size.height))
        let widget = PDFAnnotation(bounds: CGRect(origin: origin, size: size),
                                   forType: .widget,
                                   withProperties: nil)
        widget.fieldName = name
        // Document appearance must not inherit an interface-only accent setting.
        widget.backgroundColor = NSColor(srgbRed: 0, green: 0.35, blue: 0.73, alpha: 0.12)
        let border = PDFBorder()
        border.style = self == .signature ? .dashed : .solid
        border.lineWidth = 1
        widget.border = border
        switch self {
        case .text, .signature, .date:
            widget.widgetFieldType = .text
            widget.font = NSFont.systemFont(ofSize: 12)
            widget.fontColor = .black
        case .checkbox:
            widget.widgetFieldType = .button
            widget.widgetControlType = .checkBoxControl
            widget.buttonWidgetStateString = "On"
            widget.buttonWidgetState = .offState
        case .radio:
            widget.widgetFieldType = .button
            widget.widgetControlType = .radioButtonControl
            widget.buttonWidgetStateString = "On"
            widget.buttonWidgetState = .offState
        case .dropdown:
            widget.widgetFieldType = .choice
            widget.isListChoice = false
            widget.choices = ["Option 1", "Option 2", "Option 3"]
            widget.widgetStringValue = "Option 1"
            widget.font = NSFont.systemFont(ofSize: 12)
            widget.fontColor = .black
        }
        return widget
    }
}

struct PrepareFormPanel: View {
    @Environment(AppState.self) private var appState
    @State private var fields: [DetectedFormField] = []
    @State private var renamingFieldID: UUID?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Detected fields (\(fields.count))") {
                if fields.isEmpty {
                    Text("No form fields detected in this document.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                } else {
                    ForEach(fields) { field in
                        fieldRow(field)
                    }
                }
            }

            PanelSection(title: "Add field") {
                PanelToolGrid {
                    ForEach(addFieldTools, id: \.kind) { tool in
                        PanelToolButton(title: tool.title,
                                        symbolName: tool.kind.symbolName,
                                        isActive: appState.armedFormFieldTool == tool.kind) {
                            appState.toggleArmedFormFieldTool(tool.kind)
                        }
                    }
                }
                if let armed = appState.armedFormFieldTool {
                    Text("Click the page to place the \(armed.displayName.lowercased()) field.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Colors.accent)
                }
            }

            PanelSection(title: "Distribute") {
                // TODO(phase-3+): preview & distribute flow.
                PanelRow(title: "Preview & distribute…", symbolName: "paperplane")
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }

            PanelNote("Fields are auto-detected from the document's AcroForm data. Pick a tool, then click the page to place it. Signature fields are text-field placeholders — PDFKit cannot create true signature fields.")
        }
        .onAppear(perform: detectFields)
        .onChange(of: appState.activeTabID) { _, _ in detectFields() }
        .onChange(of: appState.annotationRevision) { _, _ in detectFields() }
    }

    private var addFieldTools: [(title: String, kind: DetectedFormField.Kind)] {
        [("Text field", .text),
         ("Checkbox", .checkbox),
         ("Radio button", .radio),
         ("Dropdown", .dropdown),
         ("Signature field", .signature),
         ("Date field", .date)]
    }

    // MARK: - Field rows

    @ViewBuilder
    private func fieldRow(_ field: DetectedFormField) -> some View {
        HStack(spacing: 9) {
            Image(systemName: field.kind.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Colors.accent)
                .frame(width: 16)
            if renamingFieldID == field.id {
                TextField("Field name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitRename(field) }
            } else {
                Text(field.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer()
            Text(field.kind.displayName)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.mutedText)
            if renamingFieldID == field.id {
                Button { commitRename(field) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Colors.accent)
                }
                .buttonStyle(.plain)
                .help("Confirm field name")
                .accessibilityLabel("Confirm field name: \(field.name)")
            } else {
                Button {
                    renamingFieldID = field.id
                    draftName = field.name
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
                .buttonStyle(.plain)
                .help("Rename field")
                .accessibilityLabel("Rename field: \(field.name)")
            }
            Button { delete(field) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
            }
            .buttonStyle(.plain)
            .help("Delete field")
            .accessibilityLabel("Delete field: \(field.name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
        )
    }

    /// Persist an inline rename to the widget's fieldName and refresh.
    private func commitRename(_ field: DetectedFormField) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingFieldID = nil
        guard !name.isEmpty, name != field.name else { return }
        field.annotation.fieldName = name
        appState.noteAnnotationsChanged()
    }

    /// Remove the widget annotation from its page and refresh.
    private func delete(_ field: DetectedFormField) {
        if let page = field.annotation.page {
            page.removeAnnotation(field.annotation)
        } else if let page = appState.activeTab?.pdfDocument?.page(at: field.pageIndex) {
            page.removeAnnotation(field.annotation)
        }
        appState.noteAnnotationsChanged()
    }

    // MARK: - Detection

    /// Scan every page for widget annotations and map /FT field types.
    private func detectFields() {
        guard let document = appState.activeTab?.pdfDocument else {
            fields = []
            return
        }
        var found: [DetectedFormField] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            // PDFAnnotation.type returns the subtype string WITHOUT the
            // leading slash (e.g. "Widget"), matching PDFAnnotationSubtype.
            for annotation in page.annotations where annotation.type == "Widget" {
                let name = annotation.fieldName
                    ?? "Field \(pageIndex + 1)"
                let fieldType = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/FT")) as? String
                found.append(DetectedFormField(name: name,
                                               kind: Self.kind(for: annotation, fieldType: fieldType, name: name),
                                               pageIndex: pageIndex,
                                               annotation: annotation))
            }
        }
        fields = found
    }

    /// Map a widget onto our Kind: the /FT field type first, then the
    /// button control type to split radio from checkbox, then name
    /// heuristics for the text-widget placeholders we create (a signature
    /// placeholder is a text widget named "Signature N", a date field a
    /// text widget named "Date N").
    private static func kind(for annotation: PDFAnnotation,
                             fieldType: String?,
                             name: String) -> DetectedFormField.Kind {
        switch fieldType {
        case "/Tx":
            let lowered = name.lowercased()
            if lowered.contains("signature") { return .signature }
            if lowered.contains("date") { return .date }
            return .text
        case "/Btn":
            return annotation.widgetControlType == .radioButtonControl ? .radio : .checkbox
        case "/Ch": return .dropdown
        case "/Sig": return .signature
        default: return .text
        }
    }
}
