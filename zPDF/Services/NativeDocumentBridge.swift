import Foundation

/// JSON operation lists for the helper; built on one side, read on the other.
struct NativeOps: @unchecked Sendable {
    let value: [[String: Any]]
    init(_ value: [[String: Any]]) { self.value = value }
}

/// A validated native transform result, owned until adopted as an edit source.
struct NativeTransformOutput: Sendable {
    let url: URL
    let hash: String
    let results: [NativeJSON]
    let work: NativeWorkDirectory
}

/// Whole-document native operations (see EngineSupport/transforms). Every
/// call reads an immutable editing revision and produces a new private file;
/// nothing here writes the user's document.
enum NativeDocumentBridge {
    /// Applies pending on-screen edits, then `ops`, producing a new revision.
    static func transform(source: URL, hash: String, changes: NativeSaveChanges,
                          ops request: NativeOps, password: String? = nil) async throws -> NativeTransformOutput {
        return try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            let work = try NativeWorkDirectory()
            var input = (url: source, hash: hash)
            if !changes.isEmpty {
                input = try helper.materialize(source, expectedHash: hash, changes: changes, in: work.url)
            }
            let output = work.url.appendingPathComponent("revision.pdf")
            let ops = request.value
            let (sha, result) = try helper.transform(input.url, hash: input.hash, ops: ops, to: output, password: password)
            let results = (result["results"] as? [[String: Any]] ?? []).map { NativeJSON(value: $0) }
            return NativeTransformOutput(url: output, hash: sha, results: results, work: work)
        }.value
    }

    /// Read-only inspection of an editing revision.
    static func query(source: URL, hash: String?, name: String, params request: NativeJSON = NativeJSON(value: [:]),
                      password: String? = nil) async throws -> NativeJSON {
        return try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            return NativeJSON(value: try helper.query(source, hash: hash, name: name, params: request.value, password: password))
        }.value
    }

    /// Runs ops on a file the user chose (e.g. batch processing) into a new destination.
    static func transformFile(_ source: URL, ops request: NativeOps, destination: URL, overwrite: Bool = false,
                              password: String? = nil) async throws -> NativeJSON {
        return try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            let work = try NativeWorkDirectory()
            let hash = try NativeSourceGuard.digest(source)
            let output = work.url.appendingPathComponent("output.pdf")
            let (sha, result) = try helper.transform(source, hash: hash, ops: request.value,
                                                     to: output, password: password)
            var coordinationError: NSError?
            var outcome: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                outcome = Result { _ = try helper.publish(output, hash: sha, to: target, overwrite: overwrite) }
            }
            if let coordinationError { throw coordinationError }
            try outcome?.get()
            return NativeJSON(value: result)
        }.value
    }
}

extension SaveHelper {
    func publish(_ candidate: URL, hash: String, to destination: URL, overwrite: Bool) throws -> String {
        let result = try self.result(self.call("publish", ["path": candidate.path, "sha256": hash,
                                                           "destination": destination.path, "overwrite": overwrite]))
        guard let sha = result["sha256"] as? String else { throw invalidReply() }
        return sha
    }
}
