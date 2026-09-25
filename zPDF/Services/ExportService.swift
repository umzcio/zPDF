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
import ImageIO
import PDFKit
import UniformTypeIdentifiers

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

// MARK: - Page images (all pages or a range, JPEG/PNG/TIFF, DPI, color)

enum PageImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, tiff
    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var type: UTType { self == .jpeg ? .jpeg : self == .png ? .png : .tiff }
}

enum PageImageColor: String, CaseIterable, Identifiable {
    case rgb, gray, cmyk
    var id: String { rawValue }
    var title: String { self == .rgb ? "RGB" : self == .gray ? "Grayscale" : "CMYK" }
    var space: CGColorSpace? {
        switch self {
        case .rgb: CGColorSpace(name: CGColorSpace.sRGB)
        case .gray: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        case .cmyk: CGColorSpace(name: CGColorSpace.genericCMYK)
        }
    }
}

enum PageImageExporter {
    /// Renders one page upright at `dpi` in the requested color space.
    @MainActor
    static func render(_ page: PDFPage, dpi: CGFloat, color: PageImageColor, transparent: Bool = false) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let visual = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = dpi / 72
        let width = max(1, Int((visual.width * scale).rounded())), height = max(1, Int((visual.height * scale).rounded()))
        guard width * height <= 400_000_000, let space = color.space else { return nil }
        let info: UInt32
        switch color {
        case .rgb: info = transparent ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        case .gray, .cmyk: info = CGImageAlphaInfo.none.rawValue
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return nil }
        if !(transparent && color == .rgb) {
            if color == .cmyk { context.setFillColor(CGColor(genericCMYKCyan: 0, magenta: 0, yellow: 0, black: 0, alpha: 1)) }
            else { context.setFillColor(CGColor(gray: 1, alpha: 1)) }
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.transform(context, for: .cropBox)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// Writes one image per page (or one multi-page TIFF) into `folder`.
    @MainActor
    static func export(_ document: PDFDocument, pages: [Int], format: PageImageFormat, dpi: CGFloat,
                       color: PageImageColor, quality: Double = 0.85, multipageTIFF: Bool = false,
                       to folder: URL, baseName: String, progress: ((Int) -> Void)? = nil) throws -> [URL] {
        guard !pages.isEmpty else { throw ExportError.nothingToExport }
        guard !(format == .png && color == .cmyk) else {
            throw NativeSaveError(code: "UNSUPPORTED_COLOR", message: "PNG does not support CMYK. Choose JPEG or TIFF.")
        }
        let options: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                        kCGImageDestinationLossyCompressionQuality: quality]
        if format == .tiff && multipageTIFF {
            let url = unique(folder.appendingPathComponent(baseName + ".tiff"))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, pages.count, nil)
            else { throw ExportError.renderingFailed }
            for (n, index) in pages.enumerated() {
                guard let page = document.page(at: index), let image = render(page, dpi: dpi, color: color) else { throw ExportError.renderingFailed }
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
                progress?(n + 1)
            }
            guard CGImageDestinationFinalize(destination) else { throw ExportError.renderingFailed }
            return [url]
        }
        let digits = max(2, String(document.pageCount).count)
        var written: [URL] = []
        for (n, index) in pages.enumerated() {
            guard let page = document.page(at: index), let image = render(page, dpi: dpi, color: color) else { throw ExportError.renderingFailed }
            let number = String(format: "%0\(digits)d", index + 1)
            let url = unique(folder.appendingPathComponent("\(baseName)-\(number).\(format.fileExtension)"))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
            else { throw ExportError.renderingFailed }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ExportError.renderingFailed }
            written.append(url)
            progress?(n + 1)
        }
        return written
    }

    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

