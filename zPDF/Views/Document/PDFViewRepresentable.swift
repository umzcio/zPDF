//
//  PDFViewRepresentable.swift
//  zPDF
//
//  Purpose: NSViewRepresentable wrapper around PDFKit's PDFView — the single
//  AppKit interop point for the page canvas. Syncs document, displayMode,
//  scaleFactor, and current page from DocumentTab; reports user-driven page
//  changes back via onPageChanged. Publishes the PDFView into PDFViewStore
//  so the sidebar thumbnails and toolbar fit-controls can reach it.
//  Also hosts armed-annotation interaction (phase 2): markup tools convert
//  the current text selection, point tools (note/text box/stamp) place on
//  click, and the drawing tool drags out an ink path — all routed through
//  AppState.armedAnnotationTool by AnnotationCanvasView + Coordinator.
//  Armed form-field placement (phase 3) uses the same mouse-down
//  hit-testing: Prepare Form's add-field tools drop a widget PDFAnnotation
//  at the click point via AppState.armedFormFieldTool.
//  Content editing and redaction canvas tools are handled by
//  ContentEditOverlay (a subview installed by ContentEditingController).
//  Phase: 1–4 — REAL.
//

import PDFKit
import SwiftUI

/// Plain reference box for the live PDFView. Not observable on purpose:
/// consumers read it imperatively (thumbnails, fit-width math, signature
/// placement).
final class PDFViewStore {
    // Keep the viewer available to PDFThumbnailView while the organizer replaces
    // the on-screen canvas. Replaced by the next canvas; released on last close.
    var pdfView: PDFView?

    @MainActor
    func restoreReadingPosition(for tab: DocumentTab) {
        guard let pdfView, pdfView.document === tab.pdfDocument,
              let page = tab.pdfDocument?.page(at: tab.currentPage - 1) else { return }
        pdfView.displayMode = tab.viewMode.pdfDisplayMode
        pdfView.scaleFactor = CGFloat(tab.zoomFactor)
        pdfView.layoutDocumentView()
        pdfView.go(to: page)
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    let document: PDFDocument?
    let displayMode: PDFDisplayMode
    let scaleFactor: Double
    /// 1-based page number (DocumentTab.currentPage).
    let pageNumber: Int
    var pageRevision: Int = 0
    let viewStore: PDFViewStore
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, onPageChanged: onPageChanged)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = AnnotationCanvasView()
        // File opens must go through AppState, including policy and baseline.
        pdfView.acceptsDraggedFiles = false
        pdfView.annotationCoordinator = context.coordinator
        pdfView.onNavigatePage = { [weak appState] direction in appState?.navigatePage(direction) }
        pdfView.allowsSaveEdits = appState.activeTab?.allowsSaveEdits ?? true
        pdfView.autoScales = false
        pdfView.displayMode = displayMode
        pdfView.displaysPageBreaks = appState.preferences.showPageGaps
        pdfView.formHighlights.enabled = appState.preferences.highlightFormFields
        pdfView.pageOverlayViewProvider = pdfView.formHighlights
        pdfView.backgroundColor = NSColor(DesignTokens.Colors.canvasBackground)
        pdfView.delegate = context.coordinator
        pdfView.setDisplayedDocument(document)
        context.coordinator.observe(pdfView)
        viewStore.pdfView = pdfView
        appState.comments.canvas.attach(to: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.synchronizingView = true
        defer { context.coordinator.synchronizingView = false }
        pdfView.displaysPageBreaks = appState.preferences.showPageGaps
        if let canvas = pdfView as? AnnotationCanvasView {
            canvas.formHighlights.enabled = appState.preferences.highlightFormFields
        }
        // Resolve in this window’s appearance, including live system changes.
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? pdfView.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            pdfView.backgroundColor = NSColor.underPageBackgroundColor.usingColorSpace(.deviceRGB) ?? .underPageBackgroundColor
        }
        (pdfView as? AnnotationCanvasView)?.allowsSaveEdits = appState.activeTab?.allowsSaveEdits ?? true
        if pdfView.document !== document {
            (pdfView as? AnnotationCanvasView)?.setDisplayedDocument(document)
        }
        if pdfView.displayMode != displayMode {
            pdfView.displayMode = displayMode
        }
        let clampedScale = ZoomController.clamp(scaleFactor)
        if abs(Double(pdfView.scaleFactor) - clampedScale) > 0.001 {
            pdfView.scaleFactor = CGFloat(clampedScale)
        }
        if context.coordinator.pageRevision != pageRevision {
            context.coordinator.pageRevision = pageRevision
            pdfView.layoutDocumentView()
        }
        syncPage(in: pdfView)
        context.coordinator.onPageChanged = onPageChanged
        if let tab = appState.activeTab, let initialZoom = tab.pendingInitialZoom {
            DispatchQueue.main.async { [weak pdfView, weak tab] in
                guard let pdfView, let tab, pdfView.document === tab.pdfDocument,
                      tab.pendingInitialZoom == initialZoom,
                      pdfView.bounds.width > 0, pdfView.bounds.height > 0 else { return }
                pdfView.layoutDocumentView()
                let zoom: Double
                switch initialZoom {
                case .actualSize: zoom = 1
                case .fitPage:
                    guard let size = tab.currentPageSize else { return }
                    let width = tab.viewMode == .facing ? size.width * 2 : size.width
                    zoom = ZoomController.fitPageScale(pageSize: CGSize(width: width, height: size.height), viewportSize: pdfView.bounds.size)
                case .fitWidth:
                    guard let size = tab.currentPageSize else { return }
                    let width = tab.viewMode == .facing ? size.width * 2 : size.width
                    zoom = ZoomController.fitWidthScale(pageSize: CGSize(width: width, height: size.height), viewportWidth: pdfView.bounds.width)
                }
                tab.viewHistory.isRestoring = true
                tab.pendingInitialZoom = nil
                tab.setZoom(zoom)
                tab.viewHistory.isRestoring = false
            }
        }
        viewStore.pdfView = pdfView
    }

    private func syncPage(in pdfView: PDFView) {
        guard let document = pdfView.document, document.pageCount > 0 else { return }
        let currentNumber: Int
        if let currentPage = pdfView.currentPage {
            currentNumber = document.index(for: currentPage) + 1
        } else {
            currentNumber = 1
        }
        guard currentNumber != pageNumber,
              let target = document.page(at: pageNumber - 1) else { return }
        pdfView.go(to: target)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        (nsView as? AnnotationCanvasView)?.restoreAnnotationPermissions()
        coordinator.invalidate()
    }

    // MARK: - Coordinator

    /// PDFView UI notifications and interaction are confined to the main actor.
    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        let appState: AppState
        var synchronizingView = false
        var onPageChanged: (Int) -> Void
        var pageRevision = -1
        private var observers: [NSObjectProtocol] = []
        private var editMonitor: Any?

        init(appState: AppState, onPageChanged: @escaping (Int) -> Void) {
            self.appState = appState
            self.onPageChanged = onPageChanged
        }

        func observe(_ pdfView: PDFView) {
            let center = NotificationCenter.default
            let pageObserver = center.addObserver(forName: .PDFViewPageChanged,
                                                  object: pdfView,
                                                  queue: .main) { [weak self] notification in
                // The observed object IS the PDFView — no cross-region capture.
                guard let pdfView = notification.object as? PDFView else { return }
                MainActor.assumeIsolated { self?.recordViewState(from: pdfView, zoomChanged: false) }
            }
            observers.append(pageObserver)
            observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] notification in
                guard let pdfView = notification.object as? PDFView else { return }
                MainActor.assumeIsolated { self?.recordViewState(from: pdfView, zoomChanged: true) }
            })
            let selectionObserver = center.addObserver(forName: .PDFViewSelectionChanged,
                                                       object: pdfView,
                                                       queue: .main) { [appState] _ in
                // AppState is @MainActor (implicitly Sendable) — safe capture.
                MainActor.assumeIsolated {
                    // Applies only when a markup tool is armed and the mouse
                    // is up (keyboard/menus), or after disarm — no-op else.
                    appState.applyArmedMarkupTool()
                }
            }
            observers.append(selectionObserver)
            // PDFKit's field editor can hold text before committing it to the
            // widget. Mark that work immediately, then reconcile on commit.
            for name in [NSText.didChangeNotification, NSText.didEndEditingNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [appState, weak pdfView] notification in
                    guard let editor = notification.object as? NSTextView else { return }
                    let isTextChange = notification.name == NSText.didChangeNotification
                    MainActor.assumeIsolated {
                        guard let view = pdfView,
                              editor.isDescendant(of: view)
                                || (editor.delegate as? NSView)?.isDescendant(of: view) == true,
                              let tab = appState.tabs.first(where: { $0.pdfDocument === view.document }) else { return }
                        if isTextChange {
                            tab.hasUncommittedFieldEdit = true
                            tab.hasUnsavedChanges = true
                        } else {
                            Task { @MainActor in
                                tab.hasUncommittedFieldEdit = false
                                appState.refreshUnsavedChanges(tab)
                            }
                        }
                    }
                })
            }
            // Checkbox/radio clicks and keyboard actions may bypass NSText.
            // Reconcile after PDFKit handles the event, without periodic polling.
            editMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [appState, weak pdfView] event in
                let eventWindow = event.window
                MainActor.assumeIsolated {
                    if let view = pdfView, eventWindow === view.window,
                       let tab = appState.tabs.first(where: { $0.pdfDocument === view.document }) {
                        Task { @MainActor in appState.refreshUnsavedChanges(tab) }
                    }
                }
                return event
            }
        }

        @MainActor
        func recordViewState(from pdfView: PDFView, zoomChanged: Bool) {
            guard !synchronizingView, !appState.readingPresentation.isTransitioning,
                  let document = pdfView.document,
                  let tab = appState.tabs.first(where: { $0.pdfDocument === document }) else { return }
            // Scroll and pinch notifications can arrive on every frame; keep
            // the start and end of a gesture, rather than flooding Back history.
            tab.viewHistory.coalescesNotifications = true
            defer { tab.viewHistory.coalescesNotifications = false }
            if zoomChanged {
                tab.pendingInitialZoom = nil
                tab.setZoom(Double(pdfView.scaleFactor))
            } else if let page = pdfView.currentPage {
                tab.goToPage(document.index(for: page) + 1)
            }
            appState.rememberReadingState(tab)
        }

        func invalidate() {
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
            observers.removeAll()
            if let editMonitor { NSEvent.removeMonitor(editMonitor) }
            editMonitor = nil
        }

        isolated deinit {
            // Best-effort cleanup; dismantleNSView calls invalidate() first.
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
            if let editMonitor { NSEvent.removeMonitor(editMonitor) }
        }

        // MARK: - Armed annotation interaction (phase 2)

        /// Returns true when the event was consumed by an armed tool.
        /// Called from AnnotationCanvasView.mouseDown (main thread).
        @MainActor
        func beginAnnotationInteraction(with event: NSEvent, in pdfView: PDFView) -> Bool {
            guard appState.activeTab?.allowsSaveEdits == true,
                  appState.activeTab?.pdfDocument === pdfView.document else { return false }
            // Content editing and redaction tools own the canvas through
            // ContentEditOverlay; PDFView keeps its own behavior otherwise.
            if appState.textEditingModeActive { return false }
            // An armed Prepare Form tool places a widget and consumes the
            // click (phase 3).
            if let fieldKind = appState.armedFormFieldTool {
                guard let document = pdfView.document else { return false }
                let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
                guard let page = pdfView.page(for: viewPoint, nearest: true) else { return false }
                let pagePoint = pdfView.convert(viewPoint, to: page)
                placeFormField(fieldKind, at: pagePoint, on: page, in: document)
                return true
            }
            // Comment tools and comment selection (CommentCanvasController).
            return appState.comments.canvas.mouseDown(event, in: pdfView)
        }

        /// Continues a comment gesture. Returns true while one is in progress.
        @MainActor
        func continueAnnotationInteraction(with event: NSEvent, in pdfView: PDFView) -> Bool {
            appState.comments.canvas.mouseDragged(event, in: pdfView)
        }

        /// Finishes a comment gesture (shape, stroke, move, resize).
        @MainActor
        func endAnnotationInteraction(with event: NSEvent, in pdfView: PDFView) -> Bool {
            appState.comments.canvas.mouseUp(event, in: pdfView)
        }

        /// Context menu for a comment under the pointer.
        @MainActor
        func commentMenu(for event: NSEvent, in pdfView: PDFView) -> NSMenu? {
            guard appState.activeTab?.pdfDocument === pdfView.document else { return nil }
            return appState.comments.canvas.menu(for: event, in: pdfView)
        }

        /// Called by AnnotationCanvasView after mouse-up so a finished drag
        /// selection applies an armed markup tool.
        @MainActor
        func applyArmedMarkupTool() {
            appState.applyArmedMarkupTool()
        }

        // MARK: - Armed form-field placement (phase 3)

        /// Places a widget annotation of the armed Prepare Form kind at the
        /// click point with a unique field name, then disarms the tool.
        @MainActor
        private func placeFormField(_ kind: DetectedFormField.Kind,
                                    at point: CGPoint,
                                    on page: PDFPage,
                                    in document: PDFDocument) {
            let widget = kind.makeWidget(at: point,
                                         named: uniqueFieldName(for: kind, in: document),
                                         on: page)
            page.addAnnotation(widget)
            appState.armedFormFieldTool = nil
            appState.noteAnnotationsChanged()
        }

        /// "Kind N" field names, skipping every widget fieldName already
        /// present in the document (renamed fields simply free their slot).
        private func uniqueFieldName(for kind: DetectedFormField.Kind,
                                     in document: PDFDocument) -> String {
            var existing: Set<String> = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where annotation.type == "Widget" {
                    if let name = annotation.fieldName {
                        existing.insert(name)
                    }
                }
            }
            var counter = 1
            while existing.contains("\(kind.displayName) \(counter)") {
                counter += 1
            }
            return "\(kind.displayName) \(counter)"
        }
    }
}

/// PDFView subclass that routes mouse events to the armed annotation tool
/// before falling back to PDFView's own selection/scrolling behavior.
/// Defined here because Views/Document/*Representable.swift is the only
/// place allowed to touch PDFView directly (see README conventions).
final class AnnotationCanvasView: PDFView {
    let formHighlights = FormFieldHighlightProvider()
    weak var annotationCoordinator: PDFViewRepresentable.Coordinator?
    var onNavigatePage: ((PageNavigation) -> Void)?
    private var readingKeyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let readingKeyMonitor { NSEvent.removeMonitor(readingKeyMonitor) }
        readingKeyMonitor = nil
        guard window != nil else { return }
        readingKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers local event monitors on the main thread.
            nonisolated(unsafe) let localEvent = event
            let handled = MainActor.assumeIsolated { self?.handleReadingKey(localEvent) == true }
            return handled ? nil : event
        }
    }

    isolated deinit {
        if let readingKeyMonitor { NSEvent.removeMonitor(readingKeyMonitor) }
    }

    /// Only the canvas/scroll surface owns reading keys. PDFKit field editors,
    /// widget controls, text selections with modifiers, and all sidebar/search
    /// controls receive their original events without interception.
    func ownsReadingKeys(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSText || responder is NSControl { return false }
        return responder === self || responder === documentView
            || responder === documentView?.enclosingScrollView
            || responder === documentView?.enclosingScrollView?.contentView
    }

    func handleReadingKey(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow,
              event.window == nil || event.window === window else { return false }
        return handleReadingKey(code: event.keyCode, modifiers: event.modifierFlags,
                                responder: window.firstResponder)
    }

    func handleReadingKey(code: UInt16, modifiers: NSEvent.ModifierFlags, responder: NSResponder?) -> Bool {
        if [36, 76].contains(code),
           modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
           let editor = responder as? NSTextView,
           singleLineWidget(for: editor) != nil {
            // PDFKit's editor can insert a newline even when the AcroForm
            // widget is single-line. Commit through its normal responder path
            // instead; never silently strip text at Save time.
            return window?.makeFirstResponder(self) == true
        }
        guard ownsReadingKeys(responder),
              modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              document != nil else { return false }
        switch code {
        case 123: onNavigatePage?(.previous)
        case 124: onNavigatePage?(.next)
        case 115: onNavigatePage?(.first)
        case 119: onNavigatePage?(.last)
        case 126: scrollReadingView(forward: false, screen: false)
        case 125: scrollReadingView(forward: true, screen: false)
        case 116: scrollReadingView(forward: false, screen: true)
        case 121: scrollReadingView(forward: true, screen: true)
        default: return false
        }
        return true
    }

    func singleLineWidget(for editor: NSTextView) -> PDFAnnotation? {
        guard allowsSaveEdits, editor.isDescendant(of: self) else { return nil }
        let visible = convert(editor.bounds, from: editor)
        let center = CGPoint(x: visible.midX, y: visible.midY)
        guard let page = page(for: center, nearest: false) else { return nil }
        let pageRect = convert(visible, to: page)
        let candidates = page.annotations.filter {
            $0.type == "Widget" && $0.widgetFieldType == .text && !$0.isMultiline && !$0.isReadOnly
                && $0.bounds.insetBy(dx: -3, dy: -3).contains(pageRect)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func scrollReadingView(forward: Bool, screen: Bool) {
        guard let documentView, let scroll = documentView.enclosingScrollView else { return }
        let clip = scroll.contentView
        let distance = screen ? clip.bounds.height * 0.9 : 40
        let direction: CGFloat = (forward == documentView.isFlipped) ? 1 : -1
        let original = clip.bounds.origin
        let candidate = NSRect(origin: NSPoint(x: original.x, y: original.y + direction * distance),
                               size: clip.bounds.size)
        let target = clip.constrainBoundsRect(candidate).origin
        if abs(target.y - original.y) < 0.5, screen {
            onNavigatePage?(forward ? .next : .previous)
        } else {
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
    }

    // Lock PDFKit's interactive annotations, not scrolling/selection/navigation.
    // These presentation flags never enter the native Save payload.
    private var lockedAnnotations: [(PDFAnnotation, Bool, Int)] = []
    var allowsSaveEdits = true {
        didSet { if oldValue != allowsSaveEdits { updateAnnotationPermissions() } }
    }

    // PDFKit's own background form analyzer reads the Objective-C document
    // getter. Overriding that property in this main-actor subclass synthesizes
    // an executor assertion even for the getter, crashing during analysis.
    // Keep the inherited getter; our document assignments are explicitly main-actor.
    func setDisplayedDocument(_ document: PDFDocument?) {
        restoreAnnotationPermissions()
        self.document = document
        updateAnnotationPermissions()
        formHighlights.refresh()
    }

    func restoreAnnotationPermissions() {
        for (annotation, readOnly, flags) in lockedAnnotations {
            if annotation.type == "Widget" { annotation.isReadOnly = readOnly }
            annotation.setValue(flags, forAnnotationKey: .flags)
        }
        let pages = lockedAnnotations.compactMap { $0.0.page }
        lockedAnnotations.removeAll()
        var refreshed = Set<ObjectIdentifier>()
        for page in pages where refreshed.insert(ObjectIdentifier(page)).inserted { annotationsChanged(on: page) }
    }

    private func updateAnnotationPermissions() {
        defer { formHighlights.refresh() }
        restoreAnnotationPermissions()
        guard !allowsSaveEdits, let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type != "Link" {
                let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
                lockedAnnotations.append((annotation, annotation.isReadOnly, flags))
                if annotation.type == "Widget" { annotation.isReadOnly = true }
                annotation.setValue(flags | 64, forAnnotationKey: .flags)
            }
            annotationsChanged(on: page)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if allowsSaveEdits, annotationCoordinator?.beginAnnotationInteraction(with: event, in: self) == true { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if allowsSaveEdits, annotationCoordinator?.continueAnnotationInteraction(with: event, in: self) == true { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if allowsSaveEdits, annotationCoordinator?.endAnnotationInteraction(with: event, in: self) == true { return }
        super.mouseUp(with: event)
        if allowsSaveEdits { annotationCoordinator?.applyArmedMarkupTool() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        annotationCoordinator?.commentMenu(for: event, in: self) ?? super.menu(for: event)
    }
}

/// Non-interactive screen overlays: highlighting never changes an annotation's
/// color, flags, appearance stream, or the printed/saved document.
@MainActor
final class FormFieldHighlightProvider: NSObject, PDFPageOverlayViewProvider {
    var enabled = true { didSet { if oldValue != enabled { refresh() } } }
    private let overlays = NSHashTable<FormFieldHighlightView>.weakObjects()

    func refresh() {
        for overlay in overlays.allObjects {
            overlay.isHidden = !enabled
            overlay.needsDisplay = true
        }
    }

    nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // PDFKit's imported protocol lacks actor annotations. Never construct
        // AppKit views if a background rendering path asks for an overlay.
        guard Thread.isMainThread else { return nil }
        // The foreign protocol does not express its UI callback isolation.
        // This page is used synchronously on the verified calling main thread.
        nonisolated(unsafe) let mainThreadPage = page
        return MainActor.assumeIsolated {
            let overlay = FormFieldHighlightView()
            overlay.pdfView = view
            overlay.page = mainThreadPage
            overlay.isHidden = !enabled
            overlay.setAccessibilityElement(false)
            overlays.add(overlay)
            return overlay
        }
    }
}

@MainActor
final class FormFieldHighlightView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let page else { return }
        for field in page.annotations where field.type == "Widget" && field.shouldDisplay && !field.isReadOnly {
            let rect = convert(pdfView.convert(field.bounds, from: page), from: pdfView)
            guard rect.intersects(dirtyRect) else { continue }
            // A fixed display-only blue avoids confusing interface accent with
            // document color and remains visible on white forms in either theme.
            NSColor(srgbRed: 0.12, green: 0.4, blue: 0.9, alpha: 0.12).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(srgbRed: 0.12, green: 0.4, blue: 0.9, alpha: 0.6).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}
