import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import zPDF

@MainActor
final class ReadingNavigationTests: XCTestCase {
    func testFitPageKeepsSinglePageLayoutAcrossNavigationAndViewUpdates() throws {
        let state = AppState()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/uscis-i9.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let tab = DocumentTab(pdfDocument: document)
        tab.viewMode = .continuous
        state.tabs = [tab]
        state.activeTabID = tab.id
        state.sidebarVisible = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DocumentView().environment(state))
        defer { window.close() }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        settle()
        let canvas = try XCTUnwrap(state.pdfViewStore.pdfView as? AnnotationCanvasView)

        for initialMode in [PDFViewMode.continuous, .facing] {
            tab.viewMode = initialMode
            tab.goToPage(1)
            settle()
            ZoomController.fitPage(for: tab, in: canvas)
            settle()
            func assertSinglePage(_ number: Int, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(tab.viewMode, .single, file: file, line: line)
                XCTAssertEqual(canvas.displayMode, .singlePage, file: file, line: line)
                XCTAssertTrue(canvas.currentPage === document.page(at: number - 1), file: file, line: line)
                XCTAssertEqual(canvas.visiblePages.count, 1, file: file, line: line)
            }
            assertSinglePage(1)
            // Toolbar navigation and bare Right Arrow take separate entry paths.
            state.navigatePage(.next)
            settle()
            assertSinglePage(2)
            XCTAssertTrue(canvas.handleReadingKey(code: 124, modifiers: [], responder: canvas))
            settle()
            assertSinglePage(3)
            // PDFKit-originated page changes (including scrolling) must survive
            // notification -> model -> representable synchronization as well.
            canvas.go(to: try XCTUnwrap(document.page(at: 3)))
            settle()
            XCTAssertEqual(tab.currentPage, 4)
            assertSinglePage(4)
            state.navigatePage(.previous)
            settle()
            assertSinglePage(3)
        }
        XCTAssertFalse(tab.hasUnsavedChanges)
        // An explicit layout choice still wins over the earlier Fit Page action.
        tab.viewMode = .continuous
        settle()
        XCTAssertEqual(canvas.displayMode, .singlePageContinuous)
    }

    private func tab() -> DocumentTab {
        let document = PDFDocument()
        for _ in 0..<8 { document.insert(PDFPage(), at: document.pageCount) }
        return DocumentTab(pdfDocument: document)
    }

    func testBackForwardRestoresPageZoomLayoutAndBranchesWithoutEditing() {
        let state = AppState()
        let first = tab(), second = tab()
        state.tabs = [first, second]
        state.activeTabID = first.id
        first.goToPage(3)
        first.setZoom(1.5)
        first.viewMode = .facing
        state.navigateView(backward: true)
        XCTAssertEqual(first.viewMode, .single)
        XCTAssertEqual(first.zoomFactor, 1.5)
        state.navigateView(backward: true)
        XCTAssertEqual(first.zoomFactor, 1)
        XCTAssertEqual(first.currentPage, 3)
        state.navigateView(backward: true)
        XCTAssertEqual(first.currentPage, 1)
        XCTAssertFalse(first.viewHistory.canGoBack)
        state.navigateView(backward: false)
        XCTAssertEqual(first.currentPage, 3)
        first.goToPage(7)
        XCTAssertFalse(first.viewHistory.canGoForward)
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertFalse(second.viewHistory.canGoBack)
        first.pageRevision += 1
        XCTAssertFalse(first.viewHistory.canGoBack)
    }

    func testScrollingCoalescesAndHistoryIsBounded() {
        let history = DocumentViewHistory()
        func location(_ page: Int) -> DocumentViewLocation {
            DocumentViewLocation(page: page, zoom: 1, mode: .continuous, rotation: 0)
        }
        history.coalescesNotifications = true
        history.record(from: location(1), to: location(2), now: 1)
        history.record(from: location(2), to: location(3), now: 1.1)
        history.record(from: location(3), to: location(4), now: 1.2)
        XCTAssertEqual(history.locations.map(\.page), [1, 4])
        history.record(from: location(4), to: location(5), now: 2)
        XCTAssertEqual(history.locations.map(\.page), [1, 4, 5])
        XCTAssertEqual(history.move(backward: true)?.page, 4)
        history.record(from: location(4), to: location(6), now: 2.1)
        XCTAssertEqual(history.locations.map(\.page), [1, 4, 6])
        history.coalescesNotifications = false
        for page in 7..<207 { history.record(from: location(page - 1), to: location(page)) }
        XCTAssertEqual(history.locations.count, 100)
        XCTAssertEqual(history.index, 99)
    }

    func testFullscreenResizeNotificationsDoNotNavigateOrPolluteHistory() throws {
        let state = AppState()
        let document = tab()
        state.tabs = [document]
        state.activeTabID = document.id
        document.goToPage(2)
        document.setZoom(1.5)
        let canvas = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.document = document.pdfDocument
        state.pdfViewStore.pdfView = canvas
        let coordinator = PDFViewRepresentable.Coordinator(appState: state, onPageChanged: { _ in })

        for expectedPage in [2, 5] {
            // The second transition represents leaving fullscreen after the
            // user navigated to another page while reading there.
            document.goToPage(expectedPage)
            let historyCount = document.viewHistory.locations.count
            state.readingPresentation.prepareTransition(state)
            canvas.go(to: try XCTUnwrap(document.pdfDocument?.page(at: 6)))
            canvas.scaleFactor = 0.75
            coordinator.recordViewState(from: canvas, zoomChanged: false)
            coordinator.recordViewState(from: canvas, zoomChanged: true)
            XCTAssertEqual(document.currentPage, expectedPage)
            XCTAssertEqual(document.zoomFactor, 1.5)
            state.readingPresentation.finishTransition(state)
            XCTAssertFalse(state.readingPresentation.isTransitioning)
            XCTAssertEqual(document.currentPage, expectedPage)
            XCTAssertEqual(canvas.scaleFactor, 1.5)
            XCTAssertTrue(canvas.currentPage === document.pdfDocument?.page(at: expectedPage - 1))
            XCTAssertEqual(document.viewHistory.locations.count, historyCount)
        }
    }

    func testFullScreenRestoresPanelsAndArmedToolWithoutChangingPreferences() {
        let suite = "zpdf.reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.rememberSidebar = true
        let state = AppState(preferences: preferences)
        let document = tab()
        state.tabs = [document]
        state.activeTabID = document.id
        state.railSelection = .document
        state.sidebarVisible = true
        state.activePanel = .comment
        state.documentPanel = .comments
        state.armedAnnotationTool = .stickyNote
        state.readingPresentation.capture(state)
        state.readingPresentation.begin(state)
        XCTAssertTrue(state.readingPresentation.isActive)
        XCTAssertFalse(state.sidebarVisible)
        XCTAssertTrue(preferences.sidebarVisible)
        XCTAssertNil(state.activePanel)
        XCTAssertNil(state.documentPanel)
        XCTAssertNil(state.armedAnnotationTool)
        state.readingPresentation.end(state)
        XCTAssertFalse(state.readingPresentation.isActive)
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertEqual(state.activePanel, .comment)
        XCTAssertEqual(state.documentPanel, .comments)
        XCTAssertEqual(state.armedAnnotationTool, .stickyNote)
    }

    func testFullScreenDoesNotArmOldDocumentsToolAfterSwitchingTabs() {
        let suite = "zpdf.reading-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(preferences: AppPreferences(defaults: defaults))
        let first = tab(), second = tab()
        state.tabs = [first, second]
        state.activeTabID = first.id
        state.sidebarVisible = false
        state.activePanel = .comment
        state.armedAnnotationTool = .stickyNote
        state.readingPresentation.begin(state)
        state.selectTab(second)
        state.readingPresentation.end(state)
        XCTAssertFalse(state.sidebarVisible)
        XCTAssertNil(state.activePanel)
        XCTAssertNil(state.armedAnnotationTool)
    }
}
