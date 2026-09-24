//
//  RecentFilesStore.swift
//  zPDF
//
//  Purpose: Persistence for the Home screen recents grid. Stores
//  [RecentFile] as JSON in UserDefaults, each entry carrying a
//  security-scoped bookmark so sandboxed reopening works across launches.
//  Phase: 1 — REAL.
//  TODO(phase-2): refresh stale bookmarks instead of dropping them;
//  deduplicate by resolved file identifier rather than URL equality.
//

import Foundation

@MainActor
@Observable
final class RecentFilesStore {
    private(set) var files: [RecentFile] = []
    private let defaults: UserDefaults
    var maximumCount = Constants.Limits.maxRecentFiles {
        didSet { trimAndPersist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var starred: [RecentFile] {
        files.filter { $0.isStarred }
    }

    /// Insert or bump a file at the front of the recents list.
    func add(url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        if let index = files.firstIndex(where: { $0.resolveURL() == url }) {
            files[index].lastOpened = Date()
            files[index].fileSize = Int64(size)
            files[index].bookmarkData = bookmark
        } else {
            files.insert(RecentFile(bookmarkData: bookmark,
                                    name: url.lastPathComponent,
                                    lastOpened: Date(),
                                    fileSize: Int64(size)), at: 0)
        }
        files.sort { $0.lastOpened > $1.lastOpened }
        trimAndPersist()
    }

    func clear() {
        files.removeAll()
        persist()
    }

    private func trimAndPersist() {
        files = Array(files.prefix(max(0, maximumCount)))
        persist()
    }

    func remove(_ file: RecentFile) {
        files.removeAll { $0.id == file.id }
        persist()
    }

    func toggleStar(_ file: RecentFile) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index].isStarred.toggle()
        persist()
    }

    /// Drop entries whose bookmarks no longer resolve (file moved/deleted).
    func reload() {
        files = files.filter { $0.resolveURL() != nil }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(files) {
            defaults.set(data, forKey: Constants.DefaultsKey.recentFiles)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Constants.DefaultsKey.recentFiles),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        files = decoded
    }
}
