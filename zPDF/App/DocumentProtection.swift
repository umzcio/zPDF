import AppKit
import Foundation
import PDFKit
import Security

/// How the file on disk is encrypted (from the engine's security query).
struct DocumentSecurityInfo: Equatable {
    var encrypted = false
    var method = ""
    var ownerPasswordMatched = false
    var permissions: [String: Bool] = [:]

    init() {}

    init(_ json: [String: Any]) {
        encrypted = json["encrypted"] as? Bool ?? false
        method = json["method"] as? String ?? ""
        ownerPasswordMatched = json["owner_password_matched"] as? Bool ?? false
        permissions = json["permissions"] as? [String: Bool] ?? [:]
    }

    func allows(_ key: String) -> Bool { permissions[key] ?? true }
}

/// The security the current editing revision will be saved with.
enum PendingSecurity: Equatable {
    case none
    case preserve
    case password(SecuritySettings)
    /// New certificate (public-key) security for these recipients.
    case certificate(CertificateRecipients)
    /// Keep the opened document's certificate security (same recipients and key).
    case certificatePreserve
    case removed
}

/// One signature field as reported by the engine plus app-side trust.
struct SignatureStatus: Identifiable, Equatable {
    enum Validity: Equatable { case valid, validModified, unknownSigner, invalid, unsigned }

    var id: String { field }
    var field: String
    var page: Int?
    var signed: Bool
    var visible: Bool
    var signerName = ""
    var signerEmail = ""
    var issuer = ""
    var time: Date?
    var timestampTime: Date?
    var timestampValid = false
    var timestampAuthority = ""
    var reason = ""
    var location = ""
    var integrity = false
    var coversDocument = false
    var changesAfter: [String] = []
    var certification: Int?
    var mdpViolation = false
    var revision = 0
    var ltv = false
    var subfilter = ""
    var certificates: [Data] = []
    var errors: [String] = []
    /// Filled by trust evaluation (user-trusted certificates + macOS roots).
    var trusted = false
    var trustDetail = ""
    var selfSigned = false

    var validity: Validity {
        guard signed else { return .unsigned }
        guard integrity && !mdpViolation else { return .invalid }
        guard trusted else { return .unknownSigner }
        return coversDocument ? .valid : .validModified
    }

    var summary: String {
        switch validity {
        case .unsigned: "Unsigned signature field"
        case .invalid: mdpViolation ? "Invalid: changes violate the certification" : "Invalid: the document was altered or the signature is damaged"
        case .unknownSigner: "Signer’s identity is unknown"
        case .valid: certification != nil ? "Certified and valid" : "Signature is valid"
        case .validModified: "Valid, but the document changed after signing"
        }
    }

    static func decode(_ json: [String: Any]) -> SignatureStatus {
        var s = SignatureStatus(field: json["field"] as? String ?? "", page: json["page"] as? Int,
                                signed: json["signed"] as? Bool ?? false, visible: json["visible"] as? Bool ?? false)
        let signer = json["signer"] as? [String: Any] ?? [:]
        s.signerName = signer["name"] as? String ?? (json["name"] as? String ?? "")
        s.signerEmail = signer["email"] as? String ?? ""
        s.issuer = signer["issuer"] as? String ?? ""
        s.selfSigned = signer["self_signed"] as? Bool ?? false
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
                ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: text) }()
        }
        s.time = date(json["time"]) ?? date(json["claimed_time"])
        if let ts = json["timestamp"] as? [String: Any] {
            s.timestampTime = date(ts["time"])
            s.timestampValid = ts["valid"] as? Bool ?? false
            s.timestampAuthority = ts["authority"] as? String ?? ""
        }
        s.reason = json["reason"] as? String ?? ""
        s.location = json["location"] as? String ?? ""
        s.integrity = json["integrity"] as? Bool ?? false
        s.coversDocument = json["covers_document"] as? Bool ?? false
        s.changesAfter = json["changes_after"] as? [String] ?? []
        s.certification = json["certification"] as? Int
        s.mdpViolation = json["mdp_violation"] as? Bool ?? false
        s.revision = json["revision"] as? Int ?? 0
        s.ltv = json["ltv"] as? Bool ?? false
        s.subfilter = json["subfilter"] as? String ?? ""
        s.certificates = (json["certificates"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
        s.errors = json["errors"] as? [String] ?? []
        return s
    }
}

/// Per-tab encryption, signature and form-logic state. Main-thread use only,
/// like DocumentTab itself.
@Observable
final class DocumentProtectionState {
    /// How the file on disk is protected (nil = not encrypted / unknown).
    var security: DocumentSecurityInfo?
    /// Private copy of the encrypted original, for preserving its security.
    var original: EncryptedOriginal?
    /// Passwords for security set in this session, keyed by marker token.
    var secrets: [String: SecuritySettings] = [:]
    /// Security the current revision will be saved with (refreshed after edits).
    var pending: PendingSecurity = .none
    /// Encrypted, but editing is restricted until the permissions password is entered.
    var editingRestricted = false
    var openPassword: String?

    var signatures: [SignatureStatus] = []
    var certification: Int?
    var hasDSS = false
    var isValidating = false
    var validationError: String?
    @ObservationIgnored var validatedHash: String?

    var hasFormLogic = false
    var formFields: [FormFieldInfo] = []
    var calculationOrder: [String] = []
    var tabOrder: [String] = []
    /// On-screen values at the last calculation (to find edited fields).
    @ObservationIgnored var lastFieldValues: [String: String]?
    @ObservationIgnored var profiledHash: String?

    var isSigned: Bool { signatures.contains(where: \.signed) }

    /// Certificate security chosen in this session, keyed by marker token.
    var certificateRecipients: [String: CertificateRecipients] = [:]
    /// File key of the opened certificate-secured document (never written to disk).
    var certificateKey: String?
    let outcome = SecurityOutcome()

    var saveContext: ProtectedSaveContext {
        ProtectedSaveContext(original: original, secrets: secrets, certificateRecipients: certificateRecipients,
                             certificateKey: certificateKey, outcome: outcome)
    }
}

// MARK: - Workflows

@MainActor
extension AppState {
    /// Called when a tab has an editing revision (open, reload, transform).
    func profileDocument(_ tab: DocumentTab) {
        guard let source = tab.editSource, tab.protection.profiledHash != source.hash else { return }
        tab.protection.profiledHash = source.hash
        Task {
            if let info = try? await queryDocument("form_fields", in: tab), tab.editSource === source {
                tab.protection.formFields = (info["fields"] as? [[String: Any]] ?? []).map(FormFieldInfo.init)
                tab.protection.lastFieldValues = nil
                tab.protection.calculationOrder = info["calculation_order"] as? [String] ?? []
                tab.protection.tabOrder = info["tab_order"] as? [String] ?? []
                tab.protection.hasFormLogic = info["has_logic"] as? Bool ?? false
                if tab.protection.hasFormLogic { FormLogic.startObserving(self) }
            }
            if let info = try? await queryDocument("security_info", in: tab), tab.editSource === source {
                let marker = info["marker"] as? [String: Any]
                switch marker?["mode"] as? String {
                case "Preserve": tab.protection.pending = .preserve
                case "Password":
                    let token = marker?["token"] as? String ?? ""
                    tab.protection.pending = tab.protection.secrets[token].map { .password($0) } ?? .none
                case "Certificate":
                    let token = marker?["token"] as? String ?? ""
                    if let chosen = tab.protection.certificateRecipients[token] { tab.protection.pending = .certificate(chosen) }
                    else { tab.protection.pending = tab.protection.certificateKey == nil ? .none : .certificatePreserve }
                case "None": tab.protection.pending = tab.protection.original == nil ? .none : .removed
                default: tab.protection.pending = .none
                }
                if info["signed"] as? Bool == true || !tab.protection.signatures.isEmpty {
                    await validateSignatures(tab)
                } else {
                    let fields = tab.protection.formFields.filter { $0.kind == "signature" }
                    tab.protection.signatures = fields.map {
                        SignatureStatus(field: $0.name, page: $0.widgets.first?.page, signed: false,
                                        visible: ($0.widgets.first?.rect.width ?? 0) > 0)
                    }
                }
            }
        }
    }

    /// An encrypted PDF opened with its password becomes editable through a
    /// private decrypted revision; its security is re-applied on Save.
    func prepareEncryptedEditing(_ tab: DocumentTab, url: URL, password: String, hash: String) async throws {
        let original = try await EncryptedOriginal.capture(url, password: password, expectedHash: hash)
        let token = UUID().uuidString
        let output = try await NativeDocumentBridge.transform(source: original.url, hash: hash, changes: NativeSaveChanges(),
                                                              ops: NativeOps([["op": "decrypt_for_editing", "token": token]]),
                                                              password: password)
        let details = output.results.first?.value ?? [:]
        let info = DocumentSecurityInfo(details)
        tab.protection.security = info
        tab.protection.openPassword = password
        let editable = info.ownerPasswordMatched || info.allows("modify_other")
        tab.protection.editingRestricted = !editable
        guard editable else { return }
        let revision = try await DocumentEditSource.adopt(output, name: url.lastPathComponent)
        let document = try engine.openDocument(at: revision.url)
        tab.protection.original = original
        tab.protection.pending = .preserve
        tab.editSource = revision
        tab.pdfDocument = document
        tab.saveBaseline = try await SaveBaseline.capture(document) { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.tabs.contains { $0 === tab } && tab.pdfDocument === document
        }
        tab.saveBlock = nil
        resetUndoHistory(tab)
    }

    /// Reload after Save. Encrypted results get a fresh decrypted revision and
    /// keep their (now saved) security for the next Save.
    func reloadSavedRevision(_ tab: DocumentTab, url: URL, hash: String) async throws
        -> (DocumentEditSource, PDFDocument, SaveBaseline) {
        let protection = tab.protection
        if protection.pending == .certificatePreserve || { if case .certificate = protection.pending { return true }; return false }() {
            let key = protection.outcome.fileKey ?? protection.certificateKey
            protection.outcome.fileKey = nil
            guard let key else {
                throw NativeSaveError(code: "SECURITY_UNAVAILABLE", message: "The document was saved, but it can’t be reopened for editing. Close it and open it again with your digital ID.")
            }
            let (source, original, _) = try await decryptCertificateFile(url, hash: hash, key: key)
            let document = try engine.openDocument(at: source.url)
            protection.original = original
            protection.certificateKey = key
            protection.certificateRecipients.removeAll()
            protection.pending = .certificatePreserve
            protection.profiledHash = nil
            return (source, document, try await SaveBaseline.capture(document))
        }
        var password: String?
        var ownerKnown = protection.security?.ownerPasswordMatched ?? false
        switch protection.pending {
        case .preserve: password = protection.original?.password
        case .password(let settings):
            password = settings.permissionsPassword.isEmpty ? settings.openPassword : settings.permissionsPassword
            ownerKnown = true
        case .none, .removed, .certificate, .certificatePreserve: password = nil
        }
        guard let password, protection.pending != .none else {
            protection.original = nil
            protection.security = nil
            protection.pending = .none
            protection.secrets.removeAll()
            let source = try await DocumentEditSource.capture(url, expectedHash: hash)
            let document = try engine.openDocument(at: source.url)
            return (source, document, try await SaveBaseline.capture(document))
        }
        let original = try await EncryptedOriginal.capture(url, password: password, expectedHash: hash)
        let output = try await NativeDocumentBridge.transform(source: original.url, hash: hash, changes: NativeSaveChanges(),
                                                              ops: NativeOps([["op": "decrypt_for_editing", "token": UUID().uuidString]]),
                                                              password: password)
        var info = DocumentSecurityInfo(output.results.first?.value ?? [:])
        info.ownerPasswordMatched = info.ownerPasswordMatched || ownerKnown
        let source = try await DocumentEditSource.adopt(output, name: url.lastPathComponent)
        let document = try engine.openDocument(at: source.url)
        protection.original = original
        protection.security = info
        protection.pending = .preserve
        protection.openPassword = password
        protection.secrets.removeAll()
        protection.profiledHash = nil
        return (source, document, try await SaveBaseline.capture(document))
    }

    /// Decrypts a certificate-secured file (with its file key or a digital ID)
    /// into a private editing revision; returns it with a private copy of the original.
    func decryptCertificateFile(_ url: URL, hash: String, key: String? = nil, identity: DigitalID? = nil,
                                password: String = "") async throws -> (DocumentEditSource, EncryptedOriginal, NativeJSON) {
        let original = try await EncryptedOriginal.capture(url, password: "", expectedHash: hash)
        let work = try NativeWorkDirectory()
        let output = work.url.appendingPathComponent("decrypted.pdf")
        var params: [String: Any] = ["source": original.url.path, "destination": output.path, "token": UUID().uuidString]
        if let key { params["key_b64"] = key }
        if let identity {
            params["p12_b64"] = try signatureService.pkcs12(for: identity).base64EncodedString()
            params["password"] = password
        }
        let result = try await FormsEngine.crypto("decrypt_certificate_file", params: params)
        let digest = try await Task.detached { try NativeSourceGuard.digest(output) }.value
        let source = try await DocumentEditSource.capture(output, expectedHash: digest)
        withExtendedLifetime(work) {}
        return (source, original, result)
    }

    /// Opening a PDF encrypted for certificates: choose a digital ID, decrypt
    /// privately, and edit; Save keeps the same recipients.
    func openCertificateSecured(_ url: URL, openedHash: String, restoringSession: Bool) {
        guard !restoringSession else { return }
        let identities = signatureService.digitalIDs.filter { $0.algorithm.hasPrefix("RSA") }
        guard !identities.isEmpty else {
            openError = OpenError(fileName: url.lastPathComponent, message: "This PDF is encrypted for specific certificates. Import the digital ID it was encrypted for in Certificates, then open it again.")
            return
        }
        guard let (identity, password) = requestDigitalID(for: url, identities: identities) else { return }
        Task {
            do {
                let (source, original, result) = try await decryptCertificateFile(url, hash: openedHash, identity: identity,
                                                                                    password: password)
                let document = try engine.openDocument(at: source.url)
                let tab = DocumentTab(url: url, pdfDocument: document)
                applyReadingPreferences(to: tab)
                tab.securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
                tab.sourceHash = openedHash
                tab.protection.original = original
                tab.protection.certificateKey = result["file_key"] as? String
                tab.protection.pending = .certificatePreserve
                var info = DocumentSecurityInfo()
                info.encrypted = true
                info.method = "AES-256 (certificate)"
                info.permissions = ["modify_other": result["can_modify"] as? Bool ?? true,
                                    "extract": result["can_copy"] as? Bool ?? true,
                                    "print_highres": result["can_print"] as? Bool ?? true]
                tab.protection.security = info
                let editable = result["can_modify"] as? Bool ?? true
                tab.protection.editingRestricted = !editable
                if editable {
                    tab.editSource = source
                } else {
                    tab.saveBlock = "UNSUPPORTED_ENCRYPTED_WRITE"
                }
                tabs.append(tab)
                selectTab(tab)
                recentFiles.add(url: url)
                persistOpenSession()
                if editable {
                    tab.saveBaseline = try await SaveBaseline.capture(document)
                    resetUndoHistory(tab)
                    profileDocument(tab)
                }
            } catch {
                openError = OpenError(fileName: url.lastPathComponent, message: error.localizedDescription)
            }
        }
    }

    private func requestDigitalID(for url: URL, identities: [DigitalID]) -> (DigitalID, String)? {
        if let certificatePrompt { return certificatePrompt(url, identities) }
        let alert = NSAlert()
        alert.messageText = "Open “\(url.lastPathComponent)” with your digital ID"
        alert.informativeText = "This PDF is encrypted for specific certificates. Choose your digital ID and enter its password."
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        stack.orientation = .vertical
        stack.alignment = .leading
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        identities.forEach { popup.addItem(withTitle: $0.email.isEmpty ? $0.name : "\($0.name) <\($0.email)>") }
        popup.setAccessibilityLabel("Digital ID")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Digital ID password"
        field.setAccessibilityLabel("Digital ID password")
        stack.addArrangedSubview(popup)
        stack.addArrangedSubview(field)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (identities[max(0, popup.indexOfSelectedItem)], field.stringValue)
    }

    /// Record certificate security for the next Save (Undo-able).
    func applyCertificateSecurity(_ recipients: CertificateRecipients, to tab: DocumentTab) async throws {
        try requireSecurityChangeAllowed(tab)
        let token = UUID().uuidString
        tab.protection.certificateRecipients[token] = recipients
        try await applyDocumentTransform([["op": "set_security", "mode": "Certificate", "token": token,
                                           "summary": ["recipients": "\(recipients.certificates.count)"]]],
                                         to: tab, actionName: "Set Certificate Security")
        tab.protection.pending = .certificate(recipients)
    }

    /// Enter the permissions password for an encrypted file opened read-only.
    func unlockEditing(_ tab: DocumentTab, permissionsPassword: String) async throws {
        guard let url = tab.url, let hash = tab.sourceHash else { return }
        let check = try await NativeDocumentBridge.query(source: url, hash: hash, name: "check_password",
                                                         password: permissionsPassword)
        guard check["owner_password_matched"] as? Bool == true else {
            throw NativeSaveError(code: "INVALID_PASSWORD", message: "That is not this document’s permissions password.")
        }
        tab.saveChecking = true
        defer { tab.saveChecking = false }
        try await prepareEncryptedEditing(tab, url: url, password: permissionsPassword, hash: hash)
        tab.protection.profiledHash = nil
        profileDocument(tab)
    }

    /// Record password security for the next Save (Undo-able, marks the tab edited).
    func applyPasswordSecurity(_ settings: SecuritySettings, to tab: DocumentTab) async throws {
        try requireSecurityChangeAllowed(tab)
        let token = UUID().uuidString
        tab.protection.secrets[token] = settings
        try await applyDocumentTransform([["op": "set_security", "mode": "Password", "token": token,
                                           "summary": settings.summary]],
                                         to: tab, actionName: "Set Password Security")
        tab.protection.pending = .password(settings)
    }

    func removeSecurity(from tab: DocumentTab, permissionsPassword: String? = nil) async throws {
        if let original = tab.protection.original, tab.protection.certificateKey == nil,
           tab.protection.security?.ownerPasswordMatched != true {
            guard let permissionsPassword, !permissionsPassword.isEmpty else {
                throw NativeSaveError(code: "PASSWORD_REQUIRED", message: "Enter the permissions password to remove security.")
            }
            let check = try await NativeDocumentBridge.query(source: original.url, hash: nil, name: "check_password",
                                                             password: permissionsPassword)
            guard check["owner_password_matched"] as? Bool == true else {
                throw NativeSaveError(code: "INVALID_PASSWORD", message: "That is not this document’s permissions password.")
            }
            tab.protection.security?.ownerPasswordMatched = true
        }
        try await applyDocumentTransform([["op": "set_security", "mode": "None"]], to: tab, actionName: "Remove Security")
        tab.protection.pending = tab.protection.original == nil ? .none : .removed
    }

    func requireSecurityChangeAllowed(_ tab: DocumentTab) throws {
        if tab.protection.original != nil, tab.protection.certificateKey == nil,
           tab.protection.security?.ownerPasswordMatched != true {
            throw NativeSaveError(code: "PASSWORD_REQUIRED", message: "Only the permissions password holder can change this document’s security. Remove security with the permissions password first.")
        }
    }

    // MARK: Signatures

    func validateSignatures(_ tab: DocumentTab) async {
        if let source = tab.editSource {
            await validateSignatures(tab, file: source.url, hash: source.hash)
        } else if let url = tab.url {
            await validateSignatures(tab, file: url, hash: tab.sourceHash)
        }
    }

    private func validateSignatures(_ tab: DocumentTab, file: URL, hash: String?) async {
        tab.protection.isValidating = true
        defer { tab.protection.isValidating = false }
        do {
            let report = try await NativeDocumentBridge.query(source: file, hash: hash, name: "signatures",
                                                              password: tab.protection.openPassword)
            var items = (report["signatures"] as? [[String: Any]] ?? []).map(SignatureStatus.decode)
            let anchors = signatureService.trust.anchorCertificates
            for index in items.indices where items[index].signed {
                let (trusted, detail) = CertificateTrust.evaluate(chain: items[index].certificates, anchors: anchors,
                                                                  at: items[index].timestampTime ?? items[index].time)
                items[index].trusted = trusted
                items[index].trustDetail = detail
            }
            tab.protection.signatures = items
            tab.protection.certification = report["certification"] as? Int
            tab.protection.hasDSS = report["has_dss"] as? Bool ?? false
            tab.protection.validatedHash = hash
            tab.protection.validationError = nil
        } catch {
            tab.protection.validationError = error.localizedDescription
        }
    }
}

/// The macOS system root certificates as a PEM bundle for the engine's
/// HTTPS requests (timestamp servers, OCSP/CRL), written once per launch.
enum SystemTrustRoots {
    nonisolated(unsafe) private static var cached: URL?

    static func pemFile() -> URL? {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let list = anchors as? [SecCertificate] else { return nil }
        let pem = list.map { certificate -> String in
            let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-system-roots.pem")
        guard (try? Data(pem.utf8).write(to: url, options: .atomic)) != nil else { return nil }
        cached = url
        return url
    }
}

/// Certificate path validation with macOS Security: user-trusted certificates
/// are anchors in addition to the system roots.
enum CertificateTrust {
    static func evaluate(chain: [Data], anchors: [Data], at date: Date?) -> (Bool, String) {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certificates.first else { return (false, "No certificate is embedded in the signature.") }
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return (false, "The certificate could not be evaluated.")
        }
        let anchorCerts = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        if !anchorCerts.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchorCerts as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            let leafData = SecCertificateCopyData(leaf) as Data
            let direct = anchors.contains(leafData)
            return (true, direct ? "The signer’s certificate is in your trusted certificates." : "The certificate chains to a trusted root.")
        }
        let reason = (error as Error?)?.localizedDescription ?? "The certificate is not trusted."
        return (false, reason)
    }
}
