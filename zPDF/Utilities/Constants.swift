//
//  Constants.swift
//  zPDF
//
//  Purpose: App-wide constants — identifiers, UserDefaults keys, limits.
//  Phase: 1 (stable). No TODOs here.
//

import Foundation

enum Constants {
    static let appName = "zPDF"
    static let bundleIdentifier = "app.zpdf.zPDF"

    enum DefaultsKey {
        /// JSON-encoded [RecentFile] payload.
        static let recentFiles = "zpdf.recentFiles.v1"
        /// JSON-encoded [SavedSignature] payload.
        static let signatures = "zpdf.signatures.v1"
    }

    enum Limits {
        /// Maximum number of entries kept in the recents list.
        static let maxRecentFiles = 24
        /// Zoom bounds shared by ZoomController and the toolbar (50%–200%).
        static let minZoom: Double = 0.5
        static let maxZoom: Double = 2.0
    }
}
