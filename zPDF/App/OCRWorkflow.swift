// Recognize Text (OCR): Vision recognition on rendered pages, optional scan
// cleanup, and a native text layer written in one Undo step. Suspect words
// (low confidence or unknown to the spell checker) can be reviewed and
// corrected afterwards; corrections rewrite that page's layer.

import AppKit
import PDFKit

struct OCROptions {
    enum Output: String, CaseIterable, Identifiable {
        case searchable, editable
        var id: String { rawValue }
        var title: String { self == .searchable ? "Searchable image (invisible text)" : "Editable text (replaces scanned words)" }
    }
    var languages: [String] = ["en-US"]
    var pages: [Int]?          // zero-based, nil = all
    var force = false          // also pages that already have text
    var deskew = false
    var despeckle = false
    var cleanBackground = false
    var output: Output = .searchable
    var dpi: CGFloat = 300
    var suspectConfidence: Float = 0.5
}

/// Recognized words for one page, in the page's visual space (points).
struct OCRPageText: Identifiable {
    let page: Int
    var lines: [OCRLine]
    let visualSize: CGSize
    var id: Int { page }

    var text: String { lines.map { $0.words.map(\.text).joined(separator: " ") }.joined(separator: "\n") }

    func rect(for word: OCRWord) -> CGRect {
        CGRect(x: word.box.minX * visualSize.width, y: word.box.minY * visualSize.height,
               width: word.box.width * visualSize.width, height: word.box.height * visualSize.height)
    }

    var json: [String: Any] {
        ["page": page, "lines": lines.map { line in
            line.words.map { word -> [String: Any] in
                let r = rect(for: word)
                return ["t": word.text, "b": [r.minX, r.minY, r.maxX, r.maxY].map { Double($0) }]
            }
        }]
    }
}

struct OCRSuspect: Identifiable, Equatable {
    let id: UUID
    let page: Int
    let line: Int
    let word: Int
    var text: String
    let reason: String
}

/// Per-document OCR results kept for review while the document is open.
@MainActor
@Observable
final class OCRSession {
    var pages: [Int: OCRPageText] = [:]
    var suspects: [OCRSuspect] = []
    var skipped: [Int] = []
    var output: OCROptions.Output = .searchable
    var progress: (done: Int, total: Int)?
    var message: String?
    var isRunning: Bool { progress != nil }
    var cancelRequested = false

    static var sessions: [UUID: OCRSession] = [:]
    static func session(for tab: DocumentTab) -> OCRSession {
        if let existing = sessions[tab.id] { return existing }
        let session = OCRSession()
        sessions[tab.id] = session
        return session
    }

    var recognizedText: String {
        pages.keys.sorted().compactMap { pages[$0]?.text }.joined(separator: "\n\n\u{0C}")
    }
}

@MainActor
extension AppState {
    /// Pages whose content has no text of their own (scans), from the engine.
    func textStatus(_ tab: DocumentTab) async throws -> [(page: Int, chars: Int, ocr: Bool, images: Int)] {
        let result = try await queryDocument("text_status", in: tab)
        return (result["pages"] as? [[String: Any]] ?? []).map {
            ($0["page"] as? Int ?? 0, $0["chars"] as? Int ?? 0, $0["ocr"] as? Bool ?? false, $0["images"] as? Int ?? 0)
        }
    }

    /// Runs OCR and writes the text layer. Returns false on failure/cancel.
    @discardableResult
    func recognizeText(in tab: DocumentTab, options: OCROptions, session: OCRSession? = nil) async -> Bool {
        let session = session ?? OCRSession.session(for: tab)
        guard !session.isRunning, let document = tab.pdfDocument else { return false }
        session.message = nil
        session.cancelRequested = false
        do {
            let status = try await textStatus(tab)
            let requested = options.pages ?? Array(0..<document.pageCount)
            var targets: [Int] = [], skipped: [Int] = []
            for index in requested {
                let info = status.first { $0.page == index }
                if !options.force, let info, info.chars > 0 { skipped.append(index) } else { targets.append(index) }
            }
            session.skipped = skipped
            guard !targets.isEmpty else {
                session.message = "All selected pages already contain text. Turn on “Include pages with text” to recognize them again."
                return false
            }
            let work = try NativeWorkDirectory()
            let service = OCRService()
            var replacements: [[String: Any]] = []
            var results: [OCRPageText] = []
            session.progress = (0, targets.count)
            defer { session.progress = nil }
            for (n, index) in targets.enumerated() {
                if session.cancelRequested { session.message = "Recognition cancelled; no changes were made."; return false }
                guard let page = document.page(at: index), var image = OCRService.render(page, dpi: options.dpi) else {
                    throw OCRError.pageRenderFailed(index)
                }
                let bounds = page.bounds(for: .cropBox)
                let visual = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
                var lines = try await service.recognizeWords(in: image, languages: options.languages)
                let scanOnly = (status.first { $0.page == index }).map { $0.chars == 0 && $0.images >= 1 } ?? false
                if scanOnly && (options.deskew || options.despeckle || options.cleanBackground) {
                    let angle = options.deskew ? PageImageCleaner.skew(of: lines) : nil
                    if let cleaned = PageImageCleaner.clean(image, deskewBy: angle, despeckle: options.despeckle,
                                                            whitenBackground: options.cleanBackground) {
                        image = cleaned
                        let url = work.url.appendingPathComponent("page-\(index).jpg")
                        guard ImageNormalizer.write(cleaned, to: url, jpeg: true, dpi: Double(options.dpi), quality: 0.85) else {
                            throw OCRError.pageRenderFailed(index)
                        }
                        replacements.append(["page": index, "path": url.path])
                        if angle != nil || options.despeckle { lines = try await service.recognizeWords(in: cleaned, languages: options.languages) }
                    }
                }
                results.append(OCRPageText(page: index, lines: lines, visualSize: visual))
                session.progress = (n + 1, targets.count)
            }
            var ops: [[String: Any]] = []
            if !replacements.isEmpty { ops.append(["op": "replace_page_image", "pages": replacements]) }
            ops.append(["op": "ocr_text_layer", "pages": results.map(\.json),
                        "visible": options.output == .editable, "cover": options.output == .editable])
            _ = try await applyDocumentTransform(ops, to: tab, actionName: "Recognize Text")
            withExtendedLifetime(work) {}
            for result in results { session.pages[result.page] = result }
            session.output = options.output
            session.suspects = Self.suspects(in: session, threshold: options.suspectConfidence, languages: options.languages)
            let words = results.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.words.count } }
            session.message = "Recognized \(words) words on \(results.count) page\(results.count == 1 ? "" : "s")."
                + (skipped.isEmpty ? "" : " Skipped \(skipped.count) page\(skipped.count == 1 ? "" : "s") with text.")
            return true
        } catch {
            session.message = error.localizedDescription
            return false
        }
    }

    static func suspects(in session: OCRSession, threshold: Float, languages: [String]) -> [OCRSuspect] {
        let checker = NSSpellChecker.shared
        let language = languages.first.map { $0.replacingOccurrences(of: "-", with: "_") }
        var out: [OCRSuspect] = []
        for page in session.pages.keys.sorted() {
            guard let text = session.pages[page] else { continue }
            for (l, line) in text.lines.enumerated() {
                for (w, word) in line.words.enumerated() {
                    let letters = word.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                    guard letters.count >= 2, letters.rangeOfCharacter(from: .letters) != nil else { continue }
                    var reason: String?
                    if word.confidence < threshold { reason = "Low confidence (\(Int(word.confidence * 100))%)" }
                    else if letters.rangeOfCharacter(from: .decimalDigits) == nil {
                        let range = checker.checkSpelling(of: letters, startingAt: 0, language: language, wrap: false,
                                                          inSpellDocumentWithTag: 0, wordCount: nil)
                        if range.location != NSNotFound { reason = "Not in dictionary" }
                    }
                    if let reason {
                        out.append(OCRSuspect(id: word.id, page: page, line: l, word: w, text: word.text, reason: reason))
                    }
                }
            }
        }
        return out
    }

    /// Applies suspect corrections by rewriting the affected pages' layers.
    @discardableResult
    func applyOCRCorrections(_ corrections: [UUID: String], in tab: DocumentTab) async -> Bool {
        let session = OCRSession.session(for: tab)
        var touched = Set<Int>()
        for (index, suspect) in session.suspects.enumerated() {
            guard let text = corrections[suspect.id], !text.isEmpty, text != suspect.text,
                  var page = session.pages[suspect.page] else { continue }
            page.lines[suspect.line].words[suspect.word].text = text
            session.pages[suspect.page] = page
            session.suspects[index].text = text
            touched.insert(suspect.page)
        }
        guard !touched.isEmpty else { return true }
        let pages = touched.sorted().compactMap { session.pages[$0]?.json }
        let ok = await performPageTransform([["op": "ocr_text_layer", "pages": pages, "replace": true,
                                              "visible": session.output == .editable, "cover": session.output == .editable]],
                                            in: tab, actionName: "Correct Recognized Text") != nil
        if ok {
            session.suspects.removeAll { corrections[$0.id] != nil }
            session.message = "Updated recognized text on \(touched.count) page\(touched.count == 1 ? "" : "s")."
        }
        return ok
    }

    /// Saves the document's text (including recognized text) as plain text.
    func exportRecognizedText(_ tab: DocumentTab) {
        guard let document = tab.pdfDocument else { return }
        let text = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n\n\u{0C}")
        guard let destination = FilePicker.saveDestination(title: "Export Text",
                                                           name: (tab.displayName as NSString).deletingPathExtension + ".txt",
                                                           type: .plainText, directory: tab.url?.deletingLastPathComponent()) else { return }
        do {
            try text.write(to: destination.url, atomically: true, encoding: .utf8)
            exportMessage = "Saved the document text to \(destination.url.lastPathComponent)."
            exportedURL = destination.url
        } catch {
            saveError = OpenError(fileName: destination.url.lastPathComponent, message: error.localizedDescription)
        }
    }
}

// MARK: - Scan detection

@MainActor
enum ScanDetector {
    static var dismissed: Set<UUID> = []

    /// True when the first pages carry no text but do show content — typical
    /// of scans. Cheap: PDFKit text plus a tiny thumbnail check.
    static func looksScanned(_ document: PDFDocument) -> Bool {
        let sample = min(document.pageCount, 3)
        guard sample > 0 else { return false }
        var scanned = 0
        for index in 0..<sample {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if hasInk(page) { scanned += 1 }
        }
        return scanned > 0
    }

    private static func hasInk(_ page: PDFPage) -> Bool {
        let image = page.thumbnail(of: CGSize(width: 48, height: 64), for: .cropBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let count = CFDataGetLength(data)
        var dark = 0
        let step = max(4, cg.bitsPerPixel / 8)
        for offset in stride(from: 0, to: count - 2, by: step) where Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) < 600 {
            dark += 1
        }
        return dark > 8
    }
}
