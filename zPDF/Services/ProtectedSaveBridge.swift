import Foundation

/// Security the user chose for a document, applied only while writing a
/// destination (Save / Save As). Secrets live in memory for the tab's
/// lifetime and are never written to disk; the editing revision carries a
/// non-secret `/ZPDFSecurity` marker naming the mode and a token.
struct SecuritySettings: Sendable, Equatable, Codable {
    enum Printing: String, Codable, CaseIterable, Sendable { case none, low, high }
    enum Changes: String, Codable, CaseIterable, Sendable { case none, assembly, fill, comments, any }
    enum Method: String, Codable, CaseIterable, Sendable { case aes256, aes128 }

    var openPassword: String = ""
    var permissionsPassword: String = ""
    var restrictPermissions = false
    var printing: Printing = .high
    var changes: Changes = .any
    var allowCopy = true
    var allowAccessibility = true
    var method: Method = .aes256
    var encryptMetadata = true

    var permissionsJSON: [String: Any] {
        guard restrictPermissions else {
            return ["print": "high", "changes": "any", "copy": true, "accessibility": true]
        }
        return ["print": printing.rawValue, "changes": changes.rawValue, "copy": allowCopy,
                "accessibility": allowAccessibility]
    }

    /// Non-secret description recorded in the editing revision.
    var summary: [String: Any] {
        ["method": method == .aes256 ? "AES-256" : "AES-128", "open": !openPassword.isEmpty,
         "restricted": restrictPermissions]
    }
}

/// Private copy of an encrypted original plus the password that opened it.
/// Needed to preserve its exact encryption (same passwords and file key) on Save.
final class EncryptedOriginal: Sendable {
    let url: URL
    let password: String
    private let directory: URL

    private init(url: URL, password: String, directory: URL) {
        self.url = url; self.password = password; self.directory = directory
    }

    static func capture(_ source: URL, password: String, expectedHash: String) async throws -> EncryptedOriginal {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-original-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                let copy = directory.appendingPathComponent("original.pdf")
                try FileManager.default.copyItem(at: source, to: copy)
                guard try NativeSourceGuard.digest(copy) == expectedHash else {
                    throw NativeSaveError(code: "SOURCE_CHANGED", message: "The PDF changed while opening. Reopen it before editing.")
                }
                return EncryptedOriginal(url: copy, password: password, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Everything Save needs besides the pending edits, captured on the main actor.
/// Recipients chosen for certificate security (DER certificates + permissions).
struct CertificateRecipients: Sendable, Equatable {
    var certificates: [Data]
    var settings: SecuritySettings
}

/// Receives the file key of certificate security written by Save, so the
/// saved file can be reopened for editing without asking for a digital ID.
final class SecurityOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    var fileKey: String? {
        get { lock.withLock { key } }
        set { lock.withLock { key = newValue } }
    }
}

struct ProtectedSaveContext: Sendable {
    var original: EncryptedOriginal?
    var secrets: [String: SecuritySettings] = [:]
    var certificateRecipients: [String: CertificateRecipients] = [:]
    /// File key of the original certificate-secured document (kept on Save).
    var certificateKey: String?
    var outcome = SecurityOutcome()
    var mayHaveSecurity: Bool { original != nil || !secrets.isEmpty || !certificateRecipients.isEmpty }
}

enum CertificateSecurity {
    /// PDFs protected with the public-key (Adobe.PubSec) security handler.
    static func isCertificateSecured(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return data.range(of: Data("/Adobe.PubSec".utf8)) != nil || data.range(of: Data("/Adobe#2EPubSec".utf8)) != nil
    }
}

enum SignedPDF {
    /// Fast conservative pre-check: signature dictionaries are never inside
    /// compressed object streams, so a signed file always contains the key.
    static func mayBeSigned(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return data.range(of: Data("/ByteRange".utf8)) != nil
    }
}

/// Save for documents whose bytes must not be rewritten by the facade:
/// signed documents (append-only), encrypted documents (security re-applied)
/// and documents with pending security changes. Everything else uses the
/// standard native Save unchanged.
enum ProtectedSave {
    static func save(_ url: URL, expectedHash: String, changes: NativeSaveChanges,
                     destination: URL? = nil, overwrite: Bool = false,
                     sourceGuard: NativeSourceGuard? = nil,
                     context: ProtectedSaveContext) async throws -> String {
        let signed = await Task.detached { SignedPDF.mayBeSigned(url) }.value
        var changes = changes
        if signed, changes.pages != nil, let destination, !SaveDestination.sameFile(sourceGuard?.url ?? url, destination) {
            // Extracted/reordered copies can't keep signatures; the source is untouched.
            changes.allowsSignedRewrite = true
            if !context.mayHaveSecurity {
                return try await NativeSaveBridge.save(url, expectedHash: expectedHash, changes: changes,
                                                       destination: destination, overwrite: overwrite, sourceGuard: sourceGuard)
            }
        }
        let pending = changes
        guard signed || context.mayHaveSecurity else {
            return try await NativeSaveBridge.save(url, expectedHash: expectedHash, changes: changes,
                                                   destination: destination, overwrite: overwrite,
                                                   sourceGuard: sourceGuard)
        }
        return try await Task.detached {
            let target = destination ?? sourceGuard?.url ?? url
            var coordinationError: NSError?
            var outcome: Result<String, Error>?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { coordinated in
                outcome = Result {
                    try sourceGuard?.validate()
                    let helper = try SaveHelper()
                    defer { helper.dispose() }
                    let work = try NativeWorkDirectory()
                    var (candidate, hash) = pending.isEmpty ? (url, expectedHash)
                        : try helper.materialize(url, expectedHash: expectedHash, changes: pending, in: work.url)
                    if context.mayHaveSecurity {
                        (candidate, hash) = try helper.applySecurity(candidate, hash: hash, context: context, in: work.url)
                    }
                    try sourceGuard?.validate()
                    return try helper.publish(candidate, hash: hash, to: coordinated,
                                              overwrite: destination == nil || overwrite)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else {
                throw NativeSaveError(code: "FILE_COORDINATION_FAILED", message: "Could not coordinate access to this file.")
            }
            return try outcome.get()
        }.value
    }
}

extension SaveHelper {
    /// Applies the security recorded in the revision's marker.
    func applySecurity(_ source: URL, hash: String, context: ProtectedSaveContext,
                       in directory: URL) throws -> (URL, String) {
        let info = try query(source, hash: hash, name: "security_info", params: [:])
        guard let marker = info["marker"] as? [String: Any], let mode = marker["mode"] as? String else {
            return (source, hash)
        }
        var op: [String: Any] = ["op": "apply_security"]
        switch mode {
        case "Preserve":
            guard let original = context.original else {
                throw NativeSaveError(code: "SECURITY_UNAVAILABLE", message: "The original encryption can't be kept because the original file is no longer available. Choose new security in Protect, or remove it.")
            }
            op["original"] = original.url.path
            op["original_password"] = original.password
        case "Password":
            guard let token = marker["token"] as? String, let settings = context.secrets[token] else {
                throw NativeSaveError(code: "SECURITY_UNAVAILABLE", message: "The passwords for this document's security are no longer available. Set the password again in Protect before saving.")
            }
            if !settings.openPassword.isEmpty { op["user_password"] = settings.openPassword }
            if !settings.permissionsPassword.isEmpty { op["owner_password"] = settings.permissionsPassword }
            op["permissions"] = settings.permissionsJSON
            op["method"] = settings.method.rawValue
            op["encrypt_metadata"] = settings.encryptMetadata
        case "Certificate":
            if let token = marker["token"] as? String, let chosen = context.certificateRecipients[token] {
                op["recipients"] = chosen.certificates.map { $0.base64EncodedString() }
                op["permissions"] = chosen.settings.permissionsJSON
                op["encrypt_metadata"] = chosen.settings.encryptMetadata
            } else if let key = context.certificateKey, let original = context.original {
                op["certificate_key"] = key
                op["original"] = original.url.path
            } else {
                throw NativeSaveError(code: "SECURITY_UNAVAILABLE", message: "The recipients for this document’s certificate security are no longer available. Choose them again in Protect before saving.")
            }
        default:
            break
        }
        let output = directory.appendingPathComponent("secured-\(UUID().uuidString.prefix(8)).pdf")
        let (sha, result) = try transform(source, hash: hash, ops: [op], to: output)
        if let results = result["results"] as? [[String: Any]], let key = results.first?["file_key"] as? String {
            context.outcome.fileKey = key
        }
        return (output, sha)
    }

    /// Runs before the facade: signed documents are updated append-only in a
    /// single native transform; form edits the facade can't express (radio
    /// groups, list boxes, custom combo values, documents with form logic)
    /// are filled natively so values, calculations and appearances stay correct.
    func nativePrepass(_ source: URL, expectedHash: String, changes: NativeSaveChanges,
                       in directory: URL) throws -> (url: URL, hash: String, changes: NativeSaveChanges) {
        if !changes.allowsSignedRewrite, SignedPDF.mayBeSigned(source) {
            let info = try query(source, hash: expectedHash, name: "security_info", params: [:])
            if info["signed"] as? Bool == true {
                return try materializeSigned(source, expectedHash: expectedHash, changes: changes, in: directory)
            }
        }
        guard !changes.fields.isEmpty else { return (source, expectedHash, changes) }
        let located = changes.fields.map { [$0.page, $0.annotationIndex] }
        let kinds = try query(source, hash: expectedHash, name: "widget_kinds", params: ["widgets": located])
        let hasLogic = kinds["has_logic"] as? Bool == true
        let widgets = kinds["widgets"] as? [Any] ?? []
        var native: [NativeFieldEdit] = [], facade: [NativeFieldEdit] = []
        for (index, edit) in changes.fields.enumerated() {
            let kind = index < widgets.count ? widgets[index] as? [String: Any] : nil
            let type = kind?["kind"] as? String
            let options = kind?["options"] as? [String] ?? []
            let needsNative = type != nil && (hasLogic || type == "radio" || type == "list" || type == "barcode"
                || (type == "combo" && kind?["editable"] as? Bool == true && !edit.value.isEmpty && !options.contains(edit.value)))
            if needsNative { native.append(edit) } else { facade.append(edit) }
        }
        guard !native.isEmpty else { return (source, expectedHash, changes) }
        let output = directory.appendingPathComponent("fields-\(UUID().uuidString.prefix(8)).pdf")
        let (sha, _) = try transform(source, hash: expectedHash,
                                     ops: [["op": "fill_widgets", "edits": native.map(\.json)]], to: output)
        var rest = changes
        rest.fields = facade
        return (output, sha, rest)
    }

    private func materializeSigned(_ source: URL, expectedHash: String, changes: NativeSaveChanges,
                                   in directory: URL) throws -> (url: URL, hash: String, changes: NativeSaveChanges) {
        guard changes.pages == nil, !changes.compress, changes.comments.isEmpty else {
            throw NativeSaveError(code: "SIGNED_DOCUMENT", message: "This document is digitally signed. Page changes and edits to existing comments would invalidate its signatures, so they can’t be saved. Undo them, or use Save As after removing the signatures.")
        }
        var ops: [[String: Any]] = []
        if !changes.annotationItems.isEmpty {
            ops.append(["op": "annotations", "items": changes.annotationItems.map(\.json),
                        "scratch": changes.annotationScratch?.url.path ?? ""])
        }
        for note in changes.notes {
            ops.append(["op": "add_markup_note", "page": note.page, "kind": note.type, "contents": note.contents,
                        "author": note.author, "color": note.color, "rect": note.rect])
        }
        for field in changes.newFields {
            var op: [String: Any] = ["op": "add_form_field", "type": field.type, "name": field.name,
                                     "page": field.page, "rect": field.rect, "border_color": NSNull()]
            if field.type == "text", !field.value.isEmpty { op["value"] = field.value }
            ops.append(op)
            if field.type == "checkbox", field.checked {
                ops.append(["op": "fill_fields", "values": [field.name: true]])
            }
        }
        if !changes.fields.isEmpty {
            ops.append(["op": "fill_widgets", "edits": changes.fields.map(\.json)])
        }
        if !changes.annotationItems.isEmpty { ops.append(["op": "finalize"]) }
        guard !ops.isEmpty else { return (source, expectedHash, NativeSaveChanges()) }
        let output = directory.appendingPathComponent("signed-update-\(UUID().uuidString.prefix(8)).pdf")
        let (sha, _) = try transform(source, hash: expectedHash, ops: ops, to: output)
        return (output, sha, NativeSaveChanges())
    }
}

extension NativeFieldEdit {
    var json: [String: Any] {
        ["page": page, "index": annotationIndex, "name": name, "value": value, "checked": checked]
    }
}
