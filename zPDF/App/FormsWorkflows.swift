import AppKit
import Foundation
import PDFKit

/// Forms & Signatures document actions. Each one is a native transform
/// (one Undo step, marks the tab edited); Save publishes it.
@MainActor
extension AppState {
    /// Hybrid XFA forms open read-only. Converting keeps the AcroForm fields
    /// (which every PDF reader supports) and drops the XFA packet.
    func convertXFAForm(_ tab: DocumentTab) async throws {
        guard tab.saveBlock == "XFA_EDIT_BLOCKED", let url = tab.url, let hash = tab.sourceHash,
              let document = tab.pdfDocument else { return }
        guard commitFieldEditing() else { return }
        // The original becomes the saved baseline, so Undo returns to it and the
        // converted revision counts as an unsaved edit.
        let original = try await DocumentEditSource.capture(url, expectedHash: hash)
        tab.editSource = original
        tab.saveBaseline = try await SaveBaseline.capture(document)
        tab.saveBlock = nil
        resetUndoHistory(tab)
        do {
            try await applyDocumentTransform([["op": "convert_xfa_form"]], to: tab, actionName: "Convert to Standard Form")
        } catch {
            tab.saveBlock = "XFA_EDIT_BLOCKED"
            throw error
        }
        tab.protection.profiledHash = nil
        profileDocument(tab)
    }

    func flattenFormFields(_ tab: DocumentTab, names: [String]? = nil) async throws {
        var op: [String: Any] = ["op": "flatten_form_fields"]
        if let names { op["names"] = names }
        try await applyDocumentTransform([op], to: tab, actionName: "Flatten Form Fields")
        refreshFormModel(tab)
    }

    func resetForm(_ tab: DocumentTab) async throws {
        try await applyDocumentTransform([["op": "reset_form"]], to: tab, actionName: "Clear Form")
        refreshFormModel(tab)
    }

    func fillFields(_ values: [String: Any], in tab: DocumentTab, actionName: String = "Fill Form") async throws {
        try await applyDocumentTransform([["op": "fill_fields", "values": values]], to: tab, actionName: actionName)
        refreshFormModel(tab)
    }

    func updateFormField(_ name: String, changes: [String: Any], in tab: DocumentTab) async throws {
        var op = changes
        op["op"] = "update_form_field"
        op["name"] = name
        try await applyDocumentTransform([op], to: tab, actionName: "Edit Field Properties")
        refreshFormModel(tab)
    }

    func deleteFormField(_ name: String, in tab: DocumentTab) async throws {
        try await applyDocumentTransform([["op": "delete_form_field", "name": name]], to: tab, actionName: "Delete Field")
        refreshFormModel(tab)
    }

    func duplicateFormField(_ name: String, pages: [Int], in tab: DocumentTab) async throws {
        try await applyDocumentTransform([["op": "duplicate_form_field", "name": name, "pages": pages]],
                                         to: tab, actionName: "Duplicate Field Across Pages")
        refreshFormModel(tab)
    }

    func setTabOrder(page: Int, mode: String, order: [String]?, in tab: DocumentTab) async throws {
        var op: [String: Any] = ["op": "set_tab_order", "page": page, "mode": mode]
        if let order { op["order"] = order }
        try await applyDocumentTransform([op], to: tab, actionName: "Set Tab Order")
        refreshFormModel(tab)
    }

    func setCalculationOrder(_ order: [String], in tab: DocumentTab) async throws {
        try await applyDocumentTransform([["op": "set_calculation_order", "order": order]], to: tab,
                                         actionName: "Set Calculation Order")
        refreshFormModel(tab)
    }

    /// "Remove hidden information" belongs to the Redaction stream (`sanitize`).
    func removeHiddenInformation(_ tab: DocumentTab) async throws {
        do {
            try await applyDocumentTransform([["op": "sanitize"]], to: tab, actionName: "Remove Hidden Information")
        } catch let error as NativeSaveError where error.code == "UNSUPPORTED_OPERATION" {
            throw NativeSaveError(code: "SANITIZE_UNAVAILABLE",
                                  message: "Remove Hidden Information is provided by the Redact tool, which isn’t available in this build.")
        }
    }

    /// Re-encodes barcode fields from the on-screen values of their source fields.
    func updateBarcodes(in tab: DocumentTab) async throws {
        guard let document = tab.pdfDocument else { return }
        let values = FormLogic.currentValues(document).values
        let items: [[String: Any]] = tab.protection.formFields.filter { $0.kind == "barcode" }.map { field in
            let data = field.barcodeFields.map { values[$0] ?? "" }.joined(separator: "\t")
            return ["name": field.name, "value": data,
                    "matrix": BarcodeEncoder.matrix(for: data, symbology: field.barcodeSymbology) ?? []]
        }
        guard !items.isEmpty else { return }
        try await applyDocumentTransform([["op": "update_barcodes", "items": items]], to: tab, actionName: "Update Barcodes")
        refreshFormModel(tab)
    }

    func refreshFormModel(_ tab: DocumentTab) {
        tab.protection.profiledHash = nil
        profileDocument(tab)
    }

    // MARK: Digital signatures

    struct SignRequest {
        var identity: DigitalID
        var password: String
        var page: Int
        var rect: CGRect?
        var field: String?
        var reason = ""
        var location = ""
        var contact = ""
        var name: String?
        var certify: Int?
        var image: Data?
        var showLabels = true
        var showDate = true
        var showReason = true
        var showLocation = true
        var showNameLeft = true
        var timestampURL: String?
        var addLTV = false
        var fetchRevocation = false
        var format = "pades"
    }

    /// Signs the document (append-only), optionally embeds validation data,
    /// then saves so the signature covers the file on disk.
    func signDocument(_ request: SignRequest, in tab: DocumentTab) async throws {
        guard tab.protection.pending == .none || tab.protection.pending == .removed else {
            throw NativeSaveError(code: "ENCRYPTED_SIGNING", message: "Signing an encrypted document isn’t supported yet. Remove its security in Protect, sign, then protect a copy if needed.")
        }
        let p12 = try signatureService.pkcs12(for: request.identity)
        var op: [String: Any] = [
            "op": "sign", "identity": ["p12": p12.base64EncodedString(), "password": request.password],
            "page": request.page, "reason": request.reason, "location": request.location,
            "contact": request.contact, "subfilter": request.format,
            "appearance": ["show_label": request.showLabels, "show_date": request.showDate,
                           "show_reason": request.showReason, "show_location": request.showLocation,
                           "show_name_left": request.showNameLeft]]
        if let rect = request.rect { op["rect"] = [rect.minX, rect.minY, rect.maxX, rect.maxY] }
        if let field = request.field { op["field"] = field }
        if let name = request.name, !name.isEmpty { op["name"] = name }
        if let certify = request.certify { op["certify"] = certify }
        if let image = request.image { op["image"] = image.base64EncodedString() }
        if let url = request.timestampURL, !url.isEmpty { op["timestamp_url"] = url }
        var ops: [[String: Any]] = [op]
        try await applyDocumentTransform(ops, to: tab, actionName: request.certify == nil ? "Sign Document" : "Certify Document")
        if request.addLTV {
            ops = [["op": "add_ltv", "allow_network": request.fetchRevocation]]
            try? await applyDocumentTransform(ops, to: tab, actionName: "Add Validation Information")
        }
        signatureService.preferences.lastDigitalID = request.identity.id
        refreshFormModel(tab)
        _ = await saveDocument(tab).value
        refreshFormModel(tab)
    }

    func addLongTermValidation(_ tab: DocumentTab) async throws {
        try await applyDocumentTransform([["op": "add_ltv", "allow_network": signatureService.preferences.fetchRevocation]],
                                         to: tab, actionName: "Add Validation Information")
        refreshFormModel(tab)
    }

    /// Writes the exact bytes a signature covers to a new file.
    func saveSignedVersion(of field: String, in tab: DocumentTab) async throws {
        guard let source = tab.editSource ?? nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (tab.displayName as NSString).deletingPathExtension + " (signed version).pdf"
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let destination = panel.url else { return }
        _ = try await NativeDocumentBridge.transformFile(source.url, ops: NativeOps([["op": "extract_signed_revision", "field": field]]),
                                                         destination: destination,
                                                         overwrite: FileManager.default.fileExists(atPath: destination.path))
    }
}
