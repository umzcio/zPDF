//
//  RecentFile.swift
//  zPDF
//
//  Purpose: Model for one entry in the Home screen's recents grid. Carries a
//  security-scoped bookmark so a sandboxed app can reopen the file later
//  (requires com.apple.security.files.bookmarks.app-scope — enabled).
//  Phase: 1 — REAL.
//

import Foundation

struct RecentFile: Identifiable, Codable, Equatable {
    var id: UUID
    /// Security-scoped bookmark data for the file URL.
    var bookmarkData: Data
    var name: String
    var lastOpened: Date
    var fileSize: Int64
    var isStarred: Bool

    init(id: UUID = UUID(),
         bookmarkData: Data,
         name: String,
         lastOpened: Date,
         fileSize: Int64,
         isStarred: Bool = false) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.name = name
        self.lastOpened = lastOpened
        self.fileSize = fileSize
        self.isStarred = isStarred
    }

    /// Resolve the security-scoped bookmark back to a URL.
    /// Returns nil when the bookmark is invalid or the file is gone.
    /// TODO(phase-2): when `isStale` is true, re-create and persist a fresh
    /// bookmark instead of silently keeping the old one.
    func resolveURL() -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              !isStale else {
            return nil
        }
        return url
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// e.g. "Last opened 2 hours ago".
    var formattedLastOpened: String {
        "Last opened " + lastOpened.formatted(.relative(presentation: .named))
    }
}
