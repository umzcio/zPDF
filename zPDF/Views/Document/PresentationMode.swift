import AppKit
import PDFKit
import QuartzCore
import SwiftUI

/// Full Screen Mode (⌘L): one page at a time on a plain background, on the
/// window's screen. Arrows, Space, Page Up/Down, Home/End and clicks move
/// between pages; Esc exits. Optional auto-advance and page transitions
/// (the document's own /Trans and /Dur, or a default from Settings).
@MainActor
final class PresentationController: NSObject {
    static let shared = PresentationController()
    private var window: NSWindow?
    private var pdfView: PresentationPDFView?
    private var timer: Timer?
    private weak var appState: AppState?
    private weak var tab: DocumentTab?
    private var navigation: NSHostingView<PresentationNavigationBar>?
    private var hideNavigation: DispatchWorkItem?
    private var pageObserver: NSObjectProtocol?

    var isActive: Bool { window != nil }

    func toggle(appState: AppState) {
        if isActive { exit() } else { enter(appState: appState) }
    }

    func enter(appState: AppState) {
        guard !isActive, let tab = appState.activeTab, let document = tab.pdfDocument, commitOK(appState) else { return }
        self.appState = appState
        self.tab = tab
        appState.features.readAloud.stop()
        let screen = appState.readingPresentation.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        let window = PresentationWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .mainMenu + 1
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.backgroundColor = appState.preferences.fullScreenBackground.color
        window.controller = self
        let view = PresentationPDFView(frame: NSRect(origin: .zero, size: frame.size))
        view.controller = self
        view.document = document
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = appState.preferences.fullScreenBackground.color
        view.pageShadowsEnabled = false
        view.wantsLayer = true
        DocumentDisplay.applyColors(to: view, mode: appState.preferences.documentColorMode, preferences: appState.preferences)
        if let page = document.page(at: tab.currentPage - 1) { view.go(to: page) }
        view.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(view)
        if appState.preferences.fullScreenShowNavigation {
            let bar = NSHostingView(rootView: PresentationNavigationBar(controller: self))
            bar.frame = NSRect(x: (frame.width - 320) / 2, y: 32, width: 320, height: 44)
            bar.autoresizingMask = [.minXMargin, .maxXMargin]
            bar.alphaValue = 0
            container.addSubview(bar)
            navigation = bar
        }
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.setHiddenUntilMouseMoves(true)
        self.window = window
        self.pdfView = view
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        }
        scheduleAdvance()
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: "Full screen mode. Press Escape to exit.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func commitOK(_ appState: AppState) -> Bool { appState.commitFieldEditing() }

    func exit() {
        timer?.invalidate()
        timer = nil
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        if let view = pdfView, let tab, let page = view.currentPage, let document = view.document, tab.pdfDocument === document {
            tab.goToPage(document.index(for: page) + 1)
        }
        window?.orderOut(nil)
        window = nil
        pdfView = nil
        navigation = nil
        appState?.readingPresentation.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Navigation

    func next() {
        guard let view = pdfView else { return }
        if view.canGoToNextPage { transition(forward: true) { view.goToNextPage(nil) } }
        else if appState?.preferences.fullScreenLoop == true, let first = view.document?.page(at: 0) {
            transition(forward: true) { view.go(to: first) }
        }
    }

    func previous() {
        guard let view = pdfView, view.canGoToPreviousPage else { return }
        transition(forward: false) { view.goToPreviousPage(nil) }
    }

    func first() { if let view = pdfView, let page = view.document?.page(at: 0) { transition(forward: false) { view.go(to: page) } } }
    func last() {
        if let view = pdfView, let document = view.document, let page = document.page(at: document.pageCount - 1) {
            transition(forward: true) { view.go(to: page) }
        }
    }

    var pageLabel: String {
        guard let view = pdfView, let document = view.document, let page = view.currentPage else { return "" }
        return "\(document.index(for: page) + 1) of \(document.pageCount)"
    }

    func mouseMoved() {
        guard let navigation else { return }
        hideNavigation?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; navigation.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak navigation] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; navigation?.animator().alphaValue = 0 }
        }
        hideNavigation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func clicked() {
        if appState?.preferences.fullScreenClickAdvances == true { next() }
    }

    private func pageChanged() {
        navigation?.rootView = PresentationNavigationBar(controller: self)
        scheduleAdvance()
    }

    private func scheduleAdvance() {
        timer?.invalidate()
        timer = nil
        guard let appState, let view = pdfView, let page = view.currentPage else { return }
        let seconds = Self.pageDuration(page) ?? (appState.preferences.fullScreenAdvance ? appState.preferences.fullScreenAdvanceSeconds : nil)
        guard let seconds, seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
    }

    private func transition(forward: Bool, _ change: () -> Void) {
        guard let appState, let view = pdfView, let layer = view.layer else { change(); return }
        let reduceMotion = appState.preferences.accessibilityOptions(system: SystemAccessibility.shared.options).reduceMotion
        let target: PDFPage? = {
            guard let document = view.document, let current = view.currentPage else { return nil }
            let index = document.index(for: current) + (forward ? 1 : -1)
            return document.page(at: max(0, min(document.pageCount - 1, index)))
        }()
        var style = appState.preferences.fullScreenTransition
        var duration = 0.4
        if appState.preferences.fullScreenUseDocumentTransitions, let target, let documentStyle = Self.documentTransition(target) {
            style = documentStyle.style
            duration = documentStyle.duration
        }
        if style != .none && !reduceMotion {
            let transition = CATransition()
            transition.duration = duration
            switch style {
            case .dissolve: transition.type = .fade
            case .push: transition.type = .push
            case .wipe: transition.type = .reveal
            case .moveIn: transition.type = .moveIn
            case .reveal: transition.type = .reveal
            case .none: break
            }
            transition.subtype = forward ? .fromRight : .fromLeft
            layer.add(transition, forKey: "pageTransition")
        }
        change()
    }

    /// /Dur (seconds) from the page dictionary.
    static func pageDuration(_ page: PDFPage) -> Double? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        var value: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(dictionary, "Dur", &value) && value > 0 ? Double(value) : nil
    }

    /// Maps the page's /Trans style onto a Core Animation transition.
    static func documentTransition(_ page: PDFPage) -> (style: PageTransitionStyle, duration: Double)? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        var trans: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Trans", &trans), let trans else { return nil }
        var name: UnsafePointer<CChar>?
        var style: PageTransitionStyle = .dissolve
        if CGPDFDictionaryGetName(trans, "S", &name), let name {
            switch String(cString: name) {
            case "R": style = .none
            case "Dissolve", "Fade", "Glitter": style = .dissolve
            case "Push": style = .push
            case "Wipe", "Split", "Blinds", "Box": style = .wipe
            case "Cover", "Fly": style = .moveIn
            case "Uncover": style = .reveal
            default: style = .dissolve
            }
        }
        var duration: CGPDFReal = 1
        _ = CGPDFDictionaryGetNumber(trans, "D", &duration)
        return (style, Double(max(0.1, min(5, duration))))
    }
}

private final class PresentationWindow: NSWindow {
    weak var controller: PresentationController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { controller?.exit() }
}

/// The page view: keyboard and click navigation only (no editing).
final class PresentationPDFView: PDFView {
    weak var controller: PresentationController?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.exit()
        case 124, 125, 121, 49, 36:
            if event.keyCode == 49 && event.modifierFlags.contains(.shift) { controller?.previous() } else { controller?.next() }
        case 123, 126, 116, 51: controller?.previous()
        case 115: controller?.first()
        case 119: controller?.last()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Links still work; other clicks advance when enabled in Settings.
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false), page.annotation(at: convert(point, to: page))?.type == "Link" {
            super.mouseDown(with: event)
            return
        }
        controller?.clicked()
    }

    override func rightMouseDown(with event: NSEvent) { controller?.previous() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.mouseMoved()
    }
}

struct PresentationNavigationBar: View {
    let controller: PresentationController

    var body: some View {
        HStack(spacing: 14) {
            Button { controller.previous() } label: { Image(systemName: "chevron.left") }
                .help("Previous page (←)").accessibilityLabel("Previous page")
            Text(controller.pageLabel).monospacedDigit().font(.system(size: 12))
            Button { controller.next() } label: { Image(systemName: "chevron.right") }
                .help("Next page (→)").accessibilityLabel("Next page")
            Divider().frame(height: 18)
            Button { controller.exit() } label: { Label("Exit", systemImage: "xmark") }
                .help("Exit full screen mode (Esc)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.black.opacity(0.6), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}
