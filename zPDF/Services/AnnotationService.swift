//
//  AnnotationService.swift
//  zPDF
//
//  Purpose: Contract for annotation/comment creation and the comments list
//  shown in CommentPanel. AnnotationTool enumerates the 8 annotation tools
//  from the prototype's "Add annotation" grid. PDFKitAnnotationService is
//  real: selection-based markup wraps the PDFSelection's line bounds, point
//  tools and ink create real PDFAnnotations, and the comment list is derived
//  from the document's annotations (text edits persist into
//  PDFAnnotation.contents; replies thread in memory).
//  Phase: 2 — REAL.
//  TODO(phase-2): attachFile still needs an NSOpenPanel picker before it can
//  create a file-attachment annotation.
//

import AppKit
import Foundation
import PDFKit

/// The 8 tools in the Comment panel's "Add annotation" grid (prototype order).
enum AnnotationTool: String, CaseIterable, Identifiable {
    case highlight
    case strikethrough
    case underline
    case stickyNote
    case textBox
    case drawing
    case stamp
    case attachFile

    var id: String { rawValue }

    var name: String {
        switch self {
        case .highlight: "Highlight"
        case .strikethrough: "Strikethrough"
        case .underline: "Underline"
        case .stickyNote: "Sticky Note"
        case .textBox: "Text Box"
        case .drawing: "Drawing"
        case .stamp: "Stamp"
        case .attachFile: "Attach File"
        }
    }

    var symbolName: String {
        switch self {
        case .highlight: "highlighter"
        case .strikethrough: "strikethrough"
        case .underline: "underline"
        case .stickyNote: "note.text"
        case .textBox: "character.textbox"
        case .drawing: "pencil.tip"
        case .stamp: "rosette"
        case .attachFile: "paperclip"
        }
    }

    /// PDFKit annotation subtype for placement, where one exists.
    var pdfKitSubtype: PDFAnnotationSubtype? {
        switch self {
        case .highlight: .highlight
        case .strikethrough: .strikeOut
        case .underline: .underline
        case .stickyNote: .text
        case .textBox: .freeText
        case .drawing: .ink
        case .stamp: .stamp
        case .attachFile: nil // file attachments need a file picker — TODO(phase-2)
        }
    }

    /// Tools that wrap the current text selection rather than a click point.
    var isMarkup: Bool {
        switch self {
        case .highlight, .strikethrough, .underline: true
        default: false
        }
    }

    /// Tint used for the created PDFAnnotation.
    var annotationColor: NSColor {
        switch self {
        case .highlight, .stickyNote: .systemYellow
        case .underline: .systemGreen
        case .strikethrough, .stamp: .systemRed
        case .textBox: .white
        case .drawing: .systemBlue
        case .attachFile: .systemGray
        }
    }
}

@MainActor
protocol AnnotationService {
    /// Comments for a tab, derived from the document's annotations in page
    /// order (drives the Comment panel list).
    func comments(for tab: DocumentTab) -> [Comment]

    /// Create a point-placed annotation (sticky note / text box / stamp) at
    /// a page-space point on the given page.
    func addAnnotation(_ tool: AnnotationTool, at point: CGPoint, onPage pageIndex: Int, in tab: DocumentTab)

    /// Create markup annotations (highlight / underline / strikethrough)
    /// wrapping each line of a text selection. (Phase-2 addition.)
    func addMarkupAnnotation(_ tool: AnnotationTool, over selection: PDFSelection, in tab: DocumentTab)

    /// Create an ink annotation following a dragged path of page-space
    /// points. (Phase-2 addition.)
    func addInkAnnotation(points: [CGPoint], onPage pageIndex: Int, in tab: DocumentTab)

    /// Persist an edited comment text into the backing annotation's
    /// contents. (Phase-2 addition.)
    func updateComment(_ comment: Comment, newText: String, in tab: DocumentTab)

    func remove(comment: Comment, from tab: DocumentTab)
    func addReply(_ text: String, to comment: Comment, in tab: DocumentTab)
}

/// PDFKit-backed implementation. The comment list is derived from the
/// document's real annotations; each annotation carries a stable comment
/// UUID in its annotation dictionary (a custom `/ZPDFCommentID` key) so
/// list rows, edits, deletes, and replies stay attached to the right
/// annotation. Quoted markup text and reply threads live in memory only.
final class PDFKitAnnotationService: AnnotationService {
    var preferences: AppPreferences = .shared

    private func color(for tool: AnnotationTool) -> NSColor {
        switch tool {
        case .highlight: preferences.highlightColor.nsColor
        case .underline: preferences.underlineColor.nsColor
        case .stickyNote: preferences.noteColor.nsColor
        default: tool.annotationColor
        }
    }
    /// Custom annotation-dictionary key holding the stable comment UUID.
    private static let commentIDKey = PDFAnnotationKey(rawValue: "/ZPDFCommentID")

    /// Quoted selection text captured when a markup annotation is created
    /// (PDFAnnotation has no standard key for it).
    private var quotedTextByCommentID: [UUID: String] = [:]
    /// In-memory reply threading, keyed by parent comment id.
    private var repliesByCommentID: [UUID: [Comment]] = [:]

    // MARK: - Comment list

    func comments(for tab: DocumentTab) -> [Comment] {
        guard let document = tab.pdfDocument else { return [] }
        var comments: [Comment] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where Self.isListed(annotation) {
                comments.append(makeComment(for: annotation, pageIndex: pageIndex))
            }
        }
        return comments
    }

    /// Annotation subtypes surfaced in the Comment panel.
    private static let listedSubtypes: Set<String> = [
        PDFAnnotationSubtype.highlight.rawValue,
        PDFAnnotationSubtype.strikeOut.rawValue,
        PDFAnnotationSubtype.underline.rawValue,
        PDFAnnotationSubtype.text.rawValue,
        PDFAnnotationSubtype.freeText.rawValue,
        PDFAnnotationSubtype.ink.rawValue,
        PDFAnnotationSubtype.stamp.rawValue
    ]

    private static func isListed(_ annotation: PDFAnnotation) -> Bool {
        // annotation.type returns the subtype WITHOUT the leading slash
        // (e.g. "Text"), while PDFAnnotationSubtype raw values keep it.
        guard let type = annotation.type else { return false }
        return listedSubtypes.contains("/" + type)
    }

    private func makeComment(for annotation: PDFAnnotation, pageIndex: Int) -> Comment {
        let id = commentID(for: annotation)
        return Comment(id: id,
                       author: annotation.userName ?? NSFullUserName(),
                       date: annotation.modificationDate ?? .distantPast,
                       text: annotation.contents ?? "",
                       pageIndex: pageIndex,
                       kind: CommentKind(pdfSubtype: annotation.type),
                       quotedText: quotedTextByCommentID[id],
                       replies: threadedReplies(for: id))
    }

    private func threadedReplies(for id: UUID) -> [Comment] {
        (repliesByCommentID[id] ?? []).map { reply in
            var reply = reply
            reply.replies = threadedReplies(for: reply.id)
            return reply
        }
    }

    // MARK: - Creation

    func addAnnotation(_ tool: AnnotationTool, at point: CGPoint, onPage pageIndex: Int, in tab: DocumentTab) {
        guard let page = tab.pdfDocument?.page(at: pageIndex) else { return }
        let annotation: PDFAnnotation
        switch tool {
        case .stickyNote:
            let bounds = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
            annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.contents = ""
        case .textBox:
            let bounds = CGRect(x: point.x, y: point.y - 40, width: 160, height: 40)
            annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.font = NSFont.systemFont(ofSize: 12)
            annotation.fontColor = .labelColor
            annotation.contents = ""
        case .stamp:
            let bounds = CGRect(x: point.x - 50, y: point.y - 20, width: 100, height: 40)
            annotation = PDFAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
            annotation.contents = ""
        default:
            // Markup and ink go through addMarkupAnnotation /
            // addInkAnnotation; attachFile is a TODO (see header).
            return
        }
        annotation.color = color(for: tool)
        finalize(annotation)
        page.addAnnotation(annotation)
    }

    func addMarkupAnnotation(_ tool: AnnotationTool, over selection: PDFSelection, in tab: DocumentTab) {
        guard tool.isMarkup, let subtype = tool.pdfKitSubtype else { return }
        let quoted = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        // One annotation per selection line, wrapping the line's bounds.
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = color(for: tool)
                finalize(annotation)
                page.addAnnotation(annotation)
                if let quoted, !quoted.isEmpty {
                    quotedTextByCommentID[commentID(for: annotation)] = quoted
                }
            }
        }
    }

    func addInkAnnotation(points: [CGPoint], onPage pageIndex: Int, in tab: DocumentTab) {
        guard points.count > 1, let page = tab.pdfDocument?.page(at: pageIndex) else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let bounds = path.bounds.insetBy(dx: -4, dy: -4)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.add(path)
        annotation.color = AnnotationTool.drawing.annotationColor
        finalize(annotation)
        page.addAnnotation(annotation)
    }

    // MARK: - Editing & removal

    func updateComment(_ comment: Comment, newText: String, in tab: DocumentTab) {
        guard let found = findAnnotation(for: comment, in: tab) else { return }
        found.contents = newText
        found.modificationDate = Date()
    }

    func remove(comment: Comment, from tab: DocumentTab) {
        if let found = findAnnotationWithPage(for: comment, in: tab) {
            found.page.removeAnnotation(found.annotation)
        }
        quotedTextByCommentID[comment.id] = nil
        repliesByCommentID[comment.id] = nil
        // Replies have no backing annotation; drop them from the trees too.
        for parentID in Array(repliesByCommentID.keys) {
            repliesByCommentID[parentID] = Self.removing(comment.id, from: repliesByCommentID[parentID] ?? [])
        }
    }

    func addReply(_ text: String, to comment: Comment, in tab: DocumentTab) {
        let reply = Comment(author: NSFullUserName(), text: text, pageIndex: comment.pageIndex)
        repliesByCommentID[comment.id, default: []].append(reply)
    }

    // MARK: - Identity & lookup

    /// Stable UUID for an annotation, read from (or lazily written into)
    /// its annotation dictionary so it survives within the document.
    private func commentID(for annotation: PDFAnnotation) -> UUID {
        if let raw = annotation.value(forAnnotationKey: Self.commentIDKey) as? String,
           let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        annotation.setValue(id.uuidString, forAnnotationKey: Self.commentIDKey)
        return id
    }

    /// Assign the comment id, author, and timestamp shared by all
    /// annotations we create.
    private func finalize(_ annotation: PDFAnnotation) {
        annotation.userName = preferences.commentAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        annotation.modificationDate = Date()
        _ = commentID(for: annotation)
    }

    private func findAnnotation(for comment: Comment, in tab: DocumentTab) -> PDFAnnotation? {
        findAnnotationWithPage(for: comment, in: tab)?.annotation
    }

    private func findAnnotationWithPage(for comment: Comment, in tab: DocumentTab) -> (annotation: PDFAnnotation, page: PDFPage)? {
        guard let page = tab.pdfDocument?.page(at: comment.pageIndex) else { return nil }
        for annotation in page.annotations where commentID(for: annotation) == comment.id {
            return (annotation, page)
        }
        return nil
    }

    /// Recursively remove the comment with the given id from a reply tree.
    private static func removing(_ id: UUID, from comments: [Comment]) -> [Comment] {
        comments.compactMap { comment in
            guard comment.id != id else { return nil }
            var comment = comment
            comment.replies = removing(id, from: comment.replies)
            return comment
        }
    }
}
