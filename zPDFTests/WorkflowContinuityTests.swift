import PDFKit
import XCTest
@testable import zPDF

/// Exercises failure and ownership across real native Save sessions. Every
/// source is a disposable fixture copy, with isolated preferences and recents.
@MainActor
final class WorkflowContinuityTests: XCTestCase {
    @MainActor
    private struct Workspace {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let state: AppState

        init() throws {
            suite = "zpdf.workflow-tests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Workflow ü \(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let preferences = AppPreferences(defaults: defaults)
            preferences.restoreOpenDocuments = false
            state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences,
                             readingHistory: ReadingHistoryStore(defaults: defaults))
        }

        func fixture(_ name: String = "uscis-i9", as copyName: String? = nil) throws -> URL {
            let source = try XCTUnwrap(Bundle(for: WorkflowContinuityTests.self).url(forResource: name, withExtension: "pdf"))
            let target = directory.appendingPathComponent(copyName ?? "\(name).pdf")
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func open(_ url: URL, in state: AppState) async throws -> DocumentTab {
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 {
            if !tab.saveChecking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(tab.saveChecking)
        XCTAssertNil(state.openError)
        XCTAssertNil(state.saveError, state.saveError?.message ?? "")
        XCTAssertTrue(tab.allowsSaveEdits)
        XCTAssertNotNil(tab.editSource)
        return tab
    }

    private func field(_ document: PDFDocument, _ name: String = "Last Name (Family Name)", page: Int = 0) throws -> PDFAnnotation {
        try XCTUnwrap(document.page(at: page)?.annotations.first { $0.fieldName == name })
    }

    private func addNote(_ text: String, to document: PDFDocument, page: Int = 0) throws {
        let note = PDFAnnotation(bounds: CGRect(x: 30, y: 700, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = text
        try XCTUnwrap(document.page(at: page)).addAnnotation(note)
    }

    func testExternalChangeStillBlocksSaveFromHistoricalImmutableRevision() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let state = workspace.state
        let url = try workspace.fixture()
        let originalBytes = try Data(contentsOf: url)
        let tab = try await open(url, in: state)
        try field(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "FIRST SAVED REVISION"
        state.refreshUnsavedChanges(tab)
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        let savedHash = try XCTUnwrap(tab.sourceHash)
        state.undoDocumentEdit()
        let historicalSource = try XCTUnwrap(tab.editSource)
        XCTAssertNotEqual(historicalSource.hash, savedHash)
        XCTAssertEqual(try Data(contentsOf: historicalSource.url), originalBytes)
        let display = try XCTUnwrap(tab.pdfDocument)
        try field(display).widgetStringValue = "KEEP HISTORICAL EDIT"
        try addNote("KEEP HISTORICAL NOTE", to: display)
        state.refreshUnsavedChanges(tab)
        let baseline = tab.saveBaseline
        var external = try Data(contentsOf: url)
        external.append(Data("\n% independent writer changed the disk revision\n".utf8))
        try external.write(to: url)

        let result = await state.saveDocument(tab).value
        XCTAssertFalse(result)
        XCTAssertTrue(state.saveError?.message.contains("SOURCE_CHANGED") == true)
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(tab.sourceHash, savedHash)
        XCTAssertTrue(tab.editSource === historicalSource)
        XCTAssertTrue(tab.saveBaseline === baseline)
        XCTAssertTrue(tab.pdfDocument === display)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertFalse(tab.isSaving)
        XCTAssertEqual(try field(display).widgetStringValue, "KEEP HISTORICAL EDIT")
        XCTAssertEqual(display.page(at: 0)?.annotations.filter { $0.contents == "KEEP HISTORICAL NOTE" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: historicalSource.url), originalBytes)
    }

    func testPublicationFailuresKeepEditsAndCanRetryWithoutDamagingStructures() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let state = workspace.state
        let url = try workspace.fixture("ordinary-edge")
        let sourceBytes = try Data(contentsOf: url)
        let tab = try await open(url, in: state)
        let display = try XCTUnwrap(tab.pdfDocument)
        let pageCount = display.pageCount
        try field(display, "region").widgetStringValue = "NY"
        try field(display, "approval").buttonWidgetState = .onState
        try addNote("RETRY PRESERVES THIS COMMENT", to: display)
        try state.movePage(from: 0, to: 1, in: tab)
        try state.rotatePage(1, in: tab)
        let hash = tab.sourceHash
        let baseline = tab.saveBaseline
        let editSource = tab.editSource
        let file = workspace.directory.appendingPathComponent("occupied.pdf")
        let sentinel = Data("An existing file must remain intact".utf8)
        try sentinel.write(to: file)
        let folder = workspace.directory.appendingPathComponent("directory.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("keep.txt")
        try sentinel.write(to: child)
        for destination in [SaveDestination(url: file, overwrite: false), SaveDestination(url: folder, overwrite: true)] {
            let saved = await state.saveDocumentAs(tab, to: destination).value
            XCTAssertFalse(saved)
            XCTAssertNotNil(state.saveError)
            XCTAssertEqual(tab.url, url)
            XCTAssertEqual(tab.sourceHash, hash)
            XCTAssertTrue(tab.saveBaseline === baseline)
            XCTAssertTrue(tab.editSource === editSource)
            XCTAssertTrue(tab.pdfDocument === display)
            XCTAssertTrue(tab.hasUnsavedChanges)
            XCTAssertFalse(tab.isSaving)
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: file), sentinel)
            XCTAssertEqual(try Data(contentsOf: child), sentinel)
        }
        let target = workspace.directory.appendingPathComponent("successful retry.pdf")
        let saved = await state.saveDocumentAs(tab, to: .init(url: target, overwrite: false)).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertFalse(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
        let output = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(output.pageCount, pageCount)
        XCTAssertEqual(output.page(at: 1)?.rotation, 90)
        XCTAssertEqual(try field(output, "region", page: 1).widgetStringValue, "NY")
        XCTAssertFalse(try field(output, "region", page: 1).isReadOnly)
        XCTAssertEqual(try field(output, "approval", page: 1).buttonWidgetState, .onState)
        XCTAssertEqual(output.page(at: 1)?.annotations.filter { $0.contents == "RETRY PRESERVES THIS COMMENT" }.count, 1)
    }

    func testRepeatedSavesAndHistoricalUndoRemainOwnedByTheirDocument() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let state = workspace.state
        let firstURL = try workspace.fixture(as: "First.pdf")
        let secondURL = try workspace.fixture(as: "Second.pdf")
        let first = try await open(firstURL, in: state)
        let initialValue = try field(XCTUnwrap(first.pdfDocument)).widgetStringValue
        XCTAssertEqual(initialValue ?? "", "", "This fixture starts with an empty last-name field")
        let second = try await open(secondURL, in: state)
        XCTAssertNotEqual(first.editSource?.url, second.editSource?.url)
        try field(XCTUnwrap(first.pdfDocument)).widgetStringValue = "FIRST DOCUMENT"
        try addNote("FIRST COMMENT", to: XCTUnwrap(first.pdfDocument))
        state.refreshUnsavedChanges(first)
        let firstSave = state.saveDocument(first)
        try field(XCTUnwrap(second.pdfDocument)).widgetStringValue = "SECOND DOCUMENT"
        try addNote("SECOND COMMENT", to: XCTUnwrap(second.pdfDocument))
        state.refreshUnsavedChanges(second)
        let secondSave = state.saveDocument(second)
        let firstSaved = await firstSave.value
        let secondSaved = await secondSave.value
        XCTAssertTrue(firstSaved, state.saveError?.message ?? "")
        XCTAssertTrue(secondSaved, state.saveError?.message ?? "")
        XCTAssertTrue(state.activeTab === second)
        let secondBytes = try Data(contentsOf: secondURL)
        let secondHash = second.sourceHash
        state.selectTab(first)
        state.undoDocumentEdit()
        XCTAssertEqual(try field(XCTUnwrap(first.pdfDocument)).widgetStringValue, initialValue)
        XCTAssertFalse(first.pdfDocument!.page(at: 0)!.annotations.contains { $0.contents == "FIRST COMMENT" })
        XCTAssertTrue(first.hasUnsavedChanges)
        XCTAssertFalse(second.hasUnsavedChanges)
        XCTAssertEqual(second.sourceHash, secondHash)
        let restored = await state.saveDocument(first).value
        XCTAssertTrue(restored, state.saveError?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        let restoredField = try field(XCTUnwrap(PDFDocument(url: firstURL)))
        // A blank AcroForm /V may be absent or an empty string after native
        // serialization; neither permits residual text or a missing widget.
        XCTAssertEqual(restoredField.widgetStringValue ?? "", "")
        XCTAssertEqual(restoredField.widgetFieldType, .text)
        XCTAssertFalse(restoredField.isReadOnly)
        state.redoDocumentEdit()
        let redone = await state.saveDocument(first).value
        XCTAssertTrue(redone, state.saveError?.message ?? "")
        let firstOutput = try XCTUnwrap(PDFDocument(url: firstURL))
        XCTAssertEqual(try field(firstOutput).widgetStringValue, "FIRST DOCUMENT")
        XCTAssertEqual(firstOutput.page(at: 0)?.annotations.filter { $0.contents == "FIRST COMMENT" }.count, 1)
        let firstBytes = try Data(contentsOf: firstURL)

        state.selectTab(second)
        try field(XCTUnwrap(second.pdfDocument)).widgetStringValue = "SECOND EDITING SESSION"
        state.refreshUnsavedChanges(second)
        try state.rotatePage(0, in: second)
        let secondAgain = await state.saveDocument(second).value
        XCTAssertTrue(secondAgain, state.saveError?.message ?? "")
        state.undoDocumentEdit()
        XCTAssertEqual(second.pdfDocument?.page(at: 0)?.rotation, 0)
        let secondUndoSaved = await state.saveDocument(second).value
        XCTAssertTrue(secondUndoSaved, state.saveError?.message ?? "")
        let secondOutput = try XCTUnwrap(PDFDocument(url: secondURL))
        XCTAssertEqual(secondOutput.pageCount, 4)
        XCTAssertEqual(secondOutput.page(at: 0)?.rotation, 0)
        XCTAssertEqual(try field(secondOutput).widgetStringValue, "SECOND EDITING SESSION")
        XCTAssertFalse(try field(secondOutput).isReadOnly)
        XCTAssertEqual(secondOutput.page(at: 0)?.annotations.filter { $0.contents == "SECOND COMMENT" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertTrue(state.activeTab === second)
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertFalse(second.hasUnsavedChanges)
    }
}
