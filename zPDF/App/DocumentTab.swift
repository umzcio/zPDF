//
//  DocumentTab.swift
//  zPDF
//
//  Purpose: @Observable model for one open document tab (Acrobat-style tab
//  model — NOT window-per-document). Holds the PDFDocument plus per-tab view
//  state: current page (1-based), zoom factor (0.5–2.0), view mode, view
//  rotation, and live toolbar-search state.
//  Search uses PDFKit's asynchronous search with debouncing and cancellation.
//  Toolbar rotation now changes the page through AppState's native-save path;
//  the legacy canvas rotation controller remains for existing view-state tests.
//

import AppKit
import Foundation
import PDFKit

/// Display mode for the page canvas; maps onto PDFKit's PDFDisplayMode.
enum PDFViewMode: String, CaseIterable, Identifiable {
    case single
    case continuous
    case facing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Single Page"
        case .continuous: "Continuous"
        case .facing: "Facing Pages"
        }
    }

    var symbolName: String {
        switch self {
        case .single: "rectangle.portrait"
        case .continuous: "scroll"
        case .facing: "rectangle.split.2x1"
        }
    }

    var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .single: .singlePage
        case .continuous: .singlePageContinuous
        case .facing: .twoUp
        }
    }
}

/// Non-isolated by design: mutated from PDFView notification callbacks
/// (main queue) as well as from SwiftUI views. Observation does not require
/// actor isolation; all mutation happens on the main thread in practice.
@Observable
final class DocumentTab: Identifiable {
    let id: UUID
    let viewHistory = DocumentViewHistory()
    let commentDrafts = CommentDraftStore()
    var commentReviewQuery = CommentReviewQuery()

    /// File URL on disk; nil for new/unsaved documents.
    var url: URL?
    /// The loaded document (engine document — see Services/PDFEngine.swift).
    var pdfDocument: PDFDocument? { willSet { cancelSearch(); searchMatches = []; currentMatchIndex = nil } }

    // Save slice: PDFKit is the editable display copy; only the native bridge
    // writes the original. Baseline is replaced after a successful reload.
    var saveBaseline: SaveBaseline?
    var editSource: DocumentEditSource?
    var requiresSaveAs = false
    var recoveredCheckpointID: UUID?
    var recoveredName: String?
    var recoveryID: UUID { recoveredCheckpointID ?? id }
    var sourceHash: String?
    var saveChecking = false
    var saveBlock: String?
    var isSaving = false
    var isExtracting = false
    var operationLabel: String?
    @ObservationIgnored var undoHistory: DocumentUndoHistory?
    var undoRevision = 0
    var lastExtractedURL: URL?
    var hasUnsavedChanges = false
    var hasUncommittedFieldEdit = false
    var isClosing = false
    var pageRevision = 0 { didSet { viewHistory.reset() } }
    var securityScopedURL: URL?
    var saveDirectoryAccessURL: URL?
    var allowsSaveEdits: Bool { !saveChecking && saveBlock == nil && !isSaving && !isClosing }

    deinit {
        searchObservers.forEach { NotificationCenter.default.removeObserver($0) }
        searchWork?.cancel()

        securityScopedURL?.stopAccessingSecurityScopedResource()
        saveDirectoryAccessURL?.stopAccessingSecurityScopedResource()
    }

    /// 1-based current page number (matches the prototype's page input).
    var currentPage: Int { didSet { recordViewHistory(previousPage: oldValue) } }
    /// Zoom factor, clamped to ZoomController bounds (0.5–2.0).
    var zoomFactor: Double { didSet { recordViewHistory(previousZoom: oldValue) } }
    var viewMode: PDFViewMode { didSet { recordViewHistory(previousMode: oldValue) } }
    /// Consumed only after the first canvas layout; later UI updates must not
    /// overwrite a user's zoom or a restored reading position.
    var pendingInitialZoom: DefaultPDFZoom?
    /// Visual rotation of the canvas, in degrees (0/90/180/270).
    var rotationDegrees: Int { didSet { recordViewHistory(previousRotation: oldValue) } }

    /// Live toolbar-search query (phase 2).
    var searchText: String
    var searchWholeWords = false {
        didSet { if oldValue != searchWholeWords { updateSearchResults() } }
    }
    var searchCaseSensitive = false {
        didSet { if oldValue != searchCaseSensitive { updateSearchResults() } }
    }
    /// All matches for the current query, in document order.
    private(set) var searchMatches: [PDFSelection]
    private(set) var isSearching = false
    @ObservationIgnored private var searchObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var searchWork: DispatchWorkItem?
    @ObservationIgnored private weak var searchingDocument: PDFDocument?
    @ObservationIgnored private var searchGeneration = UUID()

    /// Index into searchMatches of the match shown as the PDFView's
    /// current selection; nil when there are no matches.
    private(set) var currentMatchIndex: Int?

    /// Applies this tab's visual rotation to the shared PDFView.
    let viewRotation: CanvasRotationController

    init(id: UUID = UUID(), url: URL? = nil, pdfDocument: PDFDocument? = nil) {
        self.id = id
        self.url = url
        self.pdfDocument = pdfDocument
        self.currentPage = 1
        self.zoomFactor = 1.0
        self.viewMode = .single
        self.rotationDegrees = 0
        self.searchText = ""
        self.searchMatches = []
        self.currentMatchIndex = nil
        self.viewRotation = CanvasRotationController()
    }

    var displayName: String {
        recoveredName ?? url?.lastPathComponent ?? "Untitled.pdf"
    }

    var pageCount: Int {
        let _ = pageRevision
        return pdfDocument?.pageCount ?? 0
    }

    /// Media-box size of the current page, in points (nil when empty).
    var currentPageSize: CGSize? {
        let _ = pageRevision
        guard let document = pdfDocument,
              currentPage >= 1, currentPage <= document.pageCount else { return nil }
        return document.page(at: currentPage - 1)?.bounds(for: .mediaBox).size
    }

    /// Navigate to a 1-based page number, clamped into range.
    func goToPage(_ page: Int) {
        let upperBound = max(1, pageCount)
        currentPage = min(max(1, page), upperBound)
    }

    func goToNextPage() {
        goToPage(currentPage + 1)
    }

    func goToPreviousPage() {
        goToPage(currentPage - 1)
    }

    /// Set zoom, clamped to 50%–200%.
    func setZoom(_ zoom: Double) {
        zoomFactor = ZoomController.clamp(zoom)
    }

    // MARK: - Toolbar search (phase 2)

    /// The match currently highlighted in the PDFView, if any.
    var currentMatch: PDFSelection? {
        guard let currentMatchIndex,
              searchMatches.indices.contains(currentMatchIndex) else { return nil }
        return searchMatches[currentMatchIndex]
    }

    /// "1/12"-style label for the toolbar; nil while the field is empty.
    var searchCountText: String? {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !searchMatches.isEmpty else { return "0/0" }
        return "\((currentMatchIndex ?? 0) + 1)/\(searchMatches.count)"
    }

    /// PDFKit owns its asynchronous search. No document is shared with a
    /// detached thread, and stale results cannot cross a query or document swap.
    func cancelSearch() {
        searchGeneration = UUID()
        searchWork?.cancel(); searchWork = nil
        searchObservers.forEach { NotificationCenter.default.removeObserver($0) }
        searchObservers.removeAll()
        searchingDocument?.cancelFindString()
        searchingDocument = nil
        isSearching = false
    }

    func updateSearchResults() {
        cancelSearch()
        searchMatches = []
        currentMatchIndex = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = pdfDocument, !query.isEmpty, !document.isLocked else { return }
        let generation = searchGeneration
        let wholeWords = searchWholeWords
        let options: String.CompareOptions = searchCaseSensitive ? [] : .caseInsensitive
        isSearching = true
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document, self.searchGeneration == generation,
                  self.pdfDocument === document else { return }
            self.searchingDocument = document
            let center = NotificationCenter.default
            self.searchObservers = [
                center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
                    guard let self, self.searchGeneration == generation,
                          self.pdfDocument === document,
                          let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
                    if wholeWords && !SearchWordBoundary.containsWholeWords(selection) { return }
                    self.searchMatches.append(selection)
                    if self.currentMatchIndex == nil { self.currentMatchIndex = 0 }
                },
                center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                    guard let self, self.searchGeneration == generation else { return }
                    self.isSearching = false
                }
            ]
            document.beginFindString(query, withOptions: options)
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Move the highlight to the next match, wrapping around.
    func goToNextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = ((currentMatchIndex ?? -1) + 1) % searchMatches.count
    }

    /// Move the highlight to the previous match, wrapping around.
    func goToPreviousMatch() {
        guard !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        currentMatchIndex = ((currentMatchIndex ?? 0) - 1 + count) % count
    }
}

/// PDFKit supplies character ranges in page text. ICU's Unicode word rules
/// keep combining marks, non-Latin letters, underscores, and apostrophes in
/// their words instead of treating every non-ASCII character as a separator.
enum SearchWordBoundary {
    private static let boundary = try! NSRegularExpression(pattern: "\\b", options: .useUnicodeWordBoundaries)

    static func isBoundary(in text: String, at offset: Int) -> Bool {
        guard offset >= 0, offset <= (text as NSString).length else { return false }
        return boundary.firstMatch(in: text,
            options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
            range: NSRange(location: offset, length: 0)) != nil
    }

    static func containsWholeWords(_ selection: PDFSelection) -> Bool {
        guard let first = selection.pages.first, let last = selection.pages.last,
              let firstText = first.string, let lastText = last.string else { return false }
        let firstRanges = (0..<selection.numberOfTextRanges(on: first)).map { selection.range(at: $0, on: first) }
        let lastRanges = (0..<selection.numberOfTextRanges(on: last)).map { selection.range(at: $0, on: last) }
        guard let start = firstRanges.filter({ $0.location != NSNotFound }).map(\.location).min(),
              let end = lastRanges.filter({ $0.location != NSNotFound }).map({ NSMaxRange($0) }).max() else { return false }
        return isBoundary(in: firstText, at: start) && isBoundary(in: lastText, at: end)
    }
}

/// View-only canvas rotation for the shared PDFView (phase 2). Applies a
/// layer transform about the view's center, mirroring the prototype's CSS
/// `transform: rotate()` on the page — the PDFDocument is never mutated.
/// At 90°/270° the rotated viewport is uniformly shrunk so it stays fully
/// visible inside the frame; fit width / fit page compensate with swapped
/// width/height math (see DocumentToolbar). Main-actor isolated: it only
/// ever touches AppKit view state on the main thread.
@MainActor
final class CanvasRotationController {
    /// Only one controller drives the single shared PDFView at a time;
    /// applying from another tab's controller detaches the previous owner.
    private static weak var owner: CanvasRotationController?

    private weak var pdfView: PDFView?
    private var frameObserver: NSObjectProtocol?
    private var appliedDegrees = 0

    /// Nonisolated so DocumentTab (deliberately non-isolated) can create
    /// its controller synchronously; all mutable state is main-actor only.
    nonisolated init() {}

    @MainActor
    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
    }

    /// Apply a 0/90/180/270° visual rotation and reset the scroll position
    /// to the top of the current page.
    func apply(degrees: Int, to pdfView: PDFView) {
        if CanvasRotationController.owner !== self {
            CanvasRotationController.owner?.detach()
            CanvasRotationController.owner = self
        }
        appliedDegrees = degrees
        self.pdfView = pdfView
        pdfView.wantsLayer = true
        updateTransform(of: pdfView)
        observeFrameChanges(of: pdfView)
        if let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) {
            pdfView.go(to: page)
        }
    }

    /// Remove the transform and stop observing; called when another tab's
    /// controller takes over the shared PDFView.
    func detach() {
        if let observer = frameObserver {
            NotificationCenter.default.removeObserver(observer)
            frameObserver = nil
        }
        pdfView?.layer?.setAffineTransform(.identity)
        pdfView = nil
    }

    private func updateTransform(of pdfView: PDFView) {
        guard let layer = pdfView.layer else { return }
        let radians = CGFloat(appliedDegrees) * .pi / 180
        var transform = CGAffineTransform(rotationAngle: radians)
        if appliedDegrees == 90 || appliedDegrees == 270 {
            let width = pdfView.bounds.width
            let height = pdfView.bounds.height
            let longEdge = max(width, height)
            if longEdge > 0 {
                let shrink = min(width, height) / longEdge
                transform = transform.scaledBy(x: shrink, y: shrink)
            }
        }
        layer.setAffineTransform(transform)
    }

    /// Re-apply the transform when the view resizes so the 90°/270°
    /// shrink-to-fit correction tracks the current aspect ratio.
    private func observeFrameChanges(of pdfView: PDFView) {
        guard frameObserver == nil else { return }
        pdfView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            guard let self, let pdfView else { return }
            // queue: .main guarantees delivery on the main thread.
            MainActor.assumeIsolated {
                self.updateTransform(of: pdfView)
            }
        }
    }
}
