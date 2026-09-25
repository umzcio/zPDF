import CryptoKit
import Foundation

struct RecoverySnapshot: Sendable {
    let id: UUID
    let sourceURL: URL
    let sourceHash: String
    let displayName: String
    let changes: NativeSaveChanges
    var sourceLease: DocumentEditSource? = nil
}

struct RecoveryCheckpoint: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let generation: UUID
    let displayName: String
    let updatedAt: Date
    let sha256: String
    let byteCount: Int64
    /// Derived from the store, never trusted from the on-disk manifest.
    var fileURL: URL
}

struct RecoveryError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Each publication is an atomic directory rename containing both the native
/// PDF and its manifest. A failed update leaves the previous generation intact.
/// No recovery copy is ever used to replace the original document automatically.
actor RecoveryStore {
    typealias Writer = @Sendable (RecoverySnapshot, URL) async throws -> String
    let directory: URL
    private let maximumBytes: Int64
    private let maximumDocuments: Int
    private let writer: Writer
    private var writing = false
    private var invalidations: [UUID: UUID] = [:]

    init(directory: URL, maximumBytes: Int64 = 512 * 1_024 * 1_024,
         maximumDocuments: Int = 30, writer: Writer? = nil) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumDocuments = maximumDocuments
        self.writer = writer ?? { snapshot, destination in
            try await NativeSaveBridge.save(snapshot.sourceURL, expectedHash: snapshot.sourceHash,
                                            changes: snapshot.changes, destination: destination)
        }
    }

    static func defaultDirectory() throws -> URL {
        AppEnvironment.supportDirectory.appendingPathComponent("zPDF/Recovery", isDirectory: true)
    }

    func list() throws -> [RecoveryCheckpoint] {
        try prepareDirectory()
        if !writing { try removeAbandonedStaging() }
        // A crash immediately after publication may leave two generations.
        // Keep the newest complete one; never age out unsaved user work.
        let all = try published()
        var latest: [UUID: RecoveryCheckpoint] = [:]
        for item in all.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if latest[item.id] == nil { latest[item.id] = item }
        }
        return latest.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func write(_ snapshot: RecoverySnapshot) async throws -> RecoveryCheckpoint? {
        guard !writing else { throw RecoveryError(message: "A recovery checkpoint is already being written.") }
        writing = true
        defer { writing = false }
        try prepareDirectory()
        try removeAbandonedStaging()
        let token = invalidations[snapshot.id, default: UUID()]
        invalidations[snapshot.id] = token
        let generation = UUID()
        let staging = directory.appendingPathComponent("staging-\(generation.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = staging.appendingPathComponent("document.pdf")
        let hash = try await writer(snapshot, output)
        guard invalidations[snapshot.id] == token else { return nil }
        guard try Self.hash(of: output) == hash else {
            throw RecoveryError(message: "The recovery copy did not match the engine's saved output.")
        }
        let bytes = try size(of: output)
        let existing = try published()
        let others = existing.filter { $0.id != snapshot.id }
        // Credit only one old generation for replacement. If old-generation
        // cleanup fails, its bytes continue to consume the quota on later
        // writes instead of allowing repeated updates to grow without bound.
        let replacing = existing.filter { $0.id == snapshot.id }.max { $0.updatedAt < $1.updatedAt }
        let replacementBytes = try replacing.map { try size(of: $0.fileURL) } ?? 0
        let used = try existing.reduce(Int64(0)) { try $0 + size(of: $1.fileURL) } - replacementBytes
        guard Set(others.map(\.id)).count < maximumDocuments,
              bytes <= maximumBytes, used <= maximumBytes - bytes else {
            throw RecoveryError(message: "Recovery storage is full. Save or discard recovered documents to make room. The last recovery copy has been kept.")
        }
        let publishedDirectory = directory.appendingPathComponent("checkpoint-\(generation.uuidString)", isDirectory: true)
        let checkpoint = RecoveryCheckpoint(id: snapshot.id, generation: generation, displayName: snapshot.displayName,
            updatedAt: Date(), sha256: hash, byteCount: bytes,
            fileURL: publishedDirectory.appendingPathComponent("document.pdf"))
        let manifest = staging.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(checkpoint).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        // Flush complete files before the publication rename. Atomic visibility
        // protects application crashes; this is not a power-loss durability claim.
        for file in [output, manifest] {
            let handle = try FileHandle(forWritingTo: file)
            try handle.synchronize()
            try handle.close()
        }
        try FileManager.default.moveItem(at: staging, to: publishedDirectory)
        for old in existing where old.id == snapshot.id {
            try? FileManager.default.removeItem(at: old.fileURL.deletingLastPathComponent())
        }
        return checkpoint
    }

    /// Invalidates in-flight publication as well as deleting completed copies.
    func discard(id: UUID) throws {
        invalidations[id] = UUID()
        try prepareDirectory()
        for item in try published() where item.id == id {
            try FileManager.default.removeItem(at: item.fileURL.deletingLastPathComponent())
        }
    }

    func validate(_ checkpoint: RecoveryCheckpoint) throws -> URL {
        let expectedDirectory = directory.appendingPathComponent("checkpoint-\(checkpoint.generation.uuidString)", isDirectory: true)
        let file = expectedDirectory.appendingPathComponent("document.pdf")
        guard try Self.hash(of: file) == checkpoint.sha256 else {
            throw RecoveryError(message: "This recovery copy is damaged. The original document has not been changed.")
        }
        return file
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func removeAbandonedStaging() throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("staging-") {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func published() throws -> [RecoveryCheckpoint] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { folder in
            guard folder.lastPathComponent.hasPrefix("checkpoint-") else { return nil }
            // Leave incomplete/corrupt publications available for diagnosis, but
            // report them rather than silently pretending recovery succeeded.
            let manifest = folder.appendingPathComponent("manifest.json")
            var item = try JSONDecoder().decode(RecoveryCheckpoint.self, from: Data(contentsOf: manifest))
            guard folder.lastPathComponent == "checkpoint-\(item.generation.uuidString)" else {
                throw RecoveryError(message: "A recovery manifest is invalid. Recovery files have been preserved.")
            }
            item.fileURL = folder.appendingPathComponent("document.pdf")
            return item
        }
    }

    private func size(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw RecoveryError(message: "A recovery copy is missing or is not a regular file.")
        }
        return Int64(size)
    }

    static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
