//
//  CommentMedia.swift
//  zPDF
//
//  Purpose: Media behind file-attachment, sound and image-stamp comments.
//  New attachments/recordings are private copies in the app's temporary
//  directory until Save embeds them (the engine reads them from there; the
//  helper shares the app sandbox). Audio is normalized to 16-bit PCM WAV,
//  the encoding PDF Sound annotations share with every viewer. Custom stamp
//  images are kept in Application Support for reuse across documents.
//

import AppKit
import AVFoundation
import ObjectiveC
import PDFKit

/// Which pending media file belongs to a new comment (associated with the
/// annotation object, so it follows Save's scratch copies via /ZPDFSpec).
enum CommentMediaLink {
    private nonisolated(unsafe) static var key: UInt8 = 0

    fileprivate struct Media {
        let url: URL
        let name: String
        let isSound: Bool
    }
    fileprivate final class Box { let media: Media; init(_ media: Media) { self.media = media } }

    fileprivate static func media(of annotation: PDFAnnotation) -> Media? {
        (objc_getAssociatedObject(annotation, &key) as? Box)?.media
    }

    fileprivate static func set(_ media: Media, on annotation: PDFAnnotation) {
        objc_setAssociatedObject(annotation, &key, Box(media), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Engine completion keys for an annotation's pending media.
    static func spec(for annotation: PDFAnnotation) -> [String: Any]? {
        guard let media = media(of: annotation) else { return nil }
        if media.isSound { return ["sound": ["path": media.url.path]] }
        return ["attach": ["path": media.url.path, "name": media.name]]
    }

    /// The pending file behind a not-yet-saved media comment.
    static func pendingFile(of annotation: PDFAnnotation) -> (url: URL, name: String)? {
        media(of: annotation).map { ($0.url, $0.name) }
    }

    static func pendingSize(of annotation: PDFAnnotation) -> Int? {
        guard let url = media(of: annotation)?.url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

@MainActor
final class CommentMedia {
    static let shared = CommentMedia()

    let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-comment-media-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    /// Private copy of a user-chosen file (the original may move or be sandbox-scoped).
    func importFile(_ source: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    func attach(file: URL, name: String, to annotation: CommentAnnotation) {
        CommentMediaLink.set(.init(url: file, name: name, isSound: false), on: annotation)
        annotation.syncStandardKeys()
    }

    func attach(sound wav: URL, to annotation: CommentAnnotation) {
        CommentMediaLink.set(.init(url: wav, name: wav.lastPathComponent, isSound: true), on: annotation)
        annotation.syncStandardKeys()
    }

    // MARK: Audio

    /// Converts any AVFoundation-readable audio to 16-bit PCM WAV (≤ 48 kHz, ≤ 2 channels).
    func normalizedWAV(from source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.channelCount <= 2, format.sampleRate > 0 else {
            throw NativeSaveError(code: "UNSUPPORTED_AUDIO", message: "Choose a mono or stereo recording.")
        }
        guard Double(input.length) / format.sampleRate <= 600 else {
            throw NativeSaveError(code: "AUDIO_TOO_LONG", message: "Sound comments can be up to 10 minutes long.")
        }
        let target = directory.appendingPathComponent("sound-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let output = try AVAudioFile(forWriting: target, settings: settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NativeSaveError(code: "UNSUPPORTED_AUDIO", message: "That audio file could not be read.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: capacity)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return target
    }

    private var recorder: AVAudioRecorder?
    private(set) var recordingURL: URL?
    private var player: AVAudioPlayer?
    private var playingID: ObjectIdentifier?

    var isRecording: Bool { recorder?.isRecording == true }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func startRecording() throws {
        let url = directory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050.0,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: 600) else {
            throw NativeSaveError(code: "RECORDING_FAILED", message: "Recording could not start. Check microphone access in System Settings.")
        }
        self.recorder = recorder
        recordingURL = url
    }

    /// Stops and returns the recording (nil when cancelled or empty).
    func stopRecording(keep: Bool) -> URL? {
        recorder?.stop()
        recorder = nil
        defer { recordingURL = nil }
        guard keep, let url = recordingURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 64 else {
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }

    func play(_ wav: Data, id: ObjectIdentifier) throws {
        stopPlayback()
        let player = try AVAudioPlayer(data: wav)
        player.play()
        self.player = player
        playingID = id
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func isPlaying(_ id: ObjectIdentifier) -> Bool { playingID == id && player?.isPlaying == true }
}

// MARK: - Custom stamps

/// The user's reusable image stamps (copied PNGs + a small index).
@MainActor
@Observable
final class CustomStampLibrary {
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var file: String
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let folder: URL

    init(folder: URL? = nil) {
        let base = folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("zPDF/Stamps", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("zPDF-Stamps"))
        self.folder = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: base.appendingPathComponent("stamps.json")),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded.filter { FileManager.default.fileExists(atPath: base.appendingPathComponent($0.file).path) }
        }
    }

    /// Adds an image (any format NSImage reads), stored as PNG, longest edge ≤ 1200 px.
    @discardableResult
    func add(imageAt url: URL, name: String? = nil) throws -> Entry {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url), let png = Self.png(from: image, maxEdge: 1200) else {
            throw NativeSaveError(code: "INVALID_IMAGE", message: "That file could not be read as an image.")
        }
        let entry = Entry(id: UUID(), name: name ?? url.deletingPathExtension().lastPathComponent, file: "\(UUID().uuidString).png")
        try png.write(to: folder.appendingPathComponent(entry.file), options: .atomic)
        entries.append(entry)
        persist()
        return entry
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func design(for entry: Entry) -> StampDesign? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(entry.file)) else { return nil }
        return StampDesign(kind: .image, name: "ZPDFImage", label: entry.name, colorHex: "#000000", imagePNG: data)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: folder.appendingPathComponent("stamps.json"), options: .atomic)
        }
    }

    static func png(from image: NSImage, maxEdge: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxEdge / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
