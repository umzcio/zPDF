//
//  EditingTests.swift
//  zPDFTests
//
//  Purpose: Phase-4 content-editing tests — content-stream text-run
//  extraction (textRuns) and in-place replacement (replaceTextRun),
//  covering both CoreGraphics-generated PDFs (TJ arrays, embedded subset
//  fonts) and a hand-assembled PDF with a non-embedded base-14 font.
//  Fixtures are generated programmatically.
//

import AppKit
import PDFKit
import XCTest
@testable import zPDF

final class EditingTests: XCTestCase {

    // MARK: - Fixtures (programmatic — no resource files)

    /// A one-page PDF rendered through the CGContext PDF consumer (the
    /// OCRTests pattern): text lands in the content stream as a TJ array
    /// using an embedded subset font ("AAAAAB+Helvetica").
    private static func makeCoreGraphicsDocument(text: String = "Hello World") -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        text.draw(at: CGPoint(x: 72, y: 500), withAttributes: [
            .font: NSFont(name: "Helvetica", size: 24)!,
            .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    /// A minimal one-page PDF assembled by hand (correct xref table) whose
    /// font is non-embedded base-14 Helvetica with WinAnsiEncoding and
    /// whose text is a single literal-string Tj.
    private static func makeMinimalDocument(text: String = "Hello World") -> PDFDocument {
        let content = "BT /F1 24 Tf 72 500 Td (\(text)) Tj ET\n"
        let objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]
               /Resources << /Font << /F1 4 0 R >> >>
               /Contents 5 0 R >>
            """,
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \r\n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \r\n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return PDFDocument(data: Data(pdf.utf8))!
    }

    // MARK: - textRuns

    func testTextRunsOnCoreGraphicsFixture() {
        let engine = PDFKitEngine()
        let document = Self.makeCoreGraphicsDocument()
        let runs = engine.textRuns(onPageAt: 0, in: document)

        XCTAssertEqual(runs.count, 1, "expected a single TJ text run, got \(runs.map(\.text))")
        guard let run = runs.first else { return }
        XCTAssertEqual(run.id, 0)
        XCTAssertEqual(run.pageIndex, 0)
        XCTAssertEqual(run.text, "Hello World")
        XCTAssertEqual(run.fontName, "Helvetica", "subset prefix should be stripped")
        XCTAssertEqual(run.fontSize, 24, accuracy: 0.5)
        XCTAssertEqual(run.bounds.minX, 72, accuracy: 2)
        XCTAssertEqual(run.bounds.minY, 500, accuracy: 12, "baseline near the draw point")
        XCTAssertGreaterThan(run.bounds.width, 50)
    }

    func testTextRunsOnMinimalFixture() {
        let engine = PDFKitEngine()
        let document = Self.makeMinimalDocument()
        let runs = engine.textRuns(onPageAt: 0, in: document)

        XCTAssertEqual(runs.count, 1)
        guard let run = runs.first else { return }
        XCTAssertEqual(run.text, "Hello World")
        XCTAssertEqual(run.fontName, "Helvetica")
        XCTAssertEqual(run.fontSize, 24, accuracy: 0.5)
        XCTAssertEqual(run.bounds.minX, 72, accuracy: 2)
        XCTAssertEqual(run.bounds.minY, 500, accuracy: 2)
    }

    func testTextRunsEmptyForInvalidPage() {
        let engine = PDFKitEngine()
        let document = Self.makeMinimalDocument()
        XCTAssertTrue(engine.textRuns(onPageAt: 5, in: document).isEmpty)
        XCTAssertTrue(engine.textRuns(onPageAt: -1, in: document).isEmpty)
    }

    // MARK: - replaceTextRun

    /// Phase-4 acceptance: modify an existing text run in a simple PDF and
    /// have the document re-extract with the new text.
    func testReplaceTextRunOnMinimalFixture() throws {
        let engine = PDFKitEngine()
        let document = Self.makeMinimalDocument()
        let runs = engine.textRuns(onPageAt: 0, in: document)
        XCTAssertEqual(runs.count, 1)
        guard let run = runs.first else { return }

        try engine.replaceTextRun(run, with: "Hello zPDF", in: document)

        XCTAssertTrue(document.string?.contains("zPDF") == true,
                      "expected re-extracted text to contain 'zPDF', got \(document.string ?? "<nil>")")
        let updatedRuns = engine.textRuns(onPageAt: 0, in: document)
        XCTAssertEqual(updatedRuns.count, 1)
        XCTAssertEqual(updatedRuns.first?.text, "Hello zPDF")
        XCTAssertEqual(updatedRuns.first?.fontSize ?? 0, 24, accuracy: 0.5)
    }

    /// Same acceptance path against a CoreGraphics-generated document:
    /// the run is a TJ array and its font is an embedded subset, so the
    /// rewrite must swap the array for a Tj string and de-substitute the
    /// font before 'zPDF' can render and extract.
    func testReplaceTextRunOnCoreGraphicsFixture() throws {
        let engine = PDFKitEngine()
        let document = Self.makeCoreGraphicsDocument()
        let runs = engine.textRuns(onPageAt: 0, in: document)
        XCTAssertEqual(runs.count, 1)
        guard let run = runs.first else { return }

        try engine.replaceTextRun(run, with: "Hello zPDF", in: document)

        XCTAssertTrue(document.string?.contains("zPDF") == true,
                      "expected re-extracted text to contain 'zPDF', got \(document.string ?? "<nil>")")
        let updatedRuns = engine.textRuns(onPageAt: 0, in: document)
        XCTAssertEqual(updatedRuns.first?.text, "Hello zPDF")
    }

    /// A document that passed through the replacement once must still
    /// support a second edit (stale ids are re-fetched between edits).
    func testReplaceTextRunTwice() throws {
        let engine = PDFKitEngine()
        let document = Self.makeMinimalDocument()
        guard let first = engine.textRuns(onPageAt: 0, in: document).first else {
            return XCTFail("no initial run")
        }
        try engine.replaceTextRun(first, with: "Hello zPDF", in: document)
        guard let second = engine.textRuns(onPageAt: 0, in: document).first else {
            return XCTFail("no run after first replace")
        }
        try engine.replaceTextRun(second, with: "zPDF rules", in: document)
        XCTAssertTrue(document.string?.contains("zPDF rules") == true,
                      "got \(document.string ?? "<nil>")")
    }

    func testReplaceTextRunThrowsForUnrepresentableText() {
        let engine = PDFKitEngine()
        let document = Self.makeMinimalDocument()
        guard let run = engine.textRuns(onPageAt: 0, in: document).first else {
            return XCTFail("no run")
        }
        XCTAssertThrowsError(try engine.replaceTextRun(run, with: "Hello 世界", in: document)) { error in
            guard case PDFEngineError.unsupportedOperation = error else {
                return XCTFail("expected unsupportedOperation, got \(error)")
            }
        }
    }

    func testReplaceTextRunThrowsForStaleRun() {
        let engine = PDFKitEngine()
        let document = Self.makeMinimalDocument()
        let stale = EditableTextRun(id: 42, pageIndex: 0, text: "ghost",
                                    bounds: .zero, fontName: "Helvetica", fontSize: 12)
        XCTAssertThrowsError(try engine.replaceTextRun(stale, with: "nope", in: document))
    }
}
