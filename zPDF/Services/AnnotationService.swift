//
//  AnnotationService.swift
//  zPDF
//
//  Purpose: Creation and review of comments on the PDFKit display copy.
//  AnnotationTool is the Comment tool catalog (markup, text, drawing,
//  shapes, stamps, media). PDFKitAnnotationService builds the comment list
//  from real annotations — threads from /IRT (CommentFileInfo) or the
//  session's /ZPDFReplyTo, review status and checkmarks from /State reply
//  annotations, grouped Replace Text (StrikeOut + Caret) as one comment —
//  and creates every comment type. Everything reaches the saved file via
//  the generic annotation path (SaveBaseline → engine).
//

import AppKit
import Foundation
import PDFKit

/// Comment tools, grouped as the Comment panel shows them.
enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case highlight, underline, strikethrough, replaceText, insertText, stickyNote
    case textBox, callout
    case drawing, eraser
    case rectangle, oval, line, arrow, polygon, polyline, cloud
    case stamp, attachFile, sound

    var id: String { rawValue }

    var name: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .replaceText: "Replace Text"
        case .insertText: "Insert Text"
        case .stickyNote: "Sticky Note"
        case .textBox: "Text Box"
        case .callout: "Callout"
        case .drawing: "Pen"
        case .eraser: "Eraser"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .polygon: "Polygon"
        case .polyline: "Polyline"
        case .cloud: "Cloud"
        case .stamp: "Stamp"
        case .attachFile: "Attach File"
        case .sound: "Sound"
        }
    }

    var symbolName: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .replaceText: "character.cursor.ibeam"
        case .insertText: "text.insert"
        case .stickyNote: "note.text"
        case .textBox: "character.textbox"
        case .callout: "text.bubble"
        case .drawing: "pencil.tip"
        case .eraser: "eraser"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .polygon: "pentagon"
        case .polyline: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .cloud: "cloud"
        case .stamp: "seal"
        case .attachFile: "paperclip"
        case .sound: "waveform"
        }
    }

    /// How to use the tool, shown as its tooltip and accessibility hint.
    var usage: String {
        switch self {
        case .highlight, .underline, .strikethrough: "Select text, or drag across text on the page."
        case .replaceText: "Select the text to replace, then type the replacement."
        case .insertText: "Click where text should be inserted, then type it."
        case .stickyNote: "Click the page to place a note."
        case .textBox: "Click to type on the page, or drag to size the box."
        case .callout: "Drag from the point you're describing to where the text box goes."
        case .drawing: "Drag to draw freehand."
        case .eraser: "Drag over pen strokes to erase them."
        case .rectangle, .oval, .cloud: "Drag to draw. Hold Shift for a square or circle."
        case .line, .arrow: "Drag to draw. Hold Shift to snap to 45°."
        case .polygon, .polyline: "Click to add points; double-click or press Return to finish."
        case .stamp: "Choose a stamp, then click the page."
        case .attachFile: "Click the page, then choose a file to attach."
        case .sound: "Click the page, then record or choose audio."
        }
    }

    /// Keyboard shortcut shown in tooltips and menus (⌃⌘ + key).
    var shortcutKey: Character? {
        switch self {
        case .highlight: "h"
        case .underline: "u"
        case .strikethrough: "k"
        case .stickyNote: "n"
        case .textBox: "t"
        case .drawing: "p"
        case .rectangle: "r"
        case .oval: "o"
        case .arrow: "a"
        case .stamp: "m"
        default: nil
        }
    }

    var helpText: String {
        let key = shortcutKey.map { " (⌃⌘\(String($0).uppercased()))" } ?? ""
        return "\(name)\(key) — \(usage)"
    }

    /// Tools that apply to the current text selection.
    var isMarkup: Bool { [.highlight, .strikethrough, .underline, .replaceText].contains(self) }
    /// Tools that are dragged out on the canvas.
    var isDragged: Bool { [.textBox, .callout, .drawing, .eraser, .rectangle, .oval, .line, .arrow, .cloud].contains(self) }
    /// Tools placed by successive clicks.
    var isMultiPoint: Bool { [.polygon, .polyline].contains(self) }

    /// Whether the tool has appearance options for the properties inspector.
    var hasStyle: Bool { ![.eraser, .attachFile, .sound, .stamp].contains(self) }

    /// Default look before the user customizes it.
    var defaultStyle: CommentStyle {
        var style = CommentStyle()
        switch self {
        case .highlight: style.color = .yellow; style.opacity = 1
        case .underline: style.color = .green
        case .strikethrough, .replaceText: style.color = .red
        case .insertText: style.color = .blue
        case .stickyNote: style.color = .yellow
        case .textBox:
            style.color = .black; style.lineWidth = 0; style.fontSize = 12; style.textColor = .black
        case .callout:
            style.color = .red; style.lineWidth = 1; style.fill = .white; style.textColor = .black
        case .drawing: style.color = .blue; style.lineWidth = 2
        case .arrow: style.endEnding = .openArrow
        case .cloud: style.lineStyle = .cloudy; style.lineWidth = 1.5
        case .attachFile, .sound: style.color = .blue
        default: break
        }
        return style
    }
}

enum CommentPanelGroup: String, CaseIterable, Identifiable {
    case markup, text, drawing, stamps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .markup: "Text markup"
        case .text: "Text & notes"
        case .drawing: "Drawing & shapes"
        case .stamps: "Stamps & media"
        }
    }
    var tools: [AnnotationTool] {
        switch self {
        case .markup: [.highlight, .underline, .strikethrough, .replaceText, .insertText]
        case .text: [.stickyNote, .textBox, .callout]
        case .drawing: [.drawing, .eraser, .rectangle, .oval, .line, .arrow, .polygon, .polyline, .cloud]
        case .stamps: [.stamp, .attachFile, .sound]
        }
    }
}

@MainActor
protocol AnnotationService {
    /// Top-level comment threads for a tab in page order (drives the list).
    func comments(for tab: DocumentTab) -> [Comment]

    /// Create a click-placed comment (note, caret, stamp, text box...).
    @discardableResult
    func addAnnotation(_ tool: AnnotationTool, at point: CGPoint, onPage pageIndex: Int, in tab: DocumentTab) -> PDFAnnotation?

    /// Create text markup over a selection (one annotation per page, a
    /// quadrilateral per line). Replace Text also adds its grouped caret.
    @discardableResult
    func addMarkupAnnotation(_ tool: AnnotationTool, over selection: PDFSelection, in tab: DocumentTab) -> [PDFAnnotation]

    /// Freehand stroke(s) in page space, smoothed into one Ink annotation.
    @discardableResult
    func addInkAnnotation(points: [CGPoint], onPage pageIndex: Int, in tab: DocumentTab) -> PDFAnnotation?

    /// A shape dragged between two page points, or a multi-point shape.
    @discardableResult
    func addShape(_ tool: AnnotationTool, points: [CGPoint], onPage pageIndex: Int, in tab: DocumentTab) -> PDFAnnotation?

    func updateComment(_ comment: Comment, newText: String, in tab: DocumentTab)
    /// Removes the comment with its replies, status history and grouped markup.
    func remove(comment: Comment, from tab: DocumentTab)
    @discardableResult
    func addReply(_ text: String, to comment: Comment, in tab: DocumentTab) -> PDFAnnotation?
    func setStatus(_ status: CommentStatus, for comment: Comment, in tab: DocumentTab)
    func setMarked(_ marked: Bool, for comment: Comment, in tab: DocumentTab)

    func annotation(for comment: Comment, in tab: DocumentTab) -> (annotation: PDFAnnotation, page: PDFPage)?
    func comment(for annotation: PDFAnnotation, in tab: DocumentTab) -> Comment?
    /// The annotation plus every reply/status/grouped annotation under it.
    func thread(of annotation: PDFAnnotation, in tab: DocumentTab) -> [(annotation: PDFAnnotation, page: PDFPage)]
    func commentID(for annotation: PDFAnnotation) -> UUID
    func style(for tool: AnnotationTool) -> CommentStyle
}

/// PDFKit-backed implementation. Each annotation carries a stable session
/// UUID in its dictionary (`/ZPDFCommentID`, stripped on Save) so rows,
/// edits and replies stay attached to the right annotation.
final class PDFKitAnnotationService: AnnotationService {
    var preferences: AppPreferences = .shared
    var styles: CommentToolStyles = .shared
    /// Stamp placed by the Stamp tool.
    var stampDesign: StampDesign = StampDesign.standard[0]

    static let commentIDKey = PDFAnnotationKey(rawValue: "/ZPDFCommentID")
    static let stateKey = PDFAnnotationKey(rawValue: "/State")
    static let stateModelKey = PDFAnnotationKey(rawValue: "/StateModel")
    static let intentKey = PDFAnnotationKey(rawValue: "/IT")

    /// Quoted text of markup created this session (PDF has no standard key).
    private var quotedTextByCommentID: [UUID: String] = [:]

    func style(for tool: AnnotationTool) -> CommentStyle {
        var style = styles.style(for: tool)
        if !styles.hasCustomColor(for: tool) {
            switch tool {
            case .highlight: style.color = CommentColor(preferences.highlightColor.nsColor) ?? style.color
            case .underline: style.color = CommentColor(preferences.underlineColor.nsColor) ?? style.color
            case .stickyNote: style.color = CommentColor(preferences.noteColor.nsColor) ?? style.color
            default: break
            }
        }
        return style
    }

    // MARK: - Comment list

    /// Annotation subtypes the comment tools review.
    static let listedSubtypes: Set<String> = ["Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine",
                                              "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink",
                                              "FileAttachment", "Sound"]

    static func isListed(_ annotation: PDFAnnotation) -> Bool {
        listedSubtypes.contains(annotation.type ?? "")
    }

    private struct Node {
        let annotation: PDFAnnotation
        let page: Int
        var comment: Comment
        var parent: ObjectIdentifier?
        var grouped: Bool
        var state: (model: String, value: String)?
    }

    /// Parent of an annotation: this session's /ZPDFReplyTo, else the file's /IRT.
    private func parent(of annotation: PDFAnnotation, tab: DocumentTab, byID: [UUID: PDFAnnotation],
                        replacements: [ObjectIdentifier: PDFAnnotation]) -> (PDFAnnotation, Bool)? {
        let baseline = tab.saveBaseline
        func live(_ original: PDFAnnotation) -> PDFAnnotation { replacements[ObjectIdentifier(original)] ?? original }
        if let reply = annotation.value(forAnnotationKey: GenericAnnotations.replyKey) as? String {
            let fields = reply.split(separator: "|")
            let grouped = fields.dropFirst().contains("Group")
            let target = fields.first.map(String.init) ?? ""
            if target.hasPrefix("new:") {
                return UUID(uuidString: String(target.dropFirst(4))).flatMap { byID[$0] }.map { ($0, grouped) }
            }
            let parts = target.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let original = baseline?.annotation(page: parts[0], index: parts[1]) { return (live(original), grouped) }
            return nil
        }
        guard let baseline, let entry = CommentFileInfo.entry(for: annotation, baseline: baseline), let position = entry.parent,
              let original = baseline.annotation(page: position.page, index: position.index) else { return nil }
        return (live(original), entry.groupedWithParent)
    }

    func comments(for tab: DocumentTab) -> [Comment] {
        guard let document = tab.pdfDocument else { return [] }
        var nodes: [ObjectIdentifier: Node] = [:]
        var order: [ObjectIdentifier] = []
        var byID: [UUID: PDFAnnotation] = [:]
        var replacements: [ObjectIdentifier: PDFAnnotation] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where Self.isListed(annotation) {
                byID[commentID(for: annotation)] = annotation
                if let original = AnnotationReplacement.original(of: annotation) { replacements[ObjectIdentifier(original)] = annotation }
                let key = ObjectIdentifier(annotation)
                nodes[key] = Node(annotation: annotation, page: pageIndex, comment: makeComment(for: annotation, pageIndex: pageIndex, tab: tab),
                                  parent: nil, grouped: false, state: nil)
                order.append(key)
            }
        }
        for key in order {
            guard var node = nodes[key] else { continue }
            if let (parent, grouped) = parent(of: node.annotation, tab: tab, byID: byID, replacements: replacements),
               parent !== node.annotation, nodes[ObjectIdentifier(parent)] != nil {
                node.parent = ObjectIdentifier(parent)
                node.grouped = grouped
            }
            if let model = stateModel(of: node.annotation), let value = state(of: node.annotation), node.parent != nil {
                node.state = (model, value)
            }
            nodes[key] = node
        }
        // Children in date order; state replies become status, grouped markup merges.
        var children: [ObjectIdentifier: [ObjectIdentifier]] = [:]
        for key in order { if let parent = nodes[key]?.parent { children[parent, default: []].append(key) } }
        func build(_ key: ObjectIdentifier, depth: Int) -> Comment? {
            guard var comment = nodes[key]?.comment, depth < 32 else { return nil }
            let kids = (children[key] ?? []).compactMap { nodes[$0] }.sorted { $0.comment.date < $1.comment.date }
            var replies: [Comment] = []
            var latestReview: (Date, String, String)?
            var latestMark: (Date, String)?
            for child in kids {
                if let state = child.state {
                    if state.model == "Review" {
                        if latestReview == nil || child.comment.date >= latestReview!.0 {
                            latestReview = (child.comment.date, state.value, child.comment.author)
                        }
                    } else if state.model == "Marked" {
                        if latestMark == nil || child.comment.date >= latestMark!.0 { latestMark = (child.comment.date, state.value) }
                    }
                    continue
                }
                if child.grouped {
                    // Replace Text: the caret carries the new text, the strike-out the old.
                    if child.annotation.type == "StrikeOut" {
                        comment.kind = .replaceText
                        comment.quotedText = comment.quotedText ?? child.comment.quotedText
                    } else if comment.kind == .replaceText || comment.kind == .strikethrough {
                        comment.kind = .replaceText
                        if comment.text.isEmpty { comment.text = child.comment.text }
                    }
                    continue
                }
                if let reply = build(ObjectIdentifier(child.annotation), depth: depth + 1) { replies.append(reply) }
            }
            if let review = latestReview {
                comment.status = CommentStatus(rawValue: review.1) ?? .none
                comment.statusAuthor = review.2
            }
            if let mark = latestMark { comment.isMarked = mark.1 == "Marked" }
            comment.replies = replies
            return comment
        }
        return order.compactMap { key in nodes[key]?.parent == nil ? build(key, depth: 0) : nil }
    }

    func stateModel(of annotation: PDFAnnotation) -> String? {
        (annotation.value(forAnnotationKey: Self.stateModelKey) as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func state(of annotation: PDFAnnotation) -> String? {
        (annotation.value(forAnnotationKey: Self.stateKey) as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func makeComment(for annotation: PDFAnnotation, pageIndex: Int, tab: DocumentTab) -> Comment {
        let id = commentID(for: annotation)
        let intent: String?
        if let drawn = annotation as? CommentAnnotation, drawn.design.shape == .callout { intent = "FreeTextCallout" }
        else { intent = CommentRehydration.intent(annotation) }
        var comment = Comment(id: id,
                              author: annotation.userName ?? NSFullUserName(),
                              date: annotation.modificationDate ?? .distantPast,
                              text: annotation.contents ?? "",
                              pageIndex: pageIndex,
                              kind: CommentKind(pdfSubtype: annotation.type, intent: intent),
                              quotedText: quotedText(for: annotation, id: id),
                              replies: [])
        comment.subtype = annotation.type ?? ""
        comment.colorHex = CommentColor(annotation.color)?.hex
        let baseline = tab.saveBaseline
        comment.isNew = baseline?.position(of: annotation) == nil
        if comment.kind == .attachment {
            if let pending = CommentMediaLink.pendingFile(of: annotation) {
                comment.attachmentName = pending.name
                comment.attachmentSize = CommentMediaLink.pendingSize(of: annotation)
            } else if let baseline, let entry = CommentFileInfo.entry(for: annotation, baseline: baseline) {
                comment.attachmentName = entry.fileName
                comment.attachmentSize = entry.fileSize
            }
        }
        if comment.kind == .sound, let baseline, let entry = CommentFileInfo.entry(for: annotation, baseline: baseline) {
            comment.soundDuration = entry.soundDuration
        }
        if comment.kind == .stamp, comment.text.isEmpty, let drawn = annotation as? CommentAnnotation, let stamp = drawn.design.stamp {
            comment.text = [stamp.label.capitalized, stamp.detail].compactMap { $0 }.joined(separator: " — ")
        }
        return comment
    }

    private var loadedQuotes: [ObjectIdentifier: String] = [:]

    private func quotedText(for annotation: PDFAnnotation, id: UUID) -> String? {
        if let text = quotedTextByCommentID[id] { return text }
        guard ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(annotation.type ?? ""), let page = annotation.page else { return nil }
        let key = ObjectIdentifier(annotation)
        if let cached = loadedQuotes[key] { return cached.isEmpty ? nil : cached }
        let quads = annotation.quadrilateralPoints?.map(\.pointValue) ?? []
        var pieces: [String] = []
        if quads.count >= 4 {
            let origin = annotation.bounds.origin
            for index in stride(from: 0, to: quads.count - 3, by: 4) {
                let xs = quads[index..<index + 4].map { $0.x + origin.x }, ys = quads[index..<index + 4].map { $0.y + origin.y }
                let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                if let text = page.selection(for: rect.insetBy(dx: 0.5, dy: 1))?.string { pieces.append(text) }
            }
        } else if let text = page.selection(for: annotation.bounds)?.string {
            pieces.append(text)
        }
        let text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        loadedQuotes[key] = text
        return text.isEmpty ? nil : text
    }

    // MARK: - Creation

    @discardableResult
    func addAnnotation(_ tool: AnnotationTool, at point: CGPoint, onPage pageIndex: Int, in tab: DocumentTab) -> PDFAnnotation? {
        guard let page = tab.pdfDocument?.page(at: pageIndex) else { return nil }
        let style = style(for: tool)
        let annotation: PDFAnnotation
        switch tool {
        case .stickyNote:
            annotation = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
            annotation.contents = ""
            annotation.color = style.color.nsColor
        case .textBox:
            let width: CGFloat = 180, height = max(24, CGFloat(style.fontSize) * 1.6)
            annotation = makeTextBox(CGRect(x: point.x, y: point.y - height, width: width, height: height), style: style)
        case .callout:
            let box = CGRect(x: point.x + 40, y: point.y + 30, width: 160, height: 48)
            annotation = makeCallout(anchor: point, box: box, style: style)
        case .insertText:
            annotation = makeCaret(at: point, page: page, style: style)
        case .stamp:
            let design = stampDesign.filled(author: author, date: Date())
            let height: CGFloat = design.kind == .dynamic ? 56 : 44
            let width = min(page.bounds(for: .cropBox).width * 0.6, height * design.aspectRatio)
            let bounds = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            var stampStyle = CommentStyle(); stampStyle.opacity = style.opacity
            let stamp = CommentAnnotation(bounds: bounds, design: CommentDesign(shape: .stamp, style: stampStyle, stamp: design))
            stamp.contents = [design.label.capitalized, design.detail].compactMap { $0 }.joined(separator: " — ")
            annotation = stamp
        case .attachFile, .sound:
            let design = CommentDesign(shape: tool == .sound ? .sound : .attachment, style: style)
            annotation = CommentAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), design: design)
        default:
            return nil
        }
        finalize(annotation)
        page.addAnnotation(annotation)
        return annotation
    }

    private var author: String { preferences.commentAuthor.trimmingCharacters(in: .whitespacesAndNewlines) }

    func makeTextBox(_ rect: CGRect, style: CommentStyle) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.font = style.font
        annotation.fontColor = style.textColor.nsColor.withAlphaComponent(CGFloat(style.opacity))
        annotation.color = (style.fill ?? CommentColor(red: 1, green: 1, blue: 1, alpha: 0)).nsColor
            .withAlphaComponent(style.fill == nil ? 0 : CGFloat(style.opacity))
        let border = PDFBorder()
        border.lineWidth = CGFloat(style.lineWidth)
        if style.lineStyle == .dashed { border.style = .dashed; border.dashPattern = style.dashPattern }
        annotation.border = border
        annotation.contents = ""
        annotation.setValue("/FreeTextTypewriter", forAnnotationKey: Self.intentKey)
        CommentSpec.set(["opacity": style.opacity], on: annotation)
        return annotation
    }

    func makeCallout(anchor: CGPoint, box: CGRect, style: CommentStyle) -> CommentAnnotation {
        let knee = CGPoint(x: box.minX - 12 < anchor.x ? box.minX : box.minX - 12, y: box.midY)
        let end = CGPoint(x: box.minX, y: box.midY)
        let all = [anchor, knee, end, CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
        let pad: CGFloat = 8
        let bounds = CGRect(x: all.map(\.x).min()! - pad, y: all.map(\.y).min()! - pad,
                            width: all.map(\.x).max()! - all.map(\.x).min()! + 2 * pad,
                            height: all.map(\.y).max()! - all.map(\.y).min()! + 2 * pad)
        let o = bounds.origin
        let design = CommentDesign(shape: .callout, style: style,
                                   points: [anchor, knee, end].map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) },
                                   textBox: box.offsetBy(dx: -o.x, dy: -o.y))
        let annotation = CommentAnnotation(bounds: bounds, design: design)
        annotation.contents = ""
        return annotation
    }

    /// A caret snapped to the nearest character boundary on its text line.
    func makeCaret(at point: CGPoint, page: PDFPage, style: CommentStyle) -> CommentAnnotation {
        var anchor = point
        var height: CGFloat = 12
        let index = page.characterIndex(at: point)
        if index >= 0 {
            let character = page.characterBounds(at: index)
            if !character.isEmpty {
                height = max(8, min(24, character.height))
                anchor = CGPoint(x: point.x < character.midX ? character.minX : character.maxX, y: character.minY)
            }
        }
        let width = height * 0.7
        let bounds = CGRect(x: anchor.x - width / 2, y: anchor.y - height * 0.35, width: width, height: height * 0.8)
        let caret = CommentAnnotation(bounds: bounds, design: CommentDesign(shape: .caret, style: style))
        caret.contents = ""
        return caret
    }

    @discardableResult
    func addMarkupAnnotation(_ tool: AnnotationTool, over selection: PDFSelection, in tab: DocumentTab) -> [PDFAnnotation] {
        guard tool.isMarkup else { return [] }
        let subtype: PDFAnnotationSubtype = switch tool {
        case .highlight: .highlight
        case .underline: .underline
        default: .strikeOut
        }
        let style = style(for: tool)
        let quoted = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        var created: [PDFAnnotation] = []
        var lastLine: (page: PDFPage, rect: CGRect)?
        let lines = selection.selectionsByLine()
        for page in selection.pages {
            let rects = lines.compactMap { line -> CGRect? in
                guard line.pages.contains(where: { $0 === page }) else { return nil }
                let rect = line.bounds(for: page)
                return rect.isEmpty ? nil : rect
            }
            guard !rects.isEmpty else { continue }
            let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            // Quadrilaterals (per line, relative to bounds): top-left, top-right, bottom-left, bottom-right.
            annotation.quadrilateralPoints = rects.flatMap { rect -> [NSValue] in
                let r = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                return [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                        CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)].map { NSValue(point: $0) }
            }
            annotation.color = style.color.nsColor.withAlphaComponent(tool == .highlight ? 1 : CGFloat(style.opacity))
            if tool == .replaceText { annotation.setValue("/StrikeOutTextEdit", forAnnotationKey: Self.intentKey) }
            if style.opacity < 0.999 { CommentSpec.set(["opacity": style.opacity], on: annotation) }
            finalize(annotation)
            page.addAnnotation(annotation)
            if let quoted, !quoted.isEmpty { quotedTextByCommentID[commentID(for: annotation)] = quoted }
            created.append(annotation)
            if let last = rects.last { lastLine = (page, last) }
        }
        if tool == .replaceText, let strike = created.last, let lastLine {
            // Acrobat's Replace Text: a caret after the struck text carries the
            // new text; the strike-out is grouped with it (/IRT + /RT /Group).
            var caretStyle = style
            caretStyle.color = CommentColor(strike.color)?.opaque ?? .red
            let h = max(8, min(24, lastLine.rect.height))
            let caret = CommentAnnotation(bounds: CGRect(x: lastLine.rect.maxX - h * 0.35, y: lastLine.rect.minY - h * 0.28,
                                                         width: h * 0.7, height: h * 0.8),
                                          design: CommentDesign(shape: .caret, style: caretStyle))
            caret.contents = ""
            finalize(caret)
            lastLine.page.addAnnotation(caret)
            for piece in created {
                piece.setValue("new:\(commentID(for: caret).uuidString)|Group", forAnnotationKey: GenericAnnotations.replyKey)
            }
            if let quoted, !quoted.isEmpty { quotedTextByCommentID[commentID(for: caret)] = quoted }
            created.insert(caret, at: 0)
        }
        return created
    }

    @discardableResult
    func addInkAnnotation(points: [CGPoint], onPage pageIndex: Int, in tab: DocumentTab) -> PDFAnnotation? {
        guard points.count > 1, let page = tab.pdfDocument?.page(at: pageIndex) else { return nil }
        let style = style(for: .drawing)
        let smoothed = InkSmoothing.smooth(points)
        let pad = CGFloat(style.lineWidth) + 2
        let xs = smoothed.map(\.x), ys = smoothed.map(\.y)
        let bounds = CGRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.add(InkSmoothing.path(smoothed, relativeTo: bounds.origin, width: CGFloat(style.lineWidth)))
        let border = PDFBorder(); border.lineWidth = CGFloat(style.lineWidth)
        annotation.border = border
        annotation.color = style.color.nsColor.withAlphaComponent(CGFloat(style.opacity))
        if style.opacity < 0.999 { CommentSpec.set(["opacity": style.opacity], on: annotation) }
        finalize(annotation)
        page.addAnnotation(annotation)
        return annotation
    }

    @discardableResult
    func addShape(_ tool: AnnotationTool, points: [CGPoint], onPage pageIndex: Int, in tab: DocumentTab) -> PDFAnnotation? {
        guard let page = tab.pdfDocument?.page(at: pageIndex), points.count >= 2 else { return nil }
        let style = style(for: tool)
        let annotation: PDFAnnotation
        switch tool {
        case .rectangle, .oval, .cloud:
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            guard rect.width >= 3, rect.height >= 3 else { return nil }
            annotation = CommentAnnotation(bounds: rect, design: CommentDesign(shape: tool == .oval ? .oval : .rectangle, style: style))
        case .line, .arrow:
            let pad = max(8, CGFloat(style.lineWidth) * 4)
            let rect = CGRect(x: min(points[0].x, points[1].x) - pad, y: min(points[0].y, points[1].y) - pad,
                              width: abs(points[1].x - points[0].x) + 2 * pad, height: abs(points[1].y - points[0].y) + 2 * pad)
            guard hypot(points[1].x - points[0].x, points[1].y - points[0].y) >= 3 else { return nil }
            var lineStyle = style
            if tool == .arrow, lineStyle.endEnding == .none { lineStyle.endEnding = .openArrow }
            annotation = CommentAnnotation(bounds: rect, design: CommentDesign(shape: .line, style: lineStyle,
                                                                              points: points.prefix(2).map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }))
        case .polygon, .polyline:
            guard points.count >= (tool == .polygon ? 3 : 2) else { return nil }
            let pad = max(4, CGFloat(style.lineWidth) * 4) + (style.lineStyle == .cloudy ? CommentDrawing.cloudRadius(style) : 0)
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
            annotation = CommentAnnotation(bounds: rect, design: CommentDesign(shape: tool == .polygon ? .polygon : .polyline, style: style,
                                                                              points: points.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }))
        case .textBox:
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: max(40, abs(points[1].x - points[0].x)), height: max(20, abs(points[1].y - points[0].y)))
            annotation = makeTextBox(rect, style: style)
        case .callout:
            let anchor = points[0], end = points[1]
            let box = CGRect(x: end.x, y: end.y - 24, width: 160, height: 48)
            annotation = makeCallout(anchor: anchor, box: box, style: style)
        default:
            return nil
        }
        finalize(annotation)
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: - Editing & removal

    func updateComment(_ comment: Comment, newText: String, in tab: DocumentTab) {
        guard let found = annotation(for: comment, in: tab) else { return }
        var target = found.annotation
        // Replace Text keeps the replacement on the caret (the grouped primary).
        if comment.kind == .replaceText, target.type == "StrikeOut",
           let caret = thread(of: target, in: tab).dropFirst().first(where: { $0.annotation.type == "Caret" }) {
            target = caret.annotation
        }
        guard target.contents != newText else { return }
        target.contents = newText
        target.modificationDate = Date()
        if let drawn = target as? CommentAnnotation { drawn.setValue(UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFRevision")) }
    }

    func remove(comment: Comment, from tab: DocumentTab) {
        guard let found = annotation(for: comment, in: tab) else { return }
        for item in thread(of: found.annotation, in: tab).reversed() {
            if let popup = item.annotation.popup, popup.page === item.page { item.page.removeAnnotation(popup) }
            item.page.removeAnnotation(item.annotation)
        }
        quotedTextByCommentID[comment.id] = nil
    }

    /// A reply is a hidden Text annotation "in reply to" its parent.
    @discardableResult
    func addReply(_ text: String, to comment: Comment, in tab: DocumentTab) -> PDFAnnotation? {
        guard let found = annotation(for: comment, in: tab) else { return nil }
        let reply = makeReply(to: found.annotation, in: tab)
        reply.contents = text
        found.page.addAnnotation(reply)
        return reply
    }

    private func makeReply(to parent: PDFAnnotation, in tab: DocumentTab) -> PDFAnnotation {
        let origin = CGPoint(x: parent.bounds.minX, y: parent.bounds.maxY - 20)
        let reply = PDFAnnotation(bounds: CGRect(origin: origin, size: CGSize(width: 20, height: 20)), forType: .text, withProperties: nil)
        reply.color = parent.color.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? .systemYellow
        reply.shouldDisplay = false
        reply.shouldPrint = false
        reply.setValue(replyTarget(for: parent, in: tab), forAnnotationKey: GenericAnnotations.replyKey)
        CommentSpec.set(["flags": 30], on: reply)
        finalize(reply)
        return reply
    }

    func replyTarget(for parent: PDFAnnotation, in tab: DocumentTab) -> String {
        if let position = tab.saveBaseline?.position(of: parent) { return "\(position.page):\(position.index)" }
        return "new:\(commentID(for: parent).uuidString)"
    }

    func setStatus(_ status: CommentStatus, for comment: Comment, in tab: DocumentTab) {
        setState(model: "Review", value: status.rawValue,
                 text: status == .none ? "None set by \(author)" : "\(status.rawValue) set by \(author)", comment: comment, tab: tab)
    }

    func setMarked(_ marked: Bool, for comment: Comment, in tab: DocumentTab) {
        setState(model: "Marked", value: marked ? "Marked" : "Unmarked",
                 text: marked ? "Marked set by \(author)" : "Unmarked set by \(author)", comment: comment, tab: tab)
    }

    private func setState(model: String, value: String, text: String, comment: Comment, tab: DocumentTab) {
        guard let found = annotation(for: comment, in: tab) else { return }
        // Replace this session's earlier state by the same author; saved history stays.
        for item in thread(of: found.annotation, in: tab).dropFirst()
        where stateModel(of: item.annotation) == model && item.annotation.userName == author
            && item.annotation.value(forAnnotationKey: GenericAnnotations.replyKey) != nil
            && tab.saveBaseline?.position(of: item.annotation) == nil {
            item.page.removeAnnotation(item.annotation)
        }
        let reply = makeReply(to: found.annotation, in: tab)
        reply.contents = text
        reply.setValue("/" + value, forAnnotationKey: Self.stateKey)
        reply.setValue("/" + model, forAnnotationKey: Self.stateModelKey)
        found.page.addAnnotation(reply)
    }

    // MARK: - Identity & lookup

    /// Stable UUID for an annotation, read from (or lazily written into)
    /// its annotation dictionary so it survives within the document.
    func commentID(for annotation: PDFAnnotation) -> UUID {
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
    func finalize(_ annotation: PDFAnnotation) {
        annotation.userName = author
        annotation.modificationDate = Date()
        _ = commentID(for: annotation)
    }

    func annotation(for comment: Comment, in tab: DocumentTab) -> (annotation: PDFAnnotation, page: PDFPage)? {
        guard let document = tab.pdfDocument else { return nil }
        let order = [comment.pageIndex] + (0..<document.pageCount).filter { $0 != comment.pageIndex }
        for index in order {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where Self.isListed(annotation) && commentID(for: annotation) == comment.id {
                return (annotation, page)
            }
        }
        return nil
    }

    func comment(for annotation: PDFAnnotation, in tab: DocumentTab) -> Comment? {
        let list = comments(for: tab)
        if let direct = findComment(id: commentID(for: annotation), in: list) { return direct }
        // Grouped markup (a Replace Text strike-out) or a status answers for its thread.
        for root in list {
            guard let found = self.annotation(for: root, in: tab) else { continue }
            if thread(of: found.annotation, in: tab).contains(where: { $0.annotation === annotation }) { return root }
        }
        return nil
    }

    private func findComment(id: UUID, in list: [Comment]) -> Comment? {
        for comment in list {
            if comment.id == id { return comment }
            if let found = findComment(id: id, in: comment.replies) { return found }
        }
        return nil
    }

    func thread(of annotation: PDFAnnotation, in tab: DocumentTab) -> [(annotation: PDFAnnotation, page: PDFPage)] {
        guard let document = tab.pdfDocument, let root = annotation.page else { return [] }
        var all: [(PDFAnnotation, PDFPage)] = []
        var byID: [UUID: PDFAnnotation] = [:]
        var replacements: [ObjectIdentifier: PDFAnnotation] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for candidate in page.annotations where Self.isListed(candidate) {
                all.append((candidate, page))
                byID[commentID(for: candidate)] = candidate
                if let original = AnnotationReplacement.original(of: candidate) { replacements[ObjectIdentifier(original)] = candidate }
            }
        }
        var result: [(annotation: PDFAnnotation, page: PDFPage)] = [(annotation, root)]
        var frontier: Set<ObjectIdentifier> = [ObjectIdentifier(annotation)]
        var changed = true
        while changed {
            changed = false
            for (candidate, page) in all where !frontier.contains(ObjectIdentifier(candidate)) {
                if let (parent, _) = parent(of: candidate, tab: tab, byID: byID, replacements: replacements),
                   frontier.contains(ObjectIdentifier(parent)) {
                    frontier.insert(ObjectIdentifier(candidate))
                    result.append((candidate, page))
                    changed = true
                }
            }
        }
        return result
    }
}

/// Engine completion keys (/ZPDFSpec) on annotations PDFKit draws itself.
enum CommentSpec {
    static let key = PDFAnnotationKey(rawValue: "/ZPDFSpec")

    static func get(_ annotation: PDFAnnotation) -> [String: Any] {
        guard let text = annotation.value(forAnnotationKey: key) as? String, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    static func set(_ values: [String: Any], on annotation: PDFAnnotation) {
        if let drawn = annotation as? CommentAnnotation {
            var extra = drawn.extraSpec ?? [:]
            for (k, v) in values { extra[k] = v }
            drawn.extraSpec = extra
            return
        }
        var spec = get(annotation)
        for (k, v) in values { spec[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]) {
            annotation.setValue(String(decoding: data, as: UTF8.self), forAnnotationKey: key)
        }
        annotation.setValue(UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFRevision"))
    }
}

/// Freehand smoothing: light moving-average denoise, then Catmull-Rom
/// resampling. The result is a dense polyline, so /InkList (which PDFKit
/// writes from path points) matches the drawn curve in every viewer.
enum InkSmoothing {
    static func smooth(_ input: [CGPoint]) -> [CGPoint] {
        // Drop near-duplicate samples from high-frequency mouse events.
        var points: [CGPoint] = []
        for point in input where points.last.map({ hypot($0.x - point.x, $0.y - point.y) >= 0.75 }) ?? true { points.append(point) }
        guard points.count > 2 else { return points.count == 1 ? [points[0], CGPoint(x: points[0].x + 0.5, y: points[0].y)] : points }
        var averaged = points
        for i in 1..<(points.count - 1) {
            averaged[i] = CGPoint(x: (points[i - 1].x + 2 * points[i].x + points[i + 1].x) / 4,
                                  y: (points[i - 1].y + 2 * points[i].y + points[i + 1].y) / 4)
        }
        var result: [CGPoint] = [averaged[0]]
        for i in 0..<(averaged.count - 1) {
            let p0 = averaged[max(0, i - 1)], p1 = averaged[i], p2 = averaged[i + 1], p3 = averaged[min(averaged.count - 1, i + 2)]
            let steps = max(1, min(8, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 3)))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                result.append(CGPoint(x: x, y: y))
            }
        }
        return result
    }

    static func path(_ points: [CGPoint], relativeTo origin: CGPoint, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x - origin.x, y: first.y - origin.y))
        for point in points.dropFirst() { path.line(to: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}
