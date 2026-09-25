import SwiftUI

/// Left sidebar Signatures panel: every signature field with its validity,
/// signer, time, integrity, trust, timestamp, certification and whether the
/// document changed after signing.
struct SignaturesSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var expanded: Set<String> = []
    @State private var error: String?

    private var protection: DocumentProtectionState { tab.protection }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                Spacer()
                if protection.isValidating { ProgressView().controlSize(.small) }
                Button { Task { await appState.validateSignatures(tab) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Validate all signatures")
                .accessibilityLabel("Validate all signatures")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let certification = protection.certification {
                        Label(certificationText(certification), systemImage: "rosette")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DesignTokens.Colors.accent)
                    }
                    if protection.signatures.isEmpty && protection.certification == nil {
                        SidebarEmptyState(symbolName: "signature", message: "No signatures",
                                          detail: "This document has no digital signatures or signature fields.",
                                          actionTitle: ToolID.signWithCertificate.isImplemented ? "Sign with Certificate…" : nil,
                                          action: { appState.openTool(.signWithCertificate) })
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                    ForEach(protection.signatures) { signature in
                        SignatureRow(signature: signature, expanded: expanded.contains(signature.id),
                                     toggle: { if expanded.contains(signature.id) { expanded.remove(signature.id) } else { expanded.insert(signature.id) } },
                                     tab: tab, error: $error)
                    }
                    if protection.isSigned && tab.hasUnsavedChanges {
                        PanelNote(protection.certification == 1
                                  ? "This document is certified with no changes allowed. Saving these edits will make the certification invalid."
                                  : "Unsaved changes will be added after the signatures. Signatures stay valid, and the panel will show the document changed after signing.")
                    }
                    if let message = protection.validationError ?? error { PanelErrorText(message: message) }
                }
                .padding(10)
            }
        }
        .task(id: tab.editSource?.hash ?? tab.sourceHash ?? "") {
            appState.profileDocument(tab)
            if protection.validatedHash != (tab.editSource?.hash ?? tab.sourceHash) {
                await appState.validateSignatures(tab)
            }
        }
    }

    private var summary: String {
        let signed = protection.signatures.filter(\.signed)
        if signed.isEmpty { return protection.signatures.isEmpty ? "Not signed" : "Unsigned signature fields" }
        if signed.contains(where: { $0.validity == .invalid }) { return "At least one signature is invalid" }
        if signed.contains(where: { $0.validity == .unknownSigner }) { return "Signed; signer identity unknown" }
        return "Signed and all signatures are valid"
    }

    private func certificationText(_ level: Int) -> String {
        switch level {
        case 1: "Certified: no changes allowed"
        case 2: "Certified: form fill-in and signing allowed"
        default: "Certified: fill-in, signing and comments allowed"
        }
    }
}

private struct SignatureRow: View {
    @Environment(AppState.self) private var appState
    let signature: SignatureStatus
    let expanded: Bool
    let toggle: () -> Void
    let tab: DocumentTab
    @Binding var error: String?

    private var icon: (String, Color) {
        switch signature.validity {
        case .valid: ("checkmark.seal.fill", DesignTokens.Colors.readyGreen)
        case .validModified: ("checkmark.seal", DesignTokens.Colors.readyGreen)
        case .unknownSigner: ("exclamationmark.triangle.fill", .orange)
        case .invalid: ("xmark.seal.fill", .red)
        case .unsigned: ("signature", DesignTokens.Colors.mutedText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signature.signed ? (signature.signerName.isEmpty ? signature.field : signature.signerName) : signature.field)
                            .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text(signature.summary).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let time = signature.timestampTime ?? signature.time {
                            Text(time.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide signature details" : "Show signature details")
            .accessibilityLabel("\(signature.signerName.isEmpty ? signature.field : signature.signerName): \(signature.summary)")
            if expanded { details }
        }
        .padding(8)
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.hairline))
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if signature.signed {
                detail("Integrity", signature.integrity ? "The signed bytes are unchanged." : "The document or signature was altered.")
                detail("Coverage", signature.coversDocument ? "Covers the whole document."
                       : "Revision \(signature.revision). Later changes: \(signature.changesAfter.map(Self.changeName).joined(separator: ", ")).")
                if signature.mdpViolation { detail("Certification", "Later changes aren’t permitted by the certification.") }
                detail("Signer", [signature.signerName, signature.signerEmail].filter { !$0.isEmpty }.joined(separator: ", "))
                detail("Trust", signature.trustDetail)
                if !signature.issuer.isEmpty { detail("Issuer", signature.issuer) }
                if !signature.reason.isEmpty { detail("Reason", signature.reason) }
                if !signature.location.isEmpty { detail("Location", signature.location) }
                if let ts = signature.timestampTime {
                    detail("Timestamp", "\(ts.formatted(date: .abbreviated, time: .standard)) \(signature.timestampValid ? "by \(signature.timestampAuthority)" : "(invalid)")")
                } else {
                    detail("Time", "From the signer’s computer clock (no timestamp).")
                }
                detail("LTV", signature.ltv ? "Validation information is embedded." : "No validation information embedded.")
                detail("Format", signature.subfilter)
                ForEach(signature.errors, id: \.self) { PanelErrorText(message: $0) }
                HStack(spacing: 6) {
                    if !signature.trusted, let leaf = signature.certificates.first {
                        Button("Trust Signer") {
                            Task {
                                do {
                                    try await appState.signatureService.trust.add(der: leaf)
                                    await appState.validateSignatures(tab)
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        .help("Add this signer’s certificate to your trusted certificates")
                    }
                    if !signature.coversDocument && signature.integrity {
                        Button("Save Signed Version…") {
                            Task {
                                do { try await appState.saveSignedVersion(of: signature.field, in: tab) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        .help("Save the document exactly as it was when this signature was applied")
                    }
                    if let page = signature.page {
                        Button("Show") { tab.goToPage(page + 1) }.help("Go to the signature on page \(page + 1)")
                    }
                }
                .controlSize(.small)
            } else {
                detail("Page", "\((signature.page ?? 0) + 1)")
                Button("Sign This Field…") {
                    appState.signatureService.pendingSignField = (signature.page ?? 0, signature.field)
                    appState.openTool(.signWithCertificate)
                }
                .controlSize(.small)
                .disabled(!tab.allowsSaveEdits || appState.signatureService.digitalIDs.isEmpty)
                .help(appState.signatureService.digitalIDs.isEmpty ? "Create a digital ID in Certificates first" : "Sign this field with your digital ID")
            }
        }
        .padding(.leading, 24)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DesignTokens.Colors.mutedText)
            Text(value.isEmpty ? "—" : value).font(.system(size: 10.5)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func changeName(_ kind: String) -> String {
        switch kind {
        case "form_fill": "form fields filled"
        case "signatures": "signatures added"
        case "annotations": "comments"
        case "content": "page content"
        case "pages": "pages"
        case "security_store": "validation data"
        case "fields": "fields added or removed"
        default: kind
        }
    }
}
