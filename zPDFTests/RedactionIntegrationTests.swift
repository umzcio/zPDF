import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class RedactionIntegrationTests: XCTestCase {
    private func sample() throws -> (url: URL, directory: URL) {
        try EditingFixtures.makePDF(named: "redact", lines: [
            .init(text: "Case notes for Agent Smith 007 filed today.", origin: CGPoint(x: 72, y: 700)),
            .init(text: "SSN 123-45-6789 phone (555) 123-4567 mail jane.doe@example.com", origin: CGPoint(x: 72, y: 680)),
            .init(text: "Card 4111 1111 1111 1111 bad 4111 1111 1111 1112 due 03/14/2025", origin: CGPoint(x: 72, y: 660)),
            .init(text: "Public paragraph that must stay readable.", origin: CGPoint(x: 72, y: 640)),
        ], image: (CGRect(x: 100, y: 300, width: 200, height: 200), .red), info: ["title": "Secret Title", "author": "Jane Doe"])
    }

    func testMarksSaveReopenApplyAndVerifyRemoval() async throws {
        let (url, directory) = try sample()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        state.openTool(.redact)
        XCTAssertEqual(state.activePanel, .redact)

        // Search & Redact: literal text.
        let matches = controller.findMatches(query: "Agent Smith 007", pattern: nil, regex: false, matchCase: false, wholeWords: true)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(controller.mark(matches), 1)
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        XCTAssertEqual(page.annotations.filter { $0.type == "Redact" }.count, 1)
        XCTAssertTrue(page.annotations.contains { $0 is RedactionMarkAnnotation })
        XCTAssertTrue(tab.hasUnsavedChanges)
        // Undo removes the mark; redo restores it.
        tab.undoHistory?.manager.undo()
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.annotations.filter { $0.type == "Redact" }.count, 0)
        tab.undoHistory?.manager.redo()
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.annotations.filter { $0.type == "Redact" }.count, 1)

        // Marks are standard /Redact annotations: they survive Save and reopen.
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertEqual(saved.annotations.filter { $0.type == "Redact" }.count, 1)
        XCTAssertTrue(saved.string?.contains("Agent Smith 007") == true, "Marking alone does not remove content")

        // Reopen in a fresh session and apply.
        let state2 = AppState()
        let tab2 = try await TestSupport.open(url, in: state2)
        let controller2 = state2.contentEditing
        XCTAssertEqual(controller2.marks().count, 1)
        XCTAssertTrue(controller2.marks().first?.mark.markRects.isEmpty == false)
        controller2.redactionAppearance.overlayText = "(b)(6)"
        controller2.applyAppearanceToMarks(controller2.marks().map(\.mark))
        controller2.applyRedactions()
        try await EditingFixtures.idle(controller2, tab2)
        let report = try XCTUnwrap(controller2.lastReport)
        XCTAssertEqual(report.marks, 1)
        XCTAssertGreaterThanOrEqual(report.glyphs, 13)
        XCTAssertGreaterThan(report.checked, 0)
        XCTAssertEqual(report.stillFound, [])
        XCTAssertEqual(controller2.marks().count, 0)
        try await TestSupport.save(state2, tab2)

        // PDFKit extraction and selection.
        let final = try XCTUnwrap(PDFDocument(url: url))
        let text = try XCTUnwrap(final.page(at: 0)?.string)
        XCTAssertFalse(text.contains("Agent"))
        XCTAssertFalse(text.contains("007"))
        XCTAssertTrue(text.contains("Case notes for"))
        XCTAssertTrue(text.contains("filed today"), text)
        XCTAssertTrue(text.contains("Public paragraph that must stay readable."))
        XCTAssertTrue(final.findString("Smith", withOptions: .caseInsensitive).isEmpty)
        XCTAssertFalse(final.page(at: 0)?.annotations.contains { $0.type == "Redact" } == true)
        // PDFium extraction (independent text engine).
        let pdfium = try await EditingFixtures.pdfiumText(url)
        XCTAssertFalse(pdfium.contains("Agent"))
        XCTAssertFalse(pdfium.contains("007"))
        XCTAssertTrue(pdfium.contains("(b)(6)"))
        XCTAssertTrue(pdfium.contains("Public paragraph"))
    }

    func testPatternsFindExpectedValues() async throws {
        let (url, directory) = try sample()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        _ = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        func found(_ pattern: RedactionPattern) -> [String] {
            controller.findMatches(query: "", pattern: pattern, regex: false, matchCase: false, wholeWords: false).map(\.text)
        }
        XCTAssertEqual(found(.ssn), ["123-45-6789"])
        XCTAssertEqual(found(.phone), ["(555) 123-4567"])
        XCTAssertEqual(found(.email), ["jane.doe@example.com"])
        XCTAssertEqual(found(.creditCard), ["4111 1111 1111 1111"], "Luhn check rejects the invalid number")
        XCTAssertEqual(found(.date), ["03/14/2025"])
        // Regular expressions and whole words.
        XCTAssertEqual(controller.findMatches(query: #"\d{3}-\d{4}"#, pattern: nil, regex: true, matchCase: false, wholeWords: false).count, 1)
        XCTAssertEqual(controller.findMatches(query: "agent", pattern: nil, regex: false, matchCase: true, wholeWords: false).count, 0)
        XCTAssertEqual(controller.findMatches(query: "Smit", pattern: nil, regex: false, matchCase: false, wholeWords: true).count, 0)
    }

    func testAreaRedactionBlanksImagePixelsAndPatternMarks() async throws {
        let (url, directory) = try sample()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        // Left half of the image; white fill so only the pixel data can make it dark.
        controller.redactionAppearance.fill = .white
        XCTAssertNotNil(controller.addMark(on: page, rects: [CGRect(x: 90, y: 290, width: 110, height: 220)]))
        let ssn = controller.findMatches(query: "", pattern: .ssn, regex: false, matchCase: false, wholeWords: false)
        XCTAssertEqual(controller.mark(ssn), 1)
        controller.applyRedactions()
        try await EditingFixtures.idle(controller, tab)
        XCTAssertEqual(controller.lastReport?.images, 1)
        try await TestSupport.save(state, tab)

        let verify = AppState()
        let reopened = try await TestSupport.open(url, in: verify)
        let result = try await verify.queryDocument("image_samples", params: ["page": 0, "points": [[150, 400], [250, 400]]], in: reopened)
        let samples = try XCTUnwrap(result["samples"] as? [[Int]])
        XCTAssertEqual(samples.count, 2)
        XCTAssertLessThan(samples[0].reduce(0, +), 60, "Redacted pixels are overwritten, not covered")
        XCTAssertGreaterThan(samples[1][0], 200, "Pixels outside the mark are kept")
        XCTAssertLessThan(samples[1][1], 60)
        let text = TestSupport.text(url)
        XCTAssertFalse(text.contains("123-45-6789"))
        XCTAssertTrue(text.contains("phone"))
        // Rendered: the redacted half shows the white fill, the rest stays red.
        let image = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)).thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let kept = try XCTUnwrap(rep.colorAt(x: 250, y: 792 - 400)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(kept.redComponent, 0.8)
        XCTAssertLessThan(kept.greenComponent, 0.3)
    }

    func testWholePageRedactionRemovesFieldsAndText() async throws {
        let (url, directory) = try TestSupport.fixture("uscis-i9", in: Self.self)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        let before = try XCTUnwrap(tab.pdfDocument?.page(at: 1)?.string)
        controller.markPages(.current)
        XCTAssertEqual(controller.marks().count, 1)
        controller.applyRedactions()
        try await EditingFixtures.idle(controller, tab)
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        let first = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(first.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        XCTAssertFalse(first.annotations.contains { $0.type == "Widget" })
        XCTAssertEqual(saved.page(at: 1)?.string, before, "Other pages are untouched")
    }

    func testSanitizeRemovesMetadataAndHiddenText() async throws {
        let (url, directory) = try sample()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Secret Title")
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        let counts = await controller.scanHiddenInformation()
        XCTAssertGreaterThan(counts["metadata"] ?? 0, 0)
        controller.sanitize(["metadata": true, "hidden_text": true, "javascript": true, "embedded_files": true])
        try await EditingFixtures.idle(controller, tab)
        try await TestSupport.save(state, tab)
        let attributes = PDFDocument(url: url)?.documentAttributes ?? [:]
        XCTAssertNil(attributes[PDFDocumentAttribute.titleAttribute] as? String)
        XCTAssertNil(attributes[PDFDocumentAttribute.authorAttribute] as? String)
        XCTAssertTrue(TestSupport.text(url).contains("Public paragraph"))
    }
}
