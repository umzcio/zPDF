import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case docx, xlsx, pptx, html, markdown = "md", rtf, xml, epub, png, jpeg, text
    var id: String { rawValue }
    var usesWorker: Bool { [.docx, .xlsx, .pptx, .html, .markdown, .rtf, .xml, .epub].contains(self) }
    var isImage: Bool { self == .png || self == .jpeg }
    var hasLayout: Bool { self == .docx || self == .html }
    var title: String { switch self {
    case .docx: "Word document"; case .xlsx: "Excel workbook"; case .pptx: "PowerPoint presentation"; case .html: "HTML webpage"
    case .markdown: "Markdown"; case .rtf: "Rich Text (RTF)"; case .xml: "XML data"; case .epub: "EPUB ebook"
    case .png: "PNG image"; case .jpeg: "JPEG image"; case .text: "Plain text"
    } }
    var fileExtension: String { switch self { case .jpeg: "jpg"; case .text: "txt"; default: rawValue } }
    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }
    var explanation: String { switch self {
    case .docx: "Rebuilds editable text and layout for Word. Fonts may differ; diagrams and their labels can become pictures. Images are limited to 200 dpi."
    case .xlsx: "Reconstructs tables as worksheets, with other content on a Text sheet. Printed totals stay values, never formulas. Pictures become descriptions; page styling is not preserved."
    case .html: "Creates a self-contained webpage with no scripts or external images. Preserve layout uses fixed pages; Responsive reading rearranges content for smaller screens. Images are limited to 200 dpi."
    case .pptx: "One slide per page. Editable places text boxes, pictures and simple shapes at their positions; Page image puts each page's drawing behind editable text. Text doesn't reflow across lines, tables are drawn rather than PowerPoint tables, fonts are Arial/Times/Courier stand-ins, and comments become speaker notes."
    case .rtf: "Exports reading order as rich text with pictures, lists, tables and links. Page layout, columns, shading, text color and font changes inside a paragraph are not kept. TextEdit doesn't show RTF pictures; Word does."
    case .xml: "Structured data: pages, blocks, lines and words with positions, reading order, tables, images and form values, validated against the zPDF XML schema. Describes content, not appearance."
    case .epub: "A reflowable EPUB 3 book: one chapter per page, table of contents from bookmarks or headings, pictures included. Page layout, fonts and colors are set by the reading app."
    case .markdown: "Exports reading order as GitHub Flavored Markdown, with pictures in a companion folder. Keep that folder beside the document. Fonts, page layout and merged table cells cannot be preserved."
    case .text: "Exports selectable text, filled form values and comments. Scanned pages need OCR, which is not included."
    default: "Exports visible page content and markups. Multiple pages are saved as separate images in a new folder."
    } }
}

struct ConversionOptions: Sendable {
    var format: ConversionFormat
    var pages: IndexSet
    var dpi: Int = 150
    var jpegQuality: Double = 0.85
    var layoutMode = "preserve"
    var pptxMode = "editable"
    var producesFolder: Bool { format.isImage && pages.count > 1 }
}

struct ConversionResult: Sendable {
    let url: URL
    let fileCount: Int
    let byteCount: Int64
    let pagesWithoutText: [Int]
    var notices: [ExportNotice] = []
}

/// Cooperative cancellation between page operations, including a publication
/// gate: Cancel cannot race a successful move and report a canceled export.
final class ConversionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var published = false
    func cancel() { lock.withLock { if !published { canceled = true } } }
    func check() throws { try lock.withLock { if canceled { throw CancellationError() } } }
    func publish(_ body: () throws -> Void) throws {
        try lock.withLock {
            if canceled { throw CancellationError() }
            try body()
            published = true
        }
    }
}

/// Read-only conversion of an isolated native-engine candidate. PDFKit objects
/// are created, used and released entirely on this worker, never shared with
/// the live PDFView. This path never writes a PDF or modifies the input.
enum DocumentConversion {
    static func export(input: URL, options: ConversionOptions, destination: SaveDestination,
                       cancellation: ConversionCancellation,
                       progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> ConversionResult {
        try await Task.detached(priority: .userInitiated) {
            try cancellation.check()
            guard let document = PDFDocument(url: input), !document.isLocked,
                  !options.pages.isEmpty,
                  options.pages.allSatisfy({ (0..<document.pageCount).contains($0) }),
                  [72, 150, 300].contains(options.dpi),
                  options.jpegQuality.isFinite, (0.1...1).contains(options.jpegQuality),
                  !SaveDestination.sameFile(input, destination.url) else {
                throw NativeSaveError(code: "INVALID_EXPORT", message: "Choose valid pages, image settings and a separate export destination.")
            }
            let manager = FileManager.default
            let staging = destination.url.deletingLastPathComponent().appendingPathComponent(".zpdf-export-\(UUID())", isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            let payload = staging.appendingPathComponent("output", isDirectory: options.producesFolder)
            if options.producesFolder { try manager.createDirectory(at: payload, withIntermediateDirectories: false) }
            var bytes: Int64 = 0
            var missing: [Int] = []
            var textParts: [String] = []
            var hasTextContent = false
            for (offset, index) in options.pages.enumerated() {
                try cancellation.check()
                try autoreleasepool {
                    guard let page = document.page(at: index) else { throw ExportError.renderingFailed }
                    if options.format == .text {
                        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if text.isEmpty { missing.append(index + 1) }
                        var parts = ["Page \(index + 1)", text]
                        // PDF text extraction alone omits widget values and note
                        // contents. Preserve them in explicitly labeled sections.
                        var seen = Set<String>()
                        let fields = page.annotations.compactMap { annotation -> String? in
                            guard annotation.type == "Widget", let name = annotation.fieldName,
                                  let value = annotation.widgetStringValue, !value.isEmpty else { return nil }
                            let line = "\(name): \(value)"
                            return seen.insert(line).inserted ? line : nil
                        }
                        if !fields.isEmpty { parts.append("Form values\n" + fields.joined(separator: "\n")) }
                        let notes = page.annotations.compactMap { annotation -> String? in
                            guard annotation.type != "Widget", annotation.type != "Link",
                                  let content = annotation.contents, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                            return content
                        }
                        if !notes.isEmpty { parts.append("Comments\n" + notes.joined(separator: "\n")) }
                        if !text.isEmpty || !fields.isEmpty || !notes.isEmpty { hasTextContent = true }
                        if text.isEmpty && fields.isEmpty && notes.isEmpty {
                            parts.append("[No selectable text on this page; OCR may be needed.]")
                        }
                        textParts.append(parts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
                    } else {
                        let file = options.producesFolder
                            ? payload.appendingPathComponent(String(format: "page-%04d.%@", index + 1, options.format.fileExtension)) : payload
                        try writeImage(page, options: options, to: file)
                        bytes += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    }
                }
                try cancellation.check()
                await progress(offset + 1, options.pages.count)
            }
            if options.format == .text {
                // Do not silently succeed with an empty text file for a scan.
                if !hasTextContent {
                    throw NativeSaveError(code: "OCR_REQUIRED", message: "These pages have no selectable text. OCR is not available in this export; export images instead.")
                }
                let data = Data(textParts.joined(separator: "\n\n\u{000C}\n\n").utf8)
                try data.write(to: payload)
                bytes = Int64(data.count)
            }
            try cancellation.publish {
                var coordinationError: NSError?
                var outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(writingItemAt: destination.url, options: .forReplacing, error: &coordinationError) { target in
                    outcome = Result {
                        if manager.fileExists(atPath: target.path) {
                            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard destination.overwrite, !options.producesFolder,
                                  values.isRegularFile == true, values.isSymbolicLink != true else {
                                throw NativeSaveError(code: "DESTINATION_EXISTS", message: "Choose a new output name. Existing folders and unapproved files are never replaced.")
                            }
                            _ = try manager.replaceItemAt(target, withItemAt: payload)
                        } else { try manager.moveItem(at: payload, to: target) }
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let outcome else { throw NativeSaveError(code: "EXPORT_FAILED", message: "Could not access the export destination.") }
                try outcome.get()
            }
            return ConversionResult(url: destination.url, fileCount: options.producesFolder ? options.pages.count : 1,
                                    byteCount: bytes, pagesWithoutText: missing)
        }.value
    }

    private static func writeImage(_ page: PDFPage, options: ConversionOptions, to url: URL) throws {
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let scale = Double(options.dpi) / 72
        let width = ((rotated ? bounds.height : bounds.width) * scale).rounded()
        let height = ((rotated ? bounds.width : bounds.height) * scale).rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 20_000_000 else {
            throw NativeSaveError(code: "IMAGE_TOO_LARGE", message: "This page is too large at the selected resolution. Choose a lower resolution.")
        }
        let size = CGSize(width: width, height: height)
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.renderingFailed }
        // An opaque white page avoids black transparent regions in JPEGs.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let opaque = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(url as CFURL, options.format.contentType.identifier as CFString, 1, nil) else {
            throw ExportError.renderingFailed
        }
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: options.dpi, kCGImagePropertyDPIHeight: options.dpi,
                                          kCGImageDestinationLossyCompressionQuality: options.jpegQuality]
        CGImageDestinationAddImage(writer, opaque, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ExportError.renderingFailed }
    }
}
