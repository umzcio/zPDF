import Foundation

/// UI restoration only: never contains PDF bytes, passwords, or unsaved edits.
@MainActor
final class ReadingHistoryStore {
    struct Position: Codable {
        let page: Int
        let zoom: Double
        let viewMode: String
        let visited: Date
    }

    private let defaults: UserDefaults
    private let positionsKey = "zpdf.readingPositions.v1"
    private let sessionKey = "zpdf.openSession.v1"
    private var positions: [String: Position]

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        positions = defaults.data(forKey: positionsKey).flatMap {
            try? JSONDecoder().decode([String: Position].self, from: $0)
        } ?? [:]
    }

    func position(for url: URL) -> Position? {
        positions[url.resolvingSymlinksInPath().standardizedFileURL.path]
    }

    func remember(_ tab: DocumentTab) {
        guard let url = tab.url, tab.zoomFactor.isFinite else { return }
        positions[url.resolvingSymlinksInPath().standardizedFileURL.path] = Position(
            page: tab.currentPage, zoom: tab.zoomFactor, viewMode: tab.viewMode.rawValue, visited: Date())
        if positions.count > 200 {
            positions = Dictionary(uniqueKeysWithValues: positions.sorted { $0.value.visited > $1.value.visited }.prefix(200).map { ($0.key, $0.value) })
        }
        if let encoded = try? JSONEncoder().encode(positions) { defaults.set(encoded, forKey: positionsKey) }
    }

    func clearPositions() {
        positions.removeAll()
        defaults.removeObject(forKey: positionsKey)
    }

    var sessionBookmarks: [Data] { defaults.array(forKey: sessionKey) as? [Data] ?? [] }

    func saveSession(_ tabs: [DocumentTab]) {
        let bookmarks = tabs.compactMap { tab -> Data? in
            guard let url = tab.url, !tab.requiresSaveAs, tab.pdfDocument?.isEncrypted != true else { return nil }
            return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: sessionKey)
    }

    func clearSession() { defaults.removeObject(forKey: sessionKey) }
}

@MainActor
extension AppState {
    func applyReadingPreferences(to tab: DocumentTab) {
        tab.viewHistory.isRestoring = true
        defer { tab.viewHistory.isRestoring = false }
        tab.viewMode = preferences.defaultViewMode
        tab.pendingInitialZoom = preferences.defaultZoom
        guard preferences.rememberReadingPosition, let url = tab.url,
              let position = readingHistory.position(for: url), position.zoom.isFinite else { return }
        tab.goToPage(position.page)
        tab.setZoom(position.zoom)
        tab.viewMode = PDFViewMode(rawValue: position.viewMode) ?? preferences.defaultViewMode
        tab.pendingInitialZoom = nil
    }

    func rememberReadingState(_ tab: DocumentTab) {
        if preferences.rememberReadingPosition { readingHistory.remember(tab) }
    }

    func persistOpenSession() {
        guard !restoringSession else { return }
        if preferences.restoreOpenDocuments { readingHistory.saveSession(tabs) }
        else { readingHistory.clearSession() }
    }

    func restorePreviousSession() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        guard preferences.restoreOpenDocuments else { readingHistory.clearSession(); return }
        let bookmarks = readingHistory.sessionBookmarks
        // Consume before opening so a failed/missing document cannot loop on launch.
        readingHistory.clearSession()
        restoringSession = true
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let access = url.startAccessingSecurityScopedResource()
            if FileManager.default.fileExists(atPath: url.path) { openDocument(at: url, restoringSession: true) }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        restoringSession = false
        persistOpenSession()
    }
}
