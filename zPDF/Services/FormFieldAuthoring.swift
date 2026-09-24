import PDFKit
import SwiftUI

struct DraftFormField: Identifiable {
    let id = UUID()
    var name: String
    var type: String
    var bounds: CGRect
    var included = true
}

@MainActor
enum FormFieldAuthoring {
    static func names(in document: PDFDocument) -> Set<String> {
        Set((0..<document.pageCount).flatMap { document.page(at: $0)?.annotations.compactMap(\.fieldName) ?? [] })
    }

    static func nextName(existing: Set<String>) -> String {
        var number = 1
        while existing.contains("Field \(number)") { number += 1 }
        return "Field \(number)"
    }

    static func widget(_ field: DraftFormField) -> PDFAnnotation {
        let widget = PDFAnnotation(bounds: field.bounds, forType: .widget, withProperties: nil)
        widget.setValue("1", forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFNewField"))
        widget.setValue(field.name, forAnnotationKey: PDFAnnotationKey(rawValue: "/TU"))
        widget.shouldPrint = true
        widget.isReadOnly = false
        widget.backgroundColor = .clear
        let border = PDFBorder(); border.lineWidth = 0; widget.border = border
        if field.type == "checkbox" {
            widget.widgetFieldType = .button
            widget.widgetControlType = .checkBoxControl
            widget.buttonWidgetState = .offState
            widget.buttonWidgetStateString = "Yes"
            widget.buttonWidgetState = .offState
        } else {
            widget.widgetFieldType = .text
            widget.font = NSFont(name: "Helvetica", size: 10)
            widget.fontColor = .black
            widget.widgetStringValue = ""
        }
        // PDFKit assigns a generated name when widgetFieldType changes.
        widget.fieldName = field.name
        return widget
    }

    static func apply(_ fields: [DraftFormField], page: PDFPage, tab: DocumentTab, state: AppState) throws {
        guard state.activeTab === tab, tab.allowsSaveEdits, let document = tab.pdfDocument,
              document.index(for: page) != NSNotFound else {
            throw NativeSaveError(code: "STALE_PAGE", message: "The document changed. Close this review and try again.")
        }
        var existing = names(in: document)
        let selected = fields.filter(\.included)
        guard !selected.isEmpty, selected.count <= 200 else {
            throw NativeSaveError(code: "INVALID_FIELDS", message: "Select between 1 and 200 fields.")
        }
        let crop = page.bounds(for: .cropBox)
        for field in selected {
            let r = field.bounds
            guard !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.name.count <= 200, !field.name.contains("."), !field.name.contains("\0"),
                  existing.insert(field.name).inserted else {
                throw NativeSaveError(code: "INVALID_FIELD_NAME", message: "Give each field a unique name without dots.")
            }
            guard [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite), r.width >= 4, r.height >= 4,
                  crop.contains(r), ["text", "checkbox"].contains(field.type) else {
                throw NativeSaveError(code: "INVALID_FIELD_BOUNDS", message: "Keep each field inside the page and at least 4 points wide and high.")
            }
        }
        guard state.commitFieldEditing() else {
            throw NativeSaveError(code: "EDIT_NOT_COMMITTED", message: "Finish editing the current field before adding fields.")
        }
        for field in selected { page.addAnnotation(widget(field)) }
        state.noteAnnotationsChanged()
    }
}
