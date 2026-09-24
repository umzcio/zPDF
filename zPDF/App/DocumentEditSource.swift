import CryptoKit
import Foundation

/// Immutable native input retained by undo snapshots. Never a PDFKit rewrite.
/// A later Save can therefore restore pages removed by an earlier Save.
final class DocumentEditSource: Sendable {
    let url: URL
    let hash: String
    private let directory: URL

    private init(url: URL, hash: String, directory: URL) {
        self.url = url; self.hash = hash; self.directory = directory
    }

    static func capture(_ source: URL, expectedHash: String) async throws -> DocumentEditSource {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-edit-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                let copy = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: copy)
                guard try NativeSourceGuard.digest(copy) == expectedHash else {
                    throw NativeSaveError(code: "SOURCE_CHANGED", message: "The PDF changed while preparing its editing revision. Reopen it before editing.")
                }
                return DocumentEditSource(url: copy, hash: expectedHash, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    /// Takes ownership of a validated native transform output as a new revision.
    static func adopt(_ output: NativeTransformOutput, name: String) async throws -> DocumentEditSource {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-edit-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                let target = directory.appendingPathComponent(name)
                try FileManager.default.moveItem(at: output.url, to: target)
                guard try NativeSourceGuard.digest(target) == output.hash else {
                    throw NativeSaveError(code: "VALIDATION_FAILED", message: "The edited revision changed before it could be opened.")
                }
                return DocumentEditSource(url: target, hash: output.hash, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct NativeSourceGuard: Sendable {
    let url: URL
    let hash: String

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard try Self.digest(url) == hash else {
            throw NativeSaveError(code: "SOURCE_CHANGED", message: "The file changed on disk. Your edits are still available; reopen the changed file before replacing it.")
        }
    }
}
