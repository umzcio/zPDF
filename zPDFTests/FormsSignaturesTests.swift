import PDFKit
import XCTest
@testable import zPDF

/// End-to-end Fill & Sign, Prepare Form, Protect and digital-signature flows
/// through the bundled native engine (UI state → engine → Save → reopen).
@MainActor
final class FormsSignaturesTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    private func makeState() throws -> AppState {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-signing-test-\(UUID())")
        directories.append(store)
        return AppState(signatureService: SignatureService(directory: store))
    }

    private func fixture(_ name: String) throws -> URL {
        let (url, directory) = try TestSupport.fixture(name, in: Self.self)
        directories.append(directory)
        return url
    }

    private func query(_ name: String, _ url: URL, password: String? = nil) async throws -> NativeJSON {
        try await NativeDocumentBridge.query(source: url, hash: nil, name: name, password: password)
    }

    private func fields(_ url: URL, password: String? = nil) async throws -> [String: FormFieldInfo] {
        let info = try await query("form_fields", url, password: password)
        return Dictionary(uniqueKeysWithValues: (info["fields"] as? [[String: Any]] ?? []).map {
            let field = FormFieldInfo($0); return (field.name, field)
        })
    }

    // MARK: Protect

    func testPasswordSecuritySaveReopenEditAndKeepSecurity() async throws {
        let url = try fixture("uscis-i9")
        let state = try makeState()
        let tab = try await TestSupport.open(url, in: state)
        var settings = SecuritySettings()
        settings.openPassword = "open-pass"
        settings.permissionsPassword = "owner-pass"
        settings.restrictPermissions = true
        settings.printing = .low
        settings.changes = .fill
        settings.allowCopy = false
        try await state.applyPasswordSecurity(settings, to: tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        try await TestSupport.save(state, tab)
        let locked = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(locked.isLocked, "Saved file requires the open password")
        XCTAssertTrue(locked.unlock(withPassword: "open-pass"))
        XCTAssertFalse(locked.allowsCopying)
        let info = try await query("security_info", url, password: "open-pass")
        XCTAssertEqual(info["revision"] as? Int, 6)
        XCTAssertEqual(info["method"] as? String, "AES-256")
        // The tab stays editable after Save (fresh decrypted revision) and keeps security.
        XCTAssertTrue(tab.allowsSaveEdits)
        XCTAssertEqual(tab.protection.pending, .preserve)
        state.closeDecision = { _ in .discard }
        await withCheckedContinuation { c in state.requestCloseAll { _ in c.resume() } }

        // Reopen with the permissions password: edit a field, save, security preserved.
        let second = try makeState()
        second.passwordPrompt = { _ in "owner-pass" }
        let reopened = try await TestSupport.open(url, in: second)
        XCTAssertTrue(reopened.allowsSaveEdits, reopened.saveBlock ?? "")
        let field = try XCTUnwrap(reopened.pdfDocument?.page(at: 0)?.annotations.first { $0.widgetFieldType == .text && !$0.isReadOnly })
        field.widgetStringValue = "Encrypted edit"
        second.refreshUnsavedChanges(reopened)
        try await TestSupport.save(second, reopened)
        let check = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(check.isLocked)
        XCTAssertTrue(check.unlock(withPassword: "open-pass"), "Original open password still works")
        XCTAssertEqual(check.page(at: 0)?.annotations.first { $0.fieldName == field.fieldName }?.widgetStringValue, "Encrypted edit")
        let after = try await query("security_info", url, password: "owner-pass")
        XCTAssertEqual(after["owner_password_matched"] as? Bool, true)
        let permissions = try XCTUnwrap(after["permissions"] as? [String: Bool])
        XCTAssertEqual(permissions["extract"], false)

        // Remove security with the permissions password.
        try await second.removeSecurity(from: reopened, permissionsPassword: "owner-pass")
        try await TestSupport.save(second, reopened)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: url)).isLocked)
        let plain = try await query("security_info", url)
        XCTAssertEqual(plain["encrypted"] as? Bool, false)
    }

    func testUserPasswordWithRestrictionsOpensReadOnlyUntilUnlocked() async throws {
        let url = try fixture("ordinary-edge")
        let state = try makeState()
        let tab = try await TestSupport.open(url, in: state)
        var settings = SecuritySettings()
        settings.openPassword = "reader"
        settings.permissionsPassword = "author"
        settings.restrictPermissions = true
        settings.changes = .none
        try await state.applyPasswordSecurity(settings, to: tab)
        try await TestSupport.save(state, tab)
        state.closeDecision = { _ in .discard }
        await withCheckedContinuation { c in state.requestCloseAll { _ in c.resume() } }

        let reader = try makeState()
        reader.passwordPrompt = { _ in "reader" }
        reader.openDocument(at: url)
        let restricted = try XCTUnwrap(reader.activeTab)
        try await TestSupport.settled(restricted)
        XCTAssertTrue(restricted.protection.editingRestricted)
        XCTAssertFalse(restricted.allowsSaveEdits)
        do {
            try await reader.unlockEditing(restricted, permissionsPassword: "wrong")
            XCTFail("Wrong permissions password must be rejected")
        } catch {}
        try await reader.unlockEditing(restricted, permissionsPassword: "author")
        XCTAssertTrue(restricted.allowsSaveEdits)
        XCTAssertNotNil(restricted.editSource)
    }

    // MARK: Digital signatures

    func testCreateIDSignValidateThenFillIncrementally() async throws {
        let url = try fixture("uscis-i9")
        let state = try makeState()
        let identity = try await state.signatureService.createDigitalID(name: "Casey Signer", email: "casey@example.test",
                                                                        organization: "zPDF QA", password: "id-password")
        XCTAssertEqual(state.signatureService.digitalIDs.count, 1)
        do {
            try await state.signatureService.checkPassword("nope", for: identity)
            XCTFail("Wrong ID password must be rejected")
        } catch {}
        let tab = try await TestSupport.open(url, in: state)
        var request = AppState.SignRequest(identity: identity, password: "id-password", page: 0,
                                           rect: CGRect(x: 320, y: 40, width: 220, height: 50))
        request.reason = "Approved"
        request.location = "Missoula"
        try await state.signDocument(request, in: tab)
        XCTAssertFalse(tab.hasUnsavedChanges, state.saveError?.message ?? "")
        let signedBytes = try Data(contentsOf: url)
        var report = try await query("signatures", url)
        var signature = try XCTUnwrap((report["signatures"] as? [[String: Any]])?.first { $0["signed"] as? Bool == true })
        XCTAssertEqual(signature["integrity"] as? Bool, true)
        XCTAssertEqual(signature["covers_document"] as? Bool, true)

        // Trust: unknown until the signer's certificate is trusted.
        await state.validateSignatures(tab)
        let status = try XCTUnwrap(tab.protection.signatures.first { $0.signed })
        XCTAssertEqual(status.validity, .unknownSigner)
        try await state.signatureService.trust.add(der: identity.certificate)
        await state.validateSignatures(tab)
        XCTAssertEqual(tab.protection.signatures.first { $0.signed }?.validity, .valid)

        // A later form fill is appended; the signature stays valid.
        let field = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.widgetFieldType == .text && !$0.isReadOnly })
        field.widgetStringValue = "After signing"
        state.refreshUnsavedChanges(tab)
        try await TestSupport.save(state, tab)
        let updated = try Data(contentsOf: url)
        XCTAssertTrue(updated.starts(with: signedBytes), "Save after signing must append, not rewrite")
        report = try await query("signatures", url)
        signature = try XCTUnwrap((report["signatures"] as? [[String: Any]])?.first { $0["signed"] as? Bool == true })
        XCTAssertEqual(signature["integrity"] as? Bool, true)
        XCTAssertEqual(signature["covers_document"] as? Bool, false)
        XCTAssertEqual(signature["changes_after"] as? [String], ["form_fill"])
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.fieldName == field.fieldName }?.widgetStringValue,
                       "After signing")
        await state.validateSignatures(tab)
        XCTAssertEqual(tab.protection.signatures.first { $0.signed }?.validity, .validModified)
    }

    func testImportedIDSignsExistingFieldAndCertifies() async throws {
        let url = try fixture("ordinary-edge")
        let state = try makeState()
        // Create an ID, export its PKCS#12 to a file, and import it again.
        let created = try await FormsEngine.crypto("create_identity", params: ["name": "Imported", "password": "secret-1", "key": "p256"])
        let p12 = try XCTUnwrap(Data(base64Encoded: created["p12"] as? String ?? ""))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-id-\(UUID()).p12")
        try p12.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = try await state.signatureService.importDigitalID(from: file, password: "secret-1")
        XCTAssertTrue(identity.algorithm.hasPrefix("ECDSA"))
        let tab = try await TestSupport.open(url, in: state)
        state.placeFormField(.signature, page: 0, rect: CGRect(x: 72, y: 72, width: 200, height: 50))
        try await TestSupport.settled(tab)
        for _ in 0..<200 where !tab.protection.formFields.contains(where: { $0.kind == "signature" }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let fieldName = try XCTUnwrap(tab.protection.formFields.first { $0.kind == "signature" }?.name)
        var request = AppState.SignRequest(identity: identity, password: "secret-1", page: 0, rect: nil, field: fieldName)
        request.certify = 2
        try await state.signDocument(request, in: tab)
        let report = try await query("signatures", url)
        XCTAssertEqual(report["certification"] as? Int, 2)
        let signature = try XCTUnwrap((report["signatures"] as? [[String: Any]])?.first)
        XCTAssertEqual(signature["field"] as? String, fieldName)
        XCTAssertEqual(signature["integrity"] as? Bool, true)
    }

    // MARK: Prepare Form + fill

    func testPreparedFieldsFillSaveAndReopen() async throws {
        let url = try fixture("ordinary-edge")
        let state = try makeState()
        let tab = try await TestSupport.open(url, in: state)
        let ops: [[String: Any]] = [
            ["op": "add_form_field", "type": "radio", "name": "Plan", "page": 0, "rect": [72, 600, 86, 614], "export_value": "Basic"],
            ["op": "add_form_field", "type": "radio", "name": "Plan", "page": 0, "rect": [120, 600, 134, 614], "export_value": "Pro"],
            ["op": "add_form_field", "type": "list", "name": "Colors", "page": 0, "rect": [72, 500, 222, 570],
             "options": ["Red", "Green", "Blue"], "multi_select": true],
            ["op": "add_form_field", "type": "combo", "name": "City", "page": 0, "rect": [250, 540, 400, 562],
             "options": ["Helena", "Missoula"], "editable": true],
            ["op": "add_form_field", "type": "number", "name": "Price", "page": 0, "rect": [72, 450, 172, 472],
             "format": ["kind": "number", "decimals": 2, "currency": "$"]],
            ["op": "add_form_field", "type": "text", "name": "Qty", "page": 0, "rect": [200, 450, 260, 472]],
            ["op": "add_form_field", "type": "text", "name": "Total", "page": 0, "rect": [300, 450, 400, 472],
             "readonly": true, "format": ["kind": "number", "decimals": 2, "currency": "$"],
             "calculate": ["kind": "sfn", "expression": "Price * Qty"]],
        ]
        try await state.applyDocumentTransform(ops, to: tab, actionName: "Prepare")
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let radios = page.annotations.filter { $0.fieldName == "Plan" }
        XCTAssertEqual(radios.count, 2)
        // Choose "Pro" the way a click does: PDFKit updates both widgets.
        for radio in radios {
            radio.buttonWidgetState = radio.buttonWidgetStateString == "Pro" ? .onState : .offState
        }
        let city = try XCTUnwrap(page.annotations.first { $0.fieldName == "City" })
        city.widgetStringValue = "Bozeman"
        try XCTUnwrap(page.annotations.first { $0.fieldName == "Price" }).widgetStringValue = "$1,234.50"
        try XCTUnwrap(page.annotations.first { $0.fieldName == "Qty" }).widgetStringValue = "3"
        state.refreshUnsavedChanges(tab)
        // Multi-select list boxes are filled through the panel's native action.
        try await state.fillFields(["Colors": ["Red", "Blue"]], in: tab, actionName: "Select Colors")
        try await TestSupport.save(state, tab)

        let saved = try await fields(url)
        XCTAssertEqual(saved["Plan"]?.value, "Pro")
        XCTAssertEqual(saved["Colors"]?.values, ["Red", "Blue"])
        XCTAssertEqual(saved["City"]?.value, "Bozeman")
        XCTAssertEqual(saved["Price"]?.value, "1234.5")
        XCTAssertEqual(saved["Total"]?.value, "3703.5")
        // Reopen in PDFKit: the radio selection and values survive.
        let reopened = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let pro = reopened.annotations.first { $0.fieldName == "Plan" && $0.buttonWidgetStateString == "Pro" }
        XCTAssertEqual(pro?.buttonWidgetState, .onState)
        XCTAssertEqual(reopened.annotations.first { $0.fieldName == "City" }?.widgetStringValue, "Bozeman")
    }

    func testFlattenAndHybridXFAConversion() async throws {
        let url = try fixture("irs-w9")
        let state = try makeState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await TestSupport.settled(tab)
        XCTAssertEqual(tab.saveBlock, "XFA_EDIT_BLOCKED")
        try await state.convertXFAForm(tab)
        XCTAssertNil(tab.saveBlock)
        XCTAssertTrue(tab.allowsSaveEdits)
        XCTAssertTrue(tab.hasUnsavedChanges)
        let field = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.widgetFieldType == .text && !$0.isReadOnly })
        field.widgetStringValue = "Converted form"
        state.refreshUnsavedChanges(tab)
        try await TestSupport.save(state, tab)
        let policy = try await NativeSaveBridge.inspect(url)
        XCTAssertNil(policy.writeBlock, "Converted form is editable in the facade")
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.fieldName == field.fieldName }?.widgetStringValue,
                       "Converted form")
        try await state.flattenFormFields(tab)
        try await TestSupport.save(state, tab)
        XCTAssertFalse(PDFDocument(url: url)?.page(at: 0)?.annotations.contains { $0.type == "Widget" } ?? true)
        XCTAssertTrue(TestSupport.text(url).contains("Converted form"))
    }

    // MARK: Fill & Sign

    func testFillSignMarksAndSignatureStampSave() async throws {
        let url = try fixture("ordinary-edge")
        let state = try makeState()
        let tab = try await TestSupport.open(url, in: state)
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let canvas = state.signatureService.canvas
        canvas.addFillText("Jordan Q. Public", at: CGPoint(x: 100, y: 500), on: page, state: state)
        let ink = PDFAnnotation(bounds: CGRect(x: 100, y: 450, width: 12, height: 12), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.move(to: CGPoint(x: 1, y: 6)); path.line(to: CGPoint(x: 5, y: 2)); path.line(to: CGPoint(x: 11, y: 11))
        ink.add(path)
        page.addAnnotation(ink)
        state.refreshUnsavedChanges(tab)
        // A typed signature placed as a stamp.
        let image = try XCTUnwrap(SignatureRendering.typedImage("Jordan Public", fontName: "SnellRoundhand"))
        let signature = try XCTUnwrap(state.signatureService.addSignature(name: "Jordan Public", kind: .signature, image: image, source: .typed))
        XCTAssertEqual(state.signatureService.signatures.count, 1)
        state.placeSignature(signature, page: 0, rect: CGRect(x: 300, y: 100, width: 150, height: 40))
        for _ in 0..<400 where !(tab.pdfDocument?.page(at: 0)?.annotations.contains { $0.type == "Stamp" } ?? false) {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await TestSupport.settled(tab)
        try await TestSupport.save(state, tab)
        let reopened = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let text = try XCTUnwrap(reopened.annotations.first { $0.type == "FreeText" })
        XCTAssertEqual(text.contents, "Jordan Q. Public")
        XCTAssertTrue(FormsCanvasInteraction.isFillText(text), "Typewriter intent survives save")
        XCTAssertTrue(reopened.annotations.contains { $0.type == "Ink" })
        XCTAssertTrue(reopened.annotations.contains { $0.type == "Stamp" })
        // The library persists across service instances.
        let reloaded = SignatureService(directory: state.signatureService.store.directory)
        XCTAssertEqual(reloaded.signatures.first?.name, "Jordan Public")
    }

    func testProfileMatching() {
        var profile = FormProfile()
        profile.email = "me@example.test"
        profile.firstName = "Ada"
        profile.lastName = "Lovelace"
        profile.postalCode = "59801"
        profile.fullName = "Ada Lovelace"
        XCTAssertEqual(FormProfileMatcher.match("Email Address", profile: profile)?.1, "me@example.test")
        XCTAssertEqual(FormProfileMatcher.match("form1[0].Page1[0].FirstName[0]", profile: profile)?.1, "Ada")
        XCTAssertEqual(FormProfileMatcher.match("Last Name (Family Name)", profile: profile)?.1, "Lovelace")
        XCTAssertEqual(FormProfileMatcher.match("ZIP Code", profile: profile)?.1, "59801")
        XCTAssertEqual(FormProfileMatcher.match("Applicant name", profile: profile)?.1, "Ada Lovelace")
        XCTAssertNil(FormProfileMatcher.match("Signature of Employee", profile: profile))
    }
}
