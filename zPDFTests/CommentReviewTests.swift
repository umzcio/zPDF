import XCTest
@testable import zPDF

final class CommentReviewTests: XCTestCase {
    private func comment(_ text: String, author: String = "Alex", page: Int = 0,
                         kind: CommentKind = .note, date: TimeInterval = 100) -> Comment {
        Comment(author: author, date: Date(timeIntervalSince1970: date), text: text, pageIndex: page, kind: kind)
    }

    func testSearchMatchesTextAndAuthorCaseInsensitively() {
        let target = comment("Please check the revenue", author: "Sarah Chen")
        let other = comment("Unrelated text", author: "Alex")
        var query = CommentReviewQuery(text: "sArAh REVENUE")
        XCTAssertEqual(query.apply(to: [other, target]).map(\.id), [target.id])
        query.text = " \n "
        XCTAssertEqual(query.apply(to: [other, target]).count, 2)
    }

    func testReviewerStatusAndCheckmarkFilters() {
        var accepted = comment("One", author: "Ana")
        accepted.status = .accepted
        var marked = comment("Two", author: "Ben")
        marked.isMarked = true
        var reply = comment("Nested answer", author: "Cy")
        reply.text = "Nested answer"
        var parent = comment("Three", author: "Cy")
        parent.replies = [reply]
        let all = [accepted, marked, parent]
        XCTAssertEqual(CommentReviewQuery(author: "Ben").apply(to: all).map(\.id), [marked.id])
        XCTAssertEqual(CommentReviewQuery(status: .accepted).apply(to: all).map(\.id), [accepted.id])
        XCTAssertEqual(CommentReviewQuery(status: CommentStatus.none).apply(to: all).count, 2)
        XCTAssertEqual(CommentReviewQuery(marked: true).apply(to: all).map(\.id), [marked.id])
        XCTAssertEqual(CommentReviewQuery(text: "nested").apply(to: all).map(\.id), [parent.id], "search covers replies")
        XCTAssertFalse(CommentReviewQuery(text: "x").isFiltering)
        XCTAssertTrue(CommentReviewQuery(author: "Ana").isFiltering)
    }

    func testTypeFilterCombinesWithSearch() {
        let note = comment("Review", kind: .note)
        let highlight = comment("Review", kind: .highlight)
        let underline = comment("Something else", kind: .underline)
        let query = CommentReviewQuery(text: "review", kind: .highlight)
        XCTAssertEqual(query.apply(to: [note, highlight, underline]).map(\.id), [highlight.id])
    }

    func testSubtypeMappingDoesNotPretendOtherAnnotationsAreNotes() {
        XCTAssertEqual(CommentKind(pdfSubtype: "Text"), .note)
        XCTAssertEqual(CommentKind(pdfSubtype: "/Highlight"), .highlight)
        XCTAssertEqual(CommentKind(pdfSubtype: "Underline"), .underline)
        XCTAssertEqual(CommentKind(pdfSubtype: "FreeText"), .textBox)
        XCTAssertEqual(CommentKind(pdfSubtype: "FreeText", intent: "/FreeTextCallout"), .callout)
        XCTAssertEqual(CommentKind(pdfSubtype: "StrikeOut"), .strikethrough)
        XCTAssertEqual(CommentKind(pdfSubtype: "StrikeOut", intent: "StrikeOutTextEdit"), .replaceText)
        XCTAssertEqual(CommentKind(pdfSubtype: "Ink"), .drawing)
        XCTAssertEqual(CommentKind(pdfSubtype: "Polygon"), .shape)
        XCTAssertEqual(CommentKind(pdfSubtype: "FileAttachment"), .attachment)
        XCTAssertEqual(CommentKind(pdfSubtype: "Widget"), .other)
        XCTAssertEqual(CommentKind(pdfSubtype: nil), .other)
    }

    func testSortOrdersAndDocumentOrderTieBreak() {
        let first = comment("First", author: "Zoe", page: 2, date: 100)
        let second = comment("Second", author: "alex", page: 0, date: 300)
        let third = comment("Third", author: "Alex", page: 0, date: 200)
        let comments = [first, second, third]
        XCTAssertEqual(CommentReviewQuery(sort: .page).apply(to: comments).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(CommentReviewQuery(sort: .newest).apply(to: comments).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(CommentReviewQuery(sort: .oldest).apply(to: comments).map(\.id), [first.id, third.id, second.id])
        XCTAssertEqual(CommentReviewQuery(sort: .author).apply(to: comments).map(\.id), [second.id, third.id, first.id])
    }

    func testEditingDraftRemainsVisibleWhenTextStopsMatching() {
        let original = comment("Matching text")
        let store = CommentDraftStore()
        let draft = store.draft(for: original.id)
        draft.begin(original.text)
        draft.text = "Replacement that no longer matches"
        var updated = original
        updated.text = draft.text
        let query = CommentReviewQuery(text: "matching", kind: .highlight)
        XCTAssertTrue(query.apply(to: [updated]).isEmpty)
        XCTAssertEqual(query.apply(to: [updated], keepingVisible: store.editingIDs).map(\.id), [original.id])
        XCTAssertEqual(store.draft(for: original.id).originalText, "Matching text")
        draft.finish()
        XCTAssertTrue(query.apply(to: [updated], keepingVisible: store.editingIDs).isEmpty)
    }

    func testDraftIdentityAndCancelBaselineSurviveReordering() {
        let first = comment("Original one"), second = comment("Original two")
        let store = CommentDraftStore()
        store.retain(ids: [first.id, second.id])
        let draft = store.draft(for: first.id)
        draft.begin(first.text)
        draft.text = "Unsaved edit"
        // Rebuilding the filtered/sorted list must neither create a fresh
        // editor nor replace the original text used by Cancel.
        store.retain(ids: [second.id, first.id])
        XCTAssertTrue(store.draft(for: first.id) === draft)
        draft.begin("Unsaved edit")
        XCTAssertEqual(draft.originalText, "Original one")
        XCTAssertEqual(draft.text, "Unsaved edit")
        store.retain(ids: [second.id])
        XCTAssertNil(store.existingDraft(for: first.id))
        XCTAssertTrue(store.editingIDs.isEmpty)
    }
}
