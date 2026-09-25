import AppKit
import CoreImage
import PDFKit
import Vision

// MARK: - Word-level recognition

/// One recognized word; `box` is normalized (0–1) with a bottom-left origin.
struct OCRWord: Sendable, Equatable, Identifiable {
    let id: UUID
    var text: String
    let box: CGRect
    /// Vision's confidence for the line the word belongs to (0–1).
    let confidence: Float
    init(id: UUID = UUID(), text: String, box: CGRect, confidence: Float) {
        self.id = id; self.text = text; self.box = box; self.confidence = confidence
    }
}

struct OCRLine: Sendable, Equatable {
    var words: [OCRWord]
    /// Baseline angle in degrees (counter-clockwise), from the line's corners.
    let angle: Double
}

extension OCRService {
    /// Recognizes lines and words with their boxes (accurate, language correction).
    func recognizeWords(in image: CGImage, languages: [String]) async throws -> [OCRLine] {
        let width = Double(image.width), height = Double(image.height)
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [OCRLine] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let string = candidate.string
                    var words: [OCRWord] = []
                    var index = string.startIndex
                    while index < string.endIndex {
                        guard let start = string[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                        let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                        let range = start..<end
                        if let box = try? candidate.boundingBox(for: range)?.boundingBox, box.width > 0, box.height > 0 {
                            words.append(OCRWord(text: String(string[range]), box: box, confidence: candidate.confidence))
                        }
                        index = end
                    }
                    let dx = Double(observation.topRight.x - observation.topLeft.x) * width
                    let dy = Double(observation.topRight.y - observation.topLeft.y) * height
                    return words.isEmpty ? nil : OCRLine(words: words, angle: atan2(dy, dx) * 180 / .pi)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(cgImage: image)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Renders a page upright (rotation applied) at `dpi` onto white.
    @MainActor
    static func render(_ page: PDFPage, dpi: CGFloat = 300, maxPixels: CGFloat = 5000) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let visual = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = min(dpi / 72, maxPixels / max(visual.width, visual.height, 1))
        let width = Int((visual.width * scale).rounded()), height = Int((visual.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.transform(context, for: .cropBox)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}

// MARK: - Scan cleanup

/// Core Image cleanup for scanned page images: deskew, despeckle and
/// background whitening. Applied only to pages that are a single scan image.
enum PageImageCleaner {
    /// Median skew of recognized lines, in degrees; nil when there's too little text.
    static func skew(of lines: [OCRLine]) -> Double? {
        let angles = lines.filter { $0.words.count >= 2 }.map(\.angle).filter { abs($0) < 15 }.sorted()
        guard angles.count >= 3 else { return nil }
        return angles[angles.count / 2]
    }

    static func clean(_ image: CGImage, deskewBy angle: Double?, despeckle: Bool, whitenBackground: Bool) -> CGImage? {
        var output = CIImage(cgImage: image)
        let extent = output.extent
        if let angle, abs(angle) >= 0.2 {
            let radians = -angle * .pi / 180
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            let white = CIImage(color: .white).cropped(to: extent)
            output = output.transformed(by: rotation).composited(over: white).cropped(to: extent)
        }
        if despeckle, let filter = CIFilter(name: "CIMedianFilter") {
            filter.setValue(output, forKey: kCIInputImageKey)
            output = filter.outputImage ?? output
        }
        if whitenBackground, let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(output, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.3, y: 0.22), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.55, y: 0.55), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.8, y: 0.97), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
            output = curve.outputImage ?? output
        }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
        return context.createCGImage(output, from: extent)
    }
}
