import AppKit
import PDFKit

/// Drag a rectangle on a page (File ▸ Print Selected Area…).
@MainActor
final class MarqueeCanvasTool: CanvasTool {
    private weak var appState: AppState?
    private var start: CGPoint?
    private var current: CGPoint?
    private var pageIndex: Int?

    init(appState: AppState) { self.appState = appState }

    var cursor: NSCursor { .crosshair }

    func mouseDown(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        start = point
        current = point
        pageIndex = page.document?.index(for: page)
    }

    func mouseDragged(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        guard page.document?.index(for: page) == pageIndex else { return }
        current = point
    }

    func mouseUp(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        defer { start = nil; current = nil }
        guard let appState, let tab = appState.activeTab, let start, let pageIndex else { return }
        let end = page.document?.index(for: page) == pageIndex ? point : (current ?? point)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(page.bounds(for: .cropBox))
        guard rect.width * view.pixelsPerPoint > 8, rect.height * view.pixelsPerPoint > 8 else { NSSound.beep(); return }
        appState.features.selectingPrintArea = false
        appState.features.printArea = (tab.id, pageIndex, rect)
        appState.features.printTabID = tab.id
    }

    func mouseMoved(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {}

    func keyDown(_ event: NSEvent, in view: CanvasOverlayView) -> Bool {
        guard event.keyCode == 53 else { return false }
        appState?.features.selectingPrintArea = false
        return true
    }

    func draw(in view: CanvasOverlayView, pdfView: PDFView, context: CGContext) {
        guard let start, let current, let pageIndex, let page = pdfView.document?.page(at: pageIndex) else { return }
        let a = view.viewPoint(start, on: page), b = view.viewPoint(current, on: page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
    }
}

extension AppState {
    /// ⌘P: zPDF's print dialog, which prints a prepared copy that includes
    /// all current edits (never the display copy or the file on disk).
    func showPrintDialog() {
        guard let tab = activeTab, !tab.isSaving, !isResolvingClose, commitFieldEditing() else { return }
        guard let document = tab.pdfDocument, !document.isLocked, document.allowsPrinting else {
            saveError = OpenError(fileName: tab.displayName, message: "This PDF's permissions prohibit printing.")
            return
        }
        if document.isEncrypted && tab.editSource == nil {
            // Encrypted documents print through PDFKit with the standard panel.
            do { _ = try printOperation(for: tab).run() }
            catch { saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription) }
            return
        }
        features.printTabID = tab.id
    }

    func beginPrintAreaSelection() {
        guard activeTab != nil else { return }
        features.measure.kind = nil
        armedAnnotationTool = nil
        armedFormFieldTool = nil
        textEditingModeActive = false
        features.selectingPrintArea = true
    }
}
