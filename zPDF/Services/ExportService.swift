//
//  ExportService.swift
//  zPDF
//
//  Purpose: Contract for PDF→other-format conversion, backing the Export
//  panel's radio list (Word/Excel/PowerPoint/Text/Image/HTML).
//  BasicExportService implements plain text and image export inline and
//  dispatches Word/HTML to OOXML.swift and Excel/PowerPoint to
//  ExcelExporter.swift / PowerPointExporter.swift (all real as of phase 4).
//  Phase: 4 service — stubbed early so the Export panel has a seam.
//

import AppKit
import Foundation
import PDFKit

/// Formats in the Export panel's "Convert to" radio list (prototype order).
enum ExportFormat: String, CaseIterable, Identifiable {
    case word
    case excel
    case powerPoint
    case plainText
    case image
    case html

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .word: "Microsoft Word (.docx)"
        case .excel: "Microsoft Excel (.xlsx)"
        case .powerPoint: "Microsoft PowerPoint (.pptx)"
        case .plainText: "Plain Text (.txt)"
        case .image: "Image (PNG / JPEG)"
        case .html: "HTML Web Page"
        }
    }

    var fileExtension: String {
        switch self {
        case .word: "docx"
        case .excel: "xlsx"
        case .powerPoint: "pptx"
        case .plainText: "txt"
        case .image: "png"
        case .html: "html"
        }
    }

    var symbolName: String {
        switch self {
        case .word: "doc.richtext"
        case .excel: "tablecells"
        case .powerPoint: "play.rectangle"
        case .plainText: "doc.plaintext"
        case .image: "photo"
        case .html: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Formats BasicExportService can actually produce today. All six are
    /// real as of phase 4: text/image inline, Word/HTML via OOXML.swift,
    /// Excel/PowerPoint via their dedicated exporters.
    var isSupportedByBasicService: Bool { true }
}

enum ExportError: Error, LocalizedError {
    case unsupportedFormat(ExportFormat)
    case nothingToExport
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            "\(format.displayName) export is not implemented yet (phase 4)."
        case .nothingToExport:
            "The document contains no exportable content."
        case .renderingFailed:
            "A page could not be rendered for export."
        }
    }
}

protocol ExportService {
    /// Export `document` to `destination` in the given format.
    /// Main-actor isolated for the scaffold so PDFDocument (non-Sendable)
    /// can cross cleanly; TODO(phase-4): move heavy rendering/writing off
    /// the main actor behind a Sendable snapshot boundary, and add progress
    /// reporting + cancellation.
    @MainActor func export(document: EngineDocument, format: ExportFormat, to destination: URL) async throws
}

/// Dependency-free baseline exporter.
///
/// Office/HTML fidelity notes (phase 4): full-fidelity conversion needs
/// layout analysis — reading-order detection, column segmentation, table
/// reconstruction, font mapping — which remains the hardest feature class
/// in the product; consider an engine swap for it (see SPEC.md §2.2). The
/// current exporters reconstruct paragraphs from line geometry and accept
/// partial layout fidelity (see IMPLEMENTATION.md phase 4).
final class BasicExportService: ExportService {
    private let engine: any PDFEngine

    init(engine: any PDFEngine = PDFKitEngine()) {
        self.engine = engine
    }

    @MainActor
    func export(document: EngineDocument, format: ExportFormat, to destination: URL) async throws {
        switch format {
        case .plainText:
            guard let text = document.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExportError.nothingToExport
            }
            try text.write(to: destination, atomically: true, encoding: .utf8)

        case .image:
            // Exports the FIRST page as PNG at ~144 DPI.
            // TODO(phase-4): export every page; let the user pick a folder,
            // DPI, and PNG vs JPEG.
            guard let page = engine.page(at: 0, in: document),
                  let image = engine.renderPage(page, toFit: CGSize(width: 1224, height: 1584)),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ExportError.renderingFailed
            }
            try png.write(to: destination)

        case .word:
            try WordExporter.export(document: document, to: destination, engine: engine)

        case .html:
            try HTMLExporter.export(document: document, to: destination, engine: engine)

        case .excel:
            try ExcelExporter.export(document: document, to: destination, engine: engine)

        case .powerPoint:
            try PowerPointExporter.export(document: document, to: destination, engine: engine)
        }
    }
}
