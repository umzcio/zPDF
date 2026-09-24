import Foundation

/// Reading state only: it never captures PDF bytes or enters edit undo history.
struct DocumentViewLocation: Equatable {
    var page: Int
    var zoom: Double
    var mode: PDFViewMode
    var rotation: Int
}

@Observable
final class DocumentViewHistory {
    private(set) var locations: [DocumentViewLocation] = []
    private(set) var index = -1
    @ObservationIgnored var isRestoring = false
    @ObservationIgnored var coalescesNotifications = false
    @ObservationIgnored private var lastNotificationTime: TimeInterval?
    private let capacity = 100

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < locations.count - 1 }

    func record(from previous: DocumentViewLocation, to current: DocumentViewLocation,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isRestoring, previous != current else { return }
        if locations.isEmpty { locations = [previous]; index = 0 }
        // A new navigation after Back replaces the forward branch.
        let hadForwardBranch = canGoForward
        if hadForwardBranch { locations.removeSubrange((index + 1)..<locations.count) }
        let coalesce = coalescesNotifications && !hadForwardBranch && index > 0
            && lastNotificationTime.map { now - $0 < 0.75 } == true
        if coalesce {
            locations[index] = current
        } else if locations[index] != current {
            locations.append(current)
            index += 1
        }
        lastNotificationTime = coalescesNotifications ? now : nil
        if locations.count > capacity {
            let excess = locations.count - capacity
            locations.removeFirst(excess)
            index -= excess
        }
    }

    func move(backward: Bool) -> DocumentViewLocation? {
        guard backward ? canGoBack : canGoForward else { return nil }
        index += backward ? -1 : 1
        lastNotificationTime = nil
        return locations[index]
    }

    /// Page-tree edits change the meaning of page numbers. Start a new history.
    func reset() {
        locations = []
        index = -1
        lastNotificationTime = nil
    }
}

extension DocumentTab {
    var viewLocation: DocumentViewLocation {
        DocumentViewLocation(page: currentPage, zoom: zoomFactor, mode: viewMode,
                             rotation: rotationDegrees)
    }

    func recordViewHistory(previousPage: Int? = nil, previousZoom: Double? = nil,
                           previousMode: PDFViewMode? = nil, previousRotation: Int? = nil) {
        guard pendingInitialZoom == nil, pdfDocument != nil else { return }
        var previous = viewLocation
        if let previousPage { previous.page = previousPage }
        if let previousZoom { previous.zoom = previousZoom }
        if let previousMode { previous.mode = previousMode }
        if let previousRotation { previous.rotation = previousRotation }
        viewHistory.record(from: previous, to: viewLocation)
    }

    func restoreViewLocation(_ location: DocumentViewLocation) {
        viewHistory.isRestoring = true
        defer { viewHistory.isRestoring = false }
        pendingInitialZoom = nil
        viewMode = location.mode
        rotationDegrees = location.rotation
        setZoom(location.zoom)
        goToPage(location.page)
    }
}
