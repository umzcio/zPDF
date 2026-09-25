import SwiftUI
import UniformTypeIdentifiers

/// Settings › Forms: the auto-fill profile (stored privately on this Mac).
struct FormsProfileSettingsRows: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var service = appState.signatureService
        Group {
            Text("Auto-fill profile").font(.headline).padding(.top, 6)
            TextField("Full name", text: $service.profile.fullName)
            HStack {
                TextField("First name", text: $service.profile.firstName)
                TextField("Last name", text: $service.profile.lastName)
            }
            TextField("Email", text: $service.profile.email)
            TextField("Phone", text: $service.profile.phone)
            TextField("Street address", text: $service.profile.street)
            TextField("Address line 2", text: $service.profile.street2)
            HStack {
                TextField("City", text: $service.profile.city)
                TextField("State", text: $service.profile.state).frame(maxWidth: 110)
                TextField("ZIP", text: $service.profile.postalCode).frame(maxWidth: 90)
            }
            TextField("Country", text: $service.profile.country)
            TextField("Company", text: $service.profile.company)
            TextField("Job title", text: $service.profile.jobTitle)
            TextField("Date of birth", text: $service.profile.dateOfBirth)
            Text("Fill & Sign suggests these values for matching empty fields. They’re stored only in zPDF’s private storage on this Mac.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }
}

/// Settings › Signatures: timestamp server, validation, appearance defaults,
/// digital IDs and trusted certificates.
struct SignatureSettingsRows: View {
    @Environment(AppState.self) private var appState
    @State private var showsCreate = false
    @State private var showsImport = false
    @State private var error: String?

    var body: some View {
        @Bindable var service = appState.signatureService
        Group {
            Toggle("Timestamp signatures", isOn: $service.preferences.timestampEnabled)
                .help("Ask a trusted timestamp server (RFC 3161) to certify when you signed. Requires a network connection.")
            if service.preferences.timestampEnabled {
                TextField("Timestamp server URL", text: $service.preferences.timestampURL, prompt: Text("https://timestamp.example.com"))
                    .accessibilityLabel("Timestamp server URL")
                if !service.preferences.timestampURL.isEmpty, !(service.preferences.timestampURL.hasPrefix("http://") || service.preferences.timestampURL.hasPrefix("https://")) {
                    PanelErrorText(message: "Use an http:// or https:// address.")
                }
            }
            Toggle("Embed validation information when signing (LTV)", isOn: $service.preferences.embedValidation)
            Toggle("Download revocation data (OCSP and CRL) for validation information", isOn: $service.preferences.fetchRevocation)
                .help("Contacts the certificate authority named in the signer’s certificate")
            Picker("Signature format", selection: $service.preferences.format) {
                Text("PAdES (ETSI.CAdES.detached)").tag("pades")
                Text("CMS (adbe.pkcs7.detached)").tag("pkcs7")
            }
            TextField("Default reason", text: $service.preferences.defaultReason)
            TextField("Default location", text: $service.preferences.defaultLocation)
            Toggle("Show date in signature appearance", isOn: $service.preferences.showDateInAppearance)
            Toggle("Show labels in signature appearance", isOn: $service.preferences.showLabels)
            Text("Network access is used only for the timestamp server and revocation downloads you enable here.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)

            Text("Digital IDs").font(.headline).padding(.top, 8)
            if service.digitalIDs.isEmpty {
                Text("No digital IDs.").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(service.digitalIDs) { DigitalIDRow(identity: $0) }
            HStack {
                Button("Create Digital ID…") { showsCreate = true }
                Button("Import Digital ID…") { showsImport = true }
            }

            Text("Trusted certificates").font(.headline).padding(.top, 8)
            Text("Signatures by these certificates, or by certificates they issued, are shown as trusted. Certificates trusted by macOS are trusted too.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            ForEach(service.trust.certificates) { certificate in
                HStack {
                    Image(systemName: "checkmark.shield").foregroundStyle(DesignTokens.Colors.accent).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(certificate.name)
                        Text(certificate.issuer).font(.caption).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                    }
                    Spacer()
                    PanelIconButton(symbolName: "trash", label: "Stop trusting \(certificate.name)", role: .destructive) {
                        service.trust.remove(certificate)
                    }
                }
            }
            Button("Add Certificate…") { addCertificate() }
                .help("Trust a certificate file (.cer, .crt, .der or .pem) someone shared with you")
            if let error { PanelErrorText(message: error) }
        }
        .sheet(isPresented: $showsCreate) { DigitalIDCreateSheet().environment(appState) }
        .sheet(isPresented: $showsImport) { DigitalIDImportSheet().environment(appState) }
    }

    private func addCertificate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["cer", "crt", "der", "pem"].compactMap { UTType(filenameExtension: $0) } + [.x509Certificate]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { _ = try await appState.signatureService.trust.add(fileAt: url); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}
