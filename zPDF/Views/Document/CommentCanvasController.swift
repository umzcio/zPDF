//
//  CommentCanvasController.swift
//  zPDF
//
//  Purpose: Comment interaction on the page canvas, separate from the
//  PDFView wrapper (which forwards mouse events through small hooks):
//  placing notes/carets/stamps/media, dragging out shapes, text boxes and
//  callouts, multi-click polygons, smoothed freehand pen and the eraser,
//  and selecting existing comments to move, resize, edit or delete. A
//  non-interactive overlay draws live previews and selection handles in
//  view space; an inline editor types text boxes, callouts and notes
//  directly on the page.
//

import AppKit
import PDFKit

@MainActor
final class CommentCanvasController: NSObject {
    private weak var appState: AppState?
    private(set) weak var pdfView: PDFView?
    let overlay = CommentOverlayView()
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var editor: CommentInlineEditor?

    private enum Gesture {
        case creating(tool: AnnotationTool, page: PDFPage, start: CGPoint, current: CGPoint)
        case drawing(page: PDFPage, points: [CGPoint])
        case erasing(page: PDFPage, changed: Bool)
        case pressing(selection: CommentSelection, start: CGPoint)
        case moving(selection: CommentSelection, start: CGPoint, original: CGRect)
        case resizing(selection: CommentSelection, handle: Handle, original: CGRect, originalDesign: CommentDesign?, originalPaths: [NSBezierPath])
        case movingEndpoint(selection: CommentSelection, index: Int)
    }
    private var gesture: Gesture?
    /// In-progress polygon/polyline points (page space).
    private var polygon: (tool: AnnotationTool, page: PDFPage, points: [CGPoint])?
    private var hoverPoint: (page: PDFPage, point: CGPoint)?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        overlay.controller = self
    }

    // MARK: Attachment

    func attach(to pdfView: PDFView) {
        guard self.pdfView !== pdfView else { ensureOverlayOnTop(); return }
        detach()
        self.pdfView = pdfView
        overlay.frame = pdfView.bounds
        overlay.autoresizingMask = [.width, .height]
        pdfView.addSubview(overlay, positioned: .above, relativeTo: nil)
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] notification in
                let isDocumentChange = notification.name == .PDFViewDocumentChanged
                MainActor.assumeIsolated {
                    if isDocumentChange { self?.cancelAll() }
                    self?.viewGeometryChanged()
                }
            })
        }
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewGeometryChanged() }
            })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let local = event
            let handled = MainActor.assumeIsolated { self?.handleKey(local) == true }
            return handled ? nil : event
        }
        observeTool()
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        commitEditor()
        overlay.removeFromSuperview()
        pdfView = nil
    }

    private func ensureOverlayOnTop() {
        guard let pdfView else { return }
        if overlay.superview !== pdfView || pdfView.subviews.last !== overlay && pdfView.subviews.last !== editor {
            overlay.removeFromSuperview()
            overlay.frame = pdfView.bounds
            pdfView.addSubview(overlay, positioned: .above, relativeTo: nil)
            if let editor { pdfView.addSubview(editor, positioned: .above, relativeTo: overlay) }
        }
    }

    private func observeTool() {
        withObservationTracking { [weak self] in
            _ = self?.appState?.armedAnnotationTool
            _ = self?.appState?.comments.selectionRevision
            _ = self?.appState?.activeTabID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.appState?.armedAnnotationTool != self.polygon?.tool { self.polygon = nil }
                self.overlay.window?.invalidateCursorRects(for: self.overlay)
                self.overlay.needsDisplay = true
                self.observeTool()
            }
        }
    }

    private func viewGeometryChanged() {
        overlay.needsDisplay = true
        positionEditor()
    }

    private func cancelAll() {
        gesture = nil
        polygon = nil
        commitEditor()
        overlay.needsDisplay = true
    }

    // MARK: State helpers

    private var session: CommentSession? { appState?.comments }
    private var service: (any AnnotationService)? { appState?.annotationService }
    private var tab: DocumentTab? { appState?.activeTab }

    private var canInteract: Bool {
        guard let appState, let tab = appState.activeTab, tab.allowsSaveEdits, let pdfView,
              pdfView.document === tab.pdfDocument else { return false }
        return !appState.textEditingModeActive && appState.armedFormFieldTool == nil && appState.signatureService.armedSignature == nil
    }

    private func location(_ event: NSEvent, in pdfView: PDFView) -> (page: PDFPage, point: CGPoint, view: CGPoint)? {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        return (page, pdfView.convert(viewPoint, to: page), viewPoint)
    }

    private var scale: CGFloat { max(0.1, pdfView?.scaleFactor ?? 1) }

    private func pageIndex(_ page: PDFPage) -> Int? {
        guard let index = page.document?.index(for: page), index != NSNotFound else { return nil }
        return index
    }

    // MARK: Mouse

    /// Returns true when the comment tools consumed the event.
    func mouseDown(_ event: NSEvent, in pdfView: PDFView) -> Bool {
        attach(to: pdfView)
        guard canInteract, let appState, let tab, let hit = location(event, in: pdfView) else { return false }
        if let editor, editor.frame.contains(overlay.convert(event.locationInWindow, from: nil)) { return false }
        commitEditor()
        let shift = event.modifierFlags.contains(.shift)
        if let tool = appState.armedAnnotationTool {
            switch tool {
            case .highlight, .underline, .strikethrough, .replaceText:
                return false // PDFKit selects text; AppState applies the markup on mouse-up.
            case .stickyNote, .insertText, .stamp:
                guard let index = pageIndex(hit.page),
                      let annotation = service?.addAnnotation(tool, at: hit.point, onPage: index, in: tab) else { return true }
                appState.finishPlacement(annotation, in: tab, name: "Add \(tool.name)")
                if tool != .stamp { beginEditing(annotation, isNew: true) }
                return true
            case .attachFile:
                guard let index = pageIndex(hit.page) else { return true }
                Task { await appState.attachFileComment(at: hit.point, onPage: index) }
                return true
            case .sound:
                guard let index = pageIndex(hit.page) else { return true }
                Task { await CommentSoundPrompt.run(appState: appState, point: hit.point, pageIndex: index) }
                return true
            case .drawing:
                gesture = .drawing(page: hit.page, points: [hit.point])
                overlay.needsDisplay = true
                return true
            case .eraser:
                gesture = .erasing(page: hit.page, changed: erase(at: hit.point, on: hit.page))
                return true
            case .polygon, .polyline:
                addPolygonPoint(hit.point, on: hit.page, tool: tool, finishing: event.clickCount >= 2)
                return true
            case .textBox, .callout, .rectangle, .oval, .line, .arrow, .cloud:
                _ = shift
                gesture = .creating(tool: tool, page: hit.page, start: hit.point, current: hit.point)
                overlay.needsDisplay = true
                return true
            }
        }
        // No tool: select, move and resize existing comments.
        if let selection = session?.validSelection(in: tab), selection.page === hit.page {
            if let endpoint = endpointHandle(at: hit.point, for: selection) {
                gesture = .movingEndpoint(selection: selection, index: endpoint)
                return true
            }
            if let handle = handle(at: hit.point, for: selection) {
                let drawn = selection.annotation as? CommentAnnotation
                gesture = .resizing(selection: selection, handle: handle, original: selection.annotation.bounds,
                                    originalDesign: drawn?.design, originalPaths: (selection.annotation.paths ?? []).map { $0.copy() as! NSBezierPath })
                return true
            }
        }
        guard let annotation = hitComment(at: hit.point, on: hit.page) else {
            if session?.selection != nil { session?.selection = nil }
            return false
        }
        let selection = CommentSelection(annotation: annotation, page: hit.page)
        session?.selection = selection
        if let id = service?.comment(for: annotation, in: tab)?.id { session?.focusedCommentID = id }
        if event.clickCount >= 2 {
            activate(selection)
            return true
        }
        gesture = .pressing(selection: selection, start: hit.point)
        return true
    }

    func mouseDragged(_ event: NSEvent, in pdfView: PDFView) -> Bool {
        guard let gesture, let hit = location(event, in: pdfView) else { return false }
        switch gesture {
        case .creating(let tool, let page, let start, _):
            var current = pdfView.convert(hit.view, to: page)
            if event.modifierFlags.contains(.shift) { current = constrain(tool, start: start, to: current) }
            self.gesture = .creating(tool: tool, page: page, start: start, current: current)
        case .drawing(let page, var points):
            points.append(pdfView.convert(hit.view, to: page))
            self.gesture = .drawing(page: page, points: points)
        case .erasing(let page, let changed):
            let point = pdfView.convert(hit.view, to: page)
            hoverPoint = (page, point)
            self.gesture = .erasing(page: page, changed: erase(at: point, on: page) || changed)
        case .pressing(let selection, let start):
            let point = pdfView.convert(hit.view, to: selection.page)
            guard hypot(point.x - start.x, point.y - start.y) * scale > 3, canMove(selection.annotation) else { return true }
            let prepared = appState?.prepareForEditing(selection) ?? selection
            session?.selection = prepared
            self.gesture = .moving(selection: prepared, start: start, original: prepared.annotation.bounds)
            return mouseDragged(event, in: pdfView)
        case .moving(let selection, let start, let original):
            let point = pdfView.convert(hit.view, to: selection.page)
            var dx = point.x - start.x, dy = point.y - start.y
            if event.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            selection.annotation.bounds = original.offsetBy(dx: dx, dy: dy)
            appState?.redraw(selection.page)
        case .resizing(let selection, let handle, let original, let design, let paths):
            let point = pdfView.convert(hit.view, to: selection.page)
            resize(selection, handle: handle, original: original, design: design, paths: paths, to: point,
                   keepAspect: event.modifierFlags.contains(.shift))
        case .movingEndpoint(let selection, let index):
            moveEndpoint(selection, index: index, to: pdfView.convert(hit.view, to: selection.page))
        }
        overlay.needsDisplay = true
        return true
    }

    func mouseUp(_ event: NSEvent, in pdfView: PDFView) -> Bool {
        guard let gesture else { return false }
        self.gesture = nil
        hoverPoint = nil
        defer { overlay.needsDisplay = true }
        guard let appState, let tab else { return true }
        switch gesture {
        case .creating(let tool, let page, let start, let current):
            guard let index = pageIndex(page) else { return true }
            let dragged = hypot(current.x - start.x, current.y - start.y) * scale > 4
            let created: PDFAnnotation?
            if !dragged && (tool == .textBox || tool == .callout) {
                created = service?.addAnnotation(tool, at: start, onPage: index, in: tab)
            } else if dragged {
                created = service?.addShape(tool, points: [start, current], onPage: index, in: tab)
            } else { created = nil }
            guard let created else { return true }
            appState.finishPlacement(created, in: tab, name: "Add \(tool.name)")
            if tool == .textBox || tool == .callout { beginEditing(created, isNew: true) }
        case .drawing(let page, let points):
            guard let index = pageIndex(page), points.count > 1,
                  let created = service?.addInkAnnotation(points: points, onPage: index, in: tab) else { return true }
            if !appState.preferences.keepAnnotationToolSelected && appState.armedAnnotationTool == .drawing {
                // Pen stays armed for multi-stroke drawing, like Acrobat's pencil.
            }
            session?.focusedCommentID = service?.commentID(for: created)
            appState.commitCommentEdit("Draw", in: tab)
        case .erasing(_, let changed):
            if changed { appState.commitCommentEdit("Erase", in: tab) }
        case .pressing:
            break
        case .moving(let selection, _, let original):
            if selection.annotation.bounds != original {
                (selection.annotation as? CommentAnnotation)?.syncStandardKeys()
                selection.annotation.modificationDate = Date()
                appState.commitCommentEdit("Move Comment", in: tab)
            }
        case .resizing(let selection, _, let original, _, _):
            if selection.annotation.bounds != original {
                (selection.annotation as? CommentAnnotation)?.syncStandardKeys()
                selection.annotation.modificationDate = Date()
                appState.commitCommentEdit("Resize Comment", in: tab)
            }
        case .movingEndpoint(let selection, _):
            (selection.annotation as? CommentAnnotation)?.syncStandardKeys()
            selection.annotation.modificationDate = Date()
            appState.commitCommentEdit("Reshape Comment", in: tab)
        }
        return true
    }

    func mouseMoved(at windowPoint: CGPoint) {
        guard let pdfView, polygon != nil || appState?.armedAnnotationTool == .eraser else {
            if hoverPoint != nil { hoverPoint = nil; overlay.needsDisplay = true }
            return
        }
        let viewPoint = pdfView.convert(windowPoint, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
        hoverPoint = (page, pdfView.convert(viewPoint, to: page))
        overlay.needsDisplay = true
    }

    // MARK: Polygon

    private func addPolygonPoint(_ point: CGPoint, on page: PDFPage, tool: AnnotationTool, finishing: Bool) {
        if var current = polygon, current.page === page, current.tool == tool {
            let first = current.points[0]
            let closes = tool == .polygon && current.points.count >= 3 && hypot(point.x - first.x, point.y - first.y) * scale < 8
            if !finishing && !closes {
                if let last = current.points.last, hypot(point.x - last.x, point.y - last.y) * scale < 2 { return }
                current.points.append(point)
                polygon = current
            } else {
                polygon = current
                finishPolygon()
            }
        } else {
            polygon = (tool, page, [point])
        }
        overlay.needsDisplay = true
    }

    func finishPolygon() {
        guard let current = polygon, let appState, let tab, let index = pageIndex(current.page) else { polygon = nil; return }
        polygon = nil
        var points = current.points
        while points.count > 1, let last = points.last, hypot(last.x - points[points.count - 2].x, last.y - points[points.count - 2].y) < 1 {
            points.removeLast()
        }
        guard let created = service?.addShape(current.tool, points: points, onPage: index, in: tab) else {
            overlay.needsDisplay = true
            return
        }
        appState.finishPlacement(created, in: tab, name: "Add \(current.tool.name)")
        overlay.needsDisplay = true
    }

    // MARK: Hit testing

    static func movable(_ annotation: PDFAnnotation) -> Bool {
        !["Highlight", "Underline", "StrikeOut", "Squiggly", "Widget", "Link", "Popup"].contains(annotation.type ?? "")
    }

    private func canMove(_ annotation: PDFAnnotation) -> Bool { Self.movable(annotation) }

    static func resizable(_ annotation: PDFAnnotation) -> Bool {
        ["Square", "Circle", "FreeText", "Stamp", "Polygon", "PolyLine", "Ink"].contains(annotation.type ?? "")
    }

    private func hitComment(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        let tolerance = max(3, 5 / scale)
        for annotation in page.annotations.reversed() where PDFKitAnnotationService.isListed(annotation) && annotation.shouldDisplay {
            if Self.hit(annotation, point: point, tolerance: tolerance) { return annotation }
        }
        return nil
    }

    static func hit(_ annotation: PDFAnnotation, point: CGPoint, tolerance: CGFloat) -> Bool {
        let bounds = annotation.bounds
        guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { distance(point, a, b) <= tolerance }
        let origin = bounds.origin
        switch annotation.type {
        case "Line":
            if let drawn = annotation as? CommentAnnotation, drawn.design.points.count == 2 {
                let p = drawn.design.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                return near(p[0], p[1])
            }
            return near(CGPoint(x: annotation.startPoint.x + origin.x, y: annotation.startPoint.y + origin.y),
                        CGPoint(x: annotation.endPoint.x + origin.x, y: annotation.endPoint.y + origin.y))
        case "Ink":
            for path in annotation.paths ?? [] {
                let points = pathPoints(path).map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                let width = max(tolerance, path.lineWidth)
                if points.count == 1, hypot(points[0].x - point.x, points[0].y - point.y) <= width { return true }
                for (a, b) in zip(points, points.dropFirst()) where distance(point, a, b) <= width { return true }
            }
            return false
        case "PolyLine":
            if let drawn = annotation as? CommentAnnotation {
                let p = drawn.design.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                return zip(p, p.dropFirst()).contains { near($0, $1) }
            }
            return true
        default:
            return true
        }
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func pathPoints(_ path: NSBezierPath) -> [CGPoint] {
        var result: [CGPoint] = []
        var buffer = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            switch path.element(at: index, associatedPoints: &buffer) {
            case .moveTo, .lineTo: result.append(buffer[0])
            case .curveTo, .cubicCurveTo: result.append(buffer[2])
            case .quadraticCurveTo: result.append(buffer[1])
            case .closePath: break
            @unknown default: break
            }
        }
        return result
    }

    // MARK: Handles

    enum Handle: CaseIterable { case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left }

    private func handlePoints(for rect: CGRect) -> [(Handle, CGPoint)] {
        [(.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)), (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
         (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)), (.right, CGPoint(x: rect.maxX, y: rect.midY)),
         (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.top, CGPoint(x: rect.midX, y: rect.maxY)),
         (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.left, CGPoint(x: rect.minX, y: rect.midY))]
    }

    private func handle(at point: CGPoint, for selection: CommentSelection) -> Handle? {
        guard Self.resizable(selection.annotation) else { return nil }
        let radius = 6 / scale
        return handlePoints(for: selection.annotation.bounds).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius }?.0
    }

    /// Line/arrow endpoints and a callout's pointer are dragged individually.
    private func endpoints(of annotation: PDFAnnotation) -> [CGPoint] {
        let origin = annotation.bounds.origin
        if let drawn = annotation as? CommentAnnotation {
            switch drawn.design.shape {
            case .line: return drawn.design.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            case .callout: return drawn.design.points.prefix(1).map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            default: return []
            }
        }
        if annotation.type == "Line" {
            return [annotation.startPoint, annotation.endPoint].map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        }
        return []
    }

    private func endpointHandle(at point: CGPoint, for selection: CommentSelection) -> Int? {
        let radius = 7 / scale
        return endpoints(of: selection.annotation).firstIndex { hypot($0.x - point.x, $0.y - point.y) <= radius }
    }

    private func resize(_ selection: CommentSelection, handle: Handle, original: CGRect, design: CommentDesign?, paths: [NSBezierPath],
                        to point: CGPoint, keepAspect: Bool) {
        var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
        switch handle {
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .topRight: maxX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(6, abs(maxX - minX)), height: max(6, abs(maxY - minY)))
        if keepAspect, original.width > 0, original.height > 0 {
            let ratio = original.width / original.height
            if rect.width / rect.height > ratio { rect.size.width = rect.height * ratio } else { rect.size.height = rect.width / ratio }
            if [.bottomLeft, .topLeft, .left].contains(handle) { rect.origin.x = original.maxX - rect.width }
            if [.bottomLeft, .bottomRight, .bottom].contains(handle) { rect.origin.y = original.maxY - rect.height }
        }
        let annotation = selection.annotation
        if let drawn = annotation as? CommentAnnotation, let design {
            annotation.bounds = rect
            drawn.design = design.scaled(from: original.size, to: rect.size)
        } else if annotation.type == "Ink" {
            let sx = rect.width / max(1, original.width), sy = rect.height / max(1, original.height)
            for path in annotation.paths ?? [] { annotation.remove(path) }
            annotation.bounds = rect
            for path in paths {
                let scaled = path.copy() as! NSBezierPath
                scaled.transform(using: AffineTransform(scaleByX: sx, byY: sy))
                annotation.add(scaled)
            }
        } else {
            annotation.bounds = rect
        }
        appState?.redraw(selection.page)
    }

    private func moveEndpoint(_ selection: CommentSelection, index: Int, to point: CGPoint) {
        let annotation = selection.annotation
        var absolute = endpoints(of: annotation)
        guard absolute.indices.contains(index) else { return }
        absolute[index] = point
        if let drawn = annotation as? CommentAnnotation {
            var design = drawn.design
            let origin = annotation.bounds.origin
            var all = design.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            all[index] = point
            var extent = all
            if design.shape == .callout, let box = design.textBox { extent += [CGPoint(x: box.minX + origin.x, y: box.minY + origin.y),
                                                                               CGPoint(x: box.maxX + origin.x, y: box.maxY + origin.y)] }
            let pad = max(8, CGFloat(design.style.lineWidth) * 4)
            let bounds = CGRect(x: extent.map(\.x).min()! - pad, y: extent.map(\.y).min()! - pad,
                                width: extent.map(\.x).max()! - extent.map(\.x).min()! + 2 * pad,
                                height: extent.map(\.y).max()! - extent.map(\.y).min()! + 2 * pad)
            if let box = design.textBox { design.textBox = box.offsetBy(dx: origin.x - bounds.minX, dy: origin.y - bounds.minY) }
            design.points = all.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
            annotation.bounds = bounds
            drawn.design = design
        } else if annotation.type == "Line" {
            let pad = max(8, (annotation.border?.lineWidth ?? 1) * 4)
            let bounds = CGRect(x: min(absolute[0].x, absolute[1].x) - pad, y: min(absolute[0].y, absolute[1].y) - pad,
                                width: abs(absolute[1].x - absolute[0].x) + 2 * pad, height: abs(absolute[1].y - absolute[0].y) + 2 * pad)
            annotation.bounds = bounds
            annotation.startPoint = CGPoint(x: absolute[0].x - bounds.minX, y: absolute[0].y - bounds.minY)
            annotation.endPoint = CGPoint(x: absolute[1].x - bounds.minX, y: absolute[1].y - bounds.minY)
        }
        appState?.redraw(selection.page)
    }

    private func constrain(_ tool: AnnotationTool, start: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        switch tool {
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .rectangle, .oval, .cloud:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            return point
        }
    }

    // MARK: Eraser

    /// Removes pen stroke segments under the eraser; strokes split around the gap.
    func erase(at point: CGPoint, on page: PDFPage) -> Bool {
        let radius = max(4, 8 / scale)
        var changed = false
        for annotation in page.annotations where annotation.type == "Ink" && annotation.shouldDisplay {
            guard annotation.bounds.insetBy(dx: -radius, dy: -radius).contains(point) else { continue }
            let origin = annotation.bounds.origin
            let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            var kept: [NSBezierPath] = []
            var touched = false
            for path in annotation.paths ?? [] {
                let points = Self.pathPoints(path)
                let reach = radius + path.lineWidth / 2
                guard points.contains(where: { hypot($0.x - local.x, $0.y - local.y) <= reach })
                        || zip(points, points.dropFirst()).contains(where: { Self.distance(local, $0, $1) <= reach }) else {
                    kept.append(path)
                    continue
                }
                touched = true
                var run: [CGPoint] = []
                func flush() {
                    if run.count > 1 {
                        let piece = NSBezierPath()
                        piece.move(to: run[0])
                        run.dropFirst().forEach { piece.line(to: $0) }
                        piece.lineWidth = path.lineWidth
                        piece.lineCapStyle = .round
                        piece.lineJoinStyle = .round
                        kept.append(piece)
                    }
                    run = []
                }
                for p in points {
                    if hypot(p.x - local.x, p.y - local.y) <= reach { flush() } else { run.append(p) }
                }
                flush()
            }
            guard touched else { continue }
            changed = true
            if kept.isEmpty {
                if session?.selection?.annotation === annotation { session?.selection = nil }
                page.removeAnnotation(annotation)
            } else {
                for path in annotation.paths ?? [] { annotation.remove(path) }
                for path in kept { annotation.add(path) }
            }
        }
        if changed { appState?.redraw(page) }
        return changed
    }

    // MARK: Activation & editing

    /// Double-click: edit text in place, open an attachment, play a sound.
    private func activate(_ selection: CommentSelection) {
        guard let appState, let tab, let comment = service?.comment(for: selection.annotation, in: tab) else { return }
        switch selection.annotation.type {
        case "FileAttachment": appState.openAttachment(comment)
        case "Sound": appState.toggleSoundPlayback(comment)
        case "Stamp", "Ink", "Square", "Circle", "Line", "Polygon", "PolyLine", "Highlight", "Underline", "StrikeOut", "Squiggly":
            appState.comments.focusedCommentID = comment.id
            appState.documentPanel = .comments
        default:
            let prepared = appState.prepareForEditing(selection)
            beginEditing(prepared.annotation, isNew: false)
        }
    }

    func beginEditing(_ annotation: PDFAnnotation, isNew: Bool) {
        guard let pdfView, let page = annotation.page, pdfView.document === page.document else { return }
        commitEditor()
        let editor = CommentInlineEditor(annotation: annotation, isNew: isNew)
        editor.onFinish = { [weak self] commit in self?.finishEditing(commit: commit) }
        editor.onResize = { [weak self] in self?.positionEditor() }
        self.editor = editor
        if annotation.type == "FreeText" { CommentVisibility.hide(annotation); appState?.redraw(page) }
        pdfView.addSubview(editor, positioned: .above, relativeTo: overlay)
        positionEditor()
        editor.focus()
    }

    private func positionEditor() {
        guard let editor, let pdfView, let page = editor.annotation.page else { return }
        editor.layout(in: pdfView, page: page, overlay: overlay)
    }

    func commitEditor() { editor?.finish(commit: true) }

    private func finishEditing(commit: Bool) {
        guard let editor else { return }
        self.editor = nil
        let annotation = editor.annotation
        editor.removeFromSuperview()
        CommentVisibility.reveal(annotation)
        guard let appState, let tab, let page = annotation.page else { return }
        let text = editor.text
        let original = annotation.contents ?? ""
        if commit {
            if text != original {
                annotation.contents = text
                annotation.modificationDate = Date()
                if annotation.type == "FreeText" { editor.fitAnnotation() }
                (annotation as? CommentAnnotation)?.syncStandardKeys()
                appState.commitCommentEdit(editor.isNew ? "Add Text" : "Edit Comment", in: tab)
            }
        } else if editor.isNew, original.isEmpty, text.isEmpty, annotation.type == "FreeText" {
            // A cancelled, empty new text box leaves nothing behind.
            page.removeAnnotation(annotation)
            appState.comments.selection = nil
            appState.commitCommentEdit("Add Text", in: tab)
        }
        appState.redraw(page)
        if let pdfView { pdfView.window?.makeFirstResponder(pdfView) }
    }

    // MARK: Keys & menu

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let pdfView, let window = pdfView.window, window.isKeyWindow, event.window === window, let appState else { return false }
        let responder = window.firstResponder
        let canvasFocused = responder === pdfView || responder === pdfView.documentView
            || (responder as? NSView)?.isDescendant(of: pdfView) == true && !(responder is NSText)
        guard canvasFocused else { return false }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            guard plain, session?.validSelection(in: tab) != nil else { return false }
            appState.deleteSelectedComment()
            return true
        case 53: // Escape
            if polygon != nil { polygon = nil; overlay.needsDisplay = true; return true }
            if gesture != nil { gesture = nil; overlay.needsDisplay = true; return true }
            if appState.armedAnnotationTool != nil { appState.armedAnnotationTool = nil; return true }
            if session?.selection != nil { session?.selection = nil; return true }
            return false
        case 36, 76: // Return finishes a polygon or edits the selection
            guard plain else { return false }
            if polygon != nil { finishPolygon(); return true }
            if let selection = session?.validSelection(in: tab) { activate(selection); return true }
            return false
        default:
            return false
        }
    }

    func menu(for event: NSEvent, in pdfView: PDFView) -> NSMenu? {
        guard let appState, let tab, let hit = location(event, in: pdfView),
              let annotation = hitComment(at: hit.point, on: hit.page),
              let comment = service?.comment(for: annotation, in: tab) else { return nil }
        session?.selection = CommentSelection(annotation: annotation, page: hit.page)
        return CommentContextMenu.make(for: comment, annotation: annotation, appState: appState, editText: { [weak self] in
            guard let self, let selection = self.session?.validSelection(in: self.tab) else { return }
            self.activate(selection)
        })
    }

    // MARK: Overlay drawing

    /// Page → overlay affine transform (handles zoom, scroll and page rotation).
    func transform(for page: PDFPage) -> CGAffineTransform? {
        guard let pdfView else { return nil }
        func map(_ p: CGPoint) -> CGPoint { overlay.convert(pdfView.convert(p, from: page), from: pdfView) }
        let o = map(.zero), x = map(CGPoint(x: 1, y: 0)), y = map(CGPoint(x: 0, y: 1))
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    func drawOverlay(in context: CGContext) {
        guard let appState else { return }
        let accent = NSColor.controlAccentColor
        if let gesture {
            switch gesture {
            case .creating(let tool, let page, let start, let current):
                guard let t = transform(for: page) else { break }
                context.saveGState(); context.concatenate(t)
                if let design = previewDesign(tool, start: start, current: current) {
                    CommentDrawing.draw(design.design, bounds: design.bounds, contents: "", in: context)
                }
                context.restoreGState()
            case .drawing(let page, let points):
                guard let t = transform(for: page), points.count > 1 else { break }
                let style = appState.annotationService.style(for: .drawing)
                context.saveGState(); context.concatenate(t)
                context.setStrokeColor(style.color.nsColor.withAlphaComponent(CGFloat(style.opacity)).cgColor)
                context.setLineWidth(CGFloat(style.lineWidth)); context.setLineCap(.round); context.setLineJoin(.round)
                context.addLines(between: points); context.strokePath()
                context.restoreGState()
            default: break
            }
        }
        if let polygon, let t = transform(for: polygon.page) {
            var points = polygon.points
            if let hover = hoverPoint, hover.page === polygon.page { points.append(hover.point) }
            let style = appState.annotationService.style(for: polygon.tool)
            context.saveGState(); context.concatenate(t)
            context.setStrokeColor(style.color.cgColor)
            context.setLineWidth(CGFloat(style.lineWidth))
            context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
            if points.count > 1 { context.addLines(between: points); context.strokePath() }
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(accent.cgColor)
            for point in polygon.points { context.fillEllipse(in: CGRect(x: point.x - 3 / scale, y: point.y - 3 / scale, width: 6 / scale, height: 6 / scale)) }
            context.restoreGState()
        }
        if appState.armedAnnotationTool == .eraser, let hover = hoverPoint, let t = transform(for: hover.page) {
            let radius = max(4, 8 / scale)
            context.saveGState(); context.concatenate(t)
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineWidth(1 / scale)
            context.strokeEllipse(in: CGRect(x: hover.point.x - radius, y: hover.point.y - radius, width: 2 * radius, height: 2 * radius))
            context.restoreGState()
        }
        guard let selection = session?.validSelection(in: tab), editor?.annotation !== selection.annotation,
              selection.annotation.shouldDisplay, let t = transform(for: selection.page) else { return }
        let rect = selection.annotation.bounds.applying(t).insetBy(dx: -3, dy: -3)
        context.saveGState()
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
        let handles: [CGPoint]
        if !endpoints(of: selection.annotation).isEmpty {
            handles = endpoints(of: selection.annotation).map { $0.applying(t) }
        } else if Self.resizable(selection.annotation) {
            handles = handlePoints(for: selection.annotation.bounds).map { $0.1.applying(t) }
        } else { handles = [] }
        for point in handles {
            let box = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.setFillColor(NSColor.white.cgColor); context.fill(box)
            context.setStrokeColor(accent.cgColor); context.setLineWidth(1.25); context.stroke(box)
        }
        context.restoreGState()
    }

    private func previewDesign(_ tool: AnnotationTool, start: CGPoint, current: CGPoint) -> (design: CommentDesign, bounds: CGRect)? {
        guard let appState else { return nil }
        let style = appState.annotationService.style(for: tool)
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
        switch tool {
        case .rectangle, .cloud: return (CommentDesign(shape: .rectangle, style: style), rect)
        case .oval: return (CommentDesign(shape: .oval, style: style), rect)
        case .line, .arrow:
            var lineStyle = style
            if tool == .arrow, lineStyle.endEnding == .none { lineStyle.endEnding = .openArrow }
            return (CommentDesign(shape: .line, style: lineStyle, points: [CGPoint(x: start.x - rect.minX, y: start.y - rect.minY),
                                                                           CGPoint(x: current.x - rect.minX, y: current.y - rect.minY)]), rect)
        case .textBox:
            var boxStyle = style
            boxStyle.lineWidth = max(1, style.lineWidth); boxStyle.color = CommentColor(NSColor.controlAccentColor) ?? .blue
            boxStyle.lineStyle = .dashed; boxStyle.fill = nil
            return (CommentDesign(shape: .rectangle, style: boxStyle), rect)
        case .callout:
            let box = CGRect(x: current.x, y: current.y - 24, width: 160, height: 48)
            let all = rect.union(box).insetBy(dx: -8, dy: -8)
            return (CommentDesign(shape: .callout, style: style,
                                  points: [start, CGPoint(x: current.x, y: current.y)].map { CGPoint(x: $0.x - all.minX, y: $0.y - all.minY) },
                                  textBox: box.offsetBy(dx: -all.minX, dy: -all.minY)), all)
        default: return nil
        }
    }

    func cursor() -> NSCursor? {
        guard let tool = appState?.armedAnnotationTool, canInteract else { return nil }
        switch tool {
        case .highlight, .underline, .strikethrough, .replaceText: return .iBeam
        case .insertText: return .iBeam
        default: return .crosshair
        }
    }
}

// MARK: - Overlay view

/// Draws previews and selection handles above the page; never takes clicks.
final class CommentOverlayView: NSView {
    weak var controller: CommentCanvasController?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        controller?.drawOverlay(in: context)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(at: event.locationInWindow)
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = controller?.cursor() { cursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func resetCursorRects() {
        if let cursor = controller?.cursor() { addCursorRect(bounds, cursor: cursor) }
    }
}

// MARK: - Inline editor

/// Types a text box, callout or note directly on the page. ⌘↩ or clicking
/// elsewhere finishes; Esc cancels.
final class CommentInlineEditor: NSView, NSTextViewDelegate {
    let annotation: PDFAnnotation
    let isNew: Bool
    var onFinish: ((Bool) -> Void)?
    var onResize: (() -> Void)?
    private let textView = CommentTextView()
    private let header = NSTextField(labelWithString: "")
    private var finished = false
    private var scaleFactor: CGFloat = 1

    var text: String { textView.string }
    private var isPopupStyle: Bool { !["FreeText"].contains(annotation.type ?? "") }

    init(annotation: PDFAnnotation, isNew: Bool) {
        self.annotation = annotation
        self.isNew = isNew
        super.init(frame: .zero)
        wantsLayer = true
        textView.string = annotation.contents ?? ""
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.textContainer?.lineFragmentPadding = 1
        textView.isVerticallyResizable = true
        textView.onCommand = { [weak self] commit in self?.finish(commit: commit) }
        textView.setAccessibilityLabel(isPopupStyle ? "Comment text" : "Text box contents")
        addSubview(textView)
        if isPopupStyle {
            let kind = CommentKind(pdfSubtype: annotation.type).singular
            header.stringValue = "\(kind) — \(annotation.userName ?? NSFullUserName())   ⌘↩ Done · Esc Cancel"
            header.font = .systemFont(ofSize: 10, weight: .medium)
            header.textColor = .secondaryLabelColor
            header.lineBreakMode = .byTruncatingTail
            addSubview(header)
            layer?.cornerRadius = 8
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 6
            layer?.shadowOffset = CGSize(width: 0, height: -2)
            textView.font = .systemFont(ofSize: 12)
            textView.textColor = .textColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus() {
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        if (annotation.contents ?? "").isEmpty { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    func layout(in pdfView: PDFView, page: PDFPage, overlay: NSView) {
        scaleFactor = pdfView.scaleFactor
        let bounds = annotation.bounds
        if isPopupStyle {
            let anchor = overlay.convert(pdfView.convert(CGRect(x: bounds.maxX, y: bounds.maxY, width: 0, height: 0), from: page), from: pdfView)
            let size = CGSize(width: 260, height: 118)
            var origin = CGPoint(x: anchor.minX + 8, y: anchor.minY - size.height)
            if origin.x + size.width > overlay.bounds.maxX - 8 {
                let left = overlay.convert(pdfView.convert(CGRect(x: bounds.minX, y: bounds.maxY, width: 0, height: 0), from: page), from: pdfView)
                origin.x = left.minX - size.width - 8
            }
            origin.x = max(8, origin.x)
            origin.y = max(8, min(origin.y, overlay.bounds.maxY - size.height - 8))
            frame = CGRect(origin: origin, size: size)
            header.frame = CGRect(x: 10, y: size.height - 22, width: size.width - 20, height: 16)
            textView.frame = CGRect(x: 8, y: 8, width: size.width - 16, height: size.height - 34)
        } else {
            var rect = bounds
            if let drawn = annotation as? CommentAnnotation, drawn.design.shape == .callout, let box = drawn.design.textBox {
                rect = box.offsetBy(dx: bounds.minX, dy: bounds.minY)
            }
            let viewRect = overlay.convert(pdfView.convert(rect, from: page), from: pdfView)
            frame = viewRect.insetBy(dx: -2, dy: -2)
            textView.frame = CGRect(x: 2, y: 2, width: max(10, frame.width - 4), height: max(10, frame.height - 4))
            let style = CommentRehydration.style(of: annotation)
            let font = annotation.font ?? style.font
            textView.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scaleFactor) ?? font
            textView.textColor = (annotation.fontColor ?? style.textColor.nsColor).withAlphaComponent(1)
            let fill = (annotation as? CommentAnnotation)?.design.style.fill?.nsColor
                ?? (annotation.color.alphaComponent > 0.01 ? annotation.color : nil)
            layer?.backgroundColor = (fill ?? NSColor.white.withAlphaComponent(0.001)).cgColor
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isPopupStyle, annotation.type == "FreeText", !(annotation is CommentAnnotation) else { return }
        // Typewriter boxes grow downward as the text wraps.
        let needed = requiredSize(width: annotation.bounds.width)
        if needed.height > annotation.bounds.height + 0.5 {
            var bounds = annotation.bounds
            bounds.origin.y -= needed.height - bounds.height
            bounds.size.height = needed.height
            annotation.bounds = bounds
            onResize?()
        }
    }

    func textDidEndEditing(_ notification: Notification) { finish(commit: true) }

    func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        onFinish?(commit)
    }

    private func requiredSize(width: CGFloat) -> CGSize {
        let font = annotation.font ?? .systemFont(ofSize: 12)
        let string = textView.string.isEmpty ? " " : textView.string
        let rect = NSAttributedString(string: string, attributes: [.font: font])
            .boundingRect(with: CGSize(width: max(10, width - 8), height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width) + 10, height: ceil(rect.height) + 8)
    }

    /// Shrinks a typewriter box to its text (keeping the top edge).
    func fitAnnotation() {
        guard annotation.type == "FreeText", !(annotation is CommentAnnotation), let page = annotation.page else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let maxWidth = max(40, pageBounds.maxX - annotation.bounds.minX - 8)
        let lines = textView.string.components(separatedBy: .newlines)
        let font = annotation.font ?? .systemFont(ofSize: 12)
        let natural = lines.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 40
        let width = min(maxWidth, max(annotation.bounds.width, natural + 12))
        let size = requiredSize(width: width)
        var bounds = annotation.bounds
        let top = bounds.maxY
        bounds.size = CGSize(width: width, height: max(size.height, font.pointSize * 1.6))
        bounds.origin.y = top - bounds.height
        annotation.bounds = bounds
    }
}

final class CommentTextView: NSTextView {
    var onCommand: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCommand?(false); return }
        if [36, 76].contains(event.keyCode) && event.modifierFlags.contains(.command) { onCommand?(true); return }
        super.keyDown(with: event)
    }
}

// MARK: - Context menu

@MainActor
enum CommentContextMenu {
    static func make(for comment: Comment, annotation: PDFAnnotation, appState: AppState, editText: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(title: "Comment")
        func item(_ title: String, _ symbol: String? = nil, action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, handler: action)
            if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        let editable = appState.canEditComments
        if editable, ["FreeText", "Text", "Caret"].contains(annotation.type ?? "") { item("Edit Text", "pencil", action: editText) }
        if annotation.type == "FileAttachment" {
            item("Open Attachment", "arrow.up.forward.app") { appState.openAttachment(comment) }
            item("Save Attachment…", "square.and.arrow.down") { appState.saveAttachment(comment) }
        }
        if annotation.type == "Sound" { item("Play Sound", "play.fill") { appState.toggleSoundPlayback(comment) } }
        item("Show in Comment List", "list.bullet") {
            appState.documentPanel = .comments
            appState.comments.focusedCommentID = comment.id
        }
        if editable {
            menu.addItem(.separator())
            let status = NSMenuItem(title: "Set Status", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for value in CommentStatus.allCases {
                let entry = ClosureMenuItem(title: value.title) { appState.setCommentStatus(value, for: comment) }
                entry.state = comment.status == value ? .on : .off
                submenu.addItem(entry)
            }
            status.submenu = submenu
            menu.addItem(status)
            let mark = ClosureMenuItem(title: comment.isMarked ? "Remove Checkmark" : "Add Checkmark") {
                appState.setCommentMarked(!comment.isMarked, for: comment)
            }
            menu.addItem(mark)
            menu.addItem(.separator())
            item(comment.replies.isEmpty ? "Delete Comment" : "Delete Comment and Replies", "trash") { appState.deleteComment(comment) }
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

// MARK: - Sound prompt

@MainActor
enum CommentSoundPrompt {
    /// Record from the microphone or choose an audio file, then place it.
    static func run(appState: AppState, point: CGPoint, pageIndex: Int) async {
        if let source = appState.comments.soundSource {
            if let wav = await source() { appState.addSoundComment(from: wav, at: point, onPage: pageIndex) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add Sound Comment"
        alert.informativeText = "Record a voice note with your microphone, or choose an audio file. The sound is embedded in the PDF."
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Choose Audio File…")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard await CommentMedia.requestMicrophone() else {
                appState.saveError = OpenError(fileName: "Microphone", message: "zPDF needs microphone access to record. Allow it in System Settings › Privacy & Security › Microphone, or choose an audio file instead.")
                return
            }
            if let wav = record(appState: appState) { appState.addSoundComment(from: wav, at: point, onPage: pageIndex) }
        case .alertSecondButtonReturn:
            if let wav = await appState.chooseSoundFile() { appState.addSoundComment(from: wav, at: point, onPage: pageIndex) }
        default:
            return
        }
    }

    private static func record(appState: AppState) -> URL? {
        let media = CommentMedia.shared
        do { try media.startRecording() } catch {
            appState.saveError = OpenError(fileName: "Recording", message: error.localizedDescription)
            return nil
        }
        appState.comments.isRecording = true
        defer { appState.comments.isRecording = false }
        let alert = NSAlert()
        alert.messageText = "Recording…"
        alert.informativeText = "0:00"
        alert.addButton(withTitle: "Stop and Add")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let start = Date()
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { alert.informativeText = AVAudioDuration.format(Date().timeIntervalSince(start)) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()
        return media.stopRecording(keep: response == .alertFirstButtonReturn)
    }
}
