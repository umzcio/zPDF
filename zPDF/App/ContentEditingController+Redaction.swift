import AppKit
import PDFKit

/// One search result offered by Search & Redact.
struct RedactionMatch: Identifiable {
    let id = UUID()
    let page: Int
    let text: String
    let context: String
    let rects: [CGRect]
    var isSelected = true
}

/// Outcome of the last Apply Redactions, including the verification pass.
struct RedactionReport: Equatable {
    var marks = 0
    var pages = 0
    var glyphs = 0
    var images = 0
    var paths = 0
    var annotations = 0
    var fields = 0
    var checked = 0
    var stillFound: [String] = []

    var summary: String {
        var parts: [String] = []
        if glyphs > 0 { parts.append("\(glyphs) character\(glyphs == 1 ? "" : "s")") }
        if images > 0 { parts.append("\(images) image area\(images == 1 ? "" : "s")") }
        if paths > 0 { parts.append("\(paths) drawing\(paths == 1 ? "" : "s")") }
        if annotations > 0 { parts.append("\(annotations) comment\(annotations == 1 ? "" : "s") or field\(annotations == 1 ? "" : "s")") }
        let removed = parts.isEmpty ? "No content was under the marks." : "Removed " + parts.joined(separator: ", ") + "."
        return "Applied \(marks) mark\(marks == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s"). " + removed
    }
}

extension ContentEditingController {
    // MARK: - Marks

    func marks() -> [(page: Int, mark: RedactionMarkAnnotation)] {
        let _ = markRevision
        guard let document = tab?.pdfDocument else { return [] }
        var result: [(Int, RedactionMarkAnnotation)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let mark = annotation as? RedactionMarkAnnotation { result.append((index, mark)) }
            }
        }
        return result
    }

    @discardableResult
    func addMark(on page: PDFPage, rects: [CGRect], record: Bool = true) -> RedactionMarkAnnotation? {
        let clean = rects.map { $0.intersection(page.bounds(for: .mediaBox)) }.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard !clean.isEmpty, let tab, tab.allowsSaveEdits else { return nil }
        let mark = RedactionMarkAnnotation(page: page, rects: clean, appearance: redactionAppearance)
        page.addAnnotation(mark)
        if record { recordMarkChange("Mark for Redaction") }
        return mark
    }

    func markSelection(_ selection: PDFSelection) {
        var added = 0
        for page in selection.pages {
            let rects = selection.selectionsByLine().compactMap { line -> CGRect? in
                guard line.pages.contains(page) else { return nil }
                let bounds = line.bounds(for: page)
                return bounds.isEmpty ? nil : bounds
            }
            if addMark(on: page, rects: rects, record: false) != nil { added += 1 }
        }
        if added > 0 { recordMarkChange("Mark for Redaction") }
    }

    func removeMark(_ mark: RedactionMarkAnnotation) {
        mark.page?.removeAnnotation(mark)
        if selectedMark === mark { selectedMark = nil }
        recordMarkChange("Remove Redaction Mark")
    }

    func removeAllMarks() {
        let all = marks()
        guard !all.isEmpty else { return }
        for (_, mark) in all { mark.page?.removeAnnotation(mark) }
        selectedMark = nil
        recordMarkChange("Remove Redaction Marks")
    }

    /// Updates the look of existing marks (fill, overlay text) to the current settings.
    func applyAppearanceToMarks(_ marks: [RedactionMarkAnnotation]) {
        guard !marks.isEmpty else { return }
        for mark in marks {
            // A replacement mark (not an in-place change) carries every
            // redaction key through Save, including the overlay text.
            guard let page = mark.page else { continue }
            let replacement = RedactionMarkAnnotation(page: page, rects: mark.markRects, appearance: redactionAppearance)
            page.removeAnnotation(mark)
            page.addAnnotation(replacement)
            if selectedMark === mark { selectedMark = replacement }
        }
        recordMarkChange("Change Redaction Appearance")
    }

    func markPages(_ scope: EditPageScope) {
        guard let tab, let document = tab.pdfDocument else { return }
        let pages = scope.pages(current: tab.currentPage - 1, count: document.pageCount)
        var added = 0
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            if addMark(on: page, rects: [page.bounds(for: .cropBox)], record: false) != nil { added += 1 }
        }
        if added > 0 { recordMarkChange(added == 1 ? "Mark Page for Redaction" : "Mark Pages for Redaction") }
    }

    func recordMarkChange(_ name: String) {
        guard let appState, let tab else { return }
        tab.undoHistory?.record(name: name)
        appState.noteAnnotationsChanged()
        markRevision += 1
        overlay.needsDisplay = true
    }

    // MARK: - Search & Redact

    /// Finds text (literal or regular expression) on every page with PDFKit's
    /// own text model, so marks line up with what the viewer shows.
    func findMatches(query: String, pattern: RedactionPattern?, regex: Bool, matchCase: Bool, wholeWords: Bool) -> [RedactionMatch] {
        guard let document = tab?.pdfDocument else { return [] }
        let expression: NSRegularExpression?
        do {
            if let pattern {
                expression = try NSRegularExpression(pattern: pattern.regex, options: pattern == .email ? [.caseInsensitive] : [])
            } else if regex {
                expression = try NSRegularExpression(pattern: query, options: matchCase ? [] : [.caseInsensitive])
            } else {
                let escaped = NSRegularExpression.escapedPattern(for: query)
                let bounded = wholeWords ? "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])" : escaped
                expression = try NSRegularExpression(pattern: bounded, options: matchCase ? [] : [.caseInsensitive])
            }
        } catch {
            notice = "That isn't a valid regular expression."
            return []
        }
        guard let expression else { return [] }
        var results: [RedactionMatch] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string, !text.isEmpty else { continue }
            let ns = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
                let found = ns.substring(with: match.range)
                if let pattern, !pattern.accepts(found) { continue }
                guard let selection = page.selection(for: match.range) else { continue }
                let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
                guard !rects.isEmpty else { continue }
                let start = max(0, match.range.location - 24)
                let end = min(ns.length, NSMaxRange(match.range) + 24)
                let context = ns.substring(with: NSRange(location: start, length: end - start))
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                results.append(RedactionMatch(page: index, text: found, context: context, rects: rects))
                if results.count >= 2000 { return results }
            }
        }
        return results
    }

    func mark(_ matches: [RedactionMatch]) -> Int {
        guard let document = tab?.pdfDocument else { return 0 }
        var added = 0
        for match in matches where match.isSelected {
            guard let page = document.page(at: match.page) else { continue }
            if addMark(on: page, rects: match.rects, record: false) != nil { added += 1 }
        }
        if added > 0 { recordMarkChange(added == 1 ? "Mark for Redaction" : "Mark \(added) Items for Redaction") }
        return added
    }

    // MARK: - Apply

    /// Text under each mark, to confirm afterwards that it is gone.
    private func markedSnippets() -> [(page: Int, text: String)] {
        guard let document = tab?.pdfDocument else { return [] }
        var snippets: [(Int, String)] = []
        for (index, mark) in marks() {
            guard let page = document.page(at: index) else { continue }
            for rect in mark.markRects {
                guard let selection = page.selection(for: rect.insetBy(dx: 0.5, dy: 0.5)),
                      let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                // Whole words fully inside the mark are what must disappear.
                for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) where word.count >= 3 {
                    snippets.append((index, String(word)))
                }
            }
        }
        return snippets
    }

    func applyRedactions(sanitize: [String: Any]? = nil, completion: ((RedactionReport) -> Void)? = nil) {
        guard let appState, let tab else { return }
        let count = marks().count
        guard count > 0 else { return }
        finishEditing(commit: true)
        let snippets = markedSnippets()
        // Word counts per page before applying: every marked occurrence must disappear.
        var expected: [Int: [String: Int]] = [:]
        if let document = tab.pdfDocument {
            for (page, items) in Dictionary(grouping: snippets, by: { $0.page }) {
                let before = Self.wordCounts(document.page(at: page)?.string ?? "")
                var marked: [String: Int] = [:]
                for item in items { marked[item.text, default: 0] += 1 }
                expected[page] = marked.reduce(into: [:]) { result, entry in
                    result[entry.key] = max(0, (before[entry.key] ?? 0) - entry.value)
                }
            }
        }
        var ops: [[String: Any]] = [["op": "apply_redactions"]]
        if var sanitize { sanitize["op"] = "sanitize"; ops.append(sanitize) }
        selectedMark = nil
        isBusy = true
        Task { [weak self] in
            defer { self?.isBusy = false }
            do {
                let results = try await appState.applyDocumentTransform(ops, to: tab, actionName: "Apply Redactions")
                guard let self else { return }
                var report = RedactionReport()
                if let r = results.first {
                    report.marks = r["marks"] as? Int ?? count
                    report.pages = r["pages"] as? Int ?? 0
                    report.glyphs = r["glyphs"] as? Int ?? 0
                    report.images = (r["images"] as? Int ?? 0) + (r["images_removed"] as? Int ?? 0)
                    report.paths = (r["paths"] as? Int ?? 0) + (r["clipped"] as? Int ?? 0)
                    report.annotations = (r["annotations"] as? Int ?? 0)
                    report.fields = r["fields"] as? Int ?? 0
                }
                // Verify with PDFKit's own text extraction of the new revision.
                if let document = tab.pdfDocument {
                    let overlay = self.overlayTexts
                    for (page, limits) in expected {
                        let after = Self.wordCounts(document.page(at: page)?.string ?? "")
                        for (word, limit) in limits where !overlay.contains(word) {
                            report.checked += 1
                            if (after[word] ?? 0) > limit { report.stillFound.append(word) }
                        }
                    }
                }
                self.lastReport = report
                self.invalidateContent()
                self.markRevision += 1
                completion?(report)
            } catch {
                appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            }
        }
    }

    static func wordCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) { counts[String(word), default: 0] += 1 }
        return counts
    }

    private var overlayTexts: Set<String> {
        var words: Set<String> = []
        for text in [redactionAppearance.overlayText] {
            for word in text.split(separator: " ") { words.insert(String(word)) }
        }
        return words
    }

    // MARK: - Sanitize

    func scanHiddenInformation() async -> [String: Int] {
        guard let appState, let tab else { return [:] }
        do {
            let result = try await appState.queryDocument("sanitize_scan", in: tab)
            var counts: [String: Int] = [:]
            for (key, value) in result.value { counts[key] = value as? Int ?? 0 }
            return counts
        } catch {
            notice = error.localizedDescription
            return [:]
        }
    }

    func sanitize(_ options: [String: Bool]) {
        var op: [String: Any] = ["op": "sanitize"]
        for (key, value) in options { op[key] = value }
        guard let appState, let tab else { return }
        finishEditing(commit: true)
        isBusy = true
        Task { [weak self] in
            defer { self?.isBusy = false }
            do {
                let results = try await appState.applyDocumentTransform([op], to: tab, actionName: "Remove Hidden Information")
                let removed = results.first?["removed"] as? [String: Any] ?? [:]
                let total = removed.values.compactMap { $0 as? Int }.reduce(0, +)
                self?.sanitizeSummary = total == 0 ? "No hidden information was found." : "Removed \(total) item\(total == 1 ? "" : "s") of hidden information."
                self?.invalidateContent()
                self?.markRevision += 1
            } catch {
                appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            }
        }
    }
}
