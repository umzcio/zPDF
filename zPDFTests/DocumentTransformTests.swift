import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class DocumentTransformTests: XCTestCase {
    func testGenericAnnotationsSaveReopenAndDelete() async throws {
        let (url, directory) = try TestSupport.fixture("uscis-i9", in: Self.self)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let before = page.annotations.count
        let square = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 120, height: 80), forType: .square, withProperties: nil)
        square.color = .red
        square.contents = "Square note"
        page.addAnnotation(square)
        let ink = PDFAnnotation(bounds: CGRect(x: 200, y: 200, width: 100, height: 100), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.move(to: CGPoint(x: 5, y: 5)); path.line(to: CGPoint(x: 90, y: 80))
        ink.add(path)
        page.addAnnotation(ink)
        // A multi-line highlight uses quadrilaterals, which the facade path rejects.
        let highlight = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 200, height: 30), forType: .highlight, withProperties: nil)
        highlight.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: 30)), NSValue(point: CGPoint(x: 200, y: 30)),
                                         NSValue(point: CGPoint(x: 0, y: 15)), NSValue(point: CGPoint(x: 200, y: 15))]
        page.addAnnotation(highlight)
        state.refreshUnsavedChanges(tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        try await TestSupport.save(state, tab)

        let reopened = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let types = reopened.annotations.map { $0.type ?? "" }
        XCTAssertEqual(reopened.annotations.count, before + 3)
        XCTAssertTrue(types.contains("Square") && types.contains("Ink") && types.contains("Highlight"))
        XCTAssertEqual(reopened.annotations.first { $0.type == "Square" }?.contents, "Square note")

        // Update colour + delete the ink on the reloaded revision.
        let live = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let liveSquare = try XCTUnwrap(live.annotations.first { $0.type == "Square" })
        liveSquare.color = .blue
        live.removeAnnotation(try XCTUnwrap(live.annotations.first { $0.type == "Ink" }))
        state.refreshUnsavedChanges(tab)
        try await TestSupport.save(state, tab)
        let final = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertEqual(final.annotations.count, before + 2)
        XCTAssertFalse(final.annotations.contains { $0.type == "Ink" })
        let blue = try XCTUnwrap(final.annotations.first { $0.type == "Square" }?.color.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(blue.blueComponent, 0.9)
        XCTAssertLessThan(blue.redComponent, 0.1)
    }

    func testTransformUndoRedoAndSave() async throws {
        let (url, directory) = try TestSupport.fixture("uscis-i9", in: Self.self)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        // A pending field edit must be carried into the transformed revision.
        let field = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.widgetFieldType == .text })
        field.widgetStringValue = "Carried value"
        state.refreshUnsavedChanges(tab)
        try await state.applyDocumentTransform([["op": "watermark", "text": "DRAFT COPY"]], to: tab, actionName: "Add Watermark")
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("DRAFT COPY") == true)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), original, "Transforms never write the user's file")
        let carried = tab.pdfDocument?.page(at: 0)?.annotations.first { $0.fieldName == field.fieldName }
        XCTAssertEqual(carried?.widgetStringValue, "Carried value")

        tab.undoHistory?.manager.undo()
        XCTAssertFalse(tab.pdfDocument?.page(at: 0)?.string?.contains("DRAFT COPY") == true)
        tab.undoHistory?.manager.redo()
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("DRAFT COPY") == true)

        try await TestSupport.save(state, tab)
        XCTAssertTrue(TestSupport.text(url).contains("DRAFT COPY"))
        XCTAssertFalse(tab.hasUnsavedChanges)
        let saved = PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.fieldName == field.fieldName }
        XCTAssertEqual(saved?.widgetStringValue, "Carried value")
    }
}
