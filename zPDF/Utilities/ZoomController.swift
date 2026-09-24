//
//  ZoomController.swift
//  zPDF
//
//  Purpose: Zoom math — clamps to 50%–200%, stepped zoom matching the
//  prototype's ZSTEPS [50,67,75,90,100,110,125,150,175,200], and
//  fit-width / fit-page scale computation.
//  Phase: 1 — REAL implementation (pure functions, unit-testable).
//

import CoreGraphics
import Foundation
import PDFKit

enum ZoomDirection {
    case `in`
    case out
}

enum ZoomController {
    static let minimumZoom: Double = Constants.Limits.minZoom
    static let maximumZoom: Double = Constants.Limits.maxZoom

    /// Discrete zoom stops, mirroring the prototype.
    static let steps: [Double] = [0.50, 0.67, 0.75, 0.90, 1.00, 1.10, 1.25, 1.50, 1.75, 2.00]

    /// Clamp an arbitrary zoom factor into [0.5, 2.0].
    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumZoom), maximumZoom)
    }

    /// Move one step up/down the stops table from an arbitrary current zoom.
    static func steppedZoom(from current: Double, direction: ZoomDirection) -> Double {
        switch direction {
        case .in:
            if let next = steps.first(where: { $0 > current + 0.001 }) {
                return next
            }
            return maximumZoom
        case .out:
            if let previous = steps.last(where: { $0 < current - 0.001 }) {
                return previous
            }
            return minimumZoom
        }
    }

    /// Scale factor so the page width fills the viewport (minus padding).
    static func fitWidthScale(pageSize: CGSize, viewportWidth: CGFloat, padding: CGFloat = 90) -> Double {
        guard pageSize.width > 0, viewportWidth > padding else { return 1.0 }
        return clamp(Double((viewportWidth - padding) / pageSize.width))
    }

    /// Scale factor so the whole page fits inside the viewport (minus padding).
    static func fitPageScale(pageSize: CGSize, viewportSize: CGSize, padding: CGFloat = 80) -> Double {
        guard pageSize.width > 0, pageSize.height > 0,
              viewportSize.width > padding, viewportSize.height > padding else { return 1.0 }
        let scale = min((viewportSize.width - padding) / pageSize.width,
                        (viewportSize.height - padding) / pageSize.height)
        return clamp(Double(scale))
    }

    /// "100%" style label.
    static func percentString(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}

// Shared by the document toolbar and status-bar zoom controls.
extension ZoomController {
    @MainActor
    static func fitWidth(for tab: DocumentTab, in pdfView: PDFView) {
        guard let pageSize = tab.currentPageSize else { return }
        if (tab.rotationDegrees == 90 || tab.rotationDegrees == 270) {
            // Rotated: the page's height runs horizontally and the usable
            // viewport width is the view's height (axes swapped).
            let swappedPage = CGSize(width: pageSize.height, height: pageSize.width)
            tab.setZoom(ZoomController.fitWidthScale(pageSize: swappedPage,
                                                     viewportWidth: pdfView.bounds.height))
        } else {
            tab.setZoom(ZoomController.fitWidthScale(pageSize: pageSize,
                                                     viewportWidth: pdfView.bounds.width))
        }
    }

    @MainActor
    static func fitPage(for tab: DocumentTab, in pdfView: PDFView) {
        // Fit Page is a one-page reading mode, not just a one-time zoom in a
        // continuous strip. Keep that layout when buttons, keys, or scrolling
        // navigate to another page. Both toolbar and status bar use this path.
        tab.pendingInitialZoom = nil
        tab.viewMode = .single
        if (tab.rotationDegrees == 90 || tab.rotationDegrees == 270), let pageSize = tab.currentPageSize {
            let swappedPage = CGSize(width: pageSize.height, height: pageSize.width)
            let swappedViewport = CGSize(width: pdfView.bounds.height,
                                         height: pdfView.bounds.width)
            tab.setZoom(ZoomController.fitPageScale(pageSize: swappedPage,
                                                    viewportSize: swappedViewport))
        } else if let pageSize = tab.currentPageSize {
            // PDFKit's size-to-fit uses width in continuous mode. Fit Page
            // must consider both dimensions regardless of scrolling layout.
            tab.setZoom(ZoomController.fitPageScale(pageSize: pageSize, viewportSize: pdfView.bounds.size))
        }
    }

}
