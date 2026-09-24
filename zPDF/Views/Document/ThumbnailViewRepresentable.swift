//
//  ThumbnailViewRepresentable.swift
//  zPDF
//
//  Purpose: Wraps PDFKit's PDFThumbnailView for the sidebar's Pages tab.
//  Binds to the shared PDFView via PDFViewStore (set by
//  PDFViewRepresentable), so thumbnails track the displayed document.
//  Phase: 1 — REAL. No TODOs.
//

import PDFKit
import SwiftUI

struct ThumbnailViewRepresentable: NSViewRepresentable {
    let viewStore: PDFViewStore
    let pageRevision: Int
    let document: PDFDocument?

    final class Coordinator {
        var revision = -1
        weak var document: PDFDocument?
        var update = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = viewStore.pdfView
        thumbnailView.thumbnailSize = NSSize(width: 120, height: 155)
        thumbnailView.backgroundColor = .clear
        return thumbnailView
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        let coordinator = context.coordinator
        coordinator.update += 1
        let update = coordinator.update
        // The sidebar may update before the canvas swaps documents. Bind on
        // the next runloop, and reject callbacks from an earlier tab switch.
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, coordinator.update == update,
                  let pdfView = viewStore.pdfView,
                  pdfView.document === document else { return }
            if nsView.pdfView !== pdfView || coordinator.revision != pageRevision
                || coordinator.document !== document {
                nsView.pdfView = nil
                nsView.pdfView = pdfView
                coordinator.revision = pageRevision
                coordinator.document = document
            }
        }
    }
}
