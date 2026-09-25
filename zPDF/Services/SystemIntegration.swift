import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Default PDF viewer (LaunchServices) status and change.
@MainActor
enum DefaultApp {
    static var currentHandler: URL? { NSWorkspace.shared.urlForApplication(toOpen: .pdf) }

    static var currentHandlerName: String? {
        currentHandler.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    static var isDefault: Bool {
        guard let handler = currentHandler else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to make zPDF the default app for PDF (macOS may confirm).
    static func makeDefault() async -> String {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf)
            return isDefault ? "zPDF now opens PDFs from Finder." : "macOS didn't change the default app. You can also choose zPDF in Finder ▸ Get Info ▸ Open with."
        } catch {
            return "The default app couldn't be changed: \(error.localizedDescription)"
        }
    }
}

/// Finder ▸ Services ▸ “Open in zPDF” (declared in Info.plist NSServices).
@MainActor
final class ServicesProvider: NSObject {
    weak var appState: AppState?

    @objc func openPDFs(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let pdfs = urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
            || $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            error.pointee = "Select one or more PDF files to open in zPDF." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        pdfs.forEach { appState?.openDocument(at: $0) }
    }
}

/// Link clicks inside documents follow Settings ▸ Security.
@MainActor
enum LinkPolicy {
    static func open(_ url: URL, preferences: AppPreferences, window: NSWindow?) {
        switch preferences.linkPolicy {
        case .allow:
            NSWorkspace.shared.open(url)
        case .block:
            NSSound.beep()
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Open this link?"
            alert.informativeText = "The document wants to open:\n\(url.absoluteString)"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Always open links without asking"
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                if alert.suppressionButton?.state == .on { preferences.linkPolicy = .allow }
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handle) }
            else { handle(alert.runModal()) }
        }
    }
}

/// Applies Settings ▸ Spelling to every text view zPDF edits text in.
@MainActor
final class SpellingCoordinator {
    static let shared = SpellingCoordinator()
    private var observer: NSObjectProtocol?
    private weak var preferences: AppPreferences?

    func start(_ preferences: AppPreferences) {
        self.preferences = preferences
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: .main) { note in
            guard let textView = note.object as? NSTextView else { return }
            MainActor.assumeIsolated { SpellingCoordinator.shared.configure(textView) }
        }
    }

    func configure(_ textView: NSTextView) {
        guard let preferences, textView.isEditable else { return }
        if textView.isContinuousSpellCheckingEnabled != preferences.checkSpellingWhileTyping {
            textView.isContinuousSpellCheckingEnabled = preferences.checkSpellingWhileTyping
        }
        if textView.isAutomaticSpellingCorrectionEnabled != preferences.correctSpellingAutomatically {
            textView.isAutomaticSpellingCorrectionEnabled = preferences.correctSpellingAutomatically
        }
        let checker = NSSpellChecker.shared
        if preferences.spellingLanguage.isEmpty {
            if !checker.automaticallyIdentifiesLanguages { checker.automaticallyIdentifiesLanguages = true }
        } else if checker.language() != preferences.spellingLanguage {
            checker.automaticallyIdentifiesLanguages = false
            checker.setLanguage(preferences.spellingLanguage)
        }
    }
}
