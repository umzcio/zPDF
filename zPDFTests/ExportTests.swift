//
//  ExportTests.swift
//  zPDFTests
//
//  Purpose: Phase-4 export tests for Word (.docx) and HTML. Fixtures are
//  generated programmatically (CGContext PDF consumer, same pattern as
//  OCRTests); outputs are validated as ZIP/XML/HTML.
//

import AppKit
import PDFKit
import XCTest
@testable import zPDF

final class ExportTests: XCTestCase {

    // MARK: - Fixtures (programmatic — no resource files)

    /// Build a real PDFDocument with a large heading line and two body
    /// lines per page, so selection-based line extraction has geometry to
    /// work with (heading detection + paragraph grouping).
    private static func makeTextDocument(pageCount: Int = 2) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            NSAttributedString(string: "Quarterly Report \(page + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: NSColor.black,
            ]).draw(at: CGPoint(x: 60, y: 680))
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.black,
            ]
            NSAttributedString(string: "The quick brown fox", attributes: bodyAttributes)
                .draw(at: CGPoint(x: 60, y: 600))
            NSAttributedString(string: "jumps over the lazy dog", attributes: bodyAttributes)
                .draw(at: CGPoint(x: 60, y: 578))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    private static func temporaryURL(_ pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-export-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    /// Read a little-endian UInt16/UInt32 straight out of ZIP bytes.
    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    /// Extract a stored (uncompressed) entry from a ZIP archive by walking
    /// the local file headers. Returns nil when the entry is missing.
    private static func zipEntry(named name: String, in data: Data) -> Data? {
        var offset = 0
        while offset + 30 <= data.count, le32(data, offset) == 0x0403_4B50 {
            let method = le16(data, offset + 8)
            let compressedSize = Int(le32(data, offset + 18))
            let nameLength = Int(le16(data, offset + 26))
            let extraLength = Int(le16(data, offset + 28))
            let entryName = String(decoding: data[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            let dataStart = offset + 30 + nameLength + extraLength
            if entryName == name {
                guard method == 0, dataStart + compressedSize <= data.count else { return nil }
                return data[dataStart..<(dataStart + compressedSize)]
            }
            offset = dataStart + compressedSize
        }
        return nil
    }

    /// Central-directory entry names of a ZIP archive (walked from the
    /// end-of-central-directory record).
    private static func zipEntryNames(in data: Data) -> [String] {
        guard data.count >= 22 else { return [] }
        var eocdOffset: Int?
        var cursor = data.count - 22
        while cursor >= 0 {
            if le32(data, cursor) == 0x0605_4B50 { eocdOffset = cursor; break }
            cursor -= 1
        }
        guard let eocd = eocdOffset else { return [] }
        let entryCount = Int(le16(data, eocd + 10))
        var offset = Int(le32(data, eocd + 16))
        var names: [String] = []
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, le32(data, offset) == 0x0201_4B50 else { break }
            let nameLength = Int(le16(data, offset + 28))
            let extraLength = Int(le16(data, offset + 30))
            let commentLength = Int(le16(data, offset + 32))
            names.append(String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return names
    }

    // MARK: - Word (.docx)

    func testWordExportProducesValidDocx() async throws {
        let service = BasicExportService()
        let document = Self.makeTextDocument()
        let destination = Self.temporaryURL("docx")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await service.export(document: document, format: .word, to: destination)

        let data = try Data(contentsOf: destination)
        // Valid ZIP: local file header signature PK\x03\x04 at offset 0.
        XCTAssertGreaterThan(data.count, 4)
        XCTAssertEqual(Self.le32(data, 0), 0x0403_4B50,
                       "expected ZIP local file header signature PK\\x03\\x04")

        // The OOXML package carries the main document part.
        let names = Self.zipEntryNames(in: data)
        XCTAssertTrue(names.contains("[Content_Types].xml"), "entries: \(names)")
        XCTAssertTrue(names.contains("_rels/.rels"), "entries: \(names)")
        XCTAssertTrue(names.contains("word/document.xml"), "entries: \(names)")

        // The document part holds the fixture's text.
        let documentEntry = try XCTUnwrap(Self.zipEntry(named: "word/document.xml", in: data))
        let documentXML = String(decoding: documentEntry, as: UTF8.self)
        XCTAssertTrue(documentXML.contains("quick"), "document.xml: \(documentXML)")
        XCTAssertTrue(documentXML.contains("fox"), "document.xml: \(documentXML)")
        XCTAssertTrue(documentXML.contains("lazy"), "document.xml: \(documentXML)")
        XCTAssertTrue(documentXML.contains("Quarterly"), "document.xml: \(documentXML)")
        XCTAssertTrue(documentXML.contains("<w:p>"), "expected paragraphs in \(documentXML)")
    }

    func testWordExportThrowsOnEmptyDocument() async throws {
        let service = BasicExportService()
        let destination = Self.temporaryURL("docx")
        do {
            try await service.export(document: PDFDocument(), format: .word, to: destination)
            XCTFail("expected nothingToExport for a document with no text")
        } catch ExportError.nothingToExport {
            // Expected.
        }
    }

    // MARK: - HTML

    func testHTMLExportProducesValidHTML5() async throws {
        let service = BasicExportService()
        let document = Self.makeTextDocument()
        let destination = Self.temporaryURL("html")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await service.export(document: document, format: .html, to: destination)

        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"), "html: \(html)")
        XCTAssertTrue(html.contains("<html"), "html: \(html)")
        XCTAssertTrue(html.contains("</html>"), "html: \(html)")
        XCTAssertTrue(html.contains("quick"), "html: \(html)")
        XCTAssertTrue(html.contains("fox"), "html: \(html)")
        XCTAssertTrue(html.contains("lazy"), "html: \(html)")
        XCTAssertTrue(html.contains("<h1>Quarterly Report 1</h1>"),
                      "expected the large fixture line as a heading: \(html)")
        XCTAssertTrue(html.contains("<p>The quick brown fox jumps over the lazy dog</p>"),
                      "expected body lines joined into one paragraph: \(html)")
    }

    // MARK: - Format support surface

    func testAllFormatsAreSupportedByBasicService() {
        for format in ExportFormat.allCases {
            XCTAssertTrue(format.isSupportedByBasicService,
                          "\(format) should dispatch to a real exporter as of phase 4")
        }
    }
}
