import AppKit
import CoreText
import PDFKit
import XCTest
@testable import zPDF

/// Builds small PDFs with Quartz (real embedded fonts and images) for the
/// Edit PDF and Redact integration tests.
@MainActor
enum EditingFixtures {
    struct Line {
        let text: String
        let origin: CGPoint
        var size: CGFloat = 12
        var fontName = "Helvetica"
    }

    static func makePDF(named name: String, lines: [Line], image: (rect: CGRect, color: NSColor)? = nil,
                        pages: Int = 1, info: [String: String] = [:]) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zPDF editing \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var auxiliary: [CFString: Any] = [:]
        if let title = info["title"] { auxiliary[kCGPDFContextTitle] = title }
        if let author = info["author"] { auxiliary[kCGPDFContextAuthor] = author }
        guard let context = CGContext(url as CFURL, mediaBox: &box, auxiliary as CFDictionary) else {
            throw NSError(domain: "EditingFixtures", code: 1)
        }
        for pageNumber in 0..<pages {
            context.beginPDFPage(nil)
            for line in lines {
                let font = CTFontCreateWithName(line.fontName as CFString, line.size, nil)
                let text = pages > 1 ? line.text.replacingOccurrences(of: "#", with: "\(pageNumber + 1)") : line.text
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = line.origin
                CTLineDraw(ctLine, context)
            }
            if let image, let cgImage = solidImage(color: image.color, size: CGSize(width: 64, height: 64)) {
                context.draw(cgImage, in: image.rect)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return (url, directory)
    }

    static func solidImage(color: NSColor, size: CGSize) -> CGImage? {
        let rgb = color.usingColorSpace(.sRGB) ?? .red
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(rgb.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    static func pngFile(color: NSColor, size: CGSize, in directory: URL) throws -> URL {
        let image = try XCTUnwrap(solidImage(color: color, size: size))
        let rep = NSBitmapImageRep(cgImage: image)
        let url = directory.appendingPathComponent("image-\(UUID()).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// Waits for controller-driven engine work to finish.
    static func idle(_ controller: ContentEditingController, _ tab: DocumentTab, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Task.sleep(for: .milliseconds(30))
        for _ in 0..<1500 {
            if !controller.isBusy && !tab.isSaving { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Editing operation did not finish", file: file, line: line)
    }

    /// Loads the engine's page content for `page` through the controller cache.
    static func content(_ controller: ContentEditingController, page: PDFPage, file: StaticString = #filePath, line: UInt = #line) async throws -> PageContent {
        controller.load(page)
        for _ in 0..<1000 {
            if let content = controller.content(for: page) { return content }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Page content did not load", file: file, line: line)
        throw NSError(domain: "EditingFixtures", code: 2)
    }

    /// PDFium's text for a saved file (via the engine), for independent verification.
    static func pdfiumText(_ url: URL, page: Int = 0) async throws -> String {
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let result = try await state.queryDocument("page_text", params: ["pages": [page]], in: tab)
        let pages = result["pages"] as? [[String: Any]] ?? []
        return pages.first?["text"] as? String ?? ""
    }
}
