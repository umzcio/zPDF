import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class WidgetSaveTests: XCTestCase {
    private func fixture(_ name: String) throws -> (URL, URL) {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pdf"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Widgets \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return (destination, directory)
    }

    private func opened(_ url: URL) async throws -> (AppState, DocumentTab) {
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 {
            if !tab.saveChecking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tab.allowsSaveEdits, state.saveError?.message ?? "Open did not finish")
        return (state, tab)
    }

    private func widget(_ document: PDFDocument, _ name: String, page: Int = 0,
                        export: String? = nil) throws -> PDFAnnotation {
        try XCTUnwrap(document.page(at: page)?.annotations.first {
            $0.fieldName == name && (export == nil || $0.buttonWidgetStateString == export)
        })
    }

    private func assertValues(_ document: PDFDocument, checked: Bool, radio: String, region: String,
                              text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let approval = try widget(document, "approval")
        XCTAssertEqual(approval.buttonWidgetState == .onState, checked, file: file, line: line)
        for value in ["Postal", "Email"] {
            let button = try widget(document, "delivery", export: value)
            XCTAssertEqual(button.buttonWidgetState == .onState, value == radio, file: file, line: line)
            XCTAssertEqual(button.widgetStringValue, radio, file: file, line: line)
            XCTAssertFalse(button.isReadOnly, file: file, line: line)
        }
        XCTAssertEqual(try widget(document, "region").widgetStringValue, region, file: file, line: line)
        for page in 0...1 {
            XCTAssertEqual(try widget(document, "shared", page: page).widgetStringValue, text, file: file, line: line)
        }
        XCTAssertFalse(approval.isReadOnly, file: file, line: line)
        XCTAssertFalse(try widget(document, "region").isReadOnly, file: file, line: line)
    }

    func testUndoRedoWidgetValuesThenSave() async throws {
        let (url, directory) = try fixture("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        let document = try XCTUnwrap(tab.pdfDocument)
        let original = (0..<document.pageCount).flatMap { document.page(at: $0)!.annotations }.map { ($0, $0.widgetStringValue, $0.buttonWidgetState) }
        try widget(document, "approval").buttonWidgetState = .onState
        try widget(document, "delivery", export: "Postal").buttonWidgetState = .onState
        try widget(document, "region").widgetStringValue = "CO"
        try widget(document, "shared", page: 1).widgetStringValue = "UNDO LINKED VALUE"
        state.refreshUnsavedChanges(tab)
        state.undoDocumentEdit()
        for (annotation, value, button) in original {
            XCTAssertEqual(annotation.widgetStringValue, value)
            XCTAssertEqual(annotation.buttonWidgetState, button)
        }
        XCTAssertFalse(tab.hasUnsavedChanges)
        state.redoDocumentEdit()
        try assertValues(document, checked: true, radio: "Postal", region: "CO", text: "UNDO LINKED VALUE")
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        try assertValues(XCTUnwrap(PDFDocument(url: url)), checked: true, radio: "Postal", region: "CO", text: "UNDO LINKED VALUE")
    }

    func testOrdinaryWidgetsToggleSwitchAndSaveAgainWithLinkedFieldsAndComment() async throws {
        let (url, directory) = try fixture("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let (state, tab) = try await opened(url)
        let document = try XCTUnwrap(tab.pdfDocument)
        try widget(document, "approval").buttonWidgetState = .onState
        try widget(document, "delivery", export: "Postal").buttonWidgetState = .onState
        try widget(document, "region").widgetStringValue = "CO"
        try widget(document, "shared", page: 1).widgetStringValue = "FIRST LINKED VALUE"
        let note = PDFAnnotation(bounds: CGRect(x: 30, y: 680, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "WIDGET SAVE COMMENT"
        document.page(at: 0)?.addAnnotation(note)
        state.refreshUnsavedChanges(tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let firstSaved = await state.saveDocument(tab).value
        XCTAssertTrue(firstSaved, state.saveError?.message ?? "")
        XCTAssertFalse(tab.hasUnsavedChanges)
        try assertValues(XCTUnwrap(PDFDocument(url: url)), checked: true, radio: "Postal", region: "CO", text: "FIRST LINKED VALUE")
        let reloaded = try XCTUnwrap(tab.pdfDocument)
        try widget(reloaded, "approval").buttonWidgetState = .offState
        try widget(reloaded, "delivery", export: "Email").buttonWidgetState = .onState
        try widget(reloaded, "region").widgetStringValue = "NY"
        try widget(reloaded, "shared").widgetStringValue = "SECOND LINKED VALUE"
        let secondSaved = await state.saveDocument(tab).value
        XCTAssertTrue(secondSaved, state.saveError?.message ?? "")
        try assertValues(XCTUnwrap(PDFDocument(url: url)), checked: false, radio: "Email", region: "NY", text: "SECOND LINKED VALUE")
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.annotations.filter { $0.contents == "WIDGET SAVE COMMENT" }.count, 1)
    }

    func testI9CheckboxAndDropdownSaveThroughApp() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        let document = try XCTUnwrap(tab.pdfDocument)
        let check = try XCTUnwrap(document.page(at: 0)?.annotations.first {
            $0.widgetFieldType == .button && $0.widgetControlType == .checkBoxControl
        })
        let name = try XCTUnwrap(check.fieldName)
        check.buttonWidgetState = .onState
        try widget(document, "State").widgetStringValue = "MT"
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(try widget(reopened, name).buttonWidgetState, .onState)
        XCTAssertEqual(try widget(reopened, "State").widgetStringValue, "MT")
        XCTAssertFalse(try widget(reopened, "State").isReadOnly)
    }

    func testInvalidDropdownPreservesFileAndUnsavedChanges() async throws {
        let (url, directory) = try fixture("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let (state, tab) = try await opened(url)
        try widget(XCTUnwrap(tab.pdfDocument), "region").widgetStringValue = "NOT AN OPTION"
        let saved = await state.saveDocument(tab).value
        XCTAssertFalse(saved)
        XCTAssertTrue(state.saveError?.message.contains("UNSUPPORTED_FIELD_VALUE") == true)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
