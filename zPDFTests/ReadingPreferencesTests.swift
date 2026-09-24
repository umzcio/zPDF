import XCTest
import PDFKit
@testable import zPDF

@MainActor
final class ReadingPreferencesTests: XCTestCase {
    private func isolated() -> (String, UserDefaults, AppPreferences, ReadingHistoryStore) {
        let suite = "zpdf.reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (suite, defaults, AppPreferences(defaults: defaults), ReadingHistoryStore(defaults: defaults))
    }

    private func document() -> PDFDocument {
        let document = PDFDocument()
        for _ in 0..<4 { document.insert(PDFPage(), at: document.pageCount) }
        return document
    }

    func testRestoredPositionWinsOverDefaultsAndClampsDeletedPages() {
        let (suite, defaults, preferences, history) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tab = DocumentTab(url: URL(fileURLWithPath: "/tmp/reading-test.pdf"), pdfDocument: document())
        tab.currentPage = 4; tab.zoomFactor = 1.5; tab.viewMode = .facing
        history.remember(tab)
        let reopenedStore = ReadingHistoryStore(defaults: defaults)
        let state = AppState(preferences: preferences, readingHistory: reopenedStore)
        let reopened = DocumentTab(url: tab.url, pdfDocument: document())
        reopened.pdfDocument?.removePage(at: 3)
        state.applyReadingPreferences(to: reopened)
        XCTAssertEqual(reopened.currentPage, 3)
        XCTAssertEqual(reopened.zoomFactor, 1.5)
        XCTAssertEqual(reopened.viewMode, .facing)
        XCTAssertNil(reopened.pendingInitialZoom)
    }

    func testDisabledRememberingUsesDefaultsWithoutOverwritingStoredPosition() {
        let (suite, defaults, preferences, history) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.rememberReadingPosition = false
        preferences.defaultViewMode = .continuous; preferences.defaultZoom = .fitWidth
        let tab = DocumentTab(url: URL(fileURLWithPath: "/tmp/reading-test.pdf"), pdfDocument: document())
        let state = AppState(preferences: preferences, readingHistory: history)
        state.applyReadingPreferences(to: tab)
        state.rememberReadingState(tab)
        XCTAssertEqual(tab.viewMode, .continuous)
        XCTAssertEqual(tab.pendingInitialZoom, .fitWidth)
        XCTAssertNil(history.position(for: tab.url!))
    }

    func testRecentLimitAndClearNeverDeleteSource() throws {
        let (suite, defaults, _, _) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecentFilesStore(defaults: defaults)
        store.maximumCount = 2
        for index in 0..<3 {
            let url = folder.appendingPathComponent("\(index).pdf")
            try Data("source".utf8).write(to: url)
            store.add(url: url)
        }
        XCTAssertEqual(store.files.count, 2)
        store.maximumCount = 1
        XCTAssertEqual(RecentFilesStore(defaults: defaults).files.count, 1)
        store.clear()
        XCTAssertEqual(store.files.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
    }

    func testAnnotationPreferencesOnlyApplyToNewAnnotations() throws {
        let (suite, defaults, preferences, _) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PDFKitAnnotationService()
        service.preferences = preferences
        let tab = DocumentTab(pdfDocument: document())
        preferences.commentAuthor = "Reviewer One"; preferences.noteColor = .purple
        service.addAnnotation(.stickyNote, at: CGPoint(x: 20, y: 20), onPage: 0, in: tab)
        let first = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first)
        preferences.commentAuthor = "Reviewer Two"; preferences.noteColor = .green
        service.addAnnotation(.stickyNote, at: CGPoint(x: 40, y: 40), onPage: 0, in: tab)
        let second = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.last(where: { $0.type == "Text" }))
        XCTAssertEqual(first.userName, "Reviewer One")
        XCTAssertEqual(first.color, AnnotationPreferenceColor.purple.nsColor)
        XCTAssertEqual(second.userName, "Reviewer Two")
        XCTAssertEqual(second.color, AnnotationPreferenceColor.green.nsColor)
    }

    func testFormHighlightOverlayDoesNotMutateWidgetsOrInterceptClicks() throws {
        let pdf = document()
        let page = try XCTUnwrap(pdf.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "unchanged"; field.widgetStringValue = "Value"
        field.color = .black
        page.addAnnotation(field)
        let originalColor = field.color
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        view.document = pdf
        let provider = FormFieldHighlightProvider()
        let overlay = try XCTUnwrap(provider.pdfView(view, overlayViewFor: page))
        XCTAssertNil(overlay.hitTest(CGPoint(x: 20, y: 20)))
        provider.enabled = false
        XCTAssertTrue(overlay.isHidden)
        provider.enabled = true
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(field.widgetStringValue, "Value")
        XCTAssertEqual(field.color, originalColor)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertFalse(field.isReadOnly)
    }

    func testViewNotificationsTargetTheirDocumentAndIgnoreSynchronization() throws {
        let (suite, defaults, preferences, history) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DocumentTab(pdfDocument: document())
        let second = DocumentTab(pdfDocument: document())
        let state = AppState(preferences: preferences, readingHistory: history)
        state.tabs = [first, second]; state.activeTabID = second.id
        first.currentPage = 3; second.currentPage = 4
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        view.document = first.pdfDocument
        let coordinator = PDFViewRepresentable.Coordinator(appState: state, onPageChanged: { _ in
            XCTFail("A captured callback must not route cross-document notifications")
        })
        coordinator.synchronizingView = true
        coordinator.recordViewState(from: view, zoomChanged: false)
        XCTAssertEqual(first.currentPage, 3)
        XCTAssertEqual(second.currentPage, 4)
        coordinator.synchronizingView = false
        view.go(to: try XCTUnwrap(first.pdfDocument?.page(at: 1)))
        coordinator.recordViewState(from: view, zoomChanged: false)
        view.scaleFactor = 1.4
        coordinator.recordViewState(from: view, zoomChanged: true)
        XCTAssertEqual(first.currentPage, 2)
        XCTAssertEqual(first.zoomFactor, 1.4, accuracy: 0.001)
        XCTAssertEqual(second.currentPage, 4)
        XCTAssertEqual(second.zoomFactor, 1)
    }

    func testReadOnlyDocumentsCanReviewCommentsButCannotArmTools() {
        let (suite, defaults, preferences, history) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(preferences: preferences, readingHistory: history)
        let tab = DocumentTab(pdfDocument: document())
        tab.saveBlock = "XFA_EDIT_BLOCKED"
        state.tabs = [tab]; state.activeTabID = tab.id
        state.openTool(.comment)
        XCTAssertEqual(state.activePanel, .comment)
        state.toggleArmedAnnotationTool(.stickyNote)
        XCTAssertNil(state.armedAnnotationTool)
    }

    func testQuitPreservesOptInSessionButExplicitCloseClearsIt() async throws {
        let (suite, defaults, preferences, history) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.restoreOpenDocuments = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).pdf")
        try XCTUnwrap(document().dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState(preferences: preferences, readingHistory: history)
        let tab = DocumentTab(url: url, pdfDocument: PDFDocument(url: url))
        state.tabs = [tab]; state.activeTabID = tab.id
        state.persistOpenSession()
        XCTAssertEqual(history.sessionBookmarks.count, 1)
        let quitAllowed = await withCheckedContinuation { continuation in
            state.requestCloseAll(preserveSession: true) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(quitAllowed)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertEqual(history.sessionBookmarks.count, 1)
        state.tabs = [tab]; state.activeTabID = tab.id
        let closeAllowed = await withCheckedContinuation { continuation in
            state.requestCloseAll { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(closeAllowed)
        XCTAssertTrue(history.sessionBookmarks.isEmpty)
    }
}
