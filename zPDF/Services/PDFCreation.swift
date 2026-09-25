// Converting non-PDF sources into PDF pages with macOS facilities only.
//
// Fidelity notes (shown to the user where relevant):
// * Text documents (.docx, .doc, .rtf, .rtfd, .odt, .txt, .md) are read by
//   AppKit's NSAttributedString importers and laid out with TextKit. Text,
//   fonts, colors, paragraph styles, simple tables and inline images carry
//   over; headers/footers, footnotes, section layouts and complex Word
//   features do not.
// * HTML files and web pages render with WebKit and paginate through the
//   print system, so print CSS (@media print, page-break-*) applies.
// * Spreadsheets, presentations and other formats macOS can preview
//   (.xlsx, .pptx, .numbers, .key, .pages…) are converted from Quick Look's
//   rendering of the first sheet/slide as an image page — a best-effort
//   preview, not an editable conversion. Microsoft Office or LibreOffice is
//   not driven from the sandboxed app.

import AppKit
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import WebKit

enum CreationError: LocalizedError {
    case unsupported(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "“\(name)” can't be converted to PDF on this Mac."
        case .failed(let message): message
        }
    }
}

enum SourceKind {
    case pdf, image, text, web, preview

    static let textTypes: [UTType] = [.rtf, .rtfd, .plainText, .utf8PlainText,
                                      UTType("org.openxmlformats.wordprocessingml.document"),
                                      UTType("com.microsoft.word.doc"), UTType("org.oasis-open.opendocument.text"),
                                      UTType("net.daringfireball.markdown")].compactMap { $0 }
    static let previewTypes: [UTType] = [UTType("org.openxmlformats.spreadsheetml.sheet"),
                                         UTType("com.microsoft.excel.xls"),
                                         UTType("org.openxmlformats.presentationml.presentation"),
                                         UTType("com.microsoft.powerpoint.ppt"),
                                         UTType("com.apple.iwork.numbers.numbers"), UTType("com.apple.iwork.keynote.key"),
                                         UTType("com.apple.iwork.pages.pages"), UTType("org.oasis-open.opendocument.spreadsheet"),
                                         UTType("org.oasis-open.opendocument.presentation")].compactMap { $0 }
    static let webTypes: [UTType] = [.html, .webArchive]
    /// Everything Create PDF / Combine accepts.
    static let allTypes: [UTType] = [.pdf, .image] + textTypes + webTypes + previewTypes

    static func of(_ url: URL) -> SourceKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if webTypes.contains(where: { type.conforms(to: $0) }) { return .web }
        if textTypes.contains(where: { type.conforms(to: $0) }) || type.conforms(to: .text) { return .text }
        if previewTypes.contains(where: { type.conforms(to: $0) }) { return .preview }
        return nil
    }
}

@MainActor
enum PDFCreation {
    static let letter = CGSize(width: 612, height: 792)

    /// A one-page blank seed for engine create flows.
    static func seed(in directory: URL, size: CGSize = letter) throws -> URL {
        try blankPDF(pages: 1, size: size, to: directory.appendingPathComponent("seed-\(UUID().uuidString.prefix(6)).pdf"))
    }

    @discardableResult
    static func blankPDF(pages: Int, size: CGSize, to url: URL) throws -> URL {
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CreationError.failed("A blank PDF could not be created.")
        }
        for _ in 0..<max(1, pages) {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Text documents

    static func attributedString(from url: URL) throws -> NSAttributedString {
        var attributes: NSDictionary?
        if url.pathExtension.lowercased() == "md",
           let markdown = try? String(contentsOf: url, encoding: .utf8),
           let parsed = try? NSAttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return parsed
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
        } catch {
            throw CreationError.unsupported(url.lastPathComponent)
        }
    }

    /// Lays out attributed text across pages (TextKit) into a real-text PDF.
    @discardableResult
    static func textPDF(_ text: NSAttributedString, to url: URL, paper: CGSize = letter,
                        margins: NSEdgeInsets = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)) throws -> URL {
        let content = NSMutableAttributedString(attributedString: text)
        if content.length == 0 { content.append(NSAttributedString(string: " ")) }
        // Default to a readable body font and dark text where the source has none.
        content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if value == nil { content.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: paper.width - margins.left - margins.right, height: paper.height - margins.top - margins.bottom)
        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs || containers.count > 5000 || range.length == 0 && containers.count > 1 { break }
        }
        var box = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CreationError.failed("The PDF could not be written.")
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for container in containers {
            let range = layout.glyphRange(for: container)
            if range.length == 0 && containers.count > 1 { continue }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let origin = CGPoint(x: margins.left, y: margins.top)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Web content

    /// Loads HTML (a file, a web URL, or a string) in WebKit and paginates it
    /// through the print system (print CSS applies).
    static func webPDF(url: URL? = nil, html: String? = nil, baseURL: URL? = nil, to output: URL,
                       paper: CGSize = letter, timeout: TimeInterval = 45) async throws -> URL {
        let renderer = WebPDFRenderer(paper: paper)
        return try await renderer.render(url: url, html: html, baseURL: baseURL, to: output, timeout: timeout)
    }

    // MARK: Quick Look previews

    /// A best-effort image of the document's first page/sheet/slide.
    static func previewImage(of url: URL, into directory: URL) async throws -> URL {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1700, height: 2200), scale: 1,
                                                   representationTypes: .thumbnail)
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        let target = directory.appendingPathComponent(UUID().uuidString.prefix(8) + "-preview.png")
        guard ImageNormalizer.write(representation.cgImage, to: target, jpeg: false, dpi: 200) else {
            throw CreationError.unsupported(url.lastPathComponent)
        }
        return target
    }

    /// Converts any supported source to files the engine can insert
    /// (PDFs and images), in order.
    static func engineInputs(for urls: [URL], in work: URL) async throws -> [URL] {
        var out: [URL] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let stem = url.deletingPathExtension().lastPathComponent
            let pdf = work.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(stem).pdf")
            switch SourceKind.of(url) {
            case .pdf?, .image?:
                let copy = work.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(url.lastPathComponent)")
                try FileManager.default.copyItem(at: url, to: copy)
                out.append(copy)
            case .text?:
                out.append(try textPDF(try attributedString(from: url), to: pdf))
            case .web?:
                out.append(try await webPDF(url: url, to: pdf))
            case .preview?:
                out.append(try await previewImage(of: url, into: work))
            case nil:
                throw CreationError.unsupported(url.lastPathComponent)
            }
        }
        return out
    }
}

/// WebKit → paginated PDF via NSPrintOperation (offscreen window). Falls back
/// to slicing WebKit's single-page PDF if printing yields nothing.
@MainActor
final class WebPDFRenderer: NSObject, WKNavigationDelegate {
    private let paper: CGSize
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loaded: CheckedContinuation<Void, Error>?
    private var printed: CheckedContinuation<Bool, Never>?

    init(paper: CGSize) { self.paper = paper }

    func render(url: URL?, html: String?, baseURL: URL?, to output: URL, timeout: TimeInterval) async throws -> URL {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: paper.width, height: paper.height), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: paper.width, height: paper.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        defer { window.orderOut(nil); window.contentView = nil; self.window = nil; webView = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            if let html {
                view.loadHTMLString(html, baseURL: baseURL)
            } else if let url, url.isFileURL {
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else if let url {
                view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
            } else {
                continuation.resume(throwing: CreationError.failed("Nothing to convert."))
                loaded = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    if let pending = self?.loaded {
                        self?.loaded = nil
                        pending.resume(throwing: CreationError.failed("The page took too long to load."))
                    }
                }
            }
        }
        // Let late layout (web fonts, images) settle briefly.
        try await Task.sleep(for: .milliseconds(300))
        if try await printToPDF(view, window: window, output: output) { return output }
        return try await sliceSinglePage(view, output: output)
    }

    private func printToPDF(_ view: WKWebView, window: NSWindow, output: URL) async throws -> Bool {
        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = CGRect(origin: .zero, size: paper)
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printed = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }
        guard success, let document = PDFDocument(url: output), document.pageCount > 0 else { return false }
        // WebKit sometimes emits empty pages when printing offscreen; require text or content.
        return document.string?.isEmpty == false || (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 2000
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printed?.resume(returning: success)
        printed = nil
    }

    /// Fallback: WebKit's full-height PDF, cut into pages.
    private func sliceSinglePage(_ view: WKWebView, output: URL) async throws -> URL {
        let data = try await view.pdf(configuration: WKPDFConfiguration())
        guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider),
              let page = source.page(at: 1) else { throw CreationError.failed("The web page could not be converted.") }
        let full = page.getBoxRect(.mediaBox)
        let scale = (paper.width - 72) / max(1, full.width)
        let sliceHeight = (paper.height - 72) / scale
        var box = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { throw CreationError.failed("The PDF could not be written.") }
        var top = full.maxY
        while top > full.minY {
            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: CGRect(x: 36, y: 36, width: paper.width - 72, height: paper.height - 72))
            context.translateBy(x: 36, y: paper.height - 36)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -full.minX, y: -top)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            top -= sliceHeight
        }
        context.closePDF()
        return output
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }

    private func fail(_ error: Error) {
        loaded?.resume(throwing: CreationError.failed("The page could not be loaded: \(error.localizedDescription)"))
        loaded = nil
    }
}

@MainActor
extension AppState {
    /// Opens a newly created private PDF as an untitled document. The first
    /// Save asks where to put it; closing asks before discarding it.
    func openCreatedDocument(at url: URL, name: String) async -> DocumentTab? {
        do {
            let info = try await NativeSaveBridge.inspect(url)
            let source = try await DocumentEditSource.capture(url, expectedHash: info.sourceHash)
            let document = try engine.openDocument(at: source.url)
            let baseline = try await SaveBaseline.capture(document)
            let tab = DocumentTab(url: source.url, pdfDocument: document)
            tab.saveBaseline = baseline
            tab.editSource = source
            tab.sourceHash = info.sourceHash
            tab.saveBlock = info.writeBlock
            tab.recoveredName = name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
            tab.requiresSaveAs = true
            tab.hasUnsavedChanges = true
            applyReadingPreferences(to: tab)
            resetUndoHistory(tab)
            tabs.append(tab)
            selectTab(tab)
            return tab
        } catch {
            saveError = OpenError(fileName: name, message: error.localizedDescription)
            return nil
        }
    }

    /// Combines PDFs, images, text/Office documents and web files into one
    /// new PDF (in order) and opens it untitled.
    @discardableResult
    func createPDF(from urls: [URL], name: String? = nil, imageOptions: [String: Any] = [:]) async -> DocumentTab? {
        guard !urls.isEmpty else { return nil }
        do {
            let work = try NativeWorkDirectory()
            let inputs = try await PDFCreation.engineInputs(for: urls, in: work.url)
            let seed = try PDFCreation.seed(in: work.url)
            var ops = try AppState.insertionOps(inputs, pages: nil, at: 0, imageOptions: imageOptions, work: work.url)
            ops.append(["op": "delete_pages", "pages": [-1]])
            // The seed page is last after all insertions.
            let total = try ops.dropLast().reduce(0) { count, op in
                if op["op"] as? String == "insert_images" { return count + ((op["images"] as? [String])?.count ?? 0) }
                if let path = op["path"] as? String {
                    guard let pages = CGPDFDocument(URL(fileURLWithPath: path) as CFURL)?.numberOfPages else {
                        throw CreationError.failed("A converted file is not a readable PDF.")
                    }
                    return count + pages
                }
                return count
            }
            ops[ops.count - 1] = ["op": "delete_pages", "pages": [total]]
            let created = try await NativeWorkflowBridge.create(seed: seed, ops: NativeOps(ops), in: work)
            let title = name ?? (urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Untitled")
            return await openCreatedDocument(at: created.url, name: title)
        } catch {
            saveError = OpenError(fileName: "Create PDF", message: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func createPDFFromWeb(_ url: URL) async -> DocumentTab? {
        do {
            let work = try NativeWorkDirectory()
            let output = work.url.appendingPathComponent("web.pdf")
            _ = try await PDFCreation.webPDF(url: url, to: output)
            let name = url.host(percentEncoded: false) ?? "Web Page"
            let tab = await openCreatedDocument(at: output, name: name)
            withExtendedLifetime(work) {}
            return tab
        } catch {
            saveError = OpenError(fileName: url.absoluteString, message: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func createBlankPDF(pages: Int, size: CGSize) async -> DocumentTab? {
        do {
            let work = try NativeWorkDirectory()
            let url = try PDFCreation.blankPDF(pages: pages, size: size, to: work.url.appendingPathComponent("blank.pdf"))
            let tab = await openCreatedDocument(at: url, name: "Untitled")
            withExtendedLifetime(work) {}
            return tab
        } catch {
            saveError = OpenError(fileName: "Blank PDF", message: error.localizedDescription)
            return nil
        }
    }

    /// What Create PDF from Clipboard would use, for menu validation.
    static func clipboardContentDescription(_ pasteboard: NSPasteboard = .general) -> String? {
        let types = pasteboard.types ?? []
        if types.contains(.pdf) { return "PDF" }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return "files" }
        if types.contains(.tiff) || types.contains(.png) || NSImage.canInit(with: pasteboard) { return "image" }
        if types.contains(.rtf) || types.contains(.rtfd) || types.contains(.html) { return "formatted text" }
        if types.contains(.string) { return "text" }
        return nil
    }

    @discardableResult
    func createPDFFromClipboard(_ pasteboard: NSPasteboard = .general) async -> DocumentTab? {
        do {
            let work = try NativeWorkDirectory()
            let types = pasteboard.types ?? []
            if types.contains(.pdf), let data = pasteboard.data(forType: .pdf) {
                let url = work.url.appendingPathComponent("clipboard.pdf")
                try data.write(to: url)
                return await openCreatedDocument(at: url, name: "Clipboard")
            }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                return await createPDF(from: urls)
            }
            if types.contains(.tiff) || types.contains(.png) || NSImage.canInit(with: pasteboard),
               let image = NSImage(pasteboard: pasteboard),
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let url = work.url.appendingPathComponent("clipboard.png")
                guard ImageNormalizer.write(cg, to: url, jpeg: false, dpi: 144) else { throw CreationError.failed("The image could not be read.") }
                let tab = await createPDF(from: [url], name: "Clipboard")
                withExtendedLifetime(work) {}
                return tab
            }
            var text: NSAttributedString?
            if let data = pasteboard.data(forType: .rtfd) { text = NSAttributedString(rtfd: data, documentAttributes: nil) }
            if text == nil, let data = pasteboard.data(forType: .rtf) { text = NSAttributedString(rtf: data, documentAttributes: nil) }
            if text == nil, let data = pasteboard.data(forType: .html) { text = NSAttributedString(html: data, documentAttributes: nil) }
            if text == nil, let string = pasteboard.string(forType: .string) {
                text = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            }
            guard let text else { throw CreationError.failed("The clipboard has nothing that can become a PDF.") }
            let url = try PDFCreation.textPDF(text, to: work.url.appendingPathComponent("clipboard.pdf"))
            return await openCreatedDocument(at: url, name: "Clipboard")
        } catch {
            saveError = OpenError(fileName: "Create PDF from Clipboard", message: error.localizedDescription)
            return nil
        }
    }

    /// A PDF Portfolio: a cover page plus the files embedded as a collection.
    @discardableResult
    func createPortfolio(_ urls: [URL], title: String) async -> DocumentTab? {
        guard !urls.isEmpty else { return nil }
        do {
            let (lease, staged) = try NativeWorkflowBridge.stage(urls)
            let seed = try PDFCreation.seed(in: lease.url)
            let files: [[String: Any]] = zip(staged, urls).map { ["path": $0.path, "name": $1.lastPathComponent] }
            let created = try await NativeWorkflowBridge.create(seed: seed, ops: NativeOps([
                ["op": "create_portfolio", "files": files, "title": title]]), in: lease)
            return await openCreatedDocument(at: created.url, name: title)
        } catch {
            saveError = OpenError(fileName: "Create Portfolio", message: error.localizedDescription)
            return nil
        }
    }
}
