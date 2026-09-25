import AVFoundation
import PDFKit

/// Read Out Loud: speaks the current page or from the current page to the
/// end, highlighting each word on the canvas (display-only highlight that
/// never changes the document or the user's selection).
@MainActor @Observable
final class ReadAloudController: NSObject, AVSpeechSynthesizerDelegate {
    enum Scope { case page, toEnd }
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var pageIndex: Int?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private weak var tab: DocumentTab?
    @ObservationIgnored private var scope: Scope = .page
    @ObservationIgnored private var pageText = ""
    @ObservationIgnored private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            ($0.language, $0.quality.rawValue * -1, $0.name) < ($1.language, $1.quality.rawValue * -1, $1.name)
        }
    }

    func start(_ scope: Scope, in appState: AppState) {
        guard let tab = appState.activeTab, tab.pdfDocument != nil else { return }
        stop()
        self.appState = appState
        self.tab = tab
        self.scope = scope
        speak(page: tab.currentPage - 1)
    }

    func togglePause() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else if isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        generation += 1
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isPaused = false
        pageIndex = nil
        clearHighlight()
    }

    private func speak(page index: Int) {
        guard let appState, let tab, let document = tab.pdfDocument, index < document.pageCount,
              let page = document.page(at: index) else { finish(); return }
        let text = page.string ?? ""
        pageIndex = index
        if tab.currentPage != index + 1 { tab.goToPage(index + 1) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            advance(after: index)
            return
        }
        pageText = text
        let utterance = AVSpeechUtterance(string: text)
        let preferences = appState.preferences
        utterance.rate = Float(AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * Float(preferences.readAloudRate))
        if !preferences.readAloudVoice.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: preferences.readAloudVoice) {
            utterance.voice = voice
        } else if let language = Self.documentLanguage(document), let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        isSpeaking = true
        isPaused = false
        synthesizer.speak(utterance)
    }

    private func advance(after index: Int) {
        if scope == .toEnd, let count = tab?.pdfDocument?.pageCount, index + 1 < count {
            speak(page: index + 1)
        } else {
            finish()
        }
    }

    private func finish() {
        isSpeaking = false
        isPaused = false
        pageIndex = nil
        clearHighlight()
    }

    private func highlight(_ range: NSRange) {
        guard let appState, appState.preferences.readAloudHighlight, let tab, let index = pageIndex,
              let page = tab.pdfDocument?.page(at: index), let view = appState.pdfViewStore.pdfView,
              view.document === tab.pdfDocument, let selection = page.selection(for: range) else { return }
        selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
        view.highlightedSelections = [selection]
        if let bounds = selection.pages.first.map({ selection.bounds(for: $0) }) {
            let visible = view.convert(view.bounds, to: page)
            if !visible.contains(bounds) { view.go(to: bounds.insetBy(dx: -40, dy: -80), on: page) }
        }
    }

    private func clearHighlight() {
        appState?.pdfViewStore.pdfView?.highlightedSelections = nil
    }

    /// Catalog /Lang, used to choose a matching voice when none is set.
    static func documentLanguage(_ document: PDFDocument) -> String? {
        guard let catalog = document.documentRef?.catalog else { return nil }
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(catalog, "Lang", &string), let string,
              let value = CGPDFStringCopyTextString(string) as String?, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - AVSpeechSynthesizerDelegate (called on the main thread)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in self.highlight(characterRange) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isSpeaking, let index = self.pageIndex else { return }
            self.advance(after: index)
        }
    }
}
