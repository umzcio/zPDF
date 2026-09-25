import AppKit
import SwiftUI

/// Forms & Signatures menu: Fill & Sign, Prepare Form, Protect and
/// Certificates actions, plus the flows that work on read-only documents
/// (unlocking an encrypted file, converting a hybrid XFA form).
struct FormsCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Forms") {
            Button("Fill & Sign") { appState.openTool(.fillAndSign) }
                .disabled(!editable)
            Button("Prepare Form") { appState.openTool(.prepareForm) }
                .disabled(!editable)
            Button("Protect") { appState.openTool(.protect) }
                .disabled(!editable)
            Button("Certificates") { appState.openTool(.certificates) }
                .disabled(appState.activeTab == nil)
            Divider()
            Button("Add Text") { arm(.addText) }
                .disabled(!editable)
            Button("Add Check Mark") { arm(.check) }
                .disabled(!editable)
            Button("Add Today’s Date") { arm(.date) }
                .disabled(!editable)
            Button("Place Signature") {
                if let signature = appState.signatureService.signatures(of: .signature).last {
                    arm(.signature(signature))
                } else { appState.openTool(.fillAndSign) }
            }
            .disabled(!editable)
            Divider()
            Button("Sign with Certificate…") {
                appState.openTool(.signWithCertificate)
                if !appState.signatureService.digitalIDs.isEmpty { appState.signatureService.arm(.certificateSignature) }
            }
            .disabled(!editable)
            Button("Validate All Signatures") {
                guard let tab = appState.activeTab else { return }
                appState.documentPanel = .signatures
                Task { await appState.validateSignatures(tab) }
            }
            .disabled(appState.activeTab == nil)
            Divider()
            Button("Unlock Editing…") { unlockEditing() }
                .disabled(appState.activeTab?.protection.editingRestricted != true)
            Button("Convert to Standard Form…") { convertXFA() }
                .disabled(appState.activeTab?.saveBlock != "XFA_EDIT_BLOCKED")
            Button("Clear Form") {
                guard let tab = appState.activeTab else { return }
                appState.runDocumentTransform([["op": "reset_form"]], actionName: "Clear Form", in: tab) { _ in
                    appState.refreshFormModel(tab)
                }
            }
            .disabled(!editable || appState.activeTab?.protection.formFields.isEmpty != false)
            Button("Flatten Form Fields") {
                guard let tab = appState.activeTab else { return }
                appState.runDocumentTransform([["op": "flatten_form_fields"]], actionName: "Flatten Form Fields", in: tab) { _ in
                    appState.refreshFormModel(tab)
                }
            }
            .disabled(!editable || appState.activeTab?.protection.formFields.isEmpty != false)
        }
    }

    private var editable: Bool { appState.activeTab?.allowsSaveEdits == true }

    private func arm(_ tool: FormsCanvasTool) {
        appState.openTool(.fillAndSign)
        appState.signatureService.arm(tool)
    }

    private func unlockEditing() {
        guard let tab = appState.activeTab else { return }
        let alert = NSAlert()
        alert.messageText = "Unlock editing of “\(tab.displayName)”"
        alert.informativeText = "This document restricts changes. Enter its permissions password to edit it. The file stays protected when you save."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Permissions password"
        field.setAccessibilityLabel("Permissions password")
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        Task {
            do { try await appState.unlockEditing(tab, permissionsPassword: password) }
            catch { appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription) }
        }
    }

    private func convertXFA() {
        guard let tab = appState.activeTab else { return }
        let alert = NSAlert()
        alert.messageText = "Convert to a standard PDF form?"
        alert.informativeText = "This form also contains Adobe XFA data, which zPDF can’t edit. Converting keeps the standard form fields—which every PDF app can fill—and removes the XFA data when you save. Dynamic XFA behavior (such as growing sections) is lost."
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await appState.convertXFAForm(tab) }
            catch { appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription) }
        }
    }
}
