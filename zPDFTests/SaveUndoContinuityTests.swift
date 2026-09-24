import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class SaveUndoContinuityTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "uscis-i9", withExtension: "pdf"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Undo Save \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Original.pdf")
        try FileManager.default.copyItem(at: original, to: url)
        return (url, folder)
    }

    private func open(_ url: URL) async throws -> (AppState, DocumentTab) {
        let suite = "zpdf.undo-save.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let state = AppState(preferences: AppPreferences(defaults: defaults), readingHistory: ReadingHistoryStore(defaults: defaults))
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 where tab.saveChecking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(tab.saveBlock)
        defaults.removePersistentDomain(forName: suite)
        return (state, tab)
    }

    private func name(_ tab: DocumentTab) throws -> PDFAnnotation {
        try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" })
    }

    func testFormAndNoteUndoRedoAcrossSaveAndSaveAs() async throws {
        let (url, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (state, tab) = try await open(url)
        try name(tab).widgetStringValue = "SAVED VALUE"
        let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Survives Save"
        tab.pdfDocument?.page(at: 0)?.addAnnotation(note)
        state.refreshUnsavedChanges(tab)
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        let savedBytes = try Data(contentsOf: url)
        XCTAssertFalse(tab.hasUnsavedChanges)
        state.undoDocumentEdit()
        XCTAssertEqual(try name(tab).widgetStringValue ?? "", "")
        XCTAssertFalse(tab.pdfDocument!.page(at: 0)!.annotations.contains { $0.contents == "Survives Save" })
        XCTAssertTrue(tab.hasUnsavedChanges)
        state.redoDocumentEdit()
        XCTAssertEqual(try name(tab).widgetStringValue, "SAVED VALUE")
        XCTAssertFalse(tab.hasUnsavedChanges)
        state.undoDocumentEdit()
        let target = folder.appendingPathComponent("Undone.pdf")
        let saveAs = await state.saveDocumentAs(tab, to: .init(url: target, overwrite: false)).value
        XCTAssertTrue(saveAs, state.saveError?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: url), savedBytes)
        XCTAssertEqual(tab.url, target)
        XCTAssertFalse(tab.hasUnsavedChanges)
        state.redoDocumentEdit()
        XCTAssertEqual(try name(tab).widgetStringValue, "SAVED VALUE")
        XCTAssertTrue(tab.hasUnsavedChanges)
        let again = await state.saveDocument(tab).value
        XCTAssertTrue(again, state.saveError?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: url), savedBytes)
        let reopened = try XCTUnwrap(PDFDocument(url: target))
        let field = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" })
        XCTAssertEqual(field.widgetStringValue, "SAVED VALUE")
        XCTAssertFalse(field.isReadOnly)
        XCTAssertTrue(reopened.page(at: 0)!.annotations.contains { $0.contents == "Survives Save" })
    }

    func testDeletedPageCanBeRestoredAndSavedAfterNativeReload() async throws {
        let (url, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (state, tab) = try await open(url)
        let initial = tab.pageCount
        try name(tab).widgetStringValue = "RESTORED PAGE"
        state.refreshUnsavedChanges(tab)
        try state.rotatePage(0, in: tab)
        try state.movePage(from: 0, to: 1, in: tab)
        try state.deletePage(1, in: tab)
        let firstSave = await state.saveDocument(tab).value
        XCTAssertTrue(firstSave, state.saveError?.message ?? "")
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, initial - 1)
        state.undoDocumentEdit() // restored page comes from pre-Save input
        XCTAssertEqual(tab.pageCount, initial)
        let restoredSave = await state.saveDocument(tab).value
        XCTAssertTrue(restoredSave, state.saveError?.message ?? "")
        let restored = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(restored.pageCount, initial)
        XCTAssertEqual(restored.page(at: 1)?.rotation, 90)
        XCTAssertEqual(restored.page(at: 1)?.annotations.first { $0.fieldName == "Last Name (Family Name)" }?.widgetStringValue, "RESTORED PAGE")
        state.undoDocumentEdit() // reorder
        state.undoDocumentEdit() // rotation
        XCTAssertEqual(try name(tab).widgetStringValue, "RESTORED PAGE")
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.rotation, 0)
        let finalSave = await state.saveDocument(tab).value
        XCTAssertTrue(finalSave, state.saveError?.message ?? "")
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, initial)
    }
}
