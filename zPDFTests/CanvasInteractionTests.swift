import PDFKit
import SwiftUI
import XCTest
@testable import zPDF

/// Drives the real document window with synthesized mouse and key events
/// (window.sendEvent → hit testing → canvas controllers), so gesture code is
/// exercised the way a user's clicks and drags reach it.
@MainActor
final class CanvasInteractionTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Harness

    private func launch(_ fixture: String) async throws -> (AppState, DocumentTab, URL, URL) {
        let (url, directory) = try TestSupport.fixture(fixture, in: Self.self)
        let state = AppState()
        let host = NSHostingView(rootView: RootView().environment(state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000)) // never over the user's work
        window.orderFrontRegardless()
        window.makeKey()
        self.window = window
        let tab = try await TestSupport.open(url, in: state)
        for _ in 0..<300 where state.pdfViewStore.pdfView?.document !== tab.pdfDocument {
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try XCTUnwrap(state.pdfViewStore.pdfView)
        XCTAssertTrue(view.window === window, "PDF view is hosted in the test window")
        view.layoutDocumentView()
        return (state, tab, url, directory)
    }

    private func pdfView(_ state: AppState) throws -> PDFView { try XCTUnwrap(state.pdfViewStore.pdfView) }

    /// Window coordinates of a point in page space.
    private func windowPoint(_ state: AppState, page index: Int, _ point: CGPoint) throws -> NSPoint {
        let view = try pdfView(state)
        let page = try XCTUnwrap(view.document?.page(at: index))
        view.go(to: page)
        view.layoutDocumentView()
        return view.convert(view.convert(point, from: page), to: nil)
    }

    /// The view that currently owns a gesture (mouse-down target keeps drags/up, like AppKit).
    private var gestureView: NSView?

    private func send(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws {
        let window = try XCTUnwrap(self.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: clicks, pressure: 1))
        // The test app is in the background, so a real window would treat a
        // click as activation only. Deliver to the hit-tested view directly.
        let content = try XCTUnwrap(window.contentView)
        switch type {
        case .leftMouseDown:
            gestureView = content.hitTest(content.convert(point, from: nil))
            window.makeFirstResponder(gestureView)
            gestureView?.mouseDown(with: event)
        case .leftMouseDragged: gestureView?.mouseDragged(with: event)
        case .leftMouseUp: gestureView?.mouseUp(with: event); gestureView = nil
        default: window.sendEvent(event)
        }
    }

    /// The view AppKit will deliver a click at `point` to (debugging aid).
    private func hitView(_ p: NSPoint) -> String {
        guard let content = window?.contentView else { return "no content" }
        let v = content.hitTest(content.convert(p, from: nil))
        return v.map { String(describing: type(of: $0)) } ?? "nil"
    }

    private func click(_ state: AppState, page: Int = 0, _ point: CGPoint, clicks: Int = 1) throws {
        let p = try windowPoint(state, page: page, point)
        let window = try XCTUnwrap(self.window)
        // Views such as NSTextView track a click in their own loop until the
        // mouse-up arrives, so queue it first; deliver it ourselves if unused.
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: clicks, pressure: 0))
        NSApp.postEvent(up, atStart: false)
        try send(.leftMouseDown, at: p, clicks: clicks)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            gestureView?.mouseUp(with: pending)
        }
        gestureView = nil
    }

    private func drag(_ state: AppState, page: Int = 0, from a: CGPoint, to b: CGPoint, steps: Int = 12) throws {
        let start = try windowPoint(state, page: page, a)
        let end = try windowPoint(state, page: page, b)
        try send(.leftMouseDown, at: start)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            try send(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        try send(.leftMouseUp, at: end)
    }

    private func settle(_ tab: DocumentTab, _ ms: Int = 150) async throws {
        try await Task.sleep(for: .milliseconds(ms))
        try await TestSupport.settled(tab)
    }

    private func annotations(_ tab: DocumentTab, page: Int = 0, type: String) -> [PDFAnnotation] {
        tab.pdfDocument?.page(at: page)?.annotations.filter { $0.type == type } ?? []
    }

    // MARK: - Comments

    func testDraggingShapeAndPenToolsCreatesSavedAnnotations() async throws {
        let (state, tab, url, directory) = try await launch("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        state.openTool(.comment)
        state.toggleArmedAnnotationTool(.rectangle)
        try drag(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 170))
        try await settle(tab)
        XCTAssertEqual(annotations(tab, type: "Square").count, 1, "a rectangle drag creates one Square")
        state.toggleArmedAnnotationTool(.drawing)
        try drag(state, from: CGPoint(x: 300, y: 120), to: CGPoint(x: 400, y: 190))
        try await settle(tab)
        XCTAssertEqual(annotations(tab, type: "Ink").count, 1, "a pen drag creates one Ink stroke")
        state.toggleArmedAnnotationTool(.stickyNote)
        try click(state, CGPoint(x: 500, y: 150))
        try await settle(tab)
        XCTAssertGreaterThanOrEqual(annotations(tab, type: "Text").count, 1, "a click with Sticky Note places a note")
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let types = Set(saved.annotations.compactMap(\.type))
        XCTAssertTrue(types.isSuperset(of: ["Square", "Ink", "Text"]), "saved: \(types)")
    }

    // MARK: - Redaction

    func testDragMarksAreaAndApplyRemovesText() async throws {
        let (state, tab, url, directory) = try await launch("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let target = try XCTUnwrap(tab.pdfDocument?.findString("Employment Eligibility Verification", withOptions: []).first)
        let box = target.bounds(for: page).insetBy(dx: -2, dy: -2)
        state.openTool(.redact)
        state.contentEditing.activate(.redact)
        try drag(state, from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.maxX, y: box.maxY), steps: 8)
        try await settle(tab)
        XCTAssertEqual(annotations(tab, type: "Redact").count, 1, "an area drag creates one redaction mark")
        state.contentEditing.applyRedactions()
        try await settle(tab, 400)
        for _ in 0..<200 where annotations(tab, type: "Redact").count > 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await TestSupport.settled(tab)
        XCTAssertFalse(tab.pdfDocument?.page(at: 0)?.string?.contains("Employment Eligibility Verification") ?? true)
        try await TestSupport.save(state, tab)
        XCTAssertFalse(TestSupport.text(url).contains("Employment Eligibility Verification"))
    }

    // MARK: - Edit PDF

    func testClickingTextOpensEditorAndCommitRewritesPage() async throws {
        let (state, tab, url, directory) = try await launch("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let target = try XCTUnwrap(tab.pdfDocument?.findString("Employment Eligibility Verification", withOptions: []).first)
        let box = target.bounds(for: page)
        state.openTool(.editPDF)
        state.contentEditing.activate(.edit)
        // Page content loads asynchronously on first hover/click.
        _ = state.contentEditing.content(for: page)
        for _ in 0..<200 where state.contentEditing.content(for: page) == nil { try await Task.sleep(for: .milliseconds(50)) }
        try click(state, CGPoint(x: box.midX, y: box.midY))
        for _ in 0..<100 where !state.contentEditing.isEditingText { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(state.contentEditing.isEditingText, "clicking text opens the inline editor")
        let editor = try XCTUnwrap(window?.firstResponder as? NSTextView, "the editor takes keyboard focus")
        editor.selectAll(nil)
        editor.insertText("Edited Heading Text", replacementRange: editor.selectedRange())
        state.contentEditing.finishEditing(commit: true)
        for _ in 0..<200 where !(tab.pdfDocument?.page(at: 0)?.string?.contains("Edited Heading Text") ?? false) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await TestSupport.settled(tab)
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("Edited Heading Text") == true)
        try await TestSupport.save(state, tab)
        let saved = TestSupport.text(url)
        XCTAssertTrue(saved.contains("Edited Heading Text"))
        XCTAssertFalse(saved.contains("Employment Eligibility Verification"))
    }

    // MARK: - Forms

    func testPrepareFormDragPlacesFieldAndFillSignClickAddsText() async throws {
        let (state, tab, url, directory) = try await launch("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = annotations(tab, type: "Widget").count
        state.openTool(.prepareForm)
        state.signatureService.arm(.field(.text))
        try drag(state, from: CGPoint(x: 72, y: 500), to: CGPoint(x: 272, y: 522))
        for _ in 0..<200 where annotations(tab, type: "Widget").count == before { try await Task.sleep(for: .milliseconds(50)) }
        try await TestSupport.settled(tab)
        XCTAssertEqual(annotations(tab, type: "Widget").count, before + 1, "a field drag creates one widget")
        state.openTool(.fillAndSign)
        state.signatureService.arm(.check)
        let beforeMarks = tab.pdfDocument?.page(at: 0)?.annotations.count ?? 0
        try click(state, CGPoint(x: 400, y: 600))
        for _ in 0..<200 where (tab.pdfDocument?.page(at: 0)?.annotations.count ?? 0) == beforeMarks {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await TestSupport.settled(tab)
        XCTAssertGreaterThan(tab.pdfDocument?.page(at: 0)?.annotations.count ?? 0, beforeMarks, "a click with Check adds a mark")
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertEqual(saved.annotations.filter { $0.type == "Widget" }.count, before + 1)
    }

    // MARK: - Measure

    func testDistanceToolMeasuresTwoClicks() async throws {
        let (state, tab, _, directory) = try await launch("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        state.openTool(.measureObjects)
        let session = state.features.measure
        session.kind = .distance
        try await Task.sleep(for: .milliseconds(200)) // overlay picks up the tool on the next render
        try click(state, CGPoint(x: 100, y: 100))
        try click(state, CGPoint(x: 172, y: 100))
        try await settle(tab)
        XCTAssertEqual(session.measurements.count, 1, "two clicks make one distance measurement")
    }
}
