import PDFKit

struct PageDrag {
    let token = UUID().uuidString
    let tab: DocumentTab
    let document: PDFDocument
    let page: PDFPage
}

@MainActor
extension AppState {
    private func editablePages(in tab: DocumentTab) throws -> PDFDocument {
        guard tab.allowsSaveEdits, commitFieldEditing(), let document = tab.pdfDocument else {
            throw NativeSaveError(code: "EDIT_BLOCKED", message: "This document cannot be edited right now.")
        }
        if tab.undoHistory == nil { resetUndoHistory(tab) }
        return document
    }

    func rotatePage(_ index: Int, in tab: DocumentTab) throws {
        let document = try editablePages(in: tab)
        try engine.rotatePage(at: index, in: document, byDegrees: 90)
        tab.pageRevision += 1
        refreshUnsavedChanges(tab)
    }

    func deletePage(_ index: Int, in tab: DocumentTab) throws {
        let document = try editablePages(in: tab)
        guard document.pageCount > 1 else {
            throw NativeSaveError(code: "EMPTY_DOCUMENT", message: "A PDF must keep at least one page.")
        }
        try engine.removePage(at: index, in: document)
        tab.pageRevision += 1
        tab.goToPage(tab.currentPage)
        tab.updateSearchResults()
        refreshUnsavedChanges(tab)
    }

    /// Move to a final zero-based position, independent of the engine's
    /// insertion-boundary convention. Dropping on the last cell can move last.
    func movePage(from source: Int, to destination: Int, in tab: DocumentTab) throws {
        let document = try editablePages(in: tab)
        guard (0..<document.pageCount).contains(source), (0..<document.pageCount).contains(destination) else {
            throw NativeSaveError(code: "STALE_PAGE", message: "The requested page is no longer available.")
        }
        guard source != destination else { return }
        try engine.movePage(from: source, to: source < destination ? destination + 1 : destination, in: document)
        tab.pageRevision += 1
        tab.goToPage(destination + 1)
        tab.updateSearchResults()
        refreshUnsavedChanges(tab)
    }

    func beginPageDrag(at index: Int, in tab: DocumentTab) -> String {
        guard tab.allowsSaveEdits, let document = tab.pdfDocument, let page = document.page(at: index) else { return "" }
        let drag = PageDrag(tab: tab, document: document, page: page)
        pageDrag = drag
        return drag.token
    }

    func dropPage(_ token: String, at index: Int, in tab: DocumentTab) -> Bool {
        guard let drag = pageDrag, drag.token == token, drag.tab === tab,
              tab.pdfDocument === drag.document else { return false }
        defer { pageDrag = nil }
        do {
            try movePage(from: drag.document.index(for: drag.page), to: index, in: tab)
            return true
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return false
        }
    }
}

/// User-facing, one-based page numbers. Results follow document order.
enum PageRangeSelection {
    static func parse(_ text: String, pageCount: Int) throws -> IndexSet {
        func invalid() -> NativeSaveError {
            NativeSaveError(code: "INVALID_PAGE_RANGE", message: "Enter pages from 1 to \(pageCount), such as 1, 3–5.")
        }
        guard pageCount > 0 else { throw invalid() }
        var selected = IndexSet()
        for part in text.replacingOccurrences(of: "–", with: "-").split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]),
                  let last = Int(bounds.last!), first >= 1, last >= first, last <= pageCount else { throw invalid() }
            selected.insert(integersIn: (first - 1)..<last)
        }
        guard !selected.isEmpty else { throw invalid() }
        return selected
    }
}
