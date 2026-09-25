//
//  Comment.swift
//  zPDF
//
//  Purpose: Model for one comment thread row in the Comment panel: author,
//  date, text, page, subtype/kind, review status, checkmark, media details
//  and nested replies. Built by AnnotationService from the document's real
//  annotations: replies are Text annotations whose /IRT names the parent
//  (read from the file, or /ZPDFReplyTo for replies added this session), and
//  review status comes from /State + /StateModel reply annotations.
//

import Foundation

struct Comment: Identifiable, Equatable, Sendable {
    let id: UUID
    var author: String
    var date: Date
    var text: String
    /// Zero-based page index the comment is attached to.
    var pageIndex: Int
    var kind: CommentKind
    /// PDF subtype without the leading slash ("Square", "FreeText"...).
    var subtype: String = ""
    /// Quoted source text shown above the comment (prototype .quote block).
    var quotedText: String?
    var replies: [Comment]
    /// Latest Review-model state set on this comment (Acrobat "Set Status").
    var status: CommentStatus = .none
    var statusAuthor: String?
    /// Marked-model state (Acrobat checkmark).
    var isMarked = false
    /// sRGB hex of the annotation colour, for the list icon tint.
    var colorHex: String?
    var attachmentName: String?
    var attachmentSize: Int?
    var soundDuration: Double?
    /// True when the comment is only in this session (not yet saved).
    var isNew = false

    init(id: UUID = UUID(),
         author: String,
         date: Date = Date(),
         text: String,
         pageIndex: Int = 0,
         kind: CommentKind = .other,
         quotedText: String? = nil,
         replies: [Comment] = []) {
        self.id = id
        self.author = author
        self.date = date
        self.text = text
        self.pageIndex = pageIndex
        self.kind = kind
        self.quotedText = quotedText
        self.replies = replies
    }

    /// Up-to-two-letter avatar initials ("Sarah Chen" → "SC").
    var authorInitials: String {
        let parts = author.split(separator: " ")
        let initials = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return initials.joined().uppercased()
    }

    /// Total reply count including nested replies.
    var totalReplyCount: Int {
        replies.reduce(replies.count) { $0 + $1.totalReplyCount }
    }

    /// Every id in this thread (self first, then replies depth-first).
    var threadIDs: [UUID] { [id] + replies.flatMap(\.threadIDs) }

    /// Searchable text of the whole thread, so a query matches a reply too.
    var threadText: String { ([text] + replies.map(\.threadText)).joined(separator: "\n") }

    /// Sample threads mirroring the prototype's Comment panel — used by
    /// SwiftUI previews only.
    static let sampleData: [Comment] = [
        Comment(author: "Sarah Chen",
                text: "Can we update the Q3 figures in Table 1? The final numbers came in yesterday."),
        Comment(author: "David Okafor",
                text: "Confirmed these numbers with Finance — good to go.",
                kind: .highlight,
                quotedText: "Revenue reached $48.2 million, an increase of 12.4%…"),
        Comment(author: "Priya Nair",
                text: "Add a footnote on methodology here — auditors will ask for it.", kind: .shape),
        Comment(author: "Alex Morgan",
                text: "Looks good overall. Ready for exec review once these edits land.", kind: .stamp)
    ]
}
