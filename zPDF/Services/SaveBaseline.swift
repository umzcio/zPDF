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
        /// Appearance properties PDFKit can change that only the generic
        /// annotation path carries (border, fill, font, line ends, ink...).
        let detail: String

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
            detail = annotation.type == "Widget" ? "" : Self.detail(of: annotation)
        }

        private static func rgb(_ color: NSColor?) -> String {
            guard let color = color?.usingColorSpace(.deviceRGB) else { return "-" }
            return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                .map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
        }

        private static func detail(of annotation: PDFAnnotation) -> String {
            var parts: [String] = []
            if let border = annotation.border {
                parts.append("b\(border.lineWidth)/\(border.style.rawValue)/\(border.dashPattern.map { "\($0)" } ?? "")")
            }
            parts.append("ic" + rgb(annotation.interiorColor))
            if let font = annotation.font { parts.append("f\(font.fontName)/\(font.pointSize)") }
            parts.append("fc" + rgb(annotation.fontColor))
            parts.append("al\(annotation.alignment.rawValue)")
            if annotation.type == "Line" {
                parts.append("l\(annotation.startPoint)\(annotation.endPoint)\(annotation.startLineStyle.rawValue)\(annotation.endLineStyle.rawValue)")
            }
            if let paths = annotation.paths {
                parts.append("p" + paths.map { "\($0.elementCount):\($0.bounds):\($0.lineWidth)" }.joined(separator: ";"))
            }
            if annotation.type == "Stamp" { parts.append("s" + (annotation.stampName ?? "")) }
            if annotation.type == "Text" { parts.append("i\(annotation.iconType.rawValue)") }
            parts.append("h\(annotation.shouldDisplay)\(annotation.shouldPrint)")
            if let extra = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFRevision")) as? String {
                parts.append("r" + extra)
            }
            return parts.joined(separator: "|")
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

    /// `materialize: false` only classifies edits (dirty tracking); Save,
    /// transforms, exports and recovery need the scratch annotation file.
    func changes(in document: PDFDocument, materialize: Bool = true) throws -> NativeSaveChanges {
        func unsupported() -> NativeSaveError {
            NativeSaveError(code: "UNSUPPORTED_EDIT", message: "Save supports form values, new text fields/checkboxes, notes/highlights/underlines, and page rotation, reorder or deletion. Inserted pages, content changes cannot be saved yet; the original file has not been replaced.")
        }
        guard ObjectIdentifier(document) == documentID else { throw unsupported() }
        guard document.pageCount > 0 else {
            throw NativeSaveError(code: "EMPTY_DOCUMENT", message: "A PDF must keep at least one page. No file was replaced.")
        }
        var changes = NativeSaveChanges()
        var generic = GenericAnnotations()
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
                    // Widgets belong to the form tree; removing one is a form edit.
                    guard entry.1.type != "Widget" else { throw unsupported() }
                    generic.delete(page: index, index: annotationIndex, subtype: entry.1.type)
                    continue
                }
                let value = Item(annotation)
                if value.type == "Widget" {
                    guard entry.1.sameStructure(as: value) else { throw unsupported() }
                    if value.value != entry.1.value || value.checked != entry.1.checked {
                        changes.fields.append(NativeFieldEdit(page: index, annotationIndex: annotationIndex,
                                                             name: entry.1.name, value: value.value, checked: value.checked))
                    }
                    continue
                }
                guard value != entry.1 else { continue }
                if supportsComment, value.detail == entry.1.detail,
                   entry.1.sameStructure(as: value, allowCommentText: true) {
                    changes.comments.append(.init(page: index, annotationIndex: annotationIndex, type: entry.1.type,
                                                   originalContents: entry.1.contents, contents: value.contents))
                    continue
                }
                generic.update(annotation, page: index, index: annotationIndex, subtype: entry.1.type)
            }
            let existing = Set(baseline.annotations.map { ObjectIdentifier($0.0) })
            for annotation in page.annotations where !existing.contains(ObjectIdentifier(annotation)) {
                // PDFKit creates a companion popup for a new note. Its contents
                // belong to the parent; the native annotate command creates the
                // comment itself, not this PDFKit presentation object.
                // Generic additions never carry a PDFKit popup either.
                if annotation.type == "Popup" { continue }
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
                guard item.type != "Widget" else { throw unsupported() }
                let kind: String
                switch item.type {
                case "Text": kind = "sticky_note"
                case "Highlight": kind = "highlight"
                case "Underline": kind = "underline"
                default: kind = ""
                }
                // Rectangular notes/markup keep the facade path; everything
                // else (quads, replies, other subtypes) is a generic addition.
                let isReply = annotation.value(forAnnotationKey: GenericAnnotations.replyKey) != nil
                guard !kind.isEmpty, item.quads.isEmpty, !isReply else {
                    generic.add(annotation, page: index)
                    continue
                }
                let rect = item.bounds
                changes.notes.append(NativeNote(page: index, type: kind, contents: item.contents, author: item.author,
                                                color: item.color, rect: [rect.minX, rect.minY, rect.maxX, rect.maxY]))
            }
        }
        if selections != pages.indices.map({ NativePageSelection(sourceIndex: $0, rotationDelta: 0) }) {
            changes.pages = selections
        }
        if materialize, generic.needsScratch {
            changes.annotationScratch = try generic.writeScratch(pages: pages.map { ($0.page, $0.rotation) })
        }
        changes.annotationItems = generic.items
        return changes
    }
}

/// Collects annotation edits for the generic native path. Additions and
/// updates are serialized by PDFKit (appearance streams included) into a
/// private scratch PDF, one scratch page per edited source page.
@MainActor
struct GenericAnnotations {
    static let scratchKey = PDFAnnotationKey(rawValue: "/ZPDFScratchKey")
    /// Set on a new note that replies to an existing annotation: "page:index" in source terms,
    /// or "new:<ZPDFCommentID>" for a reply to another new annotation.
    static let replyKey = PDFAnnotationKey(rawValue: "/ZPDFReplyTo")
    private(set) var items: [NativeAnnotationItem] = []
    private var pending: [(item: Int, page: Int, annotation: PDFAnnotation)] = []
    var needsScratch: Bool { !pending.isEmpty }

    mutating func delete(page: Int, index: Int, subtype: String) {
        items.append(NativeAnnotationItem(action: "delete", page: page, index: index, subtype: subtype))
    }

    mutating func update(_ annotation: PDFAnnotation, page: Int, index: Int, subtype: String) {
        pending.append((items.count, page, annotation))
        items.append(NativeAnnotationItem(action: "update", page: page, index: index, subtype: subtype))
    }

    mutating func add(_ annotation: PDFAnnotation, page: Int) {
        var item = NativeAnnotationItem(action: "add", page: page, index: nil, subtype: annotation.type)
        if let reply = annotation.value(forAnnotationKey: Self.replyKey) as? String {
            let parts = reply.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { item.replyTo = parts }
        }
        pending.append((items.count, page, annotation))
        items.append(item)
    }

    mutating func writeScratch(pages: [(PDFPage, Int)]) throws -> AnnotationScratch {
        let lease = try AnnotationScratch()
        let document = PDFDocument()
        var scratchPages: [Int: Int] = [:]
        for (n, entry) in pending.enumerated() {
            let scratchIndex: Int
            if let existing = scratchPages[entry.page] { scratchIndex = existing }
            else {
                let source = pages[entry.page].0
                let page = PDFPage()
                page.setBounds(source.bounds(for: .mediaBox), for: .mediaBox)
                page.setBounds(source.bounds(for: .cropBox), for: .cropBox)
                page.rotation = pages[entry.page].1
                scratchIndex = document.pageCount
                document.insert(page, at: scratchIndex)
                scratchPages[entry.page] = scratchIndex
            }
            guard let copy = entry.annotation.copy() as? PDFAnnotation, let page = document.page(at: scratchIndex) else {
                throw NativeSaveError(code: "ANNOTATION_COPY_FAILED", message: "An annotation could not be prepared for saving.")
            }
            let key = "k\(n)"
            copy.setValue(key, forAnnotationKey: Self.scratchKey)
            copy.setValue(nil as String?, forAnnotationKey: Self.replyKey)
            page.addAnnotation(copy)
            items[entry.item].scratchPage = scratchIndex
            items[entry.item].scratchKey = key
        }
        guard document.write(to: lease.url) else {
            throw NativeSaveError(code: "ANNOTATION_WRITE_FAILED", message: "Annotations could not be prepared for saving.")
        }
        return lease
    }
}
