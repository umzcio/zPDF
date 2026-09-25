import AppKit
import PDFKit

/// Transparent canvas layer above the PDFView while an Edit PDF or Redact
/// tool is active. It draws block/object outlines, selection handles and
/// drag previews, routes mouse and keyboard input to the controller, and
/// hosts the inline text editor. When no tool is active it is invisible to
/// hit-testing, so PDFView behaves exactly as usual.
@MainActor
final class ContentEditOverlay: NSView {
    weak var controller: ContentEditingController?
    private(set) weak var pdfView: PDFView?
    var editor: InlineTextEditor?
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    private var drag: Drag?
    private var hoverBlock: (ObjectIdentifier, Int)?
    private var hoverObject: String?
    private var hoverMark: RedactionMarkAnnotation?
    private var nudge = CGPoint.zero
    private var nudgeWork: DispatchWorkItem?
    private var ghost: (image: NSImage, rect: CGRect, page: PDFPage)?
    private var textSelection: PDFSelection?

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    }

    private enum Drag {
        case marquee(page: PDFPage, start: CGPoint, current: CGPoint)
        case move(page: PDFPage, start: CGPoint, current: CGPoint, didMove: Bool)
        case resize(page: PDFPage, handle: Handle, original: CGRect, current: CGRect)
        case textSelect(page: PDFPage, start: CGPoint, current: CGPoint)
        case crop(page: PDFPage, handle: Handle?, start: CGPoint, original: CGRect)
        case editorMove(start: CGPoint, originalOffset: CGPoint, originalOrigin: CGPoint)
        case editorResize(handle: Handle, startX: CGFloat, originalWidth: CGFloat)
        case imageCrop(page: PDFPage, handle: Handle, original: CGRect)
    }

    // MARK: - Attachment

    func attach(to view: PDFView) {
        if pdfView === view, superview === view { return }
        removeFromSuperview()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pdfView = view
        frame = view.bounds
        autoresizingMask = [.width, .height]
        view.addSubview(self, positioned: .above, relativeTo: nil)
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.viewChanged() }
        }
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main, using: refresh))
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main, using: refresh))
        observers.append(center.addObserver(forName: .PDFViewDisplayModeChanged, object: view, queue: .main, using: refresh))
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: refresh))
        }
        setAccessibilityElement(false)
    }

    private func viewChanged() {
        positionEditor()
        needsDisplay = true
        if controller?.isActive == true { controller?.prefetchVisiblePages() }
    }

    override var acceptsFirstResponder: Bool { controller?.isActive == true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller, controller.isActive, let pdfView, !(controller.tab?.isSaving ?? true) else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let editor, editor.frame.contains(local) { return editor.hitTest(convert(point, from: superview).applying(.identity)) ?? editor }
        // Leave the scroll bars to the scroll view.
        if let scroll = pdfView.documentView?.enclosingScrollView {
            for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) where !scroller.isHidden {
                if convert(scroller.bounds, from: scroller).contains(local) { return nil }
            }
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func scrollWheel(with event: NSEvent) {
        if let scroll = pdfView?.documentView?.enclosingScrollView { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    // MARK: - Coordinates

    private func pageHit(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        guard let pdfView else { return nil }
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        return (page, pdfView.convert(viewPoint, to: page))
    }

    private func pagePoint(_ event: NSEvent, on page: PDFPage) -> CGPoint? {
        guard let pdfView else { return nil }
        return pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
    }

    func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    func viewPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    private func pageRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        return pdfView.convert(convert(rect, to: pdfView), to: page)
    }

    private var scale: CGFloat { pdfView?.scaleFactor ?? 1 }

    // MARK: - Drawing

    private static let outline = NSColor(srgbRed: 0.35, green: 0.45, blue: 0.6, alpha: 0.45)
    private var accent: NSColor { NSColor(DesignTokens.Colors.controlAccent) }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, controller.isActive, let pdfView, let tool = controller.tool else { return }
        for page in pdfView.visiblePages {
            let pageRectInView = viewRect(page.bounds(for: .cropBox), on: page)
            guard pageRectInView.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: pageRectInView).addClip()
            switch tool {
            case .edit, .addText, .addImage:
                drawContent(on: page, tool: tool)
            case .link:
                drawLinks(on: page)
            case .crop:
                drawCrop(on: page, pageRect: pageRectInView)
            case .redact:
                drawRedaction(on: page)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        drawDrag()
        if let editor { drawEditorFrame(editor) }
    }

    private func path(for quad: [CGPoint], on page: PDFPage) -> NSBezierPath {
        let path = NSBezierPath()
        for (i, point) in quad.enumerated() {
            let p = viewPoint(point, on: page)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    private func drawContent(on page: PDFPage, tool: CanvasTool) {
        guard let controller, let content = controller.content(for: page) else { return }
        let key = ObjectIdentifier(page)
        let selection = controller.selection
        let isSelectedPage = controller.selectionPage === page
        for block in content.blocks where editor?.block?.id != block.id || editor?.page !== page {
            let path = path(for: block.quad, on: page)
            let hovered = hoverBlock.map { $0.0 == key && $0.1 == block.id } ?? false
            let selected = isSelectedPage && selection?.block == block.id
            if selected || hovered {
                (selected ? accent : accent.withAlphaComponent(0.7)).setStroke()
                path.lineWidth = selected ? 1.5 : 1
            } else if tool == .edit {
                Self.outline.setStroke()
                path.lineWidth = 0.5
            } else { continue }
            path.stroke()
        }
        for object in content.objects {
            let selected = isSelectedPage && selection?.objects.contains(object.id) == true
            let hovered = hoverObject == object.id && controller.selectionPage.map { $0 === page } != false
            guard selected || hovered || (tool == .edit && object.kind.isImage) else { continue }
            let path = object.quad.count == 4 ? path(for: object.quad, on: page) : NSBezierPath(rect: viewRect(object.bbox, on: page))
            if selected {
                accent.setStroke()
                path.lineWidth = 1.5
            } else if hovered {
                accent.withAlphaComponent(0.7).setStroke()
                path.lineWidth = 1
            } else {
                Self.outline.setStroke()
                path.lineWidth = 0.5
            }
            path.stroke()
        }
        if isSelectedPage, selection?.isEmpty == false, editor == nil {
            let bounds = controller.selectionBounds(on: page)
            if !bounds.isNull {
                var rect = viewRect(bounds, on: page)
                if case .move(let p, let start, let current, true) = drag, p === page {
                    let a = viewPoint(start, on: page), b = viewPoint(current, on: page)
                    rect = rect.offsetBy(dx: b.x - a.x, dy: b.y - a.y)
                    if let ghost, ghost.page === page {
                        ghost.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.75)
                    }
                } else if case .resize(let p, _, _, let current) = drag, p === page {
                    rect = current
                } else if nudge != .zero {
                    let a = viewPoint(.zero, on: page), b = viewPoint(nudge, on: page)
                    rect = rect.offsetBy(dx: b.x - a.x, dy: b.y - a.y)
                }
                if controller.selection?.objects.count ?? 0 > 1 || selection?.block != nil {
                    let union = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
                    union.setLineDash([4, 3], count: 2, phase: 0)
                    accent.setStroke()
                    union.lineWidth = 1
                    union.stroke()
                }
                if controller.isCroppingImage, let crop = controller.imageCropRect {
                    drawImageCrop(viewRect(crop, on: page), image: rect)
                } else {
                    drawHandles(for: rect, sidesOnly: selection?.block != nil)
                }
            }
        }
    }

    private func handleRects(for rect: CGRect) -> [(Handle, CGRect)] {
        let s: CGFloat = 7
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s) }
        return [(.topLeft, box(rect.minX, rect.maxY)), (.top, box(rect.midX, rect.maxY)), (.topRight, box(rect.maxX, rect.maxY)),
                (.right, box(rect.maxX, rect.midY)), (.bottomRight, box(rect.maxX, rect.minY)), (.bottom, box(rect.midX, rect.minY)),
                (.bottomLeft, box(rect.minX, rect.minY)), (.left, box(rect.minX, rect.midY))]
    }

    private func drawHandles(for rect: CGRect, sidesOnly: Bool = false) {
        for (handle, box) in handleRects(for: rect) {
            if sidesOnly && handle != .left && handle != .right { continue }
            let path = NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawImageCrop(_ crop: CGRect, image: CGRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        let outside = NSBezierPath(rect: image)
        outside.append(NSBezierPath(rect: crop))
        outside.windingRule = .evenOdd
        outside.fill()
        let border = NSBezierPath(rect: crop)
        accent.setStroke()
        border.lineWidth = 1.5
        border.stroke()
        drawHandles(for: crop)
    }

    private func drawLinks(on page: PDFPage) {
        guard let controller, let index = controller.livePageIndex(page) else { return }
        for link in controller.links[index] ?? [] {
            let rect = viewRect(link.rect, on: page)
            let selected = controller.selectedLink == link && controller.selection == nil
            let path = NSBezierPath(rect: rect)
            NSColor.systemBlue.withAlphaComponent(selected ? 0.18 : 0.08).setFill()
            path.fill()
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
            path.lineWidth = selected ? 2 : 1
            if !selected { path.setLineDash([4, 2], count: 2, phase: 0) }
            path.stroke()
        }
        if let draft = controller.linkDraft, draft.page == index, draft.existing == nil {
            let path = NSBezierPath(rect: viewRect(draft.rect, on: page))
            NSColor.systemBlue.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func drawCrop(on page: PDFPage, pageRect: CGRect) {
        guard let controller, let rect = controller.cropRect, controller.cropPage == controller.livePageIndex(page) else { return }
        let crop = viewRect(rect, on: page)
        NSColor.black.withAlphaComponent(0.4).setFill()
        let dim = NSBezierPath(rect: pageRect)
        dim.append(NSBezierPath(rect: crop))
        dim.windingRule = .evenOdd
        dim.fill()
        let border = NSBezierPath(rect: crop)
        accent.setStroke()
        border.lineWidth = 1.5
        border.stroke()
        drawHandles(for: crop)
        let label = String(format: "%.0f × %.0f pt", rect.applying(page.visualTransform).width, rect.applying(page.visualTransform).height)
        drawBadge(label, at: CGPoint(x: crop.midX, y: crop.maxY + 12))
    }

    private func drawBadge(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
    }

    private func drawRedaction(on page: PDFPage) {
        guard let controller else { return }
        for annotation in page.annotations where RedactionMarkAnnotation.isMark(annotation) {
            let selected = controller.selectedMark === annotation
            let hovered = hoverMark === annotation
            guard selected || hovered else { continue }
            let rects = RedactionMarkAnnotation.rects(of: annotation)
            for rect in rects {
                let r = viewRect(rect, on: page)
                // Preview of the applied look.
                (annotation.interiorColor ?? .black).setFill()
                NSBezierPath(rect: r).fill()
                if let text = (annotation as? RedactionMarkAnnotation)?.overlayText, !text.isEmpty {
                    let size = min(r.height * 0.7, 12 * scale)
                    let color = (annotation.interiorColor?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5 ? NSColor.white : .black
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: max(4, size)), .foregroundColor: color]
                    let textSize = (text as NSString).size(withAttributes: attributes)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: r).addClip()
                    (text as NSString).draw(at: CGPoint(x: r.midX - textSize.width / 2, y: r.midY - textSize.height / 2), withAttributes: attributes)
                    NSGraphicsContext.restoreGraphicsState()
                }
                if selected {
                    let border = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2))
                    accent.setStroke()
                    border.lineWidth = 2
                    border.stroke()
                }
            }
        }
        if let textSelection, case .textSelect(let p, _, _) = drag, p === page {
            for line in textSelection.selectionsByLine() {
                let r = viewRect(line.bounds(for: page), on: page)
                RedactionMarkAnnotation.markColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(rect: r).fill()
                RedactionMarkAnnotation.markColor.setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    private func drawDrag() {
        guard let drag else { return }
        switch drag {
        case .marquee(let page, let start, let current):
            let a = viewPoint(start, on: page), b = viewPoint(current, on: page)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let path = NSBezierPath(rect: rect)
            let tool = controller?.tool
            let color: NSColor = tool == .redact ? RedactionMarkAnnotation.markColor : (tool == .link ? .systemBlue : accent)
            color.withAlphaComponent(0.1).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        default:
            break
        }
    }

    private func drawEditorFrame(_ editor: InlineTextEditor) {
        let rect = editor.frame.insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: rect)
        accent.setStroke()
        path.lineWidth = 1
        path.stroke()
        drawHandles(for: rect, sidesOnly: true)
        // Move band along the top edge.
        let band = CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 5)
        accent.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: band).fill()
    }

    // MARK: - Hit testing

    private func handle(at point: CGPoint, in rect: CGRect, sidesOnly: Bool = false) -> Handle? {
        for (handle, box) in handleRects(for: rect) where !sidesOnly || handle == .left || handle == .right {
            if box.insetBy(dx: -4, dy: -4).contains(point) { return handle }
        }
        return nil
    }

    private func block(at point: CGPoint, in content: PageContent) -> TextBlock? {
        content.blocks.filter { $0.contains(point, tolerance: 1.5) }.min { $0.area < $1.area }
    }

    private func object(at point: CGPoint, in content: PageContent) -> ContentObject? {
        let tolerance = 3 / scale
        let hits = content.objects.filter { $0.bbox.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        // Images before artwork; the smallest (usually topmost) first; ignore full-page backgrounds.
        let crop = content.crop
        let meaningful = hits.filter { $0.kind.isImage || $0.area < crop.width * crop.height * 0.9 }
        return meaningful.filter(\.kind.isImage).min { $0.area < $1.area } ?? meaningful.min { $0.area < $1.area }
    }

    private func mark(at point: CGPoint, on page: PDFPage) -> RedactionMarkAnnotation? {
        page.annotations.reversed().compactMap { $0 as? RedactionMarkAnnotation }
            .first { $0.markRects.contains { $0.insetBy(dx: -2, dy: -2).contains(point) } }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let controller, let tool = controller.tool, let (page, point) = pageHit(event) else { return }
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        if let editor {
            let frame = editor.frame.insetBy(dx: -3, dy: -3)
            if let handle = handle(at: local, in: frame, sidesOnly: true) {
                drag = .editorResize(handle: handle, startX: local.x, originalWidth: editor.boxWidth)
                return
            }
            if CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 10).contains(local) {
                drag = .editorMove(start: local, originalOffset: editor.offset, originalOrigin: editor.frame.origin)
                return
            }
            controller.finishEditing(commit: true)
            return
        }
        switch tool {
        case .edit:
            mouseDownEdit(event, page: page, point: point, local: local)
        case .addText, .addImage, .link:
            if tool == .link, let index = controller.livePageIndex(page),
               let link = (controller.links[index] ?? []).last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
                controller.selectedLink = link
                controller.linkDraft = LinkDraft(page: index, rect: link.rect,
                                                 target: link.uri.map { .web($0) } ?? .page(link.destinationPage ?? 0), existing: link)
                needsDisplay = true
                showLinkEditor(on: page)
                return
            }
            drag = .marquee(page: page, start: point, current: point)
        case .crop:
            let index = controller.livePageIndex(page)
            if let rect = controller.cropRect, controller.cropPage == index {
                let viewCrop = viewRect(rect, on: page)
                if let handle = handle(at: local, in: viewCrop) {
                    drag = .crop(page: page, handle: handle, start: point, original: rect)
                    return
                }
                if viewCrop.contains(local) {
                    drag = .crop(page: page, handle: nil, start: point, original: rect)
                    return
                }
            }
            drag = .marquee(page: page, start: point, current: point)
        case .redact:
            if let mark = mark(at: point, on: page), !event.modifierFlags.contains(.option) {
                controller.selectedMark = mark
                needsDisplay = true
                return
            }
            controller.selectedMark = nil
            if !event.modifierFlags.contains(.option), page.characterIndex(at: point) != NSNotFound || isNearText(point, on: page) {
                drag = .textSelect(page: page, start: point, current: point)
                textSelection = nil
            } else {
                drag = .marquee(page: page, start: point, current: point)
            }
        }
        needsDisplay = true
    }

    private func isNearText(_ point: CGPoint, on page: PDFPage) -> Bool {
        guard let selection = page.selection(for: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)) else { return false }
        return !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func mouseDownEdit(_ event: NSEvent, page: PDFPage, point: CGPoint, local: CGPoint) {
        guard let controller else { return }
        guard let content = controller.content(for: page) else {
            controller.load(page)
            return
        }
        // Handles of the current selection.
        if controller.selectionPage === page, controller.selection?.isEmpty == false {
            let bounds = controller.selectionBounds(on: page)
            if !bounds.isNull {
                let rect = viewRect(bounds, on: page)
                if controller.isCroppingImage, let crop = controller.imageCropRect {
                    let viewCrop = viewRect(crop, on: page)
                    if let handle = handle(at: local, in: viewCrop) {
                        drag = .imageCrop(page: page, handle: handle, original: viewCrop)
                        return
                    }
                    controller.commitImageCrop()
                    return
                }
                let isBlock = controller.selection?.block != nil
                if let handle = handle(at: local, in: rect, sidesOnly: isBlock) {
                    drag = .resize(page: page, handle: handle, original: rect, current: rect)
                    return
                }
                if !isBlock, rect.contains(local), !event.modifierFlags.contains(.shift) {
                    beginMove(page: page, point: point)
                    return
                }
            }
        }
        if let block = block(at: point, in: content), !event.modifierFlags.contains(.shift) {
            controller.beginEditing(block, on: page, content: content, at: point)
            if let editor {
                // Place the caret (and track a drag selection) where the user clicked.
                editor.mouseDown(with: event)
            }
            return
        }
        if let object = object(at: point, in: content) {
            var ids = controller.selectionPage === page ? (controller.selection?.objects ?? []) : []
            if event.modifierFlags.contains(.shift) {
                if let i = ids.firstIndex(of: object.id) { ids.remove(at: i) } else { ids.append(object.id) }
            } else if !ids.contains(object.id) {
                ids = [object.id]
            }
            controller.select(block: nil, objects: ids, on: page, content: content)
            if !ids.isEmpty && !event.modifierFlags.contains(.shift) { beginMove(page: page, point: point) }
            return
        }
        if !event.modifierFlags.contains(.shift) { controller.clearSelection() }
        drag = .marquee(page: page, start: point, current: point)
    }

    private func beginMove(page: PDFPage, point: CGPoint) {
        drag = .move(page: page, start: point, current: point, didMove: false)
        ghost = nil
        if let controller {
            let bounds = controller.selectionBounds(on: page)
            if !bounds.isNull, let image = snapshot(of: bounds, on: page) { ghost = (image, bounds, page) }
        }
    }

    private func snapshot(of rect: CGRect, on page: PDFPage) -> NSImage? {
        let viewSize = viewRect(rect, on: page).size
        guard viewSize.width > 1, viewSize.height > 1, viewSize.width * viewSize.height < 16_000_000 else { return nil }
        let image = NSImage(size: viewSize)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            let box = page.bounds(for: .mediaBox)
            let visual = viewRect(rect, on: page)
            let pageInView = viewRect(box, on: page)
            context.translateBy(x: pageInView.minX - visual.minX, y: pageInView.minY - visual.minY)
            context.scaleBy(x: pageInView.width / box.width, y: pageInView.height / box.height)
            if page.rotation % 360 == 0 {
                context.translateBy(x: -box.minX, y: -box.minY)
                page.draw(with: .mediaBox, to: context)
            }
        }
        image.unlockFocus()
        return page.rotation % 360 == 0 ? image : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let drag else { return }
        let local = convert(event.locationInWindow, from: nil)
        switch drag {
        case .marquee(let page, let start, _):
            if let point = pagePoint(event, on: page) { self.drag = .marquee(page: page, start: start, current: point) }
        case .move(let page, let start, _, let didMove):
            if let point = pagePoint(event, on: page) {
                let a = viewPoint(start, on: page), b = viewPoint(point, on: page)
                let moved = didMove || hypot(a.x - b.x, a.y - b.y) > 3
                self.drag = .move(page: page, start: start, current: point, didMove: moved)
            }
        case .resize(let page, let handle, let original, _):
            var keepAspect = handle.isCorner && !event.modifierFlags.contains(.shift)
            if controller.selection?.block != nil { keepAspect = false }
            self.drag = .resize(page: page, handle: handle, original: original,
                                current: resized(original, handle: handle, to: local, keepAspect: keepAspect))
        case .textSelect(let page, let start, _):
            if let point = pagePoint(event, on: page) {
                self.drag = .textSelect(page: page, start: start, current: point)
                textSelection = page.selection(from: start, to: point)
            }
        case .crop(let page, let handle, let start, let original):
            guard let point = pagePoint(event, on: page) else { break }
            if let handle {
                let viewOriginal = viewRect(original, on: page)
                let rect = resized(viewOriginal, handle: handle, to: local, keepAspect: false)
                controller.cropRect = pageRect(rect, on: page).intersection(page.bounds(for: .cropBox))
            } else {
                var rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
                let bounds = page.bounds(for: .cropBox)
                rect.origin.x = min(max(rect.origin.x, bounds.minX), bounds.maxX - rect.width)
                rect.origin.y = min(max(rect.origin.y, bounds.minY), bounds.maxY - rect.height)
                controller.cropRect = rect
            }
        case .editorMove(let start, let originalOffset, let originalOrigin):
            guard let editor, let page = editor.page, let pdfView else { break }
            let delta = CGPoint(x: local.x - start.x, y: local.y - start.y)
            editor.setFrameOrigin(CGPoint(x: originalOrigin.x + delta.x, y: originalOrigin.y + delta.y))
            let p0 = pdfView.convert(convert(start, to: pdfView), to: page)
            let p1 = pdfView.convert(convert(local, to: pdfView), to: page)
            editor.offset = CGPoint(x: originalOffset.x + p1.x - p0.x, y: originalOffset.y + p1.y - p0.y)
        case .editorResize(let handle, let startX, let originalWidth):
            guard let editor else { break }
            let delta = (local.x - startX) / scale
            let width = max(20, handle == .right ? originalWidth + delta : originalWidth - delta)
            if handle == .left {
                // Keep the right edge fixed: shift the box by the width change.
                guard let page = editor.page, let pdfView else { break }
                let shiftView = CGPoint(x: (originalWidth - width) * scale, y: 0)
                let p0 = pdfView.convert(convert(CGPoint.zero, to: pdfView), to: page)
                let p1 = pdfView.convert(convert(shiftView, to: pdfView), to: page)
                editor.offset = CGPoint(x: editor.offset.x + (p1.x - p0.x) - (editorLeftShift ?? 0), y: editor.offset.y)
                editorLeftShift = p1.x - p0.x
            }
            editor.boxWidth = width
            editor.fixedWidth = true
            editor.isHorizontallyResizable = false
            positionEditor()
        case .imageCrop(let page, let handle, let original):
            let rect = resized(original, handle: handle, to: local, keepAspect: false)
            let image = viewRect(controller.selectionBounds(on: page), on: page)
            controller.imageCropRect = pageRect(rect.intersection(image), on: page)
        }
        needsDisplay = true
    }

    private var editorLeftShift: CGFloat?

    override func mouseUp(with event: NSEvent) {
        guard let controller, let drag else { return }
        self.drag = nil
        editorLeftShift = nil
        defer { ghost = nil; needsDisplay = true }
        switch drag {
        case .marquee(let page, let start, let current):
            finishMarquee(page: page, start: start, end: current, event: event)
        case .move(let page, let start, let current, let didMove):
            guard didMove else { return }
            let t = CGAffineTransform(translationX: current.x - start.x, y: current.y - start.y)
            _ = page
            controller.transformSelection(t, name: controller.selection?.block != nil ? "Move Text" : "Move Object")
        case .resize(let page, _, let original, let current):
            guard original.distance(to: current) > 1 else { return }
            let a = pageRect(original, on: page), b = pageRect(current, on: page)
            guard a.width > 0.01, a.height > 0.01 else { return }
            if let block = controller.selectedBlock(on: page) {
                // Text boxes reflow to the new width.
                let visualA = a.applying(page.visualTransform), visualB = b.applying(page.visualTransform)
                let width = max(12, block.width * Double(visualB.width / max(visualA.width, 0.01)))
                let dxVisual = visualB.minX - visualA.minX
                let shift = CGAffineTransform(translationX: dxVisual, y: 0).conjugated(by: page.visualTransform)
                controller.editBlock(block, on: page, transform: abs(dxVisual) > 0.01 ? shift : nil, width: width, name: "Resize Text")
                return
            }
            let t = CGAffineTransform(translationX: -a.minX, y: -a.minY)
                .concatenating(CGAffineTransform(scaleX: b.width / a.width, y: b.height / a.height))
                .concatenating(CGAffineTransform(translationX: b.minX, y: b.minY))
            controller.transformSelection(t, name: "Resize Object")
        case .textSelect(let page, let start, let current):
            var selection = textSelection
            textSelection = nil
            if start.distance(to: current) < 1.5 { selection = page.selectionForWord(at: start) }
            guard let selection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            controller.markSelection(selection)
        case .crop(let page, _, _, _):
            controller.cropPage = controller.livePageIndex(page)
        case .editorMove, .editorResize:
            positionEditor()
        case .imageCrop:
            break
        }
    }

    private func finishMarquee(page: PDFPage, start: CGPoint, end: CGPoint, event: NSEvent) {
        guard let controller, let tool = controller.tool else { return }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        let isClick = viewRect(rect, on: page).width < 4 && viewRect(rect, on: page).height < 4
        switch tool {
        case .edit:
            guard !isClick, let content = controller.content(for: page) else { return }
            let ids = content.objects.filter { rect.contains($0.bbox) }.map(\.id)
            var existing = event.modifierFlags.contains(.shift) && controller.selectionPage === page ? (controller.selection?.objects ?? []) : []
            existing += ids.filter { !existing.contains($0) }
            controller.select(block: nil, objects: existing, on: page, content: content)
        case .addText:
            if isClick {
                controller.beginNewText(on: page, at: start, width: nil)
            } else {
                let visual = rect.applying(page.visualTransform)
                let topLeftVisual = CGPoint(x: visual.minX, y: visual.maxY)
                controller.beginNewText(on: page, at: topLeftVisual.applying(page.visualTransform.inverted()), width: Double(visual.width))
            }
        case .addImage:
            controller.placeImage(on: page, rect: isClick ? CGRect(origin: start, size: .zero) : rect)
        case .link:
            guard !isClick, let index = controller.livePageIndex(page) else { return }
            controller.linkDraft = LinkDraft(page: index, rect: rect, target: .web("https://"), existing: nil)
            controller.selectedLink = nil
            needsDisplay = true
            showLinkEditor(on: page)
        case .crop:
            guard !isClick else { return }
            controller.cropRect = rect.intersection(page.bounds(for: .cropBox))
            controller.cropPage = controller.livePageIndex(page)
        case .redact:
            guard !isClick else { return }
            controller.addMark(on: page, rects: [rect])
        }
    }

    private func resized(_ rect: CGRect, handle: Handle, to point: CGPoint, keepAspect: Bool) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        var result = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 4), height: max(abs(maxY - minY), 4))
        if keepAspect, rect.width > 0, rect.height > 0 {
            let ratio = rect.width / rect.height
            if result.width / result.height > ratio { result.size.width = result.height * ratio } else { result.size.height = result.width / ratio }
            if [.topLeft, .bottomLeft].contains(handle) { result.origin.x = rect.maxX - result.width }
            if [.topLeft, .topRight].contains(handle) { result.origin.y = rect.minY }
            if [.bottomLeft, .bottomRight].contains(handle) { result.origin.y = rect.maxY - result.height }
        }
        return result
    }

    // MARK: - Hover & cursor

    override func mouseMoved(with event: NSEvent) {
        guard let controller, controller.isActive, let (page, point) = pageHit(event) else { return }
        var newBlock: (ObjectIdentifier, Int)?
        var newObject: String?
        var newMark: RedactionMarkAnnotation?
        switch controller.tool {
        case .edit?:
            if let content = controller.content(for: page) {
                if let block = block(at: point, in: content) { newBlock = (ObjectIdentifier(page), block.id) }
                else if let object = object(at: point, in: content) { newObject = object.id }
            } else {
                controller.load(page)
            }
        case .redact?:
            newMark = mark(at: point, on: page)
        default:
            break
        }
        let changed = newBlock.map { "\($0.0.hashValue)-\($0.1)" } != hoverBlock.map { "\($0.0.hashValue)-\($0.1)" }
            || newObject != hoverObject || newMark !== hoverMark
        hoverBlock = newBlock
        hoverObject = newObject
        hoverMark = newMark
        if changed { needsDisplay = true }
        updateCursor(event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverBlock = nil
        hoverObject = nil
        hoverMark = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        guard let controller, controller.isActive, let tool = controller.tool else { NSCursor.arrow.set(); return }
        let local = convert(event.locationInWindow, from: nil)
        if let editor, editor.frame.contains(local) { NSCursor.iBeam.set(); return }
        if let page = controller.selectionPage, controller.selection?.isEmpty == false, tool == .edit {
            let rect = viewRect(controller.selectionBounds(on: page), on: page)
            if let handle = handle(at: local, in: rect, sidesOnly: controller.selection?.block != nil) {
                (handle == .left || handle == .right ? NSCursor.resizeLeftRight
                 : handle == .top || handle == .bottom ? NSCursor.resizeUpDown : NSCursor.crosshair).set()
                return
            }
        }
        switch tool {
        case .edit:
            if hoverBlock != nil { NSCursor.iBeam.set() }
            else if hoverObject != nil { NSCursor.openHand.set() }
            else { NSCursor.arrow.set() }
        case .addText: NSCursor.iBeam.set()
        case .addImage, .crop, .link: NSCursor.crosshair.set()
        case .redact:
            if hoverMark != nil { NSCursor.pointingHand.set() }
            else if event.modifierFlags.contains(.option) { NSCursor.crosshair.set() }
            else if let (page, point) = pageHit(event), page.characterIndex(at: point) != NSNotFound { NSCursor.iBeam.set() }
            else { NSCursor.crosshair.set() }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let controller, controller.isActive else { super.keyDown(with: event); return }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            if let mark = controller.selectedMark { controller.removeMark(mark); return }
            if let link = controller.selectedLink, let draft = controller.linkDraft { controller.removeLink(link, page: draft.page); return }
            if controller.selection?.isEmpty == false { controller.deleteSelection(); return }
        case 53: // escape
            if drag != nil { drag = nil; textSelection = nil; needsDisplay = true; return }
            if controller.isCroppingImage { controller.cancelImageCrop(); return }
            if controller.selection != nil || controller.selectedMark != nil || controller.selectedLink != nil {
                controller.clearSelection(); return
            }
            if controller.cropRect != nil { controller.cropRect = nil; needsDisplay = true; return }
        case 36, 76: // return
            if controller.isCroppingImage { controller.commitImageCrop(); return }
            if let page = controller.selectionPage, let block = controller.selectedBlock(on: page),
               let content = controller.content(for: page) {
                controller.beginEditing(block, on: page, content: content, at: nil)
                return
            }
        case 123, 124, 125, 126: // arrows
            guard controller.selection?.isEmpty == false, let page = controller.selectionPage else { break }
            let step: CGFloat = shift ? 10 : 1
            var visual = CGPoint.zero
            switch event.keyCode {
            case 123: visual.x = -step
            case 124: visual.x = step
            case 125: visual.y = -step
            default: visual.y = step
            }
            // Visual direction → page space.
            let inverse = page.visualTransform.inverted()
            let origin = CGPoint.zero.applying(inverse)
            let moved = visual.applying(inverse)
            nudge.x += moved.x - origin.x
            nudge.y += moved.y - origin.y
            needsDisplay = true
            nudgeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    let delta = self.nudge
                    self.nudge = .zero
                    controller.transformSelection(CGAffineTransform(translationX: delta.x, y: delta.y),
                                                  name: controller.selection?.block != nil ? "Move Text" : "Move Object")
                }
            }
            nudgeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: - Inline editor

    func beginEditing(block: TextBlock, page: PDFPage, digest: String, at point: CGPoint?) {
        guard let controller else { return }
        let editor = InlineTextEditor(block: block, format: controller.format, width: CGFloat(block.width), fixedWidth: false)
        editor.page = page
        editor.digest = digest
        install(editor)
        if point == nil {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    func beginNewText(page: PDFPage, at point: CGPoint, width: Double?, format: TextFormat) {
        let editor = InlineTextEditor(block: nil, format: format, width: width.map { CGFloat($0) }, fixedWidth: width != nil)
        editor.page = page
        editor.newTextPoint = point
        install(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func install(_ editor: InlineTextEditor) {
        self.editor?.removeFromSuperview()
        self.editor = editor
        editor.onCancel = { [weak self] in self?.controller?.finishEditing(commit: false) }
        editor.onCommit = { [weak self] in self?.controller?.finishEditing(commit: true) }
        editor.onSelectionFormat = { [weak self] format in self?.controller?.format = format }
        addSubview(editor)
        positionEditor()
        window?.makeFirstResponder(editor)
        controller?.format = editor.currentFormat()
        needsDisplay = true
    }

    func editorDidChange() {
        positionEditor()
        needsDisplay = true
    }

    /// Keeps the editor over its block while scrolling and zooming.
    func positionEditor() {
        guard let editor, let page = editor.page, let pdfView, pdfView.document?.index(for: page) != NSNotFound else { return }
        let baseline = editor.firstBaselineOffset
        let topLeft: CGPoint
        if let block = editor.block {
            let local = CGPoint(x: 0, y: baseline).applying(block.frame)
            topLeft = viewPoint(CGPoint(x: local.x + editor.offset.x, y: local.y + editor.offset.y), on: page)
        } else if let point = editor.newTextPoint {
            topLeft = viewPoint(point, on: page)
        } else { return }
        editor.layout(originInView: topLeft, scale: scale)
    }
}
