import AppKit
import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class SearchOptionsTests: XCTestCase {
    private func document(_ text: String) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // PDFKit extracts the system font's underscore below the baseline as
        // its own line ("cat\n_\n2"). Helvetica retains the intended word,
        // so this fixture tests boundaries rather than extraction geometry.
        text.draw(at: CGPoint(x: 36, y: 600), withAttributes: [.font: try XCTUnwrap(NSFont(name: "Helvetica", size: 14))])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func finish(_ tab: DocumentTab) async throws {
        for _ in 0..<500 {
            if !tab.isSearching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(tab.isSearching, "Asynchronous search should finish")
    }

    func testWholeWordsUseUnicodeBoundaries() {
        func whole(_ query: String, in source: String) -> Bool {
            let range = (source as NSString).range(of: query)
            return SearchWordBoundary.isBoundary(in: source, at: range.location)
                && SearchWordBoundary.isBoundary(in: source, at: NSMaxRange(range))
        }
        XCTAssertTrue(whole("café", in: "A café, here"))
        XCTAssertFalse(whole("caf", in: "A café, here"))
        XCTAssertTrue(whole("cafe\u{301}", in: "cafe\u{301}!"))
        XCTAssertFalse(whole("cafe", in: "cafe\u{301}!"))
        XCTAssertTrue(whole("κόσμος", in: "γειά κόσμος!"))
        XCTAssertFalse(whole("κόσ", in: "γειά κόσμος!"))
        XCTAssertFalse(whole("name", in: "field_name"))
        XCTAssertFalse(whole("don", in: "don't"))
        XCTAssertTrue(whole("don't", in: "don't stop"))
        XCTAssertTrue(whole("word", in: "😀word!"))
    }

    func testOptionsRerunAsyncSearchAndMatchNavigationWraps() async throws {
        let tab = DocumentTab(pdfDocument: try document("Cat cat scatter cat_2 CAT"))
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.string, "Cat cat scatter cat_2 CAT")
        tab.searchText = "cat"
        tab.updateSearchResults()
        try await finish(tab)
        XCTAssertEqual(tab.searchMatches.count, 5)
        tab.searchWholeWords = true
        try await finish(tab)
        XCTAssertEqual(tab.searchMatches.count, 3)
        XCTAssertEqual(tab.searchCountText, "1/3")
        tab.goToPreviousMatch()
        XCTAssertEqual(tab.searchCountText, "3/3")
        tab.goToNextMatch()
        XCTAssertEqual(tab.searchCountText, "1/3")
        tab.searchCaseSensitive = true
        try await finish(tab)
        XCTAssertEqual(tab.searchMatches.count, 1)
        XCTAssertEqual(tab.currentMatch?.string, "cat")
        tab.searchWholeWords = false
        try await finish(tab)
        XCTAssertEqual(tab.searchMatches.count, 3)
        tab.searchText = " "
        tab.updateSearchResults()
        XCTAssertNil(tab.searchCountText)
        XCTAssertNil(tab.currentMatch)
    }

    func testPDFSelectionsApplyUnicodeBoundaries() async throws {
        let tab = DocumentTab(pdfDocument: try document("café cafés décafé café"))
        tab.searchText = "café"
        tab.searchWholeWords = true
        try await finish(tab)
        XCTAssertEqual(tab.searchMatches.count, 2)
        XCTAssertTrue(tab.searchMatches.allSatisfy { $0.string == "café" })
    }

    func testOptionChangesAndCancellationRejectStaleResults() async throws {
        let tab = DocumentTab(pdfDocument: try document("Cat cat scatter CAT"))
        tab.searchText = "cat"
        tab.updateSearchResults()
        tab.searchWholeWords = true
        tab.searchCaseSensitive = true
        try await finish(tab)
        XCTAssertEqual(tab.searchMatches.count, 1)
        tab.searchCaseSensitive = false
        tab.cancelSearch()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(tab.isSearching)
        XCTAssertTrue(tab.searchMatches.isEmpty)
        tab.updateSearchResults()
        tab.pdfDocument = try document("A different document")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(tab.isSearching)
        XCTAssertTrue(tab.searchMatches.isEmpty)
        XCTAssertNil(tab.currentMatch)
    }
}
