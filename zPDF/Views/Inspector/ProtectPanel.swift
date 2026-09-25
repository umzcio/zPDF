//
//  ProtectPanel.swift
//  zPDF
//
//  Purpose: Protect — password security (AES-256 open password and
//  permissions password with print/change/copy restrictions), saved
//  security presets, removing security, and sanitizing. Security is
//  recorded on the editing revision and applied when the file is saved;
//  documents opened with a password keep their encryption on Save.
//  Certificate (public-key) encryption is not offered: QPDF, which writes
//  zPDF's encrypted files, has no public-key security handler.
//

import AppKit
import SwiftUI

struct ProtectPanel: View {
    @Environment(AppState.self) private var appState
    @State private var showsPasswordSheet = false
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
        case .preserve, .password: true
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
                        strength(settings.openPassword)
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
            .frame(height: 440)
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
        .opacity(password.isEmpty ? 0 : 1)
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
