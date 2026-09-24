import AppKit
import PDFKit

/// Capture values, not a PDFKit serialization. The native source remains the
/// document of record. Unsupported mutations fail before invoking engine Save.
@MainActor
final class SaveBaseline {
    private struct Item: Equatable {
        let type: String
        let bounds: CGRect
        let name: String
        let contents: String
        let author: String
        let color: [Int]
        let quads: [CGPoint]
        let value: String
        let checked: Bool

        init(_ annotation: PDFAnnotation) {
            type = annotation.type ?? ""
            bounds = annotation.bounds
            name = annotation.fieldName ?? ""
            contents = annotation.contents ?? ""
            author = annotation.userName ?? ""
            let rgb = annotation.color.usingColorSpace(.deviceRGB) ?? NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
            color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { Int(($0 * 255).rounded()) }
            quads = annotation.quadrilateralPoints?.map(\.pointValue) ?? []
            value = annotation.widgetStringValue ?? ""
            checked = annotation.buttonWidgetState == .onState
        }

        func sameStructure(as other: Item, allowCommentText: Bool = false) -> Bool {
            type == other.type && bounds == other.bounds && name == other.name &&
            (allowCommentText || contents == other.contents) && author == other.author && color == other.color && quads == other.quads
        }
    }

    private struct Page {
        // Retain source objects so removed pages/annotations cannot have their
        // identities reused by an unrelated insertion before Save.
        let page: PDFPage
        let rotation: Int
        let bounds: CGRect
        let text: String
        let annotations: [(PDFAnnotation, Item)]
    }
    private let documentID: ObjectIdentifier
    private let pages: [Page]

    init(_ document: PDFDocument) {
        documentID = ObjectIdentifier(document)
        pages = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return Page(page: page, rotation: page.rotation, bounds: page.bounds(for: .cropBox),
                        text: page.string ?? "", annotations: page.annotations.map { ($0, Item($0)) })
        }
    }

    private init(document: PDFDocument, pages: [Page]) {
        documentID = ObjectIdentifier(document)
        self.pages = pages
    }

    /// PDFKit stays on the main actor, with a run-loop opportunity between
    /// pages. The caller keeps editing blocked until the whole baseline exists.
    static func capture(_ document: PDFDocument, canContinue: () -> Bool = { true }) async throws -> SaveBaseline {
        var pages: [Page] = []
        for index in 0..<document.pageCount {
            guard canContinue() else { throw CancellationError() }
            try Task.checkCancellation()
            if let page = document.page(at: index) {
                pages.append(Page(page: page, rotation: page.rotation, bounds: page.bounds(for: .cropBox),
                                  text: page.string ?? "", annotations: page.annotations.map { ($0, Item($0)) }))
            }
            // Yielding alone can keep draining the main-actor executor without
            // giving AppKit input a turn. A brief suspension allows both queues.
            try await Task.sleep(for: .milliseconds(1))
        }
        return SaveBaseline(document: document, pages: pages)
    }

    /// Distinguishes comments captured from disk from newly added annotations.
    func containsComment(id: UUID) -> Bool {
        pages.contains { page in
            page.annotations.contains { annotation, _ in
                annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFCommentID")) as? String == id.uuidString
            }
        }
    }

    func supportsComment(id: UUID) -> Bool {
        for page in pages {
            for (annotation, item) in page.annotations where annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFCommentID")) as? String == id.uuidString {
                return ["Text", "Highlight", "Underline"].contains(item.type)
            }
        }
        return true // Newly created supported comment.
    }

    func sourceIndex(for page: PDFPage) -> Int? { pages.firstIndex { $0.page === page } }

    func changes(in document: PDFDocument) throws -> NativeSaveChanges {
        func unsupported() -> NativeSaveError {
            NativeSaveError(code: "UNSUPPORTED_EDIT", message: "Save supports form values, new text fields/checkboxes, notes/highlights/underlines, and page rotation, reorder or deletion. Inserted pages, content changes cannot be saved yet; the original file has not been replaced.")
        }
        guard ObjectIdentifier(document) == documentID else { throw unsupported() }
        guard document.pageCount > 0 else {
            throw NativeSaveError(code: "EMPTY_DOCUMENT", message: "A PDF must keep at least one page. No file was replaced.")
        }
        var changes = NativeSaveChanges()
        var selections: [NativePageSelection] = []
        var seen: Set<Int> = []
        for outputIndex in 0..<document.pageCount {
            guard let page = document.page(at: outputIndex),
                  let index = pages.firstIndex(where: { $0.page === page }),
                  seen.insert(index).inserted else { throw unsupported() }
            let baseline = pages[index]
            let rotation = ((page.rotation - baseline.rotation) % 360 + 360) % 360
            guard [0, 90, 180, 270].contains(rotation), page.bounds(for: .cropBox) == baseline.bounds,
                  page.string ?? "" == baseline.text else { throw unsupported() }
            selections.append(NativePageSelection(sourceIndex: index, rotationDelta: rotation))
            let current = Dictionary(uniqueKeysWithValues: page.annotations.map { (ObjectIdentifier($0), $0) })
            for (annotationIndex, entry) in baseline.annotations.enumerated() {
                let supportsComment = ["Text", "Highlight", "Underline"].contains(entry.1.type)
                guard let annotation = current[ObjectIdentifier(entry.0)] else {
                    if supportsComment {
                        changes.comments.append(.init(page: index, annotationIndex: annotationIndex, type: entry.1.type,
                                                       originalContents: entry.1.contents, contents: nil))
                        continue
                    }
                    throw unsupported()
                }
                let value = Item(annotation)
                guard entry.1.sameStructure(as: value, allowCommentText: supportsComment) else { throw unsupported() }
                if supportsComment, value.contents != entry.1.contents {
                    changes.comments.append(.init(page: index, annotationIndex: annotationIndex, type: entry.1.type,
                                                   originalContents: entry.1.contents, contents: value.contents))
                    continue
                }
                if value.type == "Widget" {
                    if value.value != entry.1.value || value.checked != entry.1.checked {
                        changes.fields.append(NativeFieldEdit(page: index, annotationIndex: annotationIndex,
                                                             name: entry.1.name, value: value.value, checked: value.checked))
                    }
                } else if value != entry.1 { throw unsupported() }
            }
            let existing = Set(baseline.annotations.map { ObjectIdentifier($0.0) })
            for annotation in page.annotations where !existing.contains(ObjectIdentifier(annotation)) {
                // PDFKit creates a companion popup for a new note. Its contents
                // belong to the parent; the native annotate command creates the
                // comment itself, not this PDFKit presentation object.
                if annotation.type == "Popup",
                   let parent = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation,
                   !existing.contains(ObjectIdentifier(parent)),
                   ["Text", "Highlight", "Underline"].contains(parent.type ?? "") { continue }
                let item = Item(annotation)
                if item.type == "Widget", annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFNewField")) as? String == "1" {
                    let type: String
                    if annotation.widgetFieldType == .text { type = "text" }
                    else if annotation.widgetFieldType == .button && annotation.widgetControlType == .checkBoxControl { type = "checkbox" }
                    else { throw unsupported() }
                    let r = item.bounds
                    changes.newFields.append(NativeNewField(page: index, name: item.name, type: type,
                        rect: [r.minX, r.minY, r.maxX, r.maxY], value: item.value, checked: item.checked))
                    continue
                }
                let kind: String
                switch item.type {
                case "Text": kind = "sticky_note"
                case "Highlight": kind = "highlight"
                case "Underline": kind = "underline"
                default: throw unsupported()
                }
                // The existing annotation UI creates rectangular markup; don't
                // silently change geometry from an unsupported quad editor.
                guard item.quads.isEmpty else { throw unsupported() }
                let rect = item.bounds
                changes.notes.append(NativeNote(page: index, type: kind, contents: item.contents, author: item.author,
                                                color: item.color, rect: [rect.minX, rect.minY, rect.maxX, rect.maxY]))
            }
        }
        if selections != pages.indices.map({ NativePageSelection(sourceIndex: $0, rotationDelta: 0) }) {
            changes.pages = selections
        }
        return changes
    }
}
