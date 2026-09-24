import Foundation
import Observation

enum CommentKind: String, CaseIterable, Identifiable, Sendable {
    case note, highlight, underline, other
    var id: String { rawValue }
    var title: String {
        switch self { case .note: "Notes"; case .highlight: "Highlights"; case .underline: "Underlines"; case .other: "Other" }
    }
    init(pdfSubtype: String?) {
        switch pdfSubtype?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "Text": self = .note
        case "Highlight": self = .highlight
        case "Underline": self = .underline
        default: self = .other
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

struct CommentReviewQuery {
    var text = ""
    var kind: CommentKind?
    var sort: CommentSortOrder = .page

    func matches(_ comment: Comment) -> Bool {
        guard kind == nil || kind == comment.kind else { return false }
        let terms = text.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in
            comment.text.localizedCaseInsensitiveContains(String(term)) || comment.author.localizedCaseInsensitiveContains(String(term))
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
