//
//  SignPanel.swift
//  zPDF
//
//  Purpose: Certificates / Sign with Certificate — manage digital IDs
//  (create self-signed RSA/ECDSA, import PKCS#12), sign or certify with a
//  visible or invisible PAdES signature (drag a box or use a signature
//  field), add long-term validation data, and jump to validation.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SignPanel: View {
    @Environment(AppState.self) private var appState
    @State private var showsCreate = false
    @State private var showsImport = false
    @State private var signing: SignTarget?
    @State private var error: String?
    @State private var working = false

    struct SignTarget: Identifiable {
        let id = UUID()
        let page: Int
        let rect: CGRect?
        let field: String?
    }

    private var tab: DocumentTab? { appState.activeTab }
    private var service: SignatureService { appState.signatureService }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            statusSection
            signSection
            idsSection
            validationSection
            if working { ProgressView().controlSize(.small) }
            if let error { PanelErrorText(message: error) }
        }
        .sheet(isPresented: $showsCreate) { DigitalIDCreateSheet().environment(appState) }
        .sheet(isPresented: $showsImport) { DigitalIDImportSheet().environment(appState) }
        .sheet(item: $signing) { target in
            if let tab { SignDocumentSheet(tab: tab, target: target).environment(appState) }
        }
        .onAppear {
            if let tab { appState.profileDocument(tab) }
            service.onSignatureBox = { page, rect, field in signing = SignTarget(page: page, rect: rect, field: field) }
            consumePendingField()
        }
        .onChange(of: service.pendingSignField?.field) { _, _ in consumePendingField() }
    }

    @ViewBuilder
    private var statusSection: some View {
        let signatures = tab?.protection.signatures.filter(\.signed) ?? []
        if signatures.isEmpty {
            PanelStatusCard(symbolName: "checkmark.seal", title: "Not signed",
                            detail: "A certificate signature proves who signed and shows any later changes.")
        } else {
            let bad = signatures.filter { $0.validity == .invalid }
            let unknown = signatures.filter { $0.validity == .unknownSigner }
            PanelStatusCard(symbolName: bad.isEmpty ? "checkmark.seal.fill" : "xmark.seal.fill",
                            title: bad.isEmpty ? (unknown.isEmpty ? "Signed and all signatures are valid" : "Signed; some signers aren’t trusted yet")
                                : "At least one signature is invalid",
                            detail: "\(signatures.count) signature\(signatures.count == 1 ? "" : "s"). See Signatures in the sidebar for details.",
                            tone: bad.isEmpty ? (unknown.isEmpty ? .good : .warning) : .bad)
        }
    }

    private var signSection: some View {
        PanelSection(title: "Sign") {
            if service.digitalIDs.isEmpty {
                PanelNote("Create or import a digital ID to sign with a certificate.")
            } else {
                PanelActionButton(title: "Drag a signature box", symbolName: "signature",
                                  help: "Drag on the page where the visible signature should appear", prominent: true) {
                    service.arm(.certificateSignature)
                }
                .disabled(tab?.allowsSaveEdits != true)
                let emptyFields = tab?.protection.signatures.filter { !$0.signed } ?? []
                if !emptyFields.isEmpty {
                    ForEach(emptyFields) { field in
                        PanelActionButton(title: "Sign “\(field.field)”", symbolName: "signature",
                                          help: "Sign the empty signature field on page \((field.page ?? 0) + 1)") {
                            signing = SignTarget(page: field.page ?? 0, rect: nil, field: field.field)
                        }
                        .disabled(tab?.allowsSaveEdits != true)
                    }
                }
                PanelActionButton(title: "Sign without a visible box", symbolName: "eye.slash",
                                  help: "Add an invisible signature that appears only in the Signatures panel") {
                    signing = SignTarget(page: max(0, (tab?.currentPage ?? 1) - 1), rect: nil, field: nil)
                }
                .disabled(tab?.allowsSaveEdits != true)
                ArmedToolBanner()
            }
        }
    }

    private var idsSection: some View {
        PanelSection(title: "Digital IDs") {
            ForEach(service.digitalIDs) { identity in
                DigitalIDRow(identity: identity)
            }
            HStack(spacing: 8) {
                PanelActionButton(title: "Create…", symbolName: "plus.circle", help: "Create a self-signed digital ID") { showsCreate = true }
                PanelActionButton(title: "Import…", symbolName: "square.and.arrow.down",
                                  help: "Import a digital ID from a .p12 or .pfx file") { showsImport = true }
            }
        }
    }

    @ViewBuilder
    private var validationSection: some View {
        PanelSection(title: "Validation") {
            PanelActionButton(title: "Validate all signatures", symbolName: "checkmark.shield",
                              help: "Check every signature and show details in the sidebar") {
                guard let tab else { return }
                appState.documentPanel = .signatures
                Task { await appState.validateSignatures(tab) }
            }
            .disabled(tab == nil)
            if tab?.protection.isSigned == true {
                PanelActionButton(title: "Add long-term validation", symbolName: "clock.badge.checkmark",
                                  help: "Embed certificates\(service.preferences.fetchRevocation ? " and revocation data" : "") so signatures can be validated years from now") {
                    guard let tab else { return }
                    perform { try await appState.addLongTermValidation(tab) }
                }
                .disabled(tab?.allowsSaveEdits != true)
            }
            Text(service.preferences.timestampEnabled && !service.preferences.timestampURL.isEmpty
                 ? "Signatures are timestamped by \(URL(string: service.preferences.timestampURL)?.host ?? service.preferences.timestampURL)."
                 : "Timestamps are off. Turn them on in Settings › Signatures.")
                .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private func consumePendingField() {
        guard let pending = service.pendingSignField else { return }
        service.pendingSignField = nil
        signing = SignTarget(page: pending.page, rect: nil, field: pending.field)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        working = true
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

struct DigitalIDRow: View {
    @Environment(AppState.self) private var appState
    let identity: DigitalID
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: identity.isExpired ? "person.badge.clock" : "person.text.rectangle")
                .foregroundStyle(identity.isExpired ? Color.orange : DesignTokens.Colors.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text([identity.email, identity.organization].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                Text("\(identity.selfSigned ? "Self-signed" : "Issued by \(identity.issuer)") · \(identity.algorithm) · \(identity.isExpired ? "Expired" : "Expires") \(identity.expiry?.formatted(date: .abbreviated, time: .omitted) ?? "—")")
                    .font(.system(size: 10)).foregroundStyle(identity.isExpired ? Color.orange : DesignTokens.Colors.mutedText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            PanelIconButton(symbolName: "square.and.arrow.up", label: "Export certificate to share") { export() }
            PanelIconButton(symbolName: "trash", label: "Remove digital ID", role: .destructive) { confirmRemove = true }
        }
        .padding(8)
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.hairline))
        .accessibilityElement(children: .combine)
        .confirmationDialog("Remove “\(identity.name)”?", isPresented: $confirmRemove) {
            Button("Remove Digital ID", role: .destructive) { appState.signatureService.removeDigitalID(identity) }
        } message: { Text("Its private key is deleted from this Mac. Documents you already signed stay valid.") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        panel.nameFieldStringValue = identity.name + ".cer"
        panel.message = "Share this certificate so others can trust your signatures. It contains no private key."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? identity.certificate.write(to: url)
    }
}

// MARK: - Digital ID sheets

struct DigitalIDCreateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var organization = ""
    @State private var unit = ""
    @State private var country = ""
    @State private var key = "rsa2048"
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        FormsSheet(title: "Create a Digital ID",
                   subtitle: "A self-signed ID is enough for your own records and for people who trust your certificate.", width: 460) {
            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                TextField("Organization", text: $organization)
                TextField("Department", text: $unit)
                TextField("Country code (e.g. US)", text: $country)
                Picker("Key", selection: $key) {
                    Text("RSA 2048-bit").tag("rsa2048")
                    Text("RSA 3072-bit").tag("rsa3072")
                    Text("ECDSA P-256").tag("p256")
                }
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirm)
                Text("You’ll enter this password each time you sign. It can’t be recovered.")
                    .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                if let error { PanelErrorText(message: error) }
            }
            .formStyle(.grouped)
            .frame(height: 380)
        } buttons: {
            if working { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create") { create() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 6)
        }
        .onAppear {
            let profile = appState.signatureService.profile
            name = profile.fullName.isEmpty ? [profile.firstName, profile.lastName].filter { !$0.isEmpty }.joined(separator: " ") : profile.fullName
            email = profile.email
            organization = profile.company
        }
    }

    private func create() {
        guard password == confirm else { error = "The passwords don’t match."; return }
        guard country.isEmpty || country.count == 2 else { error = "Use a two-letter country code."; return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await appState.signatureService.createDigitalID(name: name, email: email, organization: organization,
                                                                         unit: unit, country: country, key: key, password: password)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct DigitalIDImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        FormsSheet(title: "Import a Digital ID", subtitle: "Choose a PKCS#12 file (.p12 or .pfx) that contains your certificate and private key.", width: 440) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(file?.lastPathComponent ?? "No file chosen")
                        .foregroundStyle(file == nil ? DesignTokens.Colors.mutedText : DesignTokens.Colors.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx")].compactMap { $0 }
                        if panel.runModal() == .OK { file = panel.url }
                    }
                }
                SecureField("Digital ID password", text: $password).textFieldStyle(.roundedBorder)
                Text("The ID is stored in zPDF’s private storage on this Mac, still protected by its password.")
                    .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                if let error { PanelErrorText(message: error) }
            }
        } buttons: {
            if working { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Import") {
                guard let file else { return }
                working = true
                error = nil
                Task {
                    defer { working = false }
                    do { _ = try await appState.signatureService.importDigitalID(from: file, password: password); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(file == nil || working)
        }
    }
}

// MARK: - Sign sheet

struct SignDocumentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    let target: SignPanel.SignTarget

    @State private var identityID: UUID?
    @State private var password = ""
    @State private var reason = ""
    @State private var location = ""
    @State private var certify = false
    @State private var certifyLevel = 2
    @State private var graphic = "name"
    @State private var signatureImageID: UUID?
    @State private var showDate = true
    @State private var showReason = true
    @State private var showLocation = true
    @State private var showLabels = true
    @State private var timestamp = false
    @State private var ltv = true
    @State private var error: String?
    @State private var working = false

    private var service: SignatureService { appState.signatureService }
    private var identity: DigitalID? { service.digitalIDs.first { $0.id == identityID } }
    private var isVisible: Bool { target.rect != nil || target.field != nil }
    private var alreadySigned: Bool { tab.protection.isSigned }

    var body: some View {
        FormsSheet(title: certify ? "Certify Document" : "Sign Document",
                   subtitle: "The signature is added as a new revision and the document is saved.", width: 520) {
            Form {
                Section {
                    Picker("Digital ID", selection: $identityID) {
                        ForEach(service.digitalIDs) { id in Text("\(id.name)\(id.email.isEmpty ? "" : " <\(id.email)>")").tag(Optional(id.id)) }
                    }
                    SecureField("Digital ID password", text: $password)
                    if identity?.isExpired == true {
                        PanelErrorText(message: "This digital ID has expired. Signatures made with it will show as invalid.")
                    }
                }
                Section {
                    TextField("Reason", text: $reason, prompt: Text("I approve this document"))
                    TextField("Location", text: $location)
                }
                if isVisible {
                    Section("Appearance") {
                        Picker("Show on the left", selection: $graphic) {
                            Text("My name").tag("name")
                            if !service.signatures(of: .signature).isEmpty { Text("A saved signature").tag("image") }
                            Text("Nothing").tag("none")
                        }
                        if graphic == "image" {
                            Picker("Signature", selection: $signatureImageID) {
                                ForEach(service.signatures(of: .signature)) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        Toggle("Show “Digitally signed by” label", isOn: $showLabels)
                        Toggle("Show date", isOn: $showDate)
                        Toggle("Show reason", isOn: $showReason)
                        Toggle("Show location", isOn: $showLocation)
                        SignaturePreview(name: identity?.name ?? "Your Name", reason: showReason ? reason : "",
                                         location: showLocation ? location : "", showDate: showDate, labels: showLabels,
                                         graphic: graphic, image: service.signatures.first { $0.id == signatureImageID }?.image)
                    }
                }
                Section {
                    Toggle("Certify (the author’s signature; controls later changes)", isOn: $certify)
                        .disabled(alreadySigned)
                        .help(alreadySigned ? "Only an unsigned document can be certified" : "Certify as the document author")
                    if certify {
                        Picker("Changes allowed after certifying", selection: $certifyLevel) {
                            Text("No changes").tag(1)
                            Text("Form fill-in and signing").tag(2)
                            Text("Form fill-in, signing, and commenting").tag(3)
                        }
                    }
                    Toggle("Add a trusted timestamp", isOn: $timestamp)
                        .disabled(service.preferences.timestampURL.isEmpty)
                        .help(service.preferences.timestampURL.isEmpty ? "Set a timestamp server in Settings › Signatures" : service.preferences.timestampURL)
                    Toggle("Embed validation information (LTV)", isOn: $ltv)
                        .help("Store the certificate chain so the signature can be validated long-term")
                }
                if let error { PanelErrorText(message: error) }
            }
            .formStyle(.grouped)
            .frame(height: isVisible ? 560 : 400)
        } buttons: {
            if working { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(certify ? "Certify & Save" : "Sign & Save") { sign() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(identity == nil || password.isEmpty || working)
        }
        .onAppear {
            let prefs = service.preferences
            identityID = prefs.lastDigitalID.flatMap { id in service.digitalIDs.first { $0.id == id }?.id } ?? service.digitalIDs.first?.id
            reason = prefs.defaultReason
            location = prefs.defaultLocation
            showDate = prefs.showDateInAppearance
            showReason = prefs.showReasonInAppearance
            showLocation = prefs.showLocationInAppearance
            showLabels = prefs.showLabels
            timestamp = prefs.timestampEnabled && !prefs.timestampURL.isEmpty
            ltv = prefs.embedValidation
            signatureImageID = service.signatures(of: .signature).first?.id
        }
    }

    private func sign() {
        guard let identity else { return }
        error = nil
        working = true
        var request = AppState.SignRequest(identity: identity, password: password, page: target.page,
                                           rect: target.rect, field: target.field)
        request.reason = reason
        request.location = location
        request.certify = certify ? certifyLevel : nil
        request.showDate = showDate
        request.showReason = showReason
        request.showLocation = showLocation
        request.showLabels = showLabels
        request.showNameLeft = graphic != "none"
        if graphic == "image" { request.image = service.signatures.first { $0.id == signatureImageID }?.pngData }
        request.timestampURL = timestamp ? service.preferences.timestampURL : nil
        request.addLTV = ltv
        request.fetchRevocation = service.preferences.fetchRevocation
        request.format = service.preferences.format
        Task {
            defer { working = false }
            do {
                try await service.checkPassword(password, for: identity)
                try await appState.signDocument(request, in: tab)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Approximation of the visible signature appearance the engine draws.
private struct SignaturePreview: View {
    let name: String
    let reason: String
    let location: String
    let showDate: Bool
    let labels: Bool
    let graphic: String
    let image: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            if graphic == "image", let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            } else if graphic == "name" {
                Text(name).font(.system(size: 20)).lineLimit(1).minimumScaleFactor(0.3).frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(labels ? "Digitally signed by \(name)" : name)
                if showDate { Text("Date: \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))") }
                if !reason.isEmpty { Text("Reason: \(reason)") }
                if !location.isEmpty { Text("Location: \(location)") }
            }
            .font(.system(size: 8.5))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.black)
        .padding(8)
        .frame(height: 64)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.gray.opacity(0.4)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signature appearance preview")
    }
}
