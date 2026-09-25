//
//  OCRService.swift
//  zPDF
//
//  Purpose: OCR via Vision's VNRecognizeTextRequest. Single-image and
//  whole-document batch recognition are REAL: language selection,
//  >= 2x page rendering via PDFEngine.renderPage, per-page progress, and
//  cooperative cancellation between pages.
//  Phase: 3 — batch OCR over pages + language selection.
//  Word-level recognition with boxes lives in OCRLayout.swift; OCRWorkflow
//  writes it as an invisible text layer through the native `ocr_text_layer`
//  transform, so scanned documents become searchable and selectable.
//

import AppKit
import Foundation
import PDFKit
import Vision

struct OCRPageResult: Sendable, Equatable {
    let pageIndex: Int
    let recognizedText: String
}

/// Per-page progress emitted by `OCRService.recognizeDocument`.
/// Fired once after each page finishes, in page order.
struct OCRProgress: Sendable, Equatable {
    /// Pages finished so far (1…totalPages).
    let completedPages: Int
    let totalPages: Int
    /// The result of the page that just completed.
    let lastResult: OCRPageResult
}

enum OCRError: Error, LocalizedError {
    case invalidImage
    case pageRenderFailed(Int)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The image could not be prepared for OCR."
        case .pageRenderFailed(let index): "Page \(index + 1) could not be rendered for OCR."
        case .recognitionFailed(let message): "OCR failed: \(message)"
        }
    }
}

final class OCRService: Sendable {

    /// Fallback used when Vision's supported-language query fails.
    static let defaultLanguages = ["en-US"]

    /// Languages the current Vision revision can recognize (accurate level).
    /// Falls back to `defaultLanguages` if the query fails.
    static var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        return (try? request.supportedRecognitionLanguages()) ?? defaultLanguages
    }

    // MARK: - Single image (public seam)

    /// Recognize text in a single image. Completion is invoked off the main
    /// thread — hop to MainActor before touching state.
    func recognizeText(in image: NSImage,
                       completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        recognizeText(in: image, languages: Self.defaultLanguages, completion: completion)
    }

    /// Language-aware variant of the single-image API (phase 3, additive).
    /// Pass an empty array to let Vision use its default languages.
    func recognizeText(in image: NSImage,
                       languages: [String],
                       completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        var proposedRect = CGRect.zero
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            completion(.failure(OCRError.invalidImage))
            return
        }
        recognizeText(in: cgImage, languages: languages, completion: completion)
    }

    /// Async variant of the single-image API (phase 3, additive).
    func recognizeText(in image: NSImage,
                       languages: [String] = OCRService.defaultLanguages) async throws -> String {
        var proposedRect = CGRect.zero
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw OCRError.invalidImage
        }
        return try await recognizeText(in: cgImage, languages: languages)
    }

    // MARK: - Batch over a document

    /// OCR every page of a document. Each page is rasterized through
    /// `PDFEngine.renderPage` at `renderScale` (never below 2x) relative to
    /// its media box, then recognized. `progress` is invoked on the calling
    /// task's executor after each page; cancellation is cooperative and
    /// checked between pages (throws `CancellationError`).
    func recognizeDocument(_ document: EngineDocument,
                           using engine: any PDFEngine,
                           languages: [String] = OCRService.defaultLanguages,
                           renderScale: CGFloat = 2.0,
                           progress: (@Sendable (OCRProgress) -> Void)? = nil) async throws -> [OCRPageResult] {
        let pageCount = engine.pageCount(of: document)
        let scale = max(renderScale, 2.0)
        var results: [OCRPageResult] = []
        results.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = engine.page(at: index, in: document) else {
                throw OCRError.pageRenderFailed(index)
            }
            let mediaBox = page.bounds(for: .mediaBox)
            guard mediaBox.width > 0, mediaBox.height > 0,
                  let image = engine.renderPage(page, toFit: CGSize(width: mediaBox.width * scale,
                                                                    height: mediaBox.height * scale)) else {
                throw OCRError.pageRenderFailed(index)
            }
            let text = try await recognizeText(in: image, languages: languages)
            let result = OCRPageResult(pageIndex: index, recognizedText: text)
            results.append(result)
            progress?(OCRProgress(completedPages: results.count,
                                  totalPages: pageCount,
                                  lastResult: result))
        }
        return results
    }

    /// Render a page through the engine and OCR the raster result.
    /// Kept from the early scaffold; for whole-document work use
    /// `recognizeDocument(_:using:languages:progress:)`, which adds
    /// >= 2x rendering, per-page progress, and cancellation.
    func recognizePage(at index: Int,
                       in document: PDFDocument,
                       using engine: any PDFEngine,
                       completion: @escaping @Sendable (Result<OCRPageResult, Error>) -> Void) {
        guard let page = engine.page(at: index, in: document),
              let image = engine.renderPage(page, toFit: CGSize(width: 1224, height: 1584)) else {
            completion(.failure(OCRError.invalidImage))
            return
        }
        recognizeText(in: image) { result in
            switch result {
            case .success(let text):
                completion(.success(OCRPageResult(pageIndex: index, recognizedText: text)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Vision plumbing

    private func recognizeText(in cgImage: CGImage,
                               languages: [String],
                               completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                completion(.failure(OCRError.recognitionFailed(error.localizedDescription)))
                return
            }
            let text = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
            completion(.success(text))
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: cgImage)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                completion(.failure(OCRError.recognitionFailed(error.localizedDescription)))
            }
        }
    }

    private func recognizeText(in cgImage: CGImage,
                               languages: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            recognizeText(in: cgImage, languages: languages) { result in
                continuation.resume(with: result)
            }
        }
    }
}
