import AppKit
import SwiftUI

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var appState: AppState? {
        didSet {
            guard appState != nil else { return }
            let urls = pendingURLs
            pendingURLs.removeAll()
            appState?.restorePreviousSession()
            urls.forEach { appState?.openDocument(at: $0) }
        }
    }
    var showMainWindow: (() -> Void)?
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow?()
        if let appState { urls.forEach { appState.openDocument(at: $0) } }
        else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow?()
        return true
    }

    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        appState.requestCloseAll(preserveSession: true) { [weak self] allowed in
            Task { @MainActor in
                self?.terminationPending = false
                sender.reply(toApplicationShouldTerminate: allowed)
            }
        }
        return .terminateLater
    }
}

/// Guard the title-bar close button too. Preserve SwiftUI's other window
/// delegate callbacks instead of taking over window lifecycle behavior.
struct WindowCloseGuard: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> GuardView { GuardView(appState: appState) }
    func updateNSView(_ view: GuardView, context: Context) {}

    final class GuardView: NSView {
        let closeDelegate: CloseDelegate
        init(appState: AppState) {
            closeDelegate = CloseDelegate(appState: appState)
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI finishes configuring its window delegate after attaching
            // the content view. Interposing during attachment breaks opening.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      window.delegate !== self.closeDelegate else { return }
                self.closeDelegate.original = window.delegate
                window.delegate = self.closeDelegate
                window.identifier = NSUserInterfaceItemIdentifier("zpdf.main")
                self.closeDelegate.appState.documentWindowIsKey = window.isKeyWindow
            }
        }
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        let appState: AppState
        var original: (any NSWindowDelegate)?
        init(appState: AppState) { self.appState = appState }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            appState.requestCloseAll { allowed in
                if allowed { sender.close() }
            }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
