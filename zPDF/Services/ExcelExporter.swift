//
//  ExcelExporter.swift
//  zPDF
//
//  Purpose: PDF → .xlsx export used by BasicExportService. Rough table
//  reconstruction from page text geometry (partial fidelity is explicitly
//  fine): text comes from PDFKit selections (`selectionsByLine` plus a
//  strip-selection scan that splits fragments at large x-gaps), rows
//  cluster by y-coordinate, columns by x-gap. Emits minimal valid SpreadsheetML (inline strings) packed
//  with OOXMLZip from OOXML.swift.
//  Phase: 4 — implemented.
//

import AppKit
import Foundation
import PDFKit

enum ExcelExporter {
    /// One text fragment (word) with its page-space bounds (bottom-left origin).
    private struct TextFragment {
        let text: String
        let bounds: CGRect
    }

    /// X-distance below which two fragment starts count as the same column.
    private static let columnGap: CGFloat = 24

    @MainActor static func export(document: EngineDocument, to destination: URL, engine: any PDFEngine) throws {
        let pageCount = engine.pageCount(of: document)
        guard pageCount > 0 else { throw ExportError.nothingToExport }

        // All pages share one sheet; pages are separated by a blank row.
        var sheetRows: [[Int: String]] = []
        for index in 0..<pageCount {
            guard let page = engine.page(at: index, in: document) else { continue }
            if !sheetRows.isEmpty { sheetRows.append([:]) }
            sheetRows.append(contentsOf: gridRows(for: fragments(on: page)))
        }
        guard sheetRows.contains(where: { !$0.isEmpty }) else {
            throw ExportError.nothingToExport
        }

        let entries = [
            OOXMLZip.Entry(name: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            OOXMLZip.Entry(name: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            OOXMLZip.Entry(name: "xl/workbook.xml", data: Data(workbookXML.utf8)),
            OOXMLZip.Entry(name: "xl/_rels/workbook.xml.rels", data: Data(workbookRelsXML.utf8)),
            OOXMLZip.Entry(name: "xl/worksheets/sheet1.xml", data: Data(worksheetXML(rows: sheetRows).utf8)),
        ]
        try OOXMLZip.write(entries: entries, to: destination)
    }

    // MARK: - Text geometry

    /// Text fragments of a page with page-space bounds, split at large
    /// x-gaps. PDFKit's `selectionsByLine` merges disjoint text blocks on
    /// one baseline into a single selection, so each line is scanned with
    /// 1pt-wide strip selections (`selection(for:)`): a strip returns the
    /// glyph whose center it covers, and any empty run wider than the gap
    /// threshold (scaled to the line height) starts a new fragment. Each
    /// fragment's text comes from a selection over its own rect, so inner
    /// spacing is preserved verbatim.
    private static func fragments(on page: EnginePage) -> [TextFragment] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        var fragments: [TextFragment] = []
        for line in selection.selectionsByLine() {
            let lineBounds = line.bounds(for: page)
            guard lineBounds.width > 0, lineBounds.height > 0 else { continue }
            let gapThreshold = max(columnGap, lineBounds.height * 1.5)
            var fragmentStart: CGFloat?
            var lastHit = lineBounds.minX
            var x = lineBounds.minX
            while x <= lineBounds.maxX {
                let strip = CGRect(x: x, y: lineBounds.minY, width: 1, height: lineBounds.height)
                let hit = !(page.selection(for: strip)?.string?
                    .trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                if hit {
                    fragmentStart = fragmentStart ?? x
                    lastHit = x
                } else if fragmentStart != nil, x - lastHit > gapThreshold {
                    appendFragment(on: page, yBand: lineBounds, from: fragmentStart!, to: lastHit + 1,
                                   into: &fragments)
                    fragmentStart = nil
                }
                x += 1
            }
            if let start = fragmentStart {
                appendFragment(on: page, yBand: lineBounds, from: start, to: lastHit + 1,
                               into: &fragments)
            }
        }
        return fragments
    }

    private static func appendFragment(on page: EnginePage, yBand: CGRect,
                                       from minX: CGFloat, to maxX: CGFloat,
                                       into fragments: inout [TextFragment]) {
        let rect = CGRect(x: minX, y: yBand.minY, width: max(1, maxX - minX), height: yBand.height)
        guard let text = page.selection(for: rect)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        fragments.append(TextFragment(text: text, bounds: rect))
    }

    /// Cluster fragments into rows (same y-band, top of page first) and
    /// assign each fragment a column by clustering fragment-start x positions.
    private static func gridRows(for fragments: [TextFragment]) -> [[Int: String]] {
        guard !fragments.isEmpty else { return [] }

        var columnStarts: [CGFloat] = []
        for x in fragments.map({ $0.bounds.minX }).sorted() {
            if let last = columnStarts.last, x - last <= columnGap { continue }
            columnStarts.append(x)
        }

        var clustered: [[TextFragment]] = []
        for fragment in fragments.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            let tolerance = max(3, fragment.bounds.height * 0.5)
            if let reference = clustered.last?.first,
               abs(reference.bounds.midY - fragment.bounds.midY) <= tolerance {
                clustered[clustered.count - 1].append(fragment)
            } else {
                clustered.append([fragment])
            }
        }

        return clustered.map { row in
            var cells: [Int: String] = [:]
            for fragment in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                let column = columnStarts.lastIndex(where: { $0 <= fragment.bounds.minX + columnGap }) ?? 0
                cells[column] = [cells[column], fragment.text].compactMap { $0 }.joined(separator: " ")
            }
            return cells
        }
    }

    // MARK: - SpreadsheetML parts

    private static let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """

    private static let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    private static let workbookXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>\
        </workbook>
        """

    private static let workbookRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """

    private static func worksheetXML(rows: [[Int: String]]) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>

            """
        for (rowIndex, cells) in rows.enumerated() {
            xml += "<row r=\"\(rowIndex + 1)\">"
            for column in cells.keys.sorted() {
                let reference = "\(columnLetter(column))\(rowIndex + 1)"
                xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(escapeXML(cells[column] ?? ""))</t></is></c>"
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    /// Spreadsheet column letter for a 0-based column index (0 → "A").
    private static func columnLetter(_ index: Int) -> String {
        var value = index + 1
        var letters = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            letters = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(remainder))) + letters
            value = (value - 1) / 26
        }
        return letters
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
