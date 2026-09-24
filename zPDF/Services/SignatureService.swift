//
//  SignatureService.swift
//  zPDF
//
//  Purpose: Saved-signature store (UserDefaults-persisted), a mouse/trackpad
//  stroke-capture pad used by the Fill & Sign panel (macOS PencilKit has no
//  PKCanvasView — that class is iOS-only), and tap-to-place: an armed
//  SavedSignature is dropped onto a PDFPage as a stamp-type PDFAnnotation
//  whose appearance is the signature image. Armed state lives here (not on
//  AppState); the click-capture overlay lives in DocumentView.
//  Phase: 2 — capture + placement REAL; "Others" signing flow still needs
//  an account backend (phase 6 decision).
//

import AppKit
import Foundation
import PDFKit
import PencilKit
import SwiftUI

struct SavedSignature: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case signature
        case initials
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// Rendered image data (TIFF) for display and page placement.
    var imageData: Data
    /// Archived PKDrawing so the signature can be re-edited later.
    var drawingData: Data
    var createdAt: Date

    init(id: UUID = UUID(), name: String, kind: Kind, imageData: Data, drawingData: Data, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.imageData = imageData
        self.drawingData = drawingData
        self.createdAt = createdAt
    }

    var image: NSImage? {
        NSImage(data: imageData)
    }
}

@Observable
final class SignatureService {
    /// Width of a placed signature stamp, in page points.
    static let placedWidth: CGFloat = 120

    private(set) var signatures: [SavedSignature] = []
    /// Non-nil while tap-to-place is armed: the next click on the document
    /// canvas drops this signature onto the clicked page (see DocumentView).
    var armedSignature: SavedSignature?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    @discardableResult
    func addSignature(name: String, kind: SavedSignature.Kind, image: NSImage, drawing: PKDrawing) -> SavedSignature? {
        guard let imageData = image.tiffRepresentation else { return nil }
        let signature = SavedSignature(name: name,
                                       kind: kind,
                                       imageData: imageData,
                                       drawingData: drawing.dataRepresentation())
        signatures.append(signature)
        persist()
        return signature
    }

    func remove(_ signature: SavedSignature) {
        signatures.removeAll { $0.id == signature.id }
        if armedSignature?.id == signature.id {
            armedSignature = nil
        }
        persist()
    }

    // MARK: - Tap-to-place

    func armPlacement(of signature: SavedSignature) {
        armedSignature = signature
    }

    func disarmPlacement() {
        armedSignature = nil
    }

    /// Drop the armed signature at `point` (page coordinates) on `page` as a
    /// stamp annotation, then disarm. Bounds keep the image's aspect ratio at
    /// `placedWidth` points wide, centered on the click.
    @discardableResult
    func placeArmedSignature(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        guard let signature = armedSignature,
              let image = signature.image else { return nil }
        defer { armedSignature = nil }
        let aspect = image.size.height / max(image.size.width, 1)
        let size = CGSize(width: Self.placedWidth, height: Self.placedWidth * aspect)
        let bounds = CGRect(x: point.x - size.width / 2,
                            y: point.y - size.height / 2,
                            width: size.width,
                            height: size.height)
        let annotation = SignatureStampAnnotation(bounds: bounds, image: image)
        annotation.contents = signature.name
        page.addAnnotation(annotation)
        return annotation
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(signatures) {
            defaults.set(data, forKey: Constants.DefaultsKey.signatures)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Constants.DefaultsKey.signatures),
              let decoded = try? JSONDecoder().decode([SavedSignature].self, from: data) else { return }
        signatures = decoded
    }
}

/// Stamp annotation whose appearance is a saved signature image. PDFKit
/// invokes `draw(with:in:)` both for on-screen rendering and when generating
/// the appearance stream on `PDFDocument.write(to:)`, so the signature
/// persists with the file.
final class SignatureStampAnnotation: PDFAnnotation {
    private let signatureImage: NSImage

    init(bounds: CGRect, image: NSImage) {
        self.signatureImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) {
        // PDFKit archives annotations when copying them; the image is not
        // codable here, so decoded copies draw empty (placement always uses
        // the designated initializer).
        self.signatureImage = NSImage()
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = signatureImage.cgImage(forProposedRect: nil,
                                                   context: nil,
                                                   hints: nil) else { return }
        context.saveGState()
        // Quartz draws CGImages bottom-up; flip inside the bounds so the
        // signature is upright in the page's y-up coordinate system.
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }
}

/// Reference box handed to SignaturePadRepresentable so the hosting sheet
/// can read the current drawing when its "Done" button is tapped.
@Observable
final class SignaturePadController {
    weak var canvasView: SignatureCanvasView?
    /// Observed so the sheet's Clear/Save buttons update as the user draws.
    fileprivate(set) var hasInk = false

    var drawing: PKDrawing? {
        canvasView?.drawing
    }

    var isEmpty: Bool {
        !hasInk
    }

    /// Render the current drawing to an NSImage (transparent background).
    func captureImage() -> NSImage? {
        guard let drawing, !isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        return drawing.image(from: bounds, scale: 2.0)
    }

    func clear() {
        canvasView?.clear()
    }
}

/// Stroke-capture pad. macOS PencilKit ships PKDrawing/PKStroke but no
/// PKCanvasView, so this NSView records mouse/trackpad drags as
/// PKStrokePoints and renders them with NSBezierPath.
final class SignatureCanvasView: NSView {
    var onInkChange: ((Bool) -> Void)?

    private var strokes: [PKStroke] = []
    private var strokePaths: [NSBezierPath] = []
    private var currentPoints: [PKStrokePoint] = []
    private var currentPath: NSBezierPath?
    private var strokeStart: Date?

    var drawing: PKDrawing {
        var all = strokes
        if let current = currentStroke() {
            all.append(current)
        }
        return PKDrawing(strokes: all)
    }

    var isPadEmpty: Bool {
        strokes.isEmpty && currentPoints.isEmpty
    }

    func clear() {
        strokes.removeAll()
        strokePaths.removeAll()
        currentPoints.removeAll()
        currentPath = nil
        strokeStart = nil
        onInkChange?(false)
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        strokeStart = Date()
        currentPoints = [makePoint(from: event)]
        let path = NSBezierPath()
        path.move(to: convert(event.locationInWindow, from: nil))
        currentPath = path
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard strokeStart != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        currentPoints.append(makePoint(from: event, location: location))
        currentPath?.line(to: location)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard strokeStart != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        currentPoints.append(makePoint(from: event, location: location))
        if let stroke = currentStroke(), let path = currentPath {
            strokes.append(stroke)
            strokePaths.append(path)
        }
        currentPoints.removeAll()
        currentPath = nil
        strokeStart = nil
        onInkChange?(!strokes.isEmpty)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        NSColor.black.setStroke()
        for path in strokePaths {
            stroke(path)
        }
        if let currentPath {
            stroke(currentPath)
        }
    }

    private func stroke(_ path: NSBezierPath) {
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func makePoint(from event: NSEvent,
                           location: CGPoint? = nil) -> PKStrokePoint {
        let point = location ?? convert(event.locationInWindow, from: nil)
        return PKStrokePoint(location: point,
                             timeOffset: strokeStart.map { Date().timeIntervalSince($0) } ?? 0,
                             size: CGSize(width: 3, height: 3),
                             opacity: 1,
                             force: CGFloat(max(event.pressure, 0.5)),
                             azimuth: .pi / 2,
                             altitude: .pi / 2)
    }

    private func currentStroke() -> PKStroke? {
        guard let strokeStart, !currentPoints.isEmpty else { return nil }
        let path = PKStrokePath(controlPoints: currentPoints, creationDate: strokeStart)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}

/// Capture pad representable. On macOS the user draws with the trackpad or mouse.
struct SignaturePadRepresentable: NSViewRepresentable {
    let controller: SignaturePadController

    func makeNSView(context: Context) -> SignatureCanvasView {
        let canvas = SignatureCanvasView()
        canvas.onInkChange = { [weak controller] hasInk in
            controller?.hasInk = hasInk
        }
        controller.canvasView = canvas
        return canvas
    }

    func updateNSView(_ nsView: SignatureCanvasView, context: Context) {
        // Stateless: the canvas owns its drawing; the controller reads it.
    }
}
