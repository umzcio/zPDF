//
//  OCRTests.swift
//  zPDFTests
//
//  Purpose: OCRService behavior — language support query, single-image
//  recognition against a programmatically rendered text fixture, and
//  document batch OCR with per-page progress and cooperative cancellation.
//

import AppKit
import PDFKit
import XCTest
@testable import zPDF

final class OCRTests: XCTestCase {

    // MARK: - Fixtures (programmatic — no resource files)

    /// Rasterize a sentence into an NSImage via CoreGraphics text drawing.
    private static func makeTextImage(_ text: String,
                                      size: CGSize = CGSize(width: 1600, height: 300)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 96),
            .foregroundColor: NSColor.black,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(at: CGPoint(x: 40, y: (size.height - attributed.size().height) / 2))
        image.unlockFocus()
        return image
    }

    /// Build a real PDFDocument whose pages contain selectable text, so the
    /// engine's renderPage path produces crisp text rasters for Vision.
    private static func makeTextDocument(pageCount: Int) -> PDFDocument {
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
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 48),
                .foregroundColor: NSColor.black,
            ]
            "The quick brown fox, page \(page + 1)".draw(at: CGPoint(x: 60, y: 400),
                                                         withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    /// Lock-protected recorder for @Sendable progress callbacks.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [OCRProgress] = []

        func record(_ progress: OCRProgress) {
            lock.lock()
            entries.append(progress)
            lock.unlock()
        }

        var completedPages: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return entries.map(\.completedPages)
        }
    }

    // MARK: - Languages

    func testSupportedLanguagesIncludesEnglish() {
        XCTAssertFalse(OCRService.supportedLanguages.isEmpty)
        XCTAssertTrue(OCRService.supportedLanguages.contains { $0.hasPrefix("en") },
                      "expected an English recognition language, got \(OCRService.supportedLanguages)")
    }

    // MARK: - Single image

    func testRecognizeTextOnRenderedFixture() async throws {
        let service = OCRService()
        let image = Self.makeTextImage("The quick brown fox jumps over the lazy dog")
        let text = try await service.recognizeText(in: image, languages: ["en-US"])
        let lowered = text.lowercased()
        XCTAssertTrue(lowered.contains("quick"), "expected 'quick' in \(text)")
        XCTAssertTrue(lowered.contains("fox"), "expected 'fox' in \(text)")
    }

    func testRecognizeTextCompletionAPIStillWorks() async {
        let service = OCRService()
        let image = Self.makeTextImage("The quick brown fox")
        let expectation = expectation(description: "recognition completes")
        service.recognizeText(in: image) { result in
            if case .success(let text) = result {
                XCTAssertTrue(text.lowercased().contains("quick"), "expected 'quick' in \(text)")
            } else {
                XCTFail("recognition failed: \(result)")
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 30)
    }

    // MARK: - Batch over a document

    func testBatchOCRReportsProgressPerPage() async throws {
        let service = OCRService()
        let engine = PDFKitEngine()
        let document = Self.makeTextDocument(pageCount: 3)
        let recorder = ProgressRecorder()

        let results = try await service.recognizeDocument(document, using: engine,
                                                          languages: ["en-US"]) { progress in
            recorder.record(progress)
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.pageIndex), [0, 1, 2])
        XCTAssertEqual(recorder.completedPages, [1, 2, 3])
        for result in results {
            let lowered = result.recognizedText.lowercased()
            XCTAssertTrue(lowered.contains("quick"),
                          "page \(result.pageIndex): expected 'quick' in \(result.recognizedText)")
            XCTAssertTrue(lowered.contains("fox"),
                          "page \(result.pageIndex): expected 'fox' in \(result.recognizedText)")
        }
    }

    func testBatchOCRCancelsBetweenPages() async throws {
        let recorder = ProgressRecorder()

        let task = Task {
            try await OCRService().recognizeDocument(Self.makeTextDocument(pageCount: 5),
                                                     using: PDFKitEngine(),
                                                     languages: ["en-US"]) { progress in
                recorder.record(progress)
            }
        }
        // Cancel as soon as the first page reports; bounded wait so the test
        // fails rather than hangs if progress never arrives.
        for _ in 0..<10_000 where recorder.completedPages.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(recorder.completedPages, [1], "first page should report before cancel")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Cancellation is checked between pages, so an in-flight page may
            // still finish after cancel() — assert the batch stopped early.
            XCTAssertLessThan(recorder.completedPages.count, 5,
                              "cancellation should stop the batch before the last page")
        }
    }
}
