//
//  Comment.swift
//  zPDF
//
//  Purpose: Model for an annotation comment in the Comment panel: author,
//  date, text, page index, optional quoted passage, and nested reply
//  threading (replies are child Comments).
//  Phase: 2 — REAL model; synced with the document's PDFAnnotations by
//  AnnotationService (id matches the annotation's stable comment UUID,
//  text persists into PDFAnnotation.contents, replies thread in memory).
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
    /// Quoted source text shown above the comment (prototype .quote block).
    var quotedText: String?
    var replies: [Comment]

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

    /// Sample threads mirroring the prototype's Comment panel — used by
    /// SwiftUI previews only.
    static let sampleData: [Comment] = [
        Comment(author: "Sarah Chen",
                text: "Can we update the Q3 figures in Table 1? The final numbers came in yesterday."),
        Comment(author: "David Okafor",
                text: "Confirmed these numbers with Finance — good to go.",
                quotedText: "Revenue reached $48.2 million, an increase of 12.4%…"),
        Comment(author: "Priya Nair",
                text: "Add a footnote on methodology here — auditors will ask for it."),
        Comment(author: "Alex Morgan",
                text: "Looks good overall. Ready for exec review once these edits land.")
    ]
}
