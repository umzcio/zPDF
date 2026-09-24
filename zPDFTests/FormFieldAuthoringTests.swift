import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class FormFieldAuthoringTests: XCTestCase {
    private func opened(_ name: String = "irs-1040-worksheet-b") async throws -> (AppState, DocumentTab, URL, URL) {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pdf"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Form.pdf")
        try FileManager.default.copyItem(at: source, to: url)
        let state = AppState(); state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 {
            if !tab.saveChecking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(tab.saveChecking)
        return (state, tab, url, directory)
    }

    func testWorksheetDetectionReviewUndoAndRepeatedNativeSaves() async throws {
        let (state, tab, url, directory) = try await opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let document = try XCTUnwrap(tab.pdfDocument)
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(tab.editSource)
        let found = try await NativeSaveBridge.detectFields(source.url, expectedHash: source.hash, page: 0)
        XCTAssertEqual(found.filter { $0.type == "text" }.count, 11)
        XCTAssertEqual(found.filter { $0.type == "checkbox" }.count, 2)
        XCTAssertEqual(page.annotations.filter { $0.type == "Widget" }.count, 0)
        XCTAssertFalse(tab.hasUnsavedChanges)
        let drafts = found.enumerated().map { i, f in
            DraftFormField(name: "Worksheet \(i)", type: f.type,
                           bounds: CGRect(x: f.rect[0], y: f.rect[1], width: f.rect[2]-f.rect[0], height: f.rect[3]-f.rect[1]))
        }
        try FormFieldAuthoring.apply(drafts, page: page, tab: tab, state: state)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(page.annotations.filter { $0.type == "Widget" }.count, 13)
        state.undoDocumentEdit()
        XCTAssertEqual(page.annotations.filter { $0.type == "Widget" }.count, 0)
        XCTAssertFalse(tab.hasUnsavedChanges)
        state.redoDocumentEdit()
        let text = try XCTUnwrap(page.annotations.first { $0.fieldName == "Worksheet 0" })
        let checkbox = try XCTUnwrap(page.annotations.first { $0.fieldName == "Worksheet 11" })
        text.widgetStringValue = "123.45"; checkbox.buttonWidgetState = .onState
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Keep worksheet comment"; page.addAnnotation(note)
        state.noteAnnotationsChanged()
        XCTAssertEqual(try Data(contentsOf: url), original)
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertFalse(tab.pdfDocument === document)
        var reopened = try XCTUnwrap(PDFDocument(url: url))
        let widgets = reopened.page(at: 0)!.annotations.filter { $0.type == "Widget" }
        XCTAssertEqual(widgets.count, 13)
        XCTAssertTrue(widgets.allSatisfy { !$0.isReadOnly })
        XCTAssertEqual(widgets.first { $0.fieldName == "Worksheet 0" }?.widgetStringValue, "123.45")
        XCTAssertEqual(widgets.first { $0.fieldName == "Worksheet 11" }?.buttonWidgetState, .onState)
        XCTAssertTrue(reopened.page(at: 0)!.annotations.contains { $0.contents == "Keep worksheet comment" })
        let currentPage = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let currentText = try XCTUnwrap(currentPage.annotations.first { $0.fieldName == "Worksheet 0" })
        currentText.widgetStringValue = "987.65"
        currentPage.annotations.first { $0.fieldName == "Worksheet 11" }?.buttonWidgetState = .offState
        state.noteAnnotationsChanged()
        let again = await state.saveDocument(tab).value
        XCTAssertTrue(again, state.saveError?.message ?? "")
        reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.fieldName == "Worksheet 0" }?.widgetStringValue, "987.65")
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.fieldName == "Worksheet 11" }?.buttonWidgetState, .offState)
        let newSource = try XCTUnwrap(tab.editSource)
        let remaining = try await NativeSaveBridge.detectFields(newSource.url, expectedHash: newSource.hash, page: 0)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInvalidReviewDoesNotPartiallyApplyAndReadOnlyIsBlocked() async throws {
        let (state, tab, _, directory) = try await opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let valid = DraftFormField(name: "Amount", type: "text", bounds: CGRect(x: 300, y: 400, width: 100, height: 20))
        var bad = valid; bad.name = "Other"; bad.bounds.origin.x = -100
        XCTAssertThrowsError(try FormFieldAuthoring.apply([valid,bad], page: page, tab: tab, state: state))
        XCTAssertFalse(page.annotations.contains { $0.type == "Widget" })
        XCTAssertFalse(tab.hasUnsavedChanges)
        XCTAssertThrowsError(try FormFieldAuthoring.apply([valid,valid], page: page, tab: tab, state: state))
        tab.saveBlock = "XFA_EDIT_BLOCKED"
        XCTAssertThrowsError(try FormFieldAuthoring.apply([valid], page: page, tab: tab, state: state))
        XCTAssertFalse(page.annotations.contains { $0.type == "Widget" })
    }

    func testManualFieldSurvivesRotationAndPreservesExistingI9Fields() async throws {
        let (state, tab, _, directory) = try await opened("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let originalCount = (0..<tab.pdfDocument!.pageCount).flatMap { tab.pdfDocument!.page(at: $0)!.annotations }.filter { $0.type == "Widget" }.count
        let field = DraftFormField(name: "Additional reference", type: "text", bounds: CGRect(x: 35, y: 12, width: 120, height: 15))
        try FormFieldAuthoring.apply([field], page: page, tab: tab, state: state)
        page.rotation = 90
        page.annotations.first { $0.fieldName == field.name }?.widgetStringValue = "REF 2026"
        state.noteAnnotationsChanged()
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.rotation, 90)
        let all = (0..<tab.pdfDocument!.pageCount).flatMap { tab.pdfDocument!.page(at: $0)!.annotations }.filter { $0.type == "Widget" }
        XCTAssertEqual(all.count, originalCount+1)
        XCTAssertEqual(all.first { $0.fieldName == field.name }?.widgetStringValue, "REF 2026")
    }
}
