import AppKit
import PDFKit
import SwiftUI

/// A tool that takes over canvas mouse input (Measure, guide dragging...).
@MainActor
protocol CanvasTool: AnyObject {
    var cursor: NSCursor { get }
    func mouseDown(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView)
    func mouseDragged(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView)
    func mouseUp(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView)
    func mouseMoved(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView)
    func keyDown(_ event: NSEvent, in view: CanvasOverlayView) -> Bool
    func draw(in view: CanvasOverlayView, pdfView: PDFView, context: CGContext)
}

/// Everything the overlay draws for one frame.
@MainActor
struct CanvasOverlayContent {
    var showRulers = false
    var showGrid = false
    var showGuides = true
    var unit: PageUnit = .inches
    var gridSpacing: Double = 1
    var gridSubdivisions = 4
    var gridColor: NSColor = .systemTeal
    var guideColor: NSColor = .systemPink
    var readingOrder: (page: Int, items: [ReadingOrderItem])?
    weak var viewing: DocumentViewingState?
    weak var tool: CanvasTool?
}

struct CanvasOverlayRepresentable: NSViewRepresentable {
    let viewStore: PDFViewStore
    let document: PDFDocument?
    let content: CanvasOverlayContent

    func makeNSView(context: Context) -> CanvasOverlayView {
        let view = CanvasOverlayView()
        view.viewStore = viewStore
        return view
    }

    func updateNSView(_ view: CanvasOverlayView, context: Context) {
        view.content = content
        view.attach(to: viewStore.pdfView)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

/// Transparent drawing surface above the PDFView. It only intercepts mouse
/// events over the rulers or while a CanvasTool is active; otherwise every
/// event reaches PDFKit unchanged.
@MainActor
final class CanvasOverlayView: NSView {
    static let rulerThickness: CGFloat = 18
    weak var viewStore: PDFViewStore?
    var content = CanvasOverlayContent()
    private weak var observedView: PDFView?
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    /// Guide being dragged out of a ruler or moved: (horizontal?, page, value).
    private var draggingGuide: (horizontal: Bool, page: Int, original: CGFloat?)?
    private var dragPoint: CGPoint?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { content.tool != nil }

    func attach(to pdfView: PDFView?) {
        guard observedView !== pdfView else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        observedView = pdfView
        guard let pdfView else { return }
        let center = NotificationCenter.default
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main, using: redraw))
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main, using: redraw))
        observers.append(center.addObserver(forName: .PDFViewDisplayModeChanged, object: pdfView, queue: .main, using: redraw))
        observers.append(center.addObserver(forName: .PDFViewDocumentChanged, object: pdfView, queue: .main, using: redraw))
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: redraw))
        }
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: - Hit testing

    private func inRuler(_ point: CGPoint) -> Bool {
        guard content.showRulers else { return false }
        return point.y > bounds.height - Self.rulerThickness || point.x < Self.rulerThickness
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if content.tool != nil || inRuler(local) || guideHit(at: local) != nil { return self }
        return nil
    }

    override func resetCursorRects() {
        if let tool = content.tool {
            addCursorRect(bounds, cursor: tool.cursor)
        }
        if content.showRulers {
            addCursorRect(NSRect(x: 0, y: bounds.height - Self.rulerThickness, width: bounds.width, height: Self.rulerThickness), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: 0, y: 0, width: Self.rulerThickness, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        observedView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        observedView?.magnify(with: event)
    }

    // MARK: - Coordinates

    func pagePoint(for event: NSEvent) -> (PDFPage, CGPoint)? {
        guard let pdfView = observedView else { return nil }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: true) else { return nil }
        return (page, pdfView.convert(inView, to: page))
    }

    func viewPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView = observedView else { return point }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let pdfView = observedView else { return rect }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    /// Screen distance of one page point (for snapping tolerances).
    var pixelsPerPoint: CGFloat { observedView?.scaleFactor ?? 1 }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if content.showGuides || content.showRulers, let hit = guideHit(at: local) {
            draggingGuide = (hit.horizontal, hit.page, hit.value)
            removeGuide(hit)
            dragPoint = local
            needsDisplay = true
            return
        }
        if inRuler(local), let (page, _) = pagePoint(for: event), let document = observedView?.document {
            let horizontal = local.y > bounds.height - Self.rulerThickness
            draggingGuide = (horizontal, document.index(for: page), nil)
            dragPoint = local
            return
        }
        guard let tool = content.tool, let (page, point) = pagePoint(for: event) else { return }
        window?.makeFirstResponder(self)
        tool.mouseDown(at: point, page: page, event: event, in: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if draggingGuide != nil {
            dragPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        guard let tool = content.tool, let (page, point) = pagePoint(for: event) else { return }
        tool.mouseDragged(at: point, page: page, event: event, in: self)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let guide = draggingGuide {
            draggingGuide = nil
            dragPoint = nil
            let local = convert(event.locationInWindow, from: nil)
            // Dropping a guide back on a ruler removes it.
            if !inRuler(local), let (page, point) = pagePoint(for: event), let document = observedView?.document {
                addGuide(horizontal: guide.horizontal, page: document.index(for: page),
                         value: guide.horizontal ? point.y : point.x)
            }
            needsDisplay = true
            return
        }
        guard let tool = content.tool, let (page, point) = pagePoint(for: event) else { return }
        tool.mouseUp(at: point, page: page, event: event, in: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard let tool = content.tool, let (page, point) = pagePoint(for: event) else { return }
        tool.mouseMoved(at: point, page: page, event: event, in: self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if let tool = content.tool, tool.keyDown(event, in: self) { needsDisplay = true; return }
        observedView?.keyDown(with: event)
    }

    // MARK: - Guides

    private struct GuideHit { let horizontal: Bool; let page: Int; let value: CGFloat }

    private func guideHit(at local: CGPoint) -> GuideHit? {
        guard content.showGuides, let viewing = content.viewing, let pdfView = observedView,
              let document = pdfView.document else { return nil }
        for page in pdfView.visiblePages {
            let index = document.index(for: page)
            for y in viewing.horizontalGuides[index] ?? [] {
                if abs(viewPoint(CGPoint(x: 0, y: y), on: page).y - local.y) < 4 { return GuideHit(horizontal: true, page: index, value: y) }
            }
            for x in viewing.verticalGuides[index] ?? [] {
                if abs(viewPoint(CGPoint(x: x, y: 0), on: page).x - local.x) < 4 { return GuideHit(horizontal: false, page: index, value: x) }
            }
        }
        return nil
    }

    private func removeGuide(_ hit: GuideHit) {
        guard let viewing = content.viewing else { return }
        if hit.horizontal { viewing.horizontalGuides[hit.page]?.removeAll { $0 == hit.value } }
        else { viewing.verticalGuides[hit.page]?.removeAll { $0 == hit.value } }
    }

    private func addGuide(horizontal: Bool, page: Int, value: CGFloat) {
        guard let viewing = content.viewing else { return }
        if horizontal { viewing.horizontalGuides[page, default: []].append(value) }
        else { viewing.verticalGuides[page, default: []].append(value) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView = observedView, let document = pdfView.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let pages = pdfView.visiblePages
        if content.showGrid { for page in pages { drawGrid(page, context: context) } }
        if content.showGuides, let viewing = content.viewing {
            for page in pages { drawGuides(page, index: document.index(for: page), viewing: viewing, context: context) }
        }
        if let order = content.readingOrder, let page = document.page(at: order.page), pages.contains(page) {
            drawReadingOrder(order.items, page: page, context: context)
        }
        content.tool?.draw(in: self, pdfView: pdfView, context: context)
        if let guide = draggingGuide, let point = dragPoint {
            context.setStrokeColor(content.guideColor.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            if guide.horizontal {
                context.strokeLineSegments(between: [CGPoint(x: 0, y: point.y), CGPoint(x: bounds.width, y: point.y)])
            } else {
                context.strokeLineSegments(between: [CGPoint(x: point.x, y: 0), CGPoint(x: point.x, y: bounds.height)])
            }
            context.setLineDash(phase: 0, lengths: [])
        }
        if content.showRulers, let page = pdfView.currentPage { drawRulers(page, context: context) }
    }

    private func drawGrid(_ page: PDFPage, context: CGContext) {
        let box = page.bounds(for: .cropBox)
        let major = max(1, content.gridSpacing * content.unit.points)
        let minor = major / Double(max(1, content.gridSubdivisions))
        let frame = viewRect(box, on: page)
        guard frame.intersects(bounds) else { return }
        context.saveGState()
        context.clip(to: frame)
        func lines(step: Double, alpha: CGFloat, width: CGFloat) {
            guard step * Double(pixelsPerPoint) >= 4 else { return }
            context.setStrokeColor(content.gridColor.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(width)
            var x = box.minX
            while x <= box.maxX {
                let a = viewPoint(CGPoint(x: x, y: box.minY), on: page), b = viewPoint(CGPoint(x: x, y: box.maxY), on: page)
                context.strokeLineSegments(between: [a, b])
                x += step
            }
            var y = box.minY
            while y <= box.maxY {
                let a = viewPoint(CGPoint(x: box.minX, y: y), on: page), b = viewPoint(CGPoint(x: box.maxX, y: y), on: page)
                context.strokeLineSegments(between: [a, b])
                y += step
            }
        }
        if content.gridSubdivisions > 1 { lines(step: minor, alpha: 0.18, width: 0.5) }
        lines(step: major, alpha: 0.45, width: 0.75)
        context.restoreGState()
    }

    private func drawGuides(_ page: PDFPage, index: Int, viewing: DocumentViewingState, context: CGContext) {
        let box = page.bounds(for: .cropBox)
        context.setStrokeColor(content.guideColor.cgColor)
        context.setLineWidth(1)
        for y in viewing.horizontalGuides[index] ?? [] {
            context.strokeLineSegments(between: [viewPoint(CGPoint(x: box.minX, y: y), on: page), viewPoint(CGPoint(x: box.maxX, y: y), on: page)])
        }
        for x in viewing.verticalGuides[index] ?? [] {
            context.strokeLineSegments(between: [viewPoint(CGPoint(x: x, y: box.minY), on: page), viewPoint(CGPoint(x: x, y: box.maxY), on: page)])
        }
    }

    private func drawReadingOrder(_ items: [ReadingOrderItem], page: PDFPage, context: CGContext) {
        let accent = NSColor.controlAccentColor
        for item in items {
            let rect = viewRect(item.cgRect, on: page)
            context.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            context.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            context.setLineWidth(1)
            context.fill(rect)
            context.stroke(rect)
            let label = "\(item.order)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let badge = CGRect(x: rect.minX, y: rect.maxY - size.height - 2, width: size.width + 8, height: size.height + 2)
            context.setFillColor(accent.cgColor)
            context.fill(badge)
            label.draw(at: CGPoint(x: badge.minX + 4, y: badge.minY + 1), withAttributes: attributes)
        }
    }

    private func drawRulers(_ page: PDFPage, context: CGContext) {
        let thickness = Self.rulerThickness
        let top = CGRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness)
        let left = CGRect(x: 0, y: 0, width: thickness, height: bounds.height - thickness)
        let background = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        context.setFillColor(background.cgColor)
        context.fill(top)
        context.fill(left)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokeLineSegments(between: [CGPoint(x: 0, y: top.minY), CGPoint(x: bounds.width, y: top.minY),
                                             CGPoint(x: left.maxX, y: 0), CGPoint(x: left.maxX, y: top.minY)])
        let box = page.bounds(for: .cropBox)
        let origin = viewPoint(CGPoint(x: box.minX, y: box.maxY), on: page)
        let pointsPerPixel = 1 / Double(max(0.01, pixelsPerPoint))
        let (majorUnits, minorCount) = content.unit.rulerStep(pointsPerPixel: pointsPerPixel)
        let major = majorUnits * content.unit.points * Double(pixelsPerPoint)
        let minor = major / Double(minorCount)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        // Horizontal ruler: 0 at the page's left edge.
        var index = Int(floor((thickness - origin.x) / minor))
        while true {
            let x = origin.x + CGFloat(index) * minor
            if x > bounds.width { break }
            if x >= thickness {
                let isMajor = index % minorCount == 0
                context.strokeLineSegments(between: [CGPoint(x: x, y: top.minY), CGPoint(x: x, y: top.minY + (isMajor ? 10 : 4))])
                if isMajor {
                    let value = Double(index / minorCount) * majorUnits
                    ("\(Self.label(value))" as NSString).draw(at: CGPoint(x: x + 2, y: top.minY + 6), withAttributes: attributes)
                }
            }
            index += 1
        }
        // Vertical ruler: 0 at the page's top edge, increasing downward.
        index = Int(floor((origin.y - (bounds.height - thickness)) / minor))
        while true {
            let y = origin.y - CGFloat(index) * minor
            if y < 0 { break }
            if y <= bounds.height - thickness {
                let isMajor = index % minorCount == 0
                context.strokeLineSegments(between: [CGPoint(x: left.maxX, y: y), CGPoint(x: left.maxX - (isMajor ? 10 : 4), y: y)])
                if isMajor {
                    let value = Double(index / minorCount) * majorUnits
                    ("\(Self.label(value))" as NSString).draw(at: CGPoint(x: 2, y: y - 11), withAttributes: attributes)
                }
            }
            index += 1
        }
        (content.unit.symbol as NSString).draw(at: CGPoint(x: 2, y: top.minY + 4), withAttributes: attributes)
    }

    private static func label(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }
}
