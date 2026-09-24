import AppKit
import SwiftUI

/// Native fullscreen is a reversible reading presentation, not document state.
@MainActor
@Observable
final class ReadingPresentationState {
    private(set) var isActive = false
    private(set) var isTransitioning = false
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var saved: Panels?
    @ObservationIgnored private var transitionLocation: (tabID: UUID, location: DocumentViewLocation)?

    /// PDFKit reports different visible pages while AppKit resizes its canvas.
    /// Those are layout artifacts, not reading navigation.
    func prepareTransition(_ state: AppState) {
        guard let tab = state.activeTab else { return }
        transitionLocation = (tab.id, tab.viewLocation)
        isTransitioning = true
    }

    func finishTransition(_ state: AppState) {
        defer { transitionLocation = nil; isTransitioning = false }
        guard let saved = transitionLocation, let tab = state.activeTab,
              tab.id == saved.tabID else { return }
        tab.restoreViewLocation(saved.location)
        state.pdfViewStore.restoreReadingPosition(for: tab)
    }

    private struct Panels {
        var tabID: UUID?
        var sidebar: Bool
        var tool: InspectorPanel?
        var documentPanel: DocumentPanel?
        var annotation: AnnotationTool?
        var form: DetectedFormField.Kind?
        var textEditing: Bool
        var rail: RailDestination
    }

    func capture(_ state: AppState) {
        guard !isActive else { return }
        saved = Panels(tabID: state.activeTabID, sidebar: state.sidebarVisible,
                       tool: state.activePanel, documentPanel: state.documentPanel,
                       annotation: state.armedAnnotationTool, form: state.armedFormFieldTool,
                       textEditing: state.textEditingModeActive, rail: state.railSelection)
    }

    func begin(_ state: AppState) {
        guard !isActive, state.activeTab != nil else { return }
        if saved == nil { capture(state) }
        isActive = true
        state.sidebarVisible = false
        state.documentPanel = nil
        state.activePanel = nil
        state.armedAnnotationTool = nil
        state.armedFormFieldTool = nil
        state.textEditingModeActive = false
        state.railSelection = .document
    }

    func end(_ state: AppState) {
        guard let saved, isActive else { self.saved = nil; return }
        // Restore visibility while isActive still suppresses preference writes.
        state.sidebarVisible = saved.sidebar
        state.documentPanel = saved.documentPanel
        if state.activeTabID == saved.tabID {
            state.activePanel = saved.tool
            state.armedAnnotationTool = saved.annotation
            state.armedFormFieldTool = saved.form
            state.textEditingModeActive = saved.textEditing
            state.railSelection = saved.rail
        }
        self.saved = nil
        isActive = false
    }
}

extension AppState {
    func toggleReadingFullScreen() {
        guard let window = readingPresentation.window,
              window.attachedSheet == nil,
              activeTab != nil, commitFieldEditing() else { return }
        window.toggleFullScreen(nil)
    }
}

/// Observes the real window, so the green titlebar control and View menu share
/// exactly the same restoration path. It never replaces SwiftUI's delegate.
struct ReadingPresentationHost: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> HostView { HostView(appState: appState) }
    func updateNSView(_ nsView: HostView, context: Context) {}

    @MainActor
    final class HostView: NSView {
        private let appState: AppState
        private var observers: [NSObjectProtocol] = []
        private var escapeMonitor: Any?
        private var transitionCompletion: DispatchWorkItem?
        private var transitionFallback: DispatchWorkItem?

        init(appState: AppState) {
            self.appState = appState
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                close()
                appState.readingPresentation.window = nil
                return
            }
            appState.readingPresentation.window = window
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.capture() }
                },
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.begin() }
                },
                center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.prepareTransition() }
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.end() }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                }
            ]
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let localEvent = event
                let consumed = MainActor.assumeIsolated { self?.handleEscape(localEvent) ?? false }
                return consumed ? nil : event
            }
        }

        private func capture() {
            appState.readingPresentation.capture(appState)
            prepareTransition()
        }

        private func prepareTransition() {
            transitionCompletion?.cancel()
            transitionFallback?.cancel()
            appState.readingPresentation.prepareTransition(appState)
            // AppKit exposes failure via delegate methods, not notifications.
            // Keep SwiftUI's delegate intact, but never leave reading updates
            // suspended if a native fullscreen transition fails.
            let fallback = DispatchWorkItem { [weak self] in self?.finishTransition() }
            transitionFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fallback)
        }

        private func begin() {
            appState.readingPresentation.begin(appState)
            settleTransition()
        }

        private func end() {
            appState.readingPresentation.end(appState)
            settleTransition()
        }

        private func close() {
            transitionCompletion?.cancel()
            transitionFallback?.cancel()
            appState.readingPresentation.end(appState)
            appState.readingPresentation.finishTransition(appState)
        }

        private func settleTransition() {
            transitionCompletion?.cancel()
            transitionFallback?.cancel()
            // The didEnter/didExit notification precedes SwiftUI's layout of
            // the newly hidden/restored panels. Restore against that layout.
            let completion = DispatchWorkItem { [weak self] in self?.finishTransition() }
            transitionCompletion = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: completion)
        }

        private func finishTransition() {
            window?.contentView?.layoutSubtreeIfNeeded()
            appState.readingPresentation.finishTransition(appState)
        }

        private func handleEscape(_ event: NSEvent) -> Bool {
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let window, window.isKeyWindow, window.attachedSheet == nil,
                  window.styleMask.contains(.fullScreen), appState.readingPresentation.isActive,
                  event.window == nil || event.window === window,
                  let canvas = appState.pdfViewStore.pdfView as? AnnotationCanvasView,
                  canvas.ownsReadingKeys(window.firstResponder)
                    || window.firstResponder === window else { return false }
            window.toggleFullScreen(nil)
            return true
        }

        private func removeObservers() {
            transitionCompletion?.cancel()
            transitionFallback?.cancel()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }

        isolated deinit {
            transitionCompletion?.cancel()
            transitionFallback?.cancel()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }
    }
}
