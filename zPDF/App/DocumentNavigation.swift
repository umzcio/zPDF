import AppKit

/// Document commands use the same tab state as the toolbar and commit a live
/// form field before moving away. Bare reading keys are scoped to the canvas.
enum PageNavigation {
    case previous, next, first, last
}

extension AppState {
    func navigateView(backward: Bool) {
        guard let tab = activeTab, commitFieldEditing(),
              let location = tab.viewHistory.move(backward: backward) else { return }
        tab.restoreViewLocation(location)
        if let view = pdfViewStore.pdfView { view.window?.makeFirstResponder(view) }
    }

    func navigatePage(_ direction: PageNavigation) {
        guard let tab = activeTab, commitFieldEditing() else { return }
        switch direction {
        case .previous: tab.goToPreviousPage()
        case .next: tab.goToNextPage()
        case .first: tab.goToPage(1)
        case .last: tab.goToPage(tab.pageCount)
        }
        if let view = pdfViewStore.pdfView { view.window?.makeFirstResponder(view) }
    }

    func cycleDocument(backward: Bool) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        selectTab(tabs[(index + (backward ? tabs.count - 1 : 1)) % tabs.count])
    }

    /// Zoom In/Out through the stops in Settings ▸ Page Display ▸ Zoom Steps.
    func stepDocumentZoom(_ direction: ZoomDirection) {
        guard let tab = activeTab else { return }
        tab.setZoom(Self.steppedZoom(from: tab.zoomFactor, direction: direction, steps: preferences.zoomSteps))
    }

    nonisolated static func steppedZoom(from current: Double, direction: ZoomDirection, steps: [Double]) -> Double {
        let stops = steps.isEmpty ? ZoomController.steps : steps.sorted()
        switch direction {
        case .in: return stops.first { $0 > current + 0.001 } ?? ZoomController.maximumZoom
        case .out: return stops.last { $0 < current - 0.001 } ?? ZoomController.minimumZoom
        }
    }
}
