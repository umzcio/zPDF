import PDFKit
import SwiftUI

struct FormFieldReviewView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    let page: PDFPage
    let detect: Bool
    @State private var fields: [DraftFormField] = []
    @State private var selected: UUID?
    @State private var drawType: String?
    @State private var loading = false
    @State private var error: String?
    @State private var usedVision = false

    private var selectedIndex: Int? { fields.firstIndex { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review form fields").font(.title2.bold())
                    Text("Check the suggestions, or draw a field on the page. Changes are written when you Save.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                FieldReviewPreview(page: page, fields: fields, selected: selected, drawType: drawType,
                                   select: { selected = $0 }, add: addDrawn)
                    .accessibilityLabel("Form field preview. Use the field list and position controls to review suggestions.")
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Draw text field") { drawType = "text" }.help("Drag a rectangle on the page for a text field.")
                        Button("Draw checkbox") { drawType = "checkbox" }.help("Drag a rectangle on the page for a checkbox.")
                    }.disabled(loading)
                    Button("Add field at page center") {
                        let crop = page.bounds(for: .cropBox)
                        addDrawn(CGRect(x: crop.midX - 60, y: crop.midY - 10, width: 120, height: 20), "text")
                    }.disabled(loading)
                    Text(drawType == nil ? "Select a field to adjust its name, type, or position." : "Drag on the page to place the field. Escape cancels drawing.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                    if loading {
                        ProgressView("Detecting fields on this page…")
                    } else if fields.isEmpty {
                        Text("No suggestions yet. Draw a field, or add one at the page center and adjust its position.")
                            .foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    List(selection: $selected) {
                        ForEach($fields) { $field in
                            HStack {
                                Toggle("Include \(field.name)", isOn: $field.included).labelsHidden()
                                Text(field.name).lineLimit(1)
                                Spacer()
                                Image(systemName: field.type == "checkbox" ? "checkmark.square" : "character.cursor.ibeam")
                                    .accessibilityLabel(field.type == "checkbox" ? "Checkbox" : "Text field")
                            }.tag(field.id)
                        }
                    }.frame(minHeight: 130)
                    if let i = selectedIndex {
                        TextField("Field name", text: $fields[i].name).textFieldStyle(.roundedBorder).accessibilityLabel("Field name")
                        Picker("Type", selection: $fields[i].type) {
                            Text("Text").tag("text")
                            Text("Checkbox").tag("checkbox")
                        }
                        Grid(alignment: .leading) {
                            GridRow { coordinate("Left", value: $fields[i].bounds.origin.x); coordinate("Bottom", value: $fields[i].bounds.origin.y) }
                            GridRow { coordinate("Width", value: $fields[i].bounds.size.width); coordinate("Height", value: $fields[i].bounds.size.height) }
                        }
                        Text("Position and size in PDF points.").font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                        Button("Remove field", role: .destructive) { fields.remove(at: i); selected = fields.first?.id }
                    }
                    Spacer(minLength: 0)
                    Text(usedVision ? "Suggestions on scanned pages come from image analysis. Check each one before adding."
                         : "Detection uses printed boxes and lines, and image analysis on scanned pages.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                }.padding(16).frame(width: 340)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding(12)
            }
            Divider()
            HStack {
                Text("\(fields.filter(\.included).count) fields selected").foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Fields") {
                    do { try FormFieldAuthoring.apply(fields, page: page, tab: tab, state: state); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || !fields.contains(where: \.included))
            }.padding(16)
        }
        .frame(width: 960, height: 700)
        .tint(DesignTokens.Colors.accent)
        .onExitCommand { if drawType != nil { drawType = nil } else { dismiss() } }
        .task {
            guard detect else { return }
            loading = true
            defer { loading = false }
            do {
                guard let source = tab.editSource, let index = tab.saveBaseline?.sourceIndex(for: page) else {
                    throw NativeSaveError(code: "SOURCE_UNAVAILABLE", message: "Wait for the document to finish opening, then try again.")
                }
                var suggestions = try await NativeSaveBridge.detectFields(source.url, expectedHash: source.hash, page: index)
                // Scanned pages have no vector rules: use Apple Vision on the rendered page.
                if suggestions.isEmpty || ScannedFieldDetector.isRaster(page) {
                    usedVision = true
                    suggestions += await ScannedFieldDetector.detect(on: page)
                }
                guard !Task.isCancelled else { return }
                let occupied = page.annotations.filter { $0.type == "Widget" }.map(\.bounds)
                for suggestion in suggestions {
                    let r = suggestion.rect
                    let rect = CGRect(x: r[0], y: r[1], width: r[2]-r[0], height: r[3]-r[1])
                    if !occupied.contains(where: { $0.intersects(rect) }) { addDrawn(rect, suggestion.type) }
                }
                selected = fields.first?.id
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func coordinate(_ label: String, value: Binding<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption)
            TextField(label, value: Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Field \(label.lowercased()) in points")
        }
    }

    private func addDrawn(_ rect: CGRect, _ type: String) {
        guard fields.count < 200 else { error = "You can add up to 200 fields at a time."; return }
        guard let document = tab.pdfDocument else { return }
        let names = FormFieldAuthoring.names(in: document).union(fields.map(\.name))
        let field = DraftFormField(name: FormFieldAuthoring.nextName(existing: names), type: type, bounds: rect)
        fields.append(field); selected = field.id; drawType = nil
    }
}

private struct FieldReviewPreview: NSViewRepresentable {
    let page: PDFPage
    let fields: [DraftFormField]
    let selected: UUID?
    let drawType: String?
    let select: (UUID) -> Void
    let add: (CGRect, String) -> Void

    func makeNSView(context: Context) -> FieldPreviewCanvas {
        let view = FieldPreviewCanvas()
        let document = PDFDocument()
        if let copy = page.copy() as? PDFPage { document.insert(copy, at: 0) }
        view.document = document
        view.displayMode = .singlePage; view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }
    func updateNSView(_ view: FieldPreviewCanvas, context: Context) {
        view.fields = fields; view.selected = selected; view.drawType = drawType
        view.select = select; view.add = add; view.refresh()
    }
}

private final class FieldPreviewCanvas: PDFView {
    var fields: [DraftFormField] = []
    var selected: UUID?
    var drawType: String?
    var select: ((UUID) -> Void)?
    var add: ((CGRect, String) -> Void)?
    private var overlays: [PDFAnnotation] = []
    private var dragStart: CGPoint?
    private var dragPreview: PDFAnnotation?

    func refresh() {
        guard let page = document?.page(at: 0) else { return }
        for annotation in overlays { page.removeAnnotation(annotation) }
        overlays = fields.filter(\.included).map { field in
            let annotation = PDFAnnotation(bounds: field.bounds, forType: .square, withProperties: nil)
            annotation.color = field.id == selected ? .systemOrange : .systemBlue
            annotation.interiorColor = annotation.color.withAlphaComponent(0.12)
            let border = PDFBorder(); border.lineWidth = field.id == selected ? 2 : 1; annotation.border = border
            page.addAnnotation(annotation)
            return annotation
        }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard let page = document?.page(at: 0) else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        guard page.bounds(for: .cropBox).contains(point) else { return }
        if drawType != nil { dragStart = point }
        else if let field = fields.first(where: { $0.bounds.contains(point) }) { select?(field.id) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let page = document?.page(at: 0) else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let rect = CGRect(x: min(start.x,point.x), y: min(start.y,point.y), width: abs(start.x-point.x), height: abs(start.y-point.y))
            .intersection(page.bounds(for: .cropBox))
        if let dragPreview { page.removeAnnotation(dragPreview) }
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.color = .systemOrange; page.addAnnotation(annotation); dragPreview = annotation
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragPreview = nil }
        guard let page = document?.page(at: 0) else { return }
        if let dragPreview { page.removeAnnotation(dragPreview) }
        guard let start = dragStart, let type = drawType else { return }
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        let rect = CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
            .intersection(page.bounds(for: .cropBox))
        if rect.width >= 4 && rect.height >= 4 { add?(rect, type) }
        needsDisplay = true
    }
}
