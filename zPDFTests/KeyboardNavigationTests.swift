import AppKit
import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class KeyboardNavigationTests: XCTestCase {
    func testReturnCommitsOnlySingleLineWidgetEditor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        let doc = document()
        let page = try XCTUnwrap(doc.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 40, y: 800, width: 180, height: 25), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.isMultiline = false
        page.addAnnotation(widget)
        canvas.document = doc
        canvas.scaleFactor = 1
        canvas.layoutDocumentView()
        let editor = NSTextView(frame: canvas.convert(widget.bounds, from: page).insetBy(dx: 1, dy: 1))
        canvas.addSubview(editor)
        window.makeFirstResponder(editor)
        XCTAssertTrue(canvas.singleLineWidget(for: editor) === widget)
        XCTAssertTrue(canvas.handleReadingKey(code: 36, modifiers: [], responder: editor))
        XCTAssertTrue(window.firstResponder === canvas)
        widget.isMultiline = true
        window.makeFirstResponder(editor)
        XCTAssertNil(canvas.singleLineWidget(for: editor))
        XCTAssertFalse(canvas.handleReadingKey(code: 36, modifiers: [], responder: editor))
        XCTAssertTrue(window.firstResponder === editor)
    }

    private func document() -> PDFDocument {
        let doc = PDFDocument()
        for _ in 0..<4 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 1000), for: .mediaBox)
            doc.insert(page, at: doc.pageCount)
        }
        return doc
    }

    func testDocumentCommandsWrapTabsAndNavigateReadOnlyFiles() {
        let state = AppState()
        let first = DocumentTab(pdfDocument: document())
        let second = DocumentTab(pdfDocument: document())
        first.saveBlock = "XFA_EDIT_BLOCKED"
        state.tabs = [first, second]
        state.selectTab(first)
        state.navigatePage(.last)
        XCTAssertEqual(first.currentPage, 4)
        state.navigatePage(.next)
        XCTAssertEqual(first.currentPage, 4)
        state.navigatePage(.first)
        XCTAssertEqual(first.currentPage, 1)
        state.cycleDocument(backward: true)
        XCTAssertTrue(state.activeTab === second)
        state.cycleDocument(backward: false)
        XCTAssertTrue(state.activeTab === first)
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertFalse(second.hasUnsavedChanges)
    }

    func testCanvasReadingKeysRejectTextAndControlFocusAndModifiers() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        canvas.document = document()
        canvas.displayMode = .singlePageContinuous
        window.contentView = canvas
        XCTAssertTrue(window.makeFirstResponder(canvas))
        defer { window.close() }
        var navigations = 0
        canvas.onNavigatePage = { _ in navigations += 1 }
        func handle(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
            canvas.handleReadingKey(code: code, modifiers: modifiers, responder: window.firstResponder)
        }
        XCTAssertTrue(handle(124))
        XCTAssertTrue(handle(123))
        XCTAssertEqual(navigations, 2)
        XCTAssertFalse(handle(124, .shift))
        XCTAssertFalse(handle(124, .option))
        XCTAssertFalse(canvas.ownsReadingKeys(NSTextView()))
        XCTAssertFalse(canvas.ownsReadingKeys(NSTextField()))
        XCTAssertFalse(canvas.ownsReadingKeys(NSButton()))
        XCTAssertFalse(canvas.ownsReadingKeys(NSPopUpButton()))
        XCTAssertFalse(canvas.ownsReadingKeys(NSView()))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        canvas.addSubview(editor)
        window.makeFirstResponder(editor)
        XCTAssertFalse(handle(124))
        XCTAssertFalse(handle(119))
        XCTAssertEqual(navigations, 2)
    }
}
