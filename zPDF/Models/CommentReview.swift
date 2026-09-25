import Foundation
import Observation

/// What a comment is, for the list icon and the type filter. Each maps to one
/// or more PDF annotation subtypes (see `init(pdfSubtype:intent:)`).
enum CommentKind: String, CaseIterable, Identifiable, Sendable {
    case note, highlight, underline, strikethrough, replaceText, insertText
    case textBox, callout, drawing, shape, line, stamp, attachment, sound, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .note: "Notes"
        case .highlight: "Highlights"
        case .underline: "Underlines"
        case .strikethrough: "Strikethroughs"
        case .replaceText: "Replaced text"
        case .insertText: "Inserted text"
        case .textBox: "Text boxes"
        case .callout: "Callouts"
        case .drawing: "Drawings"
        case .shape: "Shapes"
        case .line: "Lines & arrows"
        case .stamp: "Stamps"
        case .attachment: "Attachments"
        case .sound: "Sounds"
        case .other: "Other"
        }
    }
    /// Singular label used in rows and accessibility text.
    var singular: String {
        switch self {
        case .note: "Note"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .replaceText: "Replace text"
        case .insertText: "Insert text"
        case .textBox: "Text box"
        case .callout: "Callout"
        case .drawing: "Drawing"
        case .shape: "Shape"
        case .line: "Line"
        case .stamp: "Stamp"
        case .attachment: "File attachment"
        case .sound: "Sound"
        case .other: "Comment"
        }
    }
    var symbolName: String {
        switch self {
        case .note: "note.text"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .replaceText: "character.cursor.ibeam"
        case .insertText: "text.insert"
        case .textBox: "character.textbox"
        case .callout: "text.bubble"
        case .drawing: "scribble.variable"
        case .shape: "square.on.circle"
        case .line: "arrow.up.right"
        case .stamp: "seal"
        case .attachment: "paperclip"
        case .sound: "waveform"
        case .other: "bubble.left"
        }
    }
    init(pdfSubtype: String?, intent: String? = nil) {
        let intent = intent?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch pdfSubtype?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "Text": self = .note
        case "Highlight": self = .highlight
        case "Underline", "Squiggly": self = .underline
        case "StrikeOut": self = intent == "StrikeOutTextEdit" ? .replaceText : .strikethrough
        case "Caret": self = .insertText
        case "FreeText": self = intent == "FreeTextCallout" ? .callout : .textBox
        case "Ink": self = .drawing
        case "Square", "Circle", "Polygon": self = .shape
        case "Line", "PolyLine": self = .line
        case "Stamp": self = .stamp
        case "FileAttachment": self = .attachment
        case "Sound": self = .sound
        default: self = .other
        }
    }
}

/// Acrobat review status (a reply annotation with /StateModel /Review).
enum CommentStatus: String, CaseIterable, Identifiable, Sendable {
    case none = "None", accepted = "Accepted", rejected = "Rejected", cancelled = "Cancelled", completed = "Completed"
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue }
    var symbolName: String {
        switch self {
        case .none: "circle.dashed"
        case .accepted: "checkmark.circle.fill"
        case .rejected: "xmark.circle.fill"
        case .cancelled: "slash.circle.fill"
        case .completed: "checkmark.seal.fill"
        }
    }
}

enum CommentSortOrder: String, CaseIterable, Identifiable {
    case page, newest, oldest, author
    var id: String { rawValue }
    var title: String {
        switch self { case .page: "Page order"; case .newest: "Newest first"; case .oldest: "Oldest first"; case .author: "Author" }
    }
}

struct CommentReviewQuery: Equatable {
    var text = ""
    var kind: CommentKind?
    /// Reviewer (author) filter; nil shows everyone.
    var author: String?
    /// Status filter; nil shows every status.
    var status: CommentStatus?
    /// Checkmark filter; nil shows marked and unmarked comments.
    var marked: Bool?
    var sort: CommentSortOrder = .page

    var isFiltering: Bool { kind != nil || author != nil || status != nil || marked != nil }

    /// Type/reviewer/status filters only (no text search): shared with the
    /// on-page filter so the canvas and the list agree.
    func passesFilters(_ comment: Comment) -> Bool {
        guard kind == nil || kind == comment.kind else { return false }
        guard author == nil || author == comment.author else { return false }
        guard status == nil || status == comment.status else { return false }
        guard marked == nil || marked == comment.isMarked else { return false }
        return true
    }

    func matches(_ comment: Comment) -> Bool {
        guard passesFilters(comment) else { return false }
        let terms = text.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in
            comment.threadText.localizedCaseInsensitiveContains(String(term)) || comment.author.localizedCaseInsensitiveContains(String(term))
                || (comment.quotedText?.localizedCaseInsensitiveContains(String(term)) ?? false)
        }
    }

    /// Original document order breaks ties, rather than a random UUID or a
    /// changing date fallback. Active drafts remain visible until completed.
    func apply(to comments: [Comment], keepingVisible ids: Set<UUID> = []) -> [Comment] {
        comments.enumerated()
            .filter { ids.contains($0.element.id) || matches($0.element) }
            .sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                switch sort {
                case .page:
                    if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
                case .newest:
                    if a.date != b.date { return a.date > b.date }
                case .oldest:
                    if a.date != b.date { return a.date < b.date }
                case .author:
                    let result = a.author.localizedCaseInsensitiveCompare(b.author)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Lives above filtered rows, so removing/reordering a row cannot discard the
/// original text needed by Cancel. Draft text is still written through live.
@Observable
final class CommentEditDraft {
    var isEditing = false
    var text = ""
    private(set) var originalText = ""
    func begin(_ text: String) {
        guard !isEditing else { return }
        originalText = text
        self.text = text
        isEditing = true
    }
    func finish() { isEditing = false }
}

@Observable
final class CommentDraftStore {
    private var drafts: [UUID: CommentEditDraft] = [:]
    var editingIDs: Set<UUID> { Set(drafts.compactMap { $0.value.isEditing ? $0.key : nil }) }
    func existingDraft(for id: UUID) -> CommentEditDraft? { drafts[id] }
    func draft(for id: UUID) -> CommentEditDraft {
        if let draft = drafts[id] { return draft }
        let draft = CommentEditDraft()
        drafts[id] = draft
        return draft
    }
    func retain(ids: Set<UUID>) {
        drafts = drafts.filter { ids.contains($0.key) }
        for id in ids where drafts[id] == nil { drafts[id] = CommentEditDraft() }
    }
}
