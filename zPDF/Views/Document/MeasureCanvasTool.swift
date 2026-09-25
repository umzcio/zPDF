import AppKit
import PDFKit

/// Canvas interaction for the Measure tool.
@MainActor
final class MeasureCanvasTool: CanvasTool {
    private weak var appState: AppState?
    private var session: MeasureSession? { appState?.features.measure }

    init(appState: AppState) { self.appState = appState }

    var cursor: NSCursor { .crosshair }

    private func context(for page: PDFPage) -> (AppState, DocumentTab, MeasureSession, Int)? {
        guard let appState, let tab = appState.activeTab, let session, let document = tab.pdfDocument else { return nil }
        return (appState, tab, session, document.index(for: page))
    }

    private func snapped(_ point: CGPoint, page index: Int, tab: DocumentTab, session: MeasureSession, appState: AppState,
                         view: CanvasOverlayView, event: NSEvent) -> CGPoint {
        var target = point
        // Shift constrains to 45° steps from the previous point.
        if event.modifierFlags.contains(.shift), let last = session.points.last, session.activePage == index {
            let dx = point.x - last.x, dy = point.y - last.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            target = CGPoint(x: last.x + cos(angle) * length, y: last.y + sin(angle) * length)
            session.snapped = nil
            return target
        }
        session.loadSnapGeometry(appState: appState, tab: tab, page: index)
        let preferences = appState.preferences
        let tolerance = 8 / max(0.05, view.pixelsPerPoint)
        let grid: CGFloat? = preferences.snapToGrid && preferences.showGrid
            ? CGFloat(preferences.gridSpacing * preferences.pageUnits.points / Double(max(1, preferences.gridSubdivisions))) : nil
        let (result, kind) = session.snap(target, key: session.snapKey(tab: tab, page: index), tolerance: tolerance,
                                          preferences: preferences, gridStep: grid)
        session.snapped = kind
        return result
    }

    func mouseDown(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        guard let (appState, tab, session, index) = context(for: page), let kind = session.kind else { return }
        if session.activePage != nil && session.activePage != index { session.cancelInProgress() }
        let snappedPoint = snapped(point, page: index, tab: tab, session: session, appState: appState, view: view, event: event)
        if event.clickCount >= 2, kind != .distance, session.points.count >= 2 {
            finish(tab: tab, appState: appState)
            return
        }
        if kind == .area, session.points.count >= 3, let first = session.points.first,
           hypot(first.x - snappedPoint.x, first.y - snappedPoint.y) * view.pixelsPerPoint < 8 {
            finish(tab: tab, appState: appState)
            return
        }
        session.activePage = index
        session.points.append(snappedPoint)
        if kind == .distance && session.points.count == 2 { finish(tab: tab, appState: appState) }
    }

    func mouseDragged(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        mouseMoved(at: point, page: page, event: event, in: view)
    }

    func mouseUp(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        // Click-drag-release draws a distance in one gesture.
        guard let (appState, tab, session, index) = context(for: page), session.kind == .distance,
              session.points.count == 1, session.activePage == index, let first = session.points.first else { return }
        let end = snapped(point, page: index, tab: tab, session: session, appState: appState, view: view, event: event)
        if hypot(end.x - first.x, end.y - first.y) * view.pixelsPerPoint > 6 {
            session.points.append(end)
            finish(tab: tab, appState: appState)
        }
    }

    func mouseMoved(at point: CGPoint, page: PDFPage, event: NSEvent, in view: CanvasOverlayView) {
        guard let (appState, tab, session, index) = context(for: page) else { return }
        guard session.activePage == nil || session.activePage == index else { session.hover = nil; return }
        session.hover = snapped(point, page: index, tab: tab, session: session, appState: appState, view: view, event: event)
        hoverPage = index
    }

    private var hoverPage: Int?

    func keyDown(_ event: NSEvent, in view: CanvasOverlayView) -> Bool {
        guard let appState, let session, let tab = appState.activeTab else { return false }
        switch event.keyCode {
        case 36, 76:
            if session.points.count >= 2 { finish(tab: tab, appState: appState) }
            return true
        case 53:
            if session.points.isEmpty { session.kind = nil; session.calibrating = false } else { session.cancelInProgress() }
            return true
        case 51, 117:
            if !session.points.isEmpty { session.points.removeLast() }
            if session.points.isEmpty { session.activePage = nil }
            return true
        default:
            return false
        }
    }

    private func finish(tab: DocumentTab, appState: AppState) {
        guard let session, let kind = session.kind, let page = session.activePage else { return }
        let points = session.points
        session.cancelInProgress()
        guard points.count >= (kind == .area ? 3 : 2) else { return }
        if session.calibrating {
            session.pendingCalibration = (tab.id, points)
            session.calibrating = false
            return
        }
        let scale = session.scale(for: tab, page: page, preferences: appState.preferences)
        let (value, unit, label) = MeasureSession.value(kind: kind, points: points, scale: scale, precision: appState.preferences.measurePrecision)
        let measurement = MeasureSession.Measurement(tabID: tab.id, page: page, kind: kind, points: points, value: value,
                                                     unit: unit, label: label, ratio: scale.ratio, committed: false)
        session.add(measurement)
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(kind.title) \(label)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if appState.preferences.measureAddAnnotations { appState.commitMeasurements([measurement], in: tab) }
    }

    // MARK: - Drawing

    func draw(in view: CanvasOverlayView, pdfView: PDFView, context: CGContext) {
        guard let appState, let session, let tab = appState.activeTab, let document = tab.pdfDocument else { return }
        let color = appState.preferences.measureColor.nsColor
        for item in session.measurements(for: tab.id) where !item.committed {
            guard let page = document.page(at: item.page), pdfView.visiblePages.contains(page) else { continue }
            drawShape(item.points, kind: item.kind, label: item.label, page: page, view: view, context: context, color: color, dashed: true)
        }
        guard let kind = session.kind, let page = (session.activePage ?? hoverPage).flatMap({ document.page(at: $0) }) else { return }
        var points = session.points
        if let hover = session.hover { points.append(hover) }
        if points.count >= 2 {
            let scale = session.scale(for: tab, page: document.index(for: page), preferences: appState.preferences)
            let label = MeasureSession.value(kind: kind == .area && points.count < 3 ? .distance : kind, points: points,
                                             scale: scale, precision: appState.preferences.measurePrecision).2
            drawShape(points, kind: kind, label: session.calibrating ? "Calibrate: \(label)" : label, page: page, view: view,
                      context: context, color: color, dashed: false)
        }
        for point in session.points { drawHandle(view.viewPoint(point, on: page), context: context, color: color) }
        if let hover = session.hover, let snap = session.snapped {
            drawSnap(view.viewPoint(hover, on: page), kind: snap, context: context)
        }
    }

    private func drawShape(_ points: [CGPoint], kind: MeasureSession.Kind, label: String, page: PDFPage, view: CanvasOverlayView,
                           context: CGContext, color: NSColor, dashed: Bool) {
        let mapped = points.map { view.viewPoint($0, on: page) }
        guard let first = mapped.first else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        if dashed { context.setLineDash(phase: 0, lengths: [5, 3]) }
        context.beginPath()
        context.move(to: first)
        for point in mapped.dropFirst() { context.addLine(to: point) }
        if kind == .area && mapped.count > 2 {
            context.closePath()
            context.setFillColor(color.withAlphaComponent(0.12).cgColor)
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
        }
        context.restoreGState()
        let anchor: CGPoint
        if kind == .area {
            anchor = CGPoint(x: mapped.map(\.x).reduce(0, +) / CGFloat(mapped.count), y: mapped.map(\.y).reduce(0, +) / CGFloat(mapped.count))
        } else if let last = mapped.last {
            anchor = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        } else { return }
        drawLabel(label, at: anchor, context: context)
    }

    private func drawLabel(_ text: String, at point: CGPoint, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: NSColor.black]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let box = CGRect(x: point.x - size.width / 2 - 5, y: point.y + 6, width: size.width + 10, height: size.height + 4)
        context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        context.addPath(path)
        context.strokePath()
        string.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attributes)
    }

    private func drawHandle(_ point: CGPoint, context: CGContext, color: NSColor) {
        let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.setStrokeColor(color.cgColor)
        context.stroke(rect)
    }

    private func drawSnap(_ point: CGPoint, kind: MeasureSession.SnapKind, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.systemGreen.cgColor)
        context.setLineWidth(1.5)
        let r: CGFloat = 6
        switch kind {
        case .endpoint:
            context.stroke(CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
        case .midpoint:
            context.beginPath()
            context.move(to: CGPoint(x: point.x, y: point.y + r))
            context.addLine(to: CGPoint(x: point.x - r, y: point.y - r))
            context.addLine(to: CGPoint(x: point.x + r, y: point.y - r))
            context.closePath()
            context.strokePath()
        case .intersection:
            context.strokeLineSegments(between: [CGPoint(x: point.x - r, y: point.y - r), CGPoint(x: point.x + r, y: point.y + r),
                                                 CGPoint(x: point.x - r, y: point.y + r), CGPoint(x: point.x + r, y: point.y - r)])
        case .path:
            context.strokeEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
        case .grid:
            context.strokeLineSegments(between: [CGPoint(x: point.x - r, y: point.y), CGPoint(x: point.x + r, y: point.y),
                                                 CGPoint(x: point.x, y: point.y - r), CGPoint(x: point.x, y: point.y + r)])
        }
        context.restoreGState()
    }
}

extension AppState {
    /// Saves measurements as Line/PolyLine/Polygon annotations with /Measure.
    func commitMeasurements(_ list: [MeasureSession.Measurement], in tab: DocumentTab) {
        let pending = list.filter { !$0.committed }
        guard !pending.isEmpty, tab.allowsSaveEdits else { return }
        let session = features.measure
        let items = MeasureSession.engineItems(pending, color: preferences.measureColor, author: preferences.commentAuthor) {
            session.scale(for: tab, page: $0.page, preferences: preferences)
        }
        Task {
            let ok = await performDocumentEdit([["op": "add_measurements", "items": items]],
                                               actionName: pending.count > 1 ? "Add Measurements" : "Add Measurement", in: tab)
            if ok { session.markCommitted(Set(pending.map(\.id))) }
        }
    }
}
