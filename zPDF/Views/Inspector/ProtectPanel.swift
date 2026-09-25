//
//  ProtectPanel.swift
//  zPDF
//
//  Purpose: Protect — password security (AES-256 open password and
//  permissions password with print/change/copy restrictions), saved
//  security presets, removing security, and sanitizing. Security is
//  recorded on the editing revision and applied when the file is saved;
//  documents opened with a password keep their encryption on Save.
//  Certificate (public-key) security encrypts for chosen recipients'
//  certificates (Adobe.PubSec, AES-256; see EngineSupport/transforms/pubsec.py).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProtectPanel: View {
    @Environment(AppState.self) private var appState
    @State private var showsPasswordSheet = false
    @State private var showsCertificateSheet = false
    @State private var preset: SecurityPreset?
    @State private var showsRemove = false
    @State private var removePassword = ""
    @State private var error: String?
    @State private var working = false

    private var tab: DocumentTab? { appState.activeTab }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            statusSection
            PanelSection(title: "Encryption") {
                PanelActionButton(title: currentlyProtected ? "Change password security…" : "Protect with password…",
                                  symbolName: "lock.shield", help: "Require a password to open the PDF, restrict printing, editing and copying",
                                  prominent: !currentlyProtected) {
                    preset = nil
                    showsPasswordSheet = true
                }
                PanelActionButton(title: "Encrypt with certificates…", symbolName: "person.badge.key",
                                  help: "Only people whose certificates you choose can open the PDF, using their digital IDs") {
                    showsCertificateSheet = true
                }
                if !appState.signatureService.securityPresets.isEmpty {
                    Menu {
                        ForEach(appState.signatureService.securityPresets) { item in
                            Button(item.name) { preset = item; showsPasswordSheet = true }
                        }
                        Divider()
                        Menu("Delete Preset") {
                            ForEach(appState.signatureService.securityPresets) { item in
                                Button(item.name, role: .destructive) {
                                    appState.signatureService.securityPresets.removeAll { $0.id == item.id }
                                }
                            }
                        }
                    } label: {
                        Label("Apply a saved preset", systemImage: "list.star").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .help("Start from security settings you saved earlier")
                }
                if currentlyProtected {
                    PanelActionButton(title: "Remove security…", symbolName: "lock.open", help: "Save without passwords or restrictions",
                                      role: .destructive) {
                        removePassword = ""
                        showsRemove = true
                    }
                }
            }
            PanelSection(title: "Sanitize") {
                PanelActionButton(title: "Remove hidden information", symbolName: "eye.trianglebadge.exclamationmark",
                                  help: "Remove metadata, hidden layers, scripts, and other hidden content before sharing") {
                    guard let tab else { return }
                    perform { try await appState.removeHiddenInformation(tab) }
                }
                if ToolID.redact.isImplemented {
                    PanelActionButton(title: "Redact text and images", symbolName: "eye.slash",
                                      help: "Permanently remove sensitive content") { appState.openTool(.redact) }
                }
            }
            if working { ProgressView().controlSize(.small) }
            if let error { PanelErrorText(message: error) }
            PanelNote("Security is applied when you save. zPDF uses AES-256 encryption. Anyone with the permissions password can change or remove the restrictions.")
        }
        .disabled(tab?.allowsSaveEdits != true)
        .sheet(isPresented: $showsPasswordSheet) {
            if let tab { PasswordSecuritySheet(tab: tab, preset: preset).environment(appState) }
        }
        .sheet(isPresented: $showsCertificateSheet) {
            if let tab { CertificateSecuritySheet(tab: tab).environment(appState) }
        }
        .alert("Remove security?", isPresented: $showsRemove) {
            if needsPermissionsPassword {
                SecureField("Permissions password", text: $removePassword)
            }
            Button("Cancel", role: .cancel) {}
            Button("Remove Security", role: .destructive) {
                guard let tab else { return }
                let password = removePassword
                perform { try await appState.removeSecurity(from: tab, permissionsPassword: password) }
            }
        } message: {
            Text(needsPermissionsPassword ? "Enter the permissions password. The document will be saved without passwords."
                 : "The document will be saved without passwords or restrictions.")
        }
    }

    private var currentlyProtected: Bool {
        switch tab?.protection.pending ?? .none {
        case .preserve, .password, .certificate, .certificatePreserve: true
        default: false
        }
    }

    private var needsPermissionsPassword: Bool {
        guard let protection = tab?.protection else { return false }
        return protection.original != nil && protection.security?.ownerPasswordMatched != true
    }

    @ViewBuilder
    private var statusSection: some View {
        let protection = tab?.protection
        switch protection?.pending ?? .none {
        case .none:
            PanelStatusCard(symbolName: "lock.open", title: "Not protected",
                            detail: "Anyone can open, print, and copy this document.")
        case .removed:
            PanelStatusCard(symbolName: "lock.open.trianglebadge.exclamationmark", title: "Security will be removed",
                            detail: "Save to write the document without passwords.", tone: .warning)
        case .preserve:
            PanelStatusCard(symbolName: "lock.fill", title: "Password protected (\(protection?.security?.method ?? "encrypted"))",
                            detail: restrictionSummary(protection?.security?.permissions ?? [:]), tone: .good)
        case .password(let settings):
            PanelStatusCard(symbolName: "lock.badge.clock", title: "New security will be applied on Save",
                            detail: settingsSummary(settings), tone: .good)
        case .certificate(let recipients):
            PanelStatusCard(symbolName: "person.badge.key.fill", title: "Certificate security will be applied on Save",
                            detail: "\(recipients.certificates.count) recipient\(recipients.certificates.count == 1 ? "" : "s") can open it with their digital IDs.",
                            tone: .good)
        case .certificatePreserve:
            PanelStatusCard(symbolName: "person.badge.key.fill", title: "Encrypted for certificates (AES-256)",
                            detail: "Saving keeps the same recipients.", tone: .good)
        }
    }

    private func restrictionSummary(_ permissions: [String: Bool]) -> String {
        var denied: [String] = []
        if permissions["print_highres"] == false { denied.append(permissions["print_lowres"] == false ? "printing" : "high-quality printing") }
        if permissions["modify_other"] == false { denied.append("editing") }
        if permissions["extract"] == false { denied.append("copying") }
        if permissions["modify_annotation"] == false { denied.append("commenting") }
        return denied.isEmpty ? "No restrictions. Saving keeps the same passwords." : "Restricts \(denied.joined(separator: ", ")). Saving keeps the same passwords."
    }

    private func settingsSummary(_ settings: SecuritySettings) -> String {
        var parts: [String] = [settings.openPassword.isEmpty ? "No open password" : "Open password required"]
        if settings.restrictPermissions {
            parts.append("printing: \(settings.printing.title.lowercased())")
            parts.append("changes: \(settings.changes.title.lowercased())")
            if !settings.allowCopy { parts.append("no copying") }
        }
        return parts.joined(separator: " · ")
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

extension SecuritySettings.Printing {
    var title: String {
        switch self {
        case .none: "Not allowed"
        case .low: "Low resolution (150 dpi)"
        case .high: "High resolution"
        }
    }
}

extension SecuritySettings.Changes {
    var title: String {
        switch self {
        case .none: "None"
        case .assembly: "Inserting, deleting, and rotating pages"
        case .fill: "Filling in form fields and signing"
        case .comments: "Commenting, filling in fields, and signing"
        case .any: "Any except extracting pages"
        }
    }
}

// MARK: - Certificate security sheet

struct CertificateSecuritySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab

    struct Candidate: Identifiable, Equatable {
        var id: String
        var name: String
        var detail: String
        var der: Data
        var mine: Bool
    }

    @State private var candidates: [Candidate] = []
    @State private var selected: Set<String> = []
    @State private var settings = SecuritySettings()
    @State private var error: String?
    @State private var applying = false

    var body: some View {
        FormsSheet(title: "Certificate Security",
                   subtitle: "Choose who can open this PDF. Each recipient opens it with the digital ID that matches their certificate.", width: 520) {
            VStack(alignment: .leading, spacing: 12) {
                if candidates.isEmpty {
                    Text("No certificates yet. Create a digital ID in Certificates, or add a certificate someone shared with you.")
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                } else {
                    List(candidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) },
                                             set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name + (candidate.mine ? " (you)" : "")).font(.system(size: 12, weight: .medium))
                                Text(candidate.detail).font(.caption).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: min(CGFloat(candidates.count) * 44 + 8, 190))
                }
                Button("Add Certificate File…") { addCertificate() }
                    .help("Add a recipient from a .cer, .crt, .der or .pem file")
                Divider()
                Toggle("Restrict what recipients can do", isOn: $settings.restrictPermissions)
                if settings.restrictPermissions {
                    Picker("Printing allowed", selection: $settings.printing) {
                        ForEach(SecuritySettings.Printing.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Changes allowed", selection: $settings.changes) {
                        ForEach(SecuritySettings.Changes.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Allow copying of text and images", isOn: $settings.allowCopy)
                }
                if !candidates.contains(where: { $0.mine && selected.contains($0.id) }) {
                    PanelErrorText(message: "Include one of your own digital IDs, or you won’t be able to open the saved file.")
                }
                if let error { PanelErrorText(message: error) }
            }
        } buttons: {
            if applying { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || applying)
                .help("Security is applied when you save the document")
        }
        .onAppear(perform: load)
    }

    private func load() {
        let service = appState.signatureService
        var list: [Candidate] = service.digitalIDs.filter { $0.algorithm.hasPrefix("RSA") }.map {
            Candidate(id: $0.sha256, name: $0.name, detail: [$0.email, $0.selfSigned ? "Self-signed" : $0.issuer].filter { !$0.isEmpty }.joined(separator: " · "),
                      der: $0.certificate, mine: true)
        }
        for trusted in service.trust.certificates where !list.contains(where: { $0.id == trusted.sha256 }) {
            list.append(Candidate(id: trusted.sha256, name: trusted.name, detail: trusted.issuer, der: trusted.der, mine: false))
        }
        candidates = list
        if selected.isEmpty, let mine = list.first(where: \.mine) { selected = [mine.id] }
    }

    private func addCertificate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["cer", "crt", "der", "pem"].compactMap { UTType(filenameExtension: $0) } + [.x509Certificate]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let added = try await appState.signatureService.trust.add(fileAt: url)
                load()
                selected.insert(added.sha256)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func apply() {
        let chosen = candidates.filter { selected.contains($0.id) }.map(\.der)
        applying = true
        error = nil
        Task {
            defer { applying = false }
            do {
                try await appState.applyCertificateSecurity(CertificateRecipients(certificates: chosen, settings: settings), to: tab)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Password security sheet

struct PasswordSecuritySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    var preset: SecurityPreset?

    @State private var settings = SecuritySettings()
    @State private var requireOpen = true
    @State private var confirmOpen = ""
    @State private var confirmPermissions = ""
    @State private var presetName = ""
    @State private var savePreset = false
    @State private var error: String?
    @State private var applying = false

    var body: some View {
        FormsSheet(title: "Password Security", subtitle: "Choose who can open this document and what they can do with it.", width: 500) {
            Form {
                Section {
                    Toggle("Require a password to open the document", isOn: $requireOpen)
                    if requireOpen {
                        SecureField("Open password", text: $settings.openPassword)
                        SecureField("Confirm open password", text: $confirmOpen)
                        if !settings.openPassword.isEmpty { strength(settings.openPassword) }
                    }
                }
                Section {
                    Toggle("Restrict printing, editing, and copying", isOn: $settings.restrictPermissions)
                    if settings.restrictPermissions {
                        SecureField("Permissions password", text: $settings.permissionsPassword)
                        SecureField("Confirm permissions password", text: $confirmPermissions)
                        Picker("Printing allowed", selection: $settings.printing) {
                            ForEach(SecuritySettings.Printing.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Changes allowed", selection: $settings.changes) {
                            ForEach(SecuritySettings.Changes.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Allow copying of text, images, and other content", isOn: $settings.allowCopy)
                        Toggle("Allow text access for screen readers", isOn: $settings.allowAccessibility)
                    }
                }
                Section {
                    Picker("Encryption", selection: $settings.method) {
                        Text("AES-256 (Acrobat X and later)").tag(SecuritySettings.Method.aes256)
                        Text("AES-128 (Acrobat 7 and later)").tag(SecuritySettings.Method.aes128)
                    }
                    Toggle("Encrypt document metadata", isOn: $settings.encryptMetadata)
                        .help("Turn off so search engines can read the title and author without the password")
                    Toggle("Save these settings as a preset", isOn: $savePreset)
                    if savePreset { TextField("Preset name", text: $presetName) }
                }
                if let error { PanelErrorText(message: error) }
            }
            .formStyle(.grouped)
            .frame(height: 420)
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(applying || (!requireOpen && !settings.restrictPermissions))
                .help("Security is applied when you save the document")
        }
        .onAppear {
            guard let preset else { return }
            requireOpen = preset.requireOpenPassword
            settings.restrictPermissions = preset.restrictPermissions
            settings.printing = preset.printing
            settings.changes = preset.changes
            settings.allowCopy = preset.allowCopy
            settings.allowAccessibility = preset.allowAccessibility
            settings.method = preset.method
        }
    }

    private func strength(_ password: String) -> some View {
        let score = [password.count >= 8, password.count >= 12,
                     password.rangeOfCharacter(from: .decimalDigits) != nil,
                     password.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil,
                     password != password.lowercased()].filter { $0 }.count
        let label = password.isEmpty ? "" : score <= 1 ? "Weak" : score <= 3 ? "Fair" : "Strong"
        return HStack {
            Gauge(value: Double(score), in: 0...5) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(score <= 1 ? .red : score <= 3 ? .orange : .green)
                .frame(width: 120)
                .accessibilityLabel("Password strength")
                .accessibilityValue(label)
            Text(label).font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private func apply() {
        error = nil
        if !requireOpen { settings.openPassword = "" }
        if !settings.restrictPermissions { settings.permissionsPassword = "" }
        if requireOpen {
            guard !settings.openPassword.isEmpty else { error = "Enter an open password."; return }
            guard settings.openPassword == confirmOpen else { error = "The open passwords don’t match."; return }
        }
        if settings.restrictPermissions {
            guard !settings.permissionsPassword.isEmpty else { error = "Enter a permissions password."; return }
            guard settings.permissionsPassword == confirmPermissions else { error = "The permissions passwords don’t match."; return }
            guard settings.permissionsPassword != settings.openPassword else {
                error = "The permissions password must be different from the open password."; return
            }
        }
        if savePreset {
            let name = presetName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { error = "Name the preset."; return }
            appState.signatureService.securityPresets.append(SecurityPreset(
                name: name, requireOpenPassword: requireOpen, restrictPermissions: settings.restrictPermissions,
                printing: settings.printing, changes: settings.changes, allowCopy: settings.allowCopy,
                allowAccessibility: settings.allowAccessibility, method: settings.method))
        }
        applying = true
        let chosen = settings
        Task {
            defer { applying = false }
            do {
                try await appState.applyPasswordSecurity(chosen, to: tab)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
