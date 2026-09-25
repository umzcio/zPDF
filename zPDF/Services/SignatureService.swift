//
//  SignatureService.swift
//  zPDF
//
//  Purpose: Fill & Sign and digital-signature state shared by the panels:
//  the saved signature/initials library, digital IDs, trusted certificates,
//  signing preferences, the auto-fill profile, and the armed canvas tool
//  (Fill & Sign marks, signature placement, Prepare Form field placement,
//  certificate-signature boxes; see FormsCanvasInteraction.swift).
//
//  Storage decision: everything lives in the app's sandbox container
//  (Application Support/zPDF/Signing) in files created with 0600 permissions.
//  Digital IDs are stored as PKCS#12 blobs protected by the ID's own password
//  (PBES2/AES-256), exactly as Acrobat stores .pfx digital IDs; the password
//  is asked for at signing time and never stored. The macOS keychain is not
//  used because ad-hoc/locally signed builds lose keychain ACL access on
//  every rebuild and the data-protection keychain needs a provisioning
//  profile; the container is private to zPDF under the App Sandbox.
//

import AppKit
import Foundation
import PDFKit
import PencilKit
import SwiftUI

// MARK: - Models

struct SavedSignature: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case signature
        case initials
    }
    enum Source: String, Codable { case drawn, typed, image }

    var id: UUID
    var name: String
    var kind: Kind
    /// PNG (or legacy TIFF) image with a transparent background.
    var imageData: Data
    /// Legacy archived PKDrawing (unused for new signatures).
    var drawingData: Data
    var createdAt: Date
    var source: Source?

    init(id: UUID = UUID(), name: String, kind: Kind, imageData: Data, drawingData: Data = Data(),
         createdAt: Date = Date(), source: Source? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.imageData = imageData
        self.drawingData = drawingData
        self.createdAt = createdAt
        self.source = source
    }

    var image: NSImage? { NSImage(data: imageData) }

    /// PNG bytes for the engine, whatever format was stored.
    var pngData: Data? {
        if imageData.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return imageData }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

struct DigitalID: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var email: String
    var organization: String
    var subject: String
    var issuer: String
    var notBefore: String
    var notAfter: String
    var sha256: String
    var certificate: Data
    var algorithm: String
    var selfSigned: Bool
    var createdAt: Date

    init(id: UUID = UUID(), json: [String: Any]) {
        self.id = id
        name = json["name"] as? String ?? "Digital ID"
        email = json["email"] as? String ?? ""
        organization = json["organization"] as? String ?? ""
        subject = json["subject"] as? String ?? ""
        issuer = json["issuer"] as? String ?? ""
        notBefore = json["not_before"] as? String ?? ""
        notAfter = json["not_after"] as? String ?? ""
        sha256 = json["sha256"] as? String ?? ""
        certificate = Data(base64Encoded: json["certificate"] as? String ?? "") ?? Data()
        algorithm = json["algorithm"] as? String ?? ""
        selfSigned = json["self_signed"] as? Bool ?? false
        createdAt = Date()
    }

    var expiry: Date? { ISO8601DateFormatter().date(from: notAfter) ?? DigitalID.parse(notAfter) }
    var isExpired: Bool { (expiry ?? .distantFuture) < Date() }

    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

struct TrustedCertificate: Identifiable, Codable, Equatable {
    var id: String { sha256 }
    var sha256: String
    var name: String
    var issuer: String
    var notAfter: String
    var der: Data
    var addedAt: Date
}

struct SigningPreferences: Codable, Equatable {
    var timestampEnabled = false
    var timestampURL = ""
    var embedValidation = true
    var fetchRevocation = false
    var defaultReason = ""
    var defaultLocation = ""
    var format = "pades"
    var lastDigitalID: UUID?
    var showDateInAppearance = true
    var showReasonInAppearance = true
    var showLocationInAppearance = true
    var showLabels = true
}

/// Personal details used to suggest values for matching form fields.
struct FormProfile: Codable, Equatable {
    var fullName = ""
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var street = ""
    var street2 = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""
    var company = ""
    var jobTitle = ""
    var dateOfBirth = ""

    var isEmpty: Bool { self == FormProfile() }
}

/// Tools armed from Fill & Sign, Prepare Form and Certificates. One canvas
/// interaction is live at a time; the canvas hook routes mouse events here.
enum FormsCanvasTool: Equatable {
    case addText
    case check
    case cross
    case dot
    case line
    case date
    case signature(SavedSignature)
    case field(FormFieldKind)
    case certificateSignature
    case signField

    var instruction: String {
        switch self {
        case .addText: "Click where you want to type."
        case .check: "Click to place a check mark."
        case .cross: "Click to place an X."
        case .dot: "Click to place a dot."
        case .line: "Drag to draw a line, or click for a short one."
        case .date: "Click to place today’s date."
        case .signature(let s): s.kind == .initials ? "Click or drag to place your initials." : "Click or drag to place your signature."
        case .field(let kind): "Drag to draw the \(kind.displayName.lowercased()), or click to place it."
        case .certificateSignature: "Drag a box where the signature should appear."
        case .signField: "Click an empty signature field to sign it."
        }
    }
}

// MARK: - Service

@MainActor
@Observable
final class SignatureService {
    /// Width of a placed signature stamp, in page points.
    static let placedWidth: CGFloat = 150
    static let placedInitialsWidth: CGFloat = 60

    private(set) var signatures: [SavedSignature] = []
    private(set) var digitalIDs: [DigitalID] = []
    let trust: TrustStore
    var preferences: SigningPreferences { didSet { if preferences != oldValue { store.save(preferences, as: "preferences.json") } } }
    var profile: FormProfile { didSet { if profile != oldValue { store.save(profile, as: "profile.json") } } }
    var securityPresets: [SecurityPreset] { didSet { if securityPresets != oldValue { store.save(securityPresets, as: "security-presets.json") } } }

    /// Legacy tap-to-place state kept for the DocumentView overlay; new
    /// placement goes through `armedTool` and the canvas hook.
    var armedSignature: SavedSignature?
    var armedTool: FormsCanvasTool?
    /// Fill & Sign text defaults.
    var fillTextSize: CGFloat = 12
    var fillColor: NSColor = .black
    /// Called with the rectangle drawn for `.certificateSignature`, or the field for `.signField`.
    @ObservationIgnored var onSignatureBox: ((Int, CGRect?, String?) -> Void)?
    /// Called after a Prepare Form field was placed (name).
    @ObservationIgnored var onFieldPlaced: ((String) -> Void)?
    @ObservationIgnored let canvas = FormsCanvasInteraction()

    let store: SecureFileStore

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let store = SecureFileStore(directory: directory ?? SecureFileStore.defaultDirectory)
        self.store = store
        trust = TrustStore(store: store)
        preferences = store.load(SigningPreferences.self, from: "preferences.json") ?? SigningPreferences()
        profile = store.load(FormProfile.self, from: "profile.json") ?? FormProfile()
        securityPresets = store.load([SecurityPreset].self, from: "security-presets.json") ?? []
        signatures = store.load([SavedSignature].self, from: "signatures.json") ?? []
        digitalIDs = store.load([DigitalID].self, from: "digital-ids.json") ?? []
        // Migrate the previous UserDefaults signature store once.
        if directory == nil, signatures.isEmpty, let data = defaults.data(forKey: Constants.DefaultsKey.signatures),
           let legacy = try? JSONDecoder().decode([SavedSignature].self, from: data) {
            signatures = legacy
            store.save(signatures, as: "signatures.json")
            defaults.removeObject(forKey: Constants.DefaultsKey.signatures)
        }
    }

    // MARK: Signature library

    @discardableResult
    func addSignature(name: String, kind: SavedSignature.Kind, image: NSImage, source: SavedSignature.Source = .drawn) -> SavedSignature? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // Initials and signatures each keep one current entry per source, like Acrobat.
        let signature = SavedSignature(name: name, kind: kind, imageData: png, source: source)
        signatures.append(signature)
        store.save(signatures, as: "signatures.json")
        return signature
    }

    /// Compatibility entry point for callers that captured a PKDrawing.
    @discardableResult
    func addSignature(name: String, kind: SavedSignature.Kind, image: NSImage, drawing: PKDrawing) -> SavedSignature? {
        addSignature(name: name, kind: kind, image: image, source: .drawn)
    }

    func remove(_ signature: SavedSignature) {
        signatures.removeAll { $0.id == signature.id }
        if armedSignature?.id == signature.id { armedSignature = nil }
        if case .signature(let armed) = armedTool, armed.id == signature.id { armedTool = nil }
        store.save(signatures, as: "signatures.json")
    }

    func signatures(of kind: SavedSignature.Kind) -> [SavedSignature] {
        signatures.filter { $0.kind == kind }
    }

    // MARK: Canvas tools

    func arm(_ tool: FormsCanvasTool?) {
        armedTool = armedTool == tool ? nil : tool
        armedSignature = nil
    }

    func armPlacement(of signature: SavedSignature) {
        arm(.signature(signature))
    }

    func disarmPlacement() {
        armedSignature = nil
        armedTool = nil
        canvas.cancel()
    }

    /// Legacy overlay entry point (DocumentView). Placement now happens through
    /// the canvas hook, which saves natively; this only disarms.
    @discardableResult
    func placeArmedSignature(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        armedSignature = nil
        return nil
    }

    // MARK: Digital IDs

    func createDigitalID(name: String, email: String, organization: String, unit: String = "", country: String = "",
                         key: String = "rsa2048", password: String) async throws -> DigitalID {
        let result = try await FormsEngine.crypto("create_identity", params: [
            "name": name, "email": email, "organization": organization, "unit": unit, "country": country,
            "key": key, "password": password])
        return try storeIdentity(result.value)
    }

    func importDigitalID(from url: URL, password: String) async throws -> DigitalID {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000 else {
            throw NativeSaveError(code: "INVALID_ARGUMENT", message: "That file is too large to be a digital ID.")
        }
        let result = try await FormsEngine.crypto("inspect_identity", params: [
            "p12_b64": data.base64EncodedString(), "password": password])
        return try storeIdentity(result.value)
    }

    private func storeIdentity(_ json: [String: Any]) throws -> DigitalID {
        guard let p12 = json["p12"] as? String, let blob = Data(base64Encoded: p12) else {
            throw NativeSaveError(code: "INVALID_REPLY", message: "The digital ID could not be created.")
        }
        let identity = DigitalID(json: json)
        if let existing = digitalIDs.first(where: { $0.sha256 == identity.sha256 }) { return existing }
        try store.write(blob, to: "ids/\(identity.id.uuidString).p12")
        digitalIDs.append(identity)
        store.save(digitalIDs, as: "digital-ids.json")
        return identity
    }

    func removeDigitalID(_ identity: DigitalID) {
        store.delete("ids/\(identity.id.uuidString).p12")
        digitalIDs.removeAll { $0.id == identity.id }
        if preferences.lastDigitalID == identity.id { preferences.lastDigitalID = nil }
        store.save(digitalIDs, as: "digital-ids.json")
    }

    func pkcs12(for identity: DigitalID) throws -> Data {
        guard let data = store.read("ids/\(identity.id.uuidString).p12") else {
            throw NativeSaveError(code: "ID_MISSING", message: "This digital ID’s key file is missing. Remove it and import it again.")
        }
        return data
    }

    /// Verifies the ID password without signing anything.
    func checkPassword(_ password: String, for identity: DigitalID) async throws {
        _ = try await FormsEngine.crypto("inspect_identity", params: [
            "p12_b64": try pkcs12(for: identity).base64EncodedString(), "password": password])
    }
}

/// Security settings users save and reuse (no passwords are stored).
struct SecurityPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var requireOpenPassword: Bool
    var restrictPermissions: Bool
    var printing: SecuritySettings.Printing
    var changes: SecuritySettings.Changes
    var allowCopy: Bool
    var allowAccessibility: Bool
    var method: SecuritySettings.Method
}

// MARK: - Trust store

@MainActor
@Observable
final class TrustStore {
    private(set) var certificates: [TrustedCertificate] = []
    private let store: SecureFileStore

    init(store: SecureFileStore) {
        self.store = store
        certificates = store.load([TrustedCertificate].self, from: "trusted-certificates.json") ?? []
    }

    var anchorCertificates: [Data] { certificates.map(\.der) }

    func contains(_ der: Data) -> Bool { certificates.contains { $0.der == der } }

    @discardableResult
    func add(der: Data) async throws -> TrustedCertificate {
        let info = try await FormsEngine.crypto("describe_certificate", params: ["der_b64": der.base64EncodedString()]).value
        let normalized = Data(base64Encoded: info["certificate"] as? String ?? "") ?? der
        let item = TrustedCertificate(sha256: info["sha256"] as? String ?? UUID().uuidString,
                                      name: info["name"] as? String ?? "Certificate",
                                      issuer: info["issuer"] as? String ?? "",
                                      notAfter: info["not_after"] as? String ?? "", der: normalized, addedAt: Date())
        if !certificates.contains(where: { $0.sha256 == item.sha256 }) {
            certificates.append(item)
            store.save(certificates, as: "trusted-certificates.json")
        }
        return item
    }

    func add(fileAt url: URL) async throws -> TrustedCertificate {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .ascii), text.contains("-----BEGIN CERTIFICATE-----") {
            let body = text.components(separatedBy: "-----BEGIN CERTIFICATE-----")[1]
                .components(separatedBy: "-----END CERTIFICATE-----")[0]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            data = Data(base64Encoded: body) ?? data
        }
        return try await add(der: data)
    }

    func remove(_ certificate: TrustedCertificate) {
        certificates.removeAll { $0.sha256 == certificate.sha256 }
        store.save(certificates, as: "trusted-certificates.json")
    }
}

// MARK: - Storage

/// JSON/blob files in the app container, readable only by this user (0600).
struct SecureFileStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("zPDF/Signing", isDirectory: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func write(_ data: Data, to name: String) throws {
        let target = url(name)
        try prepare(target)
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    func delete(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? write(data, to: name)
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = read(name) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Digital-ID helpers that need no document (see serve.py `crypto`).
enum FormsEngine {
    static func crypto(_ name: String, params: [String: Any]) async throws -> NativeJSON {
        let request = NativeJSON(value: ["name": name, "params": params])
        return try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            return NativeJSON(value: try helper.result(helper.call("crypto", request.value)))
        }.value
    }
}

// MARK: - Signature capture

/// Reference box handed to SignaturePadRepresentable so the hosting sheet
/// can read the current drawing.
@Observable
final class SignaturePadController {
    weak var canvasView: SignatureCanvasView?
    fileprivate(set) var hasInk = false
    var inkColor: NSColor = .black { didSet { canvasView?.inkColor = inkColor } }
    var lineWidth: CGFloat = 2.6 { didSet { canvasView?.lineWidth = lineWidth } }

    var isEmpty: Bool { !hasInk }

    /// The drawing rendered on a transparent background, trimmed to its ink.
    func captureImage() -> NSImage? {
        guard !isEmpty else { return nil }
        return canvasView?.renderedImage()
    }

    func clear() { canvasView?.clear() }
    func undo() { canvasView?.undoStroke() }
}

/// Smooth mouse/trackpad signature capture. Points are smoothed with
/// midpoint quadratic curves; line width eases with stroke speed so the
/// result looks like ink rather than a polyline.
final class SignatureCanvasView: NSView {
    var onInkChange: ((Bool) -> Void)?
    var inkColor: NSColor = .black { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 2.6 { didSet { needsDisplay = true } }

    private struct Stroke { var points: [CGPoint]; var widths: [CGFloat] }
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var lastTime: TimeInterval = 0

    var isPadEmpty: Bool { strokes.isEmpty && current == nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func clear() {
        strokes.removeAll()
        current = nil
        onInkChange?(false)
        needsDisplay = true
    }

    func undoStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        onInkChange?(!strokes.isEmpty)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = Stroke(points: [point], widths: [lineWidth])
        lastTime = event.timestamp
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var stroke = current, let last = stroke.points.last else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - last.x, point.y - last.y)
        guard distance > 0.8 else { return }
        let dt = max(event.timestamp - lastTime, 0.001)
        lastTime = event.timestamp
        let speed = distance / CGFloat(dt)           // points per second
        let pressure = event.pressure > 0 && event.pressure < 1 ? CGFloat(event.pressure) : 0.5
        let target = lineWidth * (1.35 - min(speed / 2200, 0.75)) * (0.75 + pressure * 0.5)
        let width = (stroke.widths.last ?? lineWidth) * 0.7 + target * 0.3
        stroke.points.append(point)
        stroke.widths.append(width)
        current = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = current else { return }
        if stroke.points.count == 1 {
            // A tap draws a dot (for i and j).
            var dot = stroke
            dot.points.append(CGPoint(x: stroke.points[0].x + 0.5, y: stroke.points[0].y))
            dot.widths.append(lineWidth)
            strokes.append(dot)
        } else {
            strokes.append(stroke)
        }
        current = nil
        onInkChange?(true)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0).setFill()
        dirtyRect.fill()
        // Signature baseline guide.
        NSColor.separatorColor.setStroke()
        let guide = NSBezierPath()
        guide.move(to: CGPoint(x: 24, y: bounds.height * 0.3))
        guide.line(to: CGPoint(x: bounds.width - 24, y: bounds.height * 0.3))
        guide.lineWidth = 1
        guide.setLineDash([4, 4], count: 2, phase: 0)
        guide.stroke()
        inkColor.setStroke()
        inkColor.setFill()
        for stroke in strokes + (current.map { [$0] } ?? []) {
            Self.render(stroke.points, widths: stroke.widths)
        }
    }

    private static func render(_ points: [CGPoint], widths: [CGFloat]) {
        guard points.count > 1 else { return }
        // Draw segment-by-segment so width can vary; midpoint quad smoothing.
        var previousMid = points[0]
        for index in 1..<points.count {
            let current = points[index]
            let prior = points[index - 1]
            let mid = CGPoint(x: (prior.x + current.x) / 2, y: (prior.y + current.y) / 2)
            let path = NSBezierPath()
            path.move(to: previousMid)
            path.curve(to: mid, controlPoint1: prior, controlPoint2: prior)
            path.lineWidth = widths[index]
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            previousMid = mid
        }
        let tail = NSBezierPath()
        tail.move(to: previousMid)
        tail.line(to: points[points.count - 1])
        tail.lineWidth = widths.last ?? 2
        tail.lineCapStyle = .round
        tail.stroke()
    }

    /// Transparent PNG-ready image of the ink at 4× resolution.
    func renderedImage() -> NSImage? {
        let all = strokes.flatMap(\.points)
        guard !all.isEmpty else { return nil }
        let maxWidth = strokes.flatMap(\.widths).max() ?? lineWidth
        let minX = all.map(\.x).min()! - maxWidth - 4, maxX = all.map(\.x).max()! + maxWidth + 4
        let minY = all.map(\.y).min()! - maxWidth - 4, maxY = all.map(\.y).max()! + maxWidth + 4
        let size = CGSize(width: maxX - minX, height: maxY - minY)
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.translateX(by: -minX, yBy: -minY)
        transform.concat()
        inkColor.setStroke()
        for stroke in strokes { Self.render(stroke.points, widths: stroke.widths) }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// Capture pad representable (trackpad or mouse).
struct SignaturePadRepresentable: NSViewRepresentable {
    let controller: SignaturePadController

    func makeNSView(context: Context) -> SignatureCanvasView {
        let canvas = SignatureCanvasView()
        canvas.inkColor = controller.inkColor
        canvas.lineWidth = controller.lineWidth
        canvas.onInkChange = { [weak controller] hasInk in controller?.hasInk = hasInk }
        canvas.setAccessibilityLabel("Signature drawing area")
        canvas.setAccessibilityHelp("Draw your signature with the trackpad or mouse.")
        controller.canvasView = canvas
        return canvas
    }

    func updateNSView(_ nsView: SignatureCanvasView, context: Context) {
        nsView.inkColor = controller.inkColor
        nsView.lineWidth = controller.lineWidth
    }
}

enum SignatureRendering {
    /// Script-style fonts shipped with macOS for typed signatures.
    static let typedFonts: [(name: String, title: String)] = [
        ("SnellRoundhand", "Snell Roundhand"), ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Zapfino", "Zapfino"), ("Apple-Chancery", "Apple Chancery"), ("SavoyeLetPlain", "Savoye"),
        ("Noteworthy-Light", "Noteworthy"),
    ]

    static func typedImage(_ text: String, fontName: String, color: NSColor = .black) -> NSImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let font = NSFont(name: fontName, size: 96) ?? NSFont.systemFont(ofSize: 96)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: trimmed, attributes: attributes)
        let bounds = string.boundingRect(with: CGSize(width: 4000, height: 600), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(bounds.width) + 24, height: ceil(bounds.height) + 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        string.draw(with: CGRect(x: 12, y: 12 - bounds.minY, width: bounds.width + 4, height: bounds.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Imported signature photo/scan: optionally knock out a light background.
    static func importedImage(from url: URL, removeBackground: Bool) -> NSImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = NSImage(contentsOf: url), let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        if removeBackground, let data = context.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for i in 0..<(width * height) {
                let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
                let lightness = (r + g + b) / 3
                if lightness > 200 {
                    // Fade near-white paper to transparent, keeping anti-aliased ink edges.
                    let alpha = max(0, min(255, (235 - lightness) * 255 / 35))
                    let factor = Double(alpha) / 255
                    pixels[i * 4] = UInt8(Double(r) * factor)
                    pixels[i * 4 + 1] = UInt8(Double(g) * factor)
                    pixels[i * 4 + 2] = UInt8(Double(b) * factor)
                    pixels[i * 4 + 3] = UInt8(alpha)
                }
            }
        }
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: CGSize(width: width, height: height))
    }
}
