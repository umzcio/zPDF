import Foundation

/// Native plumbing for workflows that read files the user picked or write a
/// new file the user chose (create, insert, optimize, convert). The helper
/// only ever sees private copies; results are published to the user's
/// destination through the helper's atomic `publish` command.
enum NativeWorkflowBridge {
    /// Copies user-chosen inputs into a private work directory the helper can
    /// read. The directory lives as long as the returned lease.
    static func stage(_ urls: [URL]) throws -> (lease: NativeWorkDirectory, urls: [URL]) {
        let work = try NativeWorkDirectory()
        var staged: [URL] = []
        for (index, url) in urls.enumerated() {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let name = "\(index)-" + url.lastPathComponent.replacingOccurrences(of: "/", with: "-")
            let target = work.url.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: target)
            staged.append(target)
        }
        return (work, staged)
    }

    /// Applies pending edits + `ops` to an editing revision and publishes the
    /// result to `destination` (never the revision itself).
    static func exportTransform(source: URL, hash: String, changes: NativeSaveChanges, ops request: NativeOps,
                                destination: URL, overwrite: Bool) async throws -> NativeJSON {
        try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            let work = try NativeWorkDirectory()
            var input = (url: source, hash: hash)
            if !changes.isEmpty {
                input = try helper.materialize(source, expectedHash: hash, changes: changes, in: work.url)
            }
            let output = work.url.appendingPathComponent("export.pdf")
            let (sha, result) = try helper.transform(input.url, hash: input.hash, ops: request.value, to: output)
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

    /// Runs `ops` on a private seed PDF and returns a private output file
    /// (for create flows; the result is opened as a new untitled document).
    static func create(seed: URL, ops request: NativeOps, in work: NativeWorkDirectory,
                       name: String = "created.pdf") async throws -> (url: URL, result: NativeJSON) {
        try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            let hash = try NativeSourceGuard.digest(seed)
            let output = work.url.appendingPathComponent(UUID().uuidString + "-" + name)
            let (_, result) = try helper.transform(seed, hash: hash, ops: request.value, to: output)
            return (output, NativeJSON(value: result))
        }.value
    }

    /// Installs a finished private PDF at the user's destination (atomic, coordinated).
    static func publish(_ candidate: URL, to destination: URL, overwrite: Bool) async throws -> String {
        try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            let hash = try NativeSourceGuard.digest(candidate)
            var coordinationError: NSError?
            var outcome: Result<String, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                outcome = Result { try helper.publish(candidate, hash: hash, to: target, overwrite: overwrite) }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw NativeSaveError(code: "FILE_COORDINATION_FAILED", message: "Could not coordinate the output file.") }
            return try outcome.get()
        }.value
    }

    /// Read-only query on an arbitrary private file (e.g. the other side of a comparison).
    static func queryFile(_ url: URL, name: String, params: [String: Any] = [:]) async throws -> NativeJSON {
        let request = NativeJSON(value: params)
        return try await Task.detached {
            let helper = try SaveHelper()
            defer { helper.dispose() }
            return NativeJSON(value: try helper.query(url, hash: nil, name: name, params: request.value))
        }.value
    }
}
