//
//  OOXML.swift
//  zPDF
//
//  Purpose: Dependency-free OOXML foundation (ZIP container writer) plus
//  the Word (.docx) and HTML exporters used by BasicExportService.
//  Phase: 4 — REAL for Word and HTML. Text is extracted with position per
//  page via PDFKit line selections and grouped into paragraphs with y-gap
//  heuristics; partial layout fidelity is accepted by design. Excel and
//  PowerPoint export live in ExcelExporter.swift / PowerPointExporter.swift
//  and share the OOXMLZip writer below.
//

import AppKit
import Foundation
import PDFKit

/// Minimal ZIP writer for OOXML containers. Entries are stored
/// uncompressed with CRC-32 checksums — valid input for Word, Excel, and
/// PowerPoint, and far simpler than wiring the Compression framework for
/// deflate (documents stay small either way).
enum OOXMLZip {
    struct Entry {
        let name: String
        let data: Data
    }

    /// Write a ZIP archive containing `entries` to `url`: one local file
    /// header + payload per entry, then the central directory and the
    /// end-of-central-directory record.
    static func write(entries: [Entry], to url: URL) throws {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let checksum = CRC32.of(entry.data)
            let localOffset = UInt32(archive.count)
            let byteCount = UInt32(entry.data.count)

            // Local file header (signature PK\x03\x04).
            archive.appendUInt32LE(0x0403_4B50)
            archive.appendUInt16LE(20)               // version needed to extract
            archive.appendUInt16LE(0x0800)           // flag: UTF-8 entry names
            archive.appendUInt16LE(0)                // method 0 = stored
            archive.appendUInt16LE(0)                // file mod time
            archive.appendUInt16LE(0x21)             // file mod date (1980-01-01)
            archive.appendUInt32LE(checksum)
            archive.appendUInt32LE(byteCount)        // compressed size
            archive.appendUInt32LE(byteCount)        // uncompressed size
            archive.appendUInt16LE(UInt16(nameBytes.count))
            archive.appendUInt16LE(0)                // extra field length
            archive.append(contentsOf: nameBytes)
            archive.append(entry.data)

            // Central directory record (signature PK\x01\x02).
            centralDirectory.appendUInt32LE(0x0201_4B50)
            centralDirectory.appendUInt16LE(20)      // version made by
            centralDirectory.appendUInt16LE(20)      // version needed
            centralDirectory.appendUInt16LE(0x0800)  // UTF-8 entry names
            centralDirectory.appendUInt16LE(0)       // method 0 = stored
            centralDirectory.appendUInt16LE(0)       // file mod time
            centralDirectory.appendUInt16LE(0x21)    // file mod date
            centralDirectory.appendUInt32LE(checksum)
            centralDirectory.appendUInt32LE(byteCount)
            centralDirectory.appendUInt32LE(byteCount)
            centralDirectory.appendUInt16LE(UInt16(nameBytes.count))
            centralDirectory.appendUInt16LE(0)       // extra field length
            centralDirectory.appendUInt16LE(0)       // comment length
            centralDirectory.appendUInt16LE(0)       // disk number start
            centralDirectory.appendUInt16LE(0)       // internal attributes
            centralDirectory.appendUInt32LE(0)       // external attributes
            centralDirectory.appendUInt32LE(localOffset)
            centralDirectory.append(contentsOf: nameBytes)
        }

        // End of central directory (signature PK\x05\x06).
        let directoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x0605_4B50)
        archive.appendUInt16LE(0)                    // disk number
        archive.appendUInt16LE(0)                    // central directory disk
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(directoryOffset)
        archive.appendUInt16LE(0)                    // archive comment length

        try archive.write(to: url, options: .atomic)
    }
}

/// Table-driven CRC-32 (IEEE polynomial), as required by the ZIP format.
private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func of(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum = table[Int((checksum ^ UInt32(byte)) & 0xFF)] ^ (checksum >> 8)
        }
        return checksum ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// One line of text extracted from a page, with the geometry the exporters
/// need to reconstruct paragraphs and rough heading levels.
struct ExportTextLine {
    let text: String
    /// Point size of the line's first character (proxy for the whole line).
    let fontSize: CGFloat
    /// Line bounds in page space (points, bottom-left origin).
    let bounds: CGRect
    /// 0-based page index the line lives on.
    let pageIndex: Int

    /// All text lines of the document in reading order (page order, then
    /// top-to-bottom within each page) via PDFKit line selections.
    static func lines(in document: EngineDocument, engine: any PDFEngine) -> [ExportTextLine] {
        var lines: [ExportTextLine] = []
        for pageIndex in 0..<engine.pageCount(of: document) {
            guard let page = engine.page(at: pageIndex, in: document),
                  let pageSelection = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            for lineSelection in pageSelection.selectionsByLine() {
                guard let text = lineSelection.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let bounds = lineSelection.bounds(for: page)
                var fontSize = max(bounds.height, 1)
                if let attributed = lineSelection.attributedString, attributed.length > 0,
                   let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    fontSize = font.pointSize
                }
                lines.append(ExportTextLine(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                            fontSize: fontSize, bounds: bounds, pageIndex: pageIndex))
            }
        }
        return lines
    }

    /// Group consecutive lines into paragraphs: a new paragraph starts on
    /// a page break, a font-size change, or a vertical gap beyond 60% of
    /// the line height. Lines inside a paragraph are joined with a space.
    static func paragraphs(from lines: [ExportTextLine]) -> [(text: String, fontSize: CGFloat, pageIndex: Int)] {
        var paragraphs: [(text: String, fontSize: CGFloat, pageIndex: Int)] = []
        var previousLine: ExportTextLine?
        for line in lines {
            var startsNewParagraph = true
            if let previous = previousLine, previous.pageIndex == line.pageIndex,
               abs(previous.fontSize - line.fontSize) < 1 {
                // Page space grows upward: the previous line sits above the
                // current one, so the gap is previous-bottom minus current-top.
                let gap = previous.bounds.minY - line.bounds.maxY
                let threshold = max(previous.bounds.height, line.bounds.height) * 0.6
                startsNewParagraph = gap > threshold
            }
            if startsNewParagraph || paragraphs.isEmpty {
                paragraphs.append((text: line.text, fontSize: line.fontSize, pageIndex: line.pageIndex))
            } else {
                paragraphs[paragraphs.count - 1].text += " " + line.text
            }
            previousLine = line
        }
        return paragraphs
    }

    /// Median font size across the document — the "body text" baseline the
    /// exporters compare against to detect headings.
    static func bodyFontSize(of lines: [ExportTextLine]) -> CGFloat {
        let sizes = lines.map(\.fontSize).sorted()
        guard !sizes.isEmpty else { return 12 }
        return sizes[sizes.count / 2]
    }
}

/// Shared XML/HTML escaping for the exporters.
func exportEscapeXML(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// PDF → .docx export: a minimal-but-valid OOXML package
/// ([Content_Types].xml, _rels/.rels, word/document.xml). Paragraphs are
/// reconstructed from line geometry; single-line paragraphs set noticeably
/// larger than the body size become bold, larger runs (direct formatting —
/// no styles.xml part). Acceptance: a valid file; layout fidelity is
/// intentionally partial (see IMPLEMENTATION.md phase 4).
enum WordExporter {
    @MainActor static func export(document: EngineDocument, to destination: URL, engine: any PDFEngine) throws {
        let lines = ExportTextLine.lines(in: document, engine: engine)
        guard !lines.isEmpty else { throw ExportError.nothingToExport }
        let paragraphs = ExportTextLine.paragraphs(from: lines)
        let bodySize = ExportTextLine.bodyFontSize(of: lines)

        var body = ""
        var currentPage = paragraphs.first?.pageIndex ?? 0
        for paragraph in paragraphs {
            if paragraph.pageIndex != currentPage {
                currentPage = paragraph.pageIndex
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
            let isHeading = paragraph.fontSize >= bodySize * 1.3
            let halfPoints = Int((paragraph.fontSize * 2).rounded())
            let runProperties = isHeading
                ? "<w:rPr><w:b/><w:sz w:val=\"\(halfPoints)\"/></w:rPr>"
                : "<w:rPr><w:sz w:val=\"\(halfPoints)\"/></w:rPr>"
            body += "<w:p><w:r>\(runProperties)<w:t xml:space=\"preserve\">\(exportEscapeXML(paragraph.text))</w:t></w:r></w:p>"
        }

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """

        let relationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """

        try OOXMLZip.write(entries: [
            OOXMLZip.Entry(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            OOXMLZip.Entry(name: "_rels/.rels", data: Data(relationships.utf8)),
            OOXMLZip.Entry(name: "word/document.xml", data: Data(documentXML.utf8)),
        ], to: destination)
    }
}

/// PDF → .html export: a single UTF-8 HTML5 document. Paragraphs are
/// reconstructed from line geometry; single-paragraph lines set noticeably
/// larger than the body size become h1/h2 headings, everything else a p.
enum HTMLExporter {
    @MainActor static func export(document: EngineDocument, to destination: URL, engine: any PDFEngine) throws {
        let lines = ExportTextLine.lines(in: document, engine: engine)
        guard !lines.isEmpty else { throw ExportError.nothingToExport }
        let paragraphs = ExportTextLine.paragraphs(from: lines)
        let bodySize = ExportTextLine.bodyFontSize(of: lines)

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Exported document"

        var body = ""
        var currentPage = paragraphs.first?.pageIndex ?? 0
        for paragraph in paragraphs {
            if paragraph.pageIndex != currentPage {
                currentPage = paragraph.pageIndex
                body += "<hr>\n"
            }
            let text = exportEscapeXML(paragraph.text)
            if paragraph.fontSize >= bodySize * 1.6 {
                body += "<h1>\(text)</h1>\n"
            } else if paragraph.fontSize >= bodySize * 1.25 {
                body += "<h2>\(text)</h2>\n"
            } else {
                body += "<p>\(text)</p>\n"
            }
        }

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(exportEscapeXML(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; line-height: 1.5; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; color: #111; }
        hr { border: none; border-top: 1px solid #ddd; margin: 2rem 0; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>
        """

        try Data(html.utf8).write(to: destination, options: .atomic)
    }
}
