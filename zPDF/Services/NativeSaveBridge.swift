import Foundation

struct NativeSaveError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { "\(message) (\(code))" }
}

struct NativeOpenInfo: Sendable {
    let sourceHash: String
    let writeBlock: String?
}

struct NativeFieldEdit: Sendable {
    let page: Int
    let annotationIndex: Int
    let name: String
    let value: String
    let checked: Bool
}

struct NativeNewField: Sendable {
    let page: Int
    let name: String
    let type: String
    let rect: [Double]
    let value: String
    let checked: Bool
}

struct NativeFieldSuggestion: Sendable {
    let type: String
    let rect: [Double]
}

struct NativeNote: Sendable {
    let page: Int
    let type: String
    let contents: String
    let author: String
    let color: [Int]
    let rect: [Double]
}

struct NativePageSelection: Sendable, Equatable {
    let sourceIndex: Int
    let rotationDelta: Int
}

struct NativeCommentEdit: Sendable {
    let page: Int
    let annotationIndex: Int
    let type: String
    let originalContents: String
    let contents: String?
}

/// One generic annotation edit, in source page/annotation terms.
struct NativeAnnotationItem: Sendable, Equatable {
    let action: String
    let page: Int
    let index: Int?
    let subtype: String?
    var scratchPage: Int?
    var scratchKey: String?
    var replyTo: [Int]?
    /// Reply to an annotation added in the same edit (its /ZPDFCommentID).
    var replyToComment: String?
    /// "R" (reply, default) or "Group" (grouped markup such as Replace Text).
    var replyType: String?

    var json: [String: Any] {
        var value: [String: Any] = ["action": action, "page": page]
        if let index { value["index"] = index }
        if let subtype { value["subtype"] = subtype }
        if let scratchPage { value["scratch_page"] = scratchPage }
        if let scratchKey { value["scratch_key"] = scratchKey }
        if let replyTo { value["reply_to"] = replyTo }
        if let replyToComment { value["reply_to_comment"] = replyToComment }
        if let replyType { value["reply_type"] = replyType }
        return value
    }
}

/// Private PDFKit-written file holding annotation dictionaries for one Save.
/// Retained by the changes that reference it (Save, export, recovery).
final class AnnotationScratch: Sendable {
    let url: URL
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-annotations-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("annotations.pdf")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct NativeSaveChanges: Sendable {
    var comments: [NativeCommentEdit] = []
    var fields: [NativeFieldEdit] = []
    var newFields: [NativeNewField] = []
    var notes: [NativeNote] = []
    /// nil means unchanged; entries refer to source pages before any edits.
    var pages: [NativePageSelection]?
    var compress = false
    /// Generic annotation edits applied natively before the facade runs.
    var annotationItems: [NativeAnnotationItem] = []
    var annotationScratch: AnnotationScratch?
    /// A copy written elsewhere (Extract Pages) may rewrite a signed source;
    /// saving the signed document itself never does (ProtectedSaveBridge).
    var allowsSignedRewrite = false

    var hasFacadeEdits: Bool {
        !comments.isEmpty || !fields.isEmpty || !newFields.isEmpty || !notes.isEmpty || pages != nil || compress
    }
    var isEmpty: Bool { !hasFacadeEdits && annotationItems.isEmpty }
}

/// Plain JSON results crossing from the helper; only read on the receiving side.
struct NativeJSON: @unchecked Sendable {
    let value: [String: Any]
    subscript(key: String) -> Any? { value[key] }
}

/// All process/native work runs away from AppKit. Each save gets an isolated
/// facade session. Lost Save acknowledgements report an uncertain outcome; callers
/// must check the destination before retrying.
enum NativeSaveBridge {
    static func detectFields(_ url: URL, expectedHash: String, page: Int) async throws -> [NativeFieldSuggestion] {
        try await Task.detached {
            let helper = try SaveHelper(runtime: nil)
            defer { helper.dispose() }
            let opened = try helper.call("open", ["path": url.path])
            guard try helper.sourceHash(opened) == expectedHash else {
                throw NativeSaveError(code: "SOURCE_CHANGED", message: "The source PDF changed. Reopen it before detecting fields.")
            }
            let document = try helper.result(opened)
            guard let pages = document["pages"] as? [[String: Any]], pages.indices.contains(page) else { throw helper.invalidReply() }
            let result = try helper.result(helper.call("detect_fields", ["ref": document["ref"]!, "page_id": pages[page]["id"]!]))
            guard let fields = result["fields"] as? [[String: Any]] else { throw helper.invalidReply() }
            return try fields.map {
                guard let type = $0["type"] as? String, ["text", "checkbox"].contains(type),
                      let rect = $0["rect"] as? [Double], rect.count == 4, rect.allSatisfy(\.isFinite) else { throw helper.invalidReply() }
                return NativeFieldSuggestion(type: type, rect: rect)
            }
        }.value
    }

    static func inspect(_ url: URL, password: String? = nil, runtime: URL? = nil) async throws -> NativeOpenInfo {
        try await Task.detached {
            let helper = try SaveHelper(runtime: runtime)
            defer { helper.dispose() }
            var args: [String: Any] = ["path": url.path]
            if let password { args["password"] = password }
            let opened = try helper.call("open", args)
            let document = try helper.result(opened)
            let policy = try helper.result(helper.call("inspect_policy", ["ref": document["ref"]!]))
            return NativeOpenInfo(sourceHash: try helper.sourceHash(opened), writeBlock: policy["write_block"] as? String)
        }.value
    }

    static func save(_ url: URL, expectedHash: String, changes: NativeSaveChanges,
                     destination: URL? = nil, overwrite: Bool = false,
                     sourceGuard: NativeSourceGuard? = nil,
                     runtime: URL? = nil) async throws -> String {
        try await Task.detached {
            func write(source: URL, target: URL) throws -> String {
                try sourceGuard?.validate()
                let helper = try SaveHelper(runtime: runtime)
                defer { helper.dispose() }
                let work = try NativeWorkDirectory()
                let doc = try helper.prepared(source, expectedHash: expectedHash, changes: changes, in: work.url)
                try sourceGuard?.validate()
                let saved = try helper.result(helper.call("save", ["ref": doc["ref"]!, "destination": target.path,
                                                                   "overwrite": destination == nil || overwrite]))
                guard let sha = saved["sha256"] as? String else { throw helper.invalidReply() }
                return sha
            }
            var coordinationError: NSError?
            var outcome: Result<String, Error>?
            let guardedURL = sourceGuard?.url ?? url
            if let destination,
               !SaveDestination.sameFile(guardedURL, destination) {
                NSFileCoordinator().coordinate(readingItemAt: guardedURL, options: [], writingItemAt: destination,
                                               options: .forReplacing, error: &coordinationError) { source, target in
                    outcome = Result { try write(source: sourceGuard == nil ? source : url, target: target) }
                }
            } else {
                NSFileCoordinator().coordinate(writingItemAt: destination ?? guardedURL, options: .forReplacing, error: &coordinationError) { target in
                    outcome = Result { try write(source: sourceGuard == nil ? target : url, target: target) }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else {
                throw NativeSaveError(code: "FILE_COORDINATION_FAILED", message: "Could not coordinate access to this file.")
            }
            return try outcome.get()
        }.value
    }
    struct Input: Sendable {
        let url: URL
        let hash: String
        let changes: NativeSaveChanges
        var sourceGuard: NativeSourceGuard? = nil
        var displayURL: URL { sourceGuard?.url ?? url }
    }

    static func combine(_ inputs: [Input], destination: URL, overwrite: Bool = false,
                        runtime: URL? = nil) async throws -> String {
        try await Task.detached {
            guard inputs.count >= 2, !inputs.contains(where: { SaveDestination.sameFile($0.displayURL, destination) }) else {
                throw NativeSaveError(code: "INVALID_DESTINATION", message: "Choose a new file for the combined PDF.")
            }
            var coordinationError: NSError?
            var result: Result<String, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                result = Result {
                    let helper = try SaveHelper(runtime: runtime)
                    defer { helper.dispose() }
                    let work = try NativeWorkDirectory()
                    let docs = try inputs.map {
                        try $0.sourceGuard?.validate()
                        return try helper.prepared($0.url, expectedHash: $0.hash, changes: $0.changes, in: work.url)
                    }
                    let pages: [[String: Any]] = docs.flatMap { doc in
                        (doc["pages"] as! [[String: Any]]).map {
                            ["source_ref": doc["ref"]!, "page_id": $0["id"]!, "rotation_delta": 0]
                        }
                    }
                    let combined = try helper.result(helper.call("organize_pages", ["ref": docs[0]["ref"]!, "pages": pages]))
                    let saved = try helper.result(helper.call("save", ["ref": combined["ref"]!, "destination": target.path, "overwrite": overwrite]))
                    guard let sha = saved["sha256"] as? String else { throw helper.invalidReply() }
                    return sha
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw NativeSaveError(code: "FILE_COORDINATION_FAILED", message: "Could not coordinate the combined file.") }
            return try result.get()
        }.value
    }

}

/// Private per-operation directory for intermediate native candidates.
final class NativeWorkDirectory: Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-work-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

final class SaveHelper {
    private let transport: NativeHelperTransport

    init(runtime: URL? = nil) throws {
        guard let runtime = runtime ?? Bundle.main.resourceURL?.appendingPathComponent("EngineRuntime"),
              FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("python/bin/python3.13").path) else {
            throw NativeSaveError(code: "ENGINE_UNAVAILABLE", message: "The Save engine is missing from this app build.")
        }
        transport = try NativeHelperTransport(
            executable: runtime.appendingPathComponent("python/bin/python3.13"),
            arguments: ["-B", "-u", runtime.appendingPathComponent("support/serve.py").path],
            environment: ["PYTHONHOME": runtime.appendingPathComponent("python").path,
                          "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                          "TMPDIR": NSTemporaryDirectory(), "ZPDF_HELPER_PROCESS_GROUP": "1"],
            requiresProcessGroup: true)
    }

    func prepare(_ source: URL, expectedHash: String, changes: NativeSaveChanges) throws -> [String: Any] {
        let opened = try self.call("open", ["path": source.path])
        var doc = try self.result(opened)
        guard try self.sourceHash(opened) == expectedHash else {
            throw NativeSaveError(code: "SOURCE_CHANGED", message: "The file changed on disk. Reopen it before saving; your on-screen edits are still available.")
        }
        let policy = try self.result(self.call("inspect_policy", ["ref": doc["ref"]!]))
        if let block = policy["write_block"] as? String {
            throw NativeSaveError(code: block, message: "This document is read-only. XFA/hybrid forms and encrypted-document writes are not supported.")
        }
        // Validate every target before the first mutation. Locator + object
        // inventory determines identity; names are only a consistency check.
        var grouped: [String: String] = [:]
        for edit in changes.fields {
            let field = try self.field(for: edit, in: doc)
            let value = try self.fieldValue(edit, field: field)
            let key = field["id"] as! String
            let encoded = String(data: try JSONSerialization.data(withJSONObject: [value], options: .sortedKeys), encoding: .utf8)!
            if let previous = grouped[key], previous != encoded {
                throw NativeSaveError(code: "CONFLICTING_WIDGET_EDITS", message: "Linked form widgets contain conflicting edits.")
            }
            grouped[key] = encoded
        }
        let pageCount = (doc["pages"] as? [[String: Any]])?.count ?? 0
        guard changes.notes.allSatisfy({ (0..<pageCount).contains($0.page) }) else {
            throw NativeSaveError(code: "STALE_PAGE", message: "An edited page no longer matches the source document.")
        }
        if let selections = changes.pages {
            guard !selections.isEmpty, Set(selections.map(\.sourceIndex)).count == selections.count,
                  selections.allSatisfy({ (0..<pageCount).contains($0.sourceIndex) && [0, 90, 180, 270].contains($0.rotationDelta) }) else {
                throw NativeSaveError(code: "INVALID_PAGE_PLAN", message: "The requested page order or rotation is invalid. No file was replaced.")
            }
        }
        for edit in changes.fields {
            let field = try self.field(for: edit, in: doc)
            doc = try self.result(self.call("fill", ["ref": doc["ref"]!, "field_id": field["id"]!,
                                  "value": try self.fieldValue(edit, field: field)]))
        }
        if !changes.comments.isEmpty {
            let inventory = doc["annotations"] as? [[String: Any]] ?? []
            let types = ["Text": 1, "Highlight": 9, "Underline": 10]
            let edits: [[String: Any]] = try changes.comments.map { edit in
                let matches = inventory.filter {
                    ($0["page"] as? Int) == edit.page && ($0["index"] as? Int) == edit.annotationIndex
                        && ($0["type"] as? Int) == types[edit.type] && ($0["contents"] as? String) == edit.originalContents
                }
                guard matches.count == 1, let id = matches[0]["id"] else {
                    throw NativeSaveError(code: "STALE_ANNOTATION", message: "A comment no longer matches the opened file.")
                }
                return ["annotation_id": id, "contents": edit.contents.map { $0 as Any } ?? NSNull()]
            }
            doc = try self.result(self.call("edit_comments", ["ref": doc["ref"]!, "edits": edits]))
        }
        for note in changes.notes {
            let page = (doc["pages"] as! [[String: Any]])[note.page]
            var spec: [String: Any] = ["type": note.type, "contents": note.contents,
                              "author": note.author, "color": note.color]
            let r = note.rect
            if note.type == "sticky_note" {
                spec["rect"] = r
            } else {
                spec["quads"] = [["top_left": [r[0], r[3]], "top_right": [r[2], r[3]],
                          "bottom_left": [r[0], r[1]], "bottom_right": [r[2], r[1]]]]
            }
            doc = try self.result(self.call("annotate", ["ref": doc["ref"]!, "page_id": page["id"]!, "annotation": spec]))
        }
        if !changes.newFields.isEmpty {
            let pages = doc["pages"] as! [[String: Any]]
            let specs: [[String: Any]] = try changes.newFields.map { field in
                guard pages.indices.contains(field.page) else { throw self.invalidReply() }
                return ["page_id": pages[field.page]["id"]!, "name": field.name,
                        "type": field.type, "rect": field.rect]
            }
            doc = try self.result(self.call("add_fields", ["ref": doc["ref"]!, "fields": specs]))
            for field in changes.newFields where !field.value.isEmpty || field.checked {
                let matches = (doc["fields"] as! [[String: Any]]).filter { ($0["name"] as? String) == field.name }
                guard matches.count == 1 else { throw self.invalidReply() }
                let value: Any = field.type == "checkbox" ? field.checked : field.value
                doc = try self.result(self.call("fill", ["ref": doc["ref"]!, "field_id": matches[0]["id"]!, "value": value]))
            }
        }
        if changes.pages != nil || changes.compress {
            let selections = changes.pages ?? (0..<pageCount).map { NativePageSelection(sourceIndex: $0, rotationDelta: 0) }
            // Fill/annotate first, then use IDs from that exact revision.
            // The facade serializes a candidate before QPDF sees it.
            let pages = doc["pages"] as! [[String: Any]]
            let selected: [[String: Any]] = selections.map {
                ["source_ref": doc["ref"]!, "page_id": pages[$0.sourceIndex]["id"]!,
                 "rotation_delta": $0.rotationDelta]
            }
            doc = try self.result(self.call("organize_pages", ["ref": doc["ref"]!, "pages": selected, "compression": changes.compress ? "lossless" : "none"]))
        }
        return doc
    }

    func dispose() { transport.dispose() }

    /// file -> file native operations (transforms package). Output must not exist.
    func transform(_ source: URL, hash: String, ops: [[String: Any]], to output: URL,
                   password: String? = nil) throws -> (hash: String, result: [String: Any]) {
        var args: [String: Any] = ["path": source.path, "sha256": hash, "destination": output.path, "ops": ops]
        if let password { args["password"] = password }
        let result = try self.result(self.call("transform", args))
        guard let sha = result["sha256"] as? String else { throw invalidReply() }
        return (sha, result)
    }

    func query(_ source: URL, hash: String?, name: String, params: [String: Any], password: String? = nil) throws -> [String: Any] {
        var args: [String: Any] = ["path": source.path, "name": name, "params": params]
        if let hash { args["sha256"] = hash }
        if let password { args["password"] = password }
        return try self.result(self.call("query", args))
    }

    /// Applies pending edits: generic annotations first (index-stable), then
    /// the facade, then removal of annotations marked for deletion.
    func materialize(_ source: URL, expectedHash: String, changes pending: NativeSaveChanges,
                     in directory: URL) throws -> (url: URL, hash: String) {
        // Signed documents and form edits the facade can't express (see ProtectedSaveBridge).
        let (preparedURL, preparedHash, changes) = try nativePrepass(source, expectedHash: expectedHash, changes: pending, in: directory)
        var url = preparedURL, hash = preparedHash
        let tag = UUID().uuidString.prefix(8)
        if !changes.annotationItems.isEmpty {
            var op: [String: Any] = ["op": "annotations", "items": changes.annotationItems.map(\.json)]
            op["scratch"] = changes.annotationScratch?.url.path ?? ""
            let output = directory.appendingPathComponent("annotations-\(tag).pdf")
            hash = try transform(url, hash: hash, ops: [op], to: output).hash
            url = output
        }
        if changes.hasFacadeEdits {
            var facade = changes
            facade.annotationItems = []
            let doc = try prepare(url, expectedHash: hash, changes: facade)
            let output = directory.appendingPathComponent("facade-\(tag).pdf")
            let saved = try result(call("save", ["ref": doc["ref"]!, "destination": output.path, "overwrite": false]))
            guard let sha = saved["sha256"] as? String else { throw invalidReply() }
            url = output; hash = sha
        }
        if !changes.annotationItems.isEmpty {
            let output = directory.appendingPathComponent("final-\(tag).pdf")
            hash = try transform(url, hash: hash, ops: [["op": "finalize"]], to: output).hash
            url = output
        }
        return (url, hash)
    }

    /// An open facade session containing every pending edit.
    func prepared(_ source: URL, expectedHash: String, changes pending: NativeSaveChanges, in directory: URL) throws -> [String: Any] {
        let (source, expectedHash, changes) = try nativePrepass(source, expectedHash: expectedHash, changes: pending, in: directory)
        guard !changes.annotationItems.isEmpty else {
            return try prepare(source, expectedHash: expectedHash, changes: changes)
        }
        let (url, hash) = try materialize(source, expectedHash: expectedHash, changes: changes, in: directory)
        return try prepare(url, expectedHash: hash, changes: NativeSaveChanges())
    }

    func invalidReply() -> NativeSaveError { transport.invalidReply() }

    func call(_ command: String, _ parameters: [String: Any]) throws -> [String: Any] {
        try transport.call(command, parameters)
    }

    func result(_ response: [String: Any]) throws -> [String: Any] {
        guard let result = response["result"] as? [String: Any] else { throw invalidReply() }
        return result
    }

    func sourceHash(_ response: [String: Any]) throws -> String {
        guard let info = response["transport"] as? [String: Any], let sha = info["source_sha256"] as? String else { throw invalidReply() }
        return sha
    }

    func field(for edit: NativeFieldEdit, in document: [String: Any]) throws -> [String: Any] {
        let matches = (document["fields"] as? [[String: Any]] ?? []).filter { field in
            (field["widgets"] as? [[String: Any]] ?? []).contains {
                ($0["page"] as? Int) == edit.page && ($0["index"] as? Int) == edit.annotationIndex
            }
        }
        guard matches.count == 1, matches[0]["name"] as? String == edit.name else {
            throw NativeSaveError(code: "FIELD_MISMATCH", message: "The field no longer matches the opened document. No file was replaced.")
        }
        return matches[0]
    }

    func fieldValue(_ edit: NativeFieldEdit, field: [String: Any]) throws -> Any {
        switch field["type"] as? Int {
        case 6: return edit.value // PDFium text
        case 2: return edit.checked
        case 3: return edit.value // radio export
        case 4:
            let options = (field["options"] as? [[String: Any]] ?? []).filter {
                ($0["export"] as? String) == edit.value || ($0["label"] as? String) == edit.value
            }
            guard options.count == 1, let id = options[0]["id"] as? String else {
                throw NativeSaveError(code: "UNSUPPORTED_FIELD_VALUE", message: "Choose a supported dropdown option before saving.")
            }
            return id
        default:
            throw NativeSaveError(code: "UNSUPPORTED_FIELD", message: "This form control is not supported by Save yet.")
        }
    }
}
