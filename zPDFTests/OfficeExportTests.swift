//
//  OfficeExportTests.swift
//  zPDFTests
//
//  Purpose: Phase-4 export tests for Excel (.xlsx) and PowerPoint (.pptx).
//  Fixtures are generated programmatically; outputs validated as ZIP/XML
//  via the system `unzip` tool.
//

import AppKit
import PDFKit
import XCTest
@testable import zPDF

final class OfficeExportTests: XCTestCase {

    // MARK: - Fixtures (programmatic — no resource files)

    /// Two-page PDF whose pages carry short text lines at distinct
    /// positions, so table/slide reconstruction has geometry to work with.
    private static func makeFixtureDocument() -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        let linesByPage: [[(text: String, x: CGFloat, y: CGFloat)]] = [
            [("Name", 60, 700), ("Alice", 300, 700), ("Total", 60, 640), ("42", 300, 640)],
            [("Second page", 60, 700), ("Bob", 60, 640)],
        ]
        for lines in linesByPage {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 36),
                .foregroundColor: NSColor.black,
            ]
            for line in lines {
                line.text.draw(at: CGPoint(x: line.x, y: line.y), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    private func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-export-\(UUID().uuidString).\(ext)")
    }

    /// Read one entry out of a ZIP archive with the system unzip tool.
    private func zipEntry(_ name: String, in url: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, name]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip could not read \(name)")
        return String(decoding: data, as: UTF8.self)
    }

    private func assertZipSignature(_ url: URL) throws {
        let bytes = try Data(contentsOf: url).prefix(4)
        XCTAssertEqual([UInt8](bytes), [0x50, 0x4B, 0x03, 0x04],
                       "expected PK\\x03\\x04 ZIP signature in \(url.lastPathComponent)")
    }

    // MARK: - Excel (.xlsx)

    func testExcelExportProducesValidXLSX() async throws {
        let destination = temporaryURL(extension: "xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await ExcelExporter.export(document: Self.makeFixtureDocument(),
                                       to: destination, engine: PDFKitEngine())

        try assertZipSignature(destination)
        let sheet = try zipEntry("xl/worksheets/sheet1.xml", in: destination)
        for word in ["Name", "Alice", "Total", "42", "Bob"] {
            XCTAssertTrue(sheet.contains(word), "sheet1.xml should contain \(word)")
        }
        XCTAssertGreaterThanOrEqual(
            sheet.components(separatedBy: "<row ").count - 1, 2,
            "lines at different y positions should land in different rows")
        _ = try zipEntry("xl/workbook.xml", in: destination)
        // Brackets escaped: unzip matches entry names as wildcard patterns.
        _ = try zipEntry("\\[Content_Types\\].xml", in: destination)
    }

    func testExcelExportClustersColumnsByXGap() async throws {
        let destination = temporaryURL(extension: "xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await ExcelExporter.export(document: Self.makeFixtureDocument(),
                                       to: destination, engine: PDFKitEngine())

        let sheet = try zipEntry("xl/worksheets/sheet1.xml", in: destination)
        // "Alice" starts ~240pt right of "Name" on the same baseline; both
        // should land on row 1, with "Alice" in a column past A.
        XCTAssertTrue(sheet.contains("<c r=\"A1\" t=\"inlineStr\"><is><t>Name</t></is></c>"),
                      "Name should be cell A1, sheet: \(sheet)")
        XCTAssertTrue(sheet.contains("t=\"inlineStr\"><is><t>Alice</t></is></c>"),
                      "Alice should be its own cell, sheet: \(sheet)")
        XCTAssertFalse(sheet.contains("Name Alice"),
                       "x-separated lines should not merge into one cell, sheet: \(sheet)")
    }

    func testExcelExportRejectsEmptyDocument() async throws {
        let destination = temporaryURL(extension: "xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await ExcelExporter.export(document: PDFDocument(),
                                           to: destination, engine: PDFKitEngine())
            XCTFail("expected nothingToExport for an empty document")
        } catch ExportError.nothingToExport {
            // expected
        }
    }

    // MARK: - PowerPoint (.pptx)

    func testPowerPointExportProducesValidPPTX() async throws {
        let destination = temporaryURL(extension: "pptx")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await PowerPointExporter.export(document: Self.makeFixtureDocument(),
                                            to: destination, engine: PDFKitEngine())

        try assertZipSignature(destination)
        let slide1 = try zipEntry("ppt/slides/slide1.xml", in: destination)
        for word in ["Name", "Alice", "Total"] {
            XCTAssertTrue(slide1.contains(word), "slide1.xml should contain \(word)")
        }
        let slide2 = try zipEntry("ppt/slides/slide2.xml", in: destination)
        XCTAssertTrue(slide2.contains("Bob"), "slide2.xml should contain the page-2 text")
        let presentation = try zipEntry("ppt/presentation.xml", in: destination)
        XCTAssertTrue(presentation.contains("<p:sldId "), "presentation should list slides")
        _ = try zipEntry("ppt/slideMasters/slideMaster1.xml", in: destination)
        _ = try zipEntry("ppt/slideLayouts/slideLayout1.xml", in: destination)
        _ = try zipEntry("ppt/theme/theme1.xml", in: destination)
    }

    func testPowerPointExportRejectsEmptyDocument() async throws {
        let destination = temporaryURL(extension: "pptx")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await PowerPointExporter.export(document: PDFDocument(),
                                                to: destination, engine: PDFKitEngine())
            XCTFail("expected nothingToExport for an empty document")
        } catch ExportError.nothingToExport {
            // expected
        }
    }
}
