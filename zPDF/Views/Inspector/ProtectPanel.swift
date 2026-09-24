//
//  ProtectPanel.swift
//  zPDF
//
//  Purpose: Protect inspector — Encryption rows (password / certificate),
//  Permissions toggles (restrict editing & printing, require password to
//  open, block copying), Sanitize rows (remove hidden info, redact).
//  Phase: 1 — password encryption is REAL via PDFEngine.encrypt; the rest
//  is TODO(phase-5) UI scaffold.
//  TODO(phase-5): certificate encryption, permission bits (PDFKit write
//  options only carry passwords — permission flags need raw PDF writing),
//  sanitize hidden info, redaction burn-in via engine.applyRedactions.
//

import AppKit
import SwiftUI

struct ProtectPanel: View {
    @Environment(AppState.self) private var appState
    @State private var restrictEditing = true
    @State private var requirePasswordToOpen = false
    @State private var blockCopying = true
    @State private var showsEncryptSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Encryption") {
                PanelRow(title: "Encrypt with password", symbolName: "lock.shield") {
                    showsEncryptSheet = true
                }
                PanelRow(title: "Encrypt with certificate", symbolName: "checkmark.seal") {
                    // TODO(phase-5): certificate picker + recipient-based
                    // encryption (not supported by PDFKit write options).
                }
            }

            PanelSection(title: "Permissions") {
                Toggle("Restrict editing & printing", isOn: $restrictEditing)
                Toggle("Require password to open", isOn: $requirePasswordToOpen)
                Toggle("Block copying text & images", isOn: $blockCopying)
                // TODO(phase-5): map toggles onto PDF permission bits when
                // encrypting; PDFKit write options cannot express them.
            }
            .toggleStyle(.switch)
            .font(.system(size: 12))

            PanelSection(title: "Sanitize") {
                PanelRow(title: "Remove hidden information", symbolName: "trash") {
                    // TODO(phase-5): strip metadata, comments, embedded
                    // thumbnails before sharing.
                }
                PanelRow(title: "Redact text & images", symbolName: "eye.slash") {
                    // TODO(phase-5): appState.engine.applyRedactions(in:)
                    // after marking regions with redaction annotations.
                }
            }

            PanelNote("Redaction is permanent. Sanitizing removes metadata, comments, and embedded thumbnails before sharing.")
        }
        .sheet(isPresented: $showsEncryptSheet) {
            EncryptSheet()
        }
    }
}

/// Password-encryption sheet — REAL: writes an encrypted copy through
/// PDFKitEngine.encrypt (PDFKit write options).
private struct EncryptSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var userPassword = ""
    @State private var ownerPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("Encrypt with Password")
                .font(.system(size: 13, weight: .semibold))

            SecureField("Open password (user)", text: $userPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Permissions password (owner)", text: $ownerPassword)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Encrypt & Save As…") { encryptAndSave() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.controlAccent)
                    .disabled(userPassword.isEmpty && ownerPassword.isEmpty
                              || appState.activeTab?.pdfDocument == nil)
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(width: 380)
    }

    private func encryptAndSave() {
        guard let document = appState.activeTab?.pdfDocument else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = suggestedName()
        savePanel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let destination = savePanel.url else { return }
                do {
                    try appState.engine.encrypt(document,
                                                to: destination,
                                                userPassword: userPassword.isEmpty ? nil : userPassword,
                                                ownerPassword: ownerPassword.isEmpty ? nil : ownerPassword)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func suggestedName() -> String {
        let base = appState.activeTab?.url?.deletingPathExtension().lastPathComponent ?? "Document"
        return "\(base)-protected.pdf"
    }
}
