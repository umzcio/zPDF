import PDFKit
import SwiftUI

/// Honest limitation notice for XFA forms. Dynamic (XFA-only) forms can't be
/// rendered; hybrid forms show their PDF pages read-only. When the engine
/// provides `remove_xfa`, a converted AcroForm copy can be saved.
struct XFANoticeBanner: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var canConvert = false
    @State private var converting = false

    private var isDynamic: Bool {
        guard let catalog = tab.pdfDocument?.documentRef?.catalog else { return false }
        var acroForm: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm else { return false }
        var fields: CGPDFArrayRef?
        return !CGPDFDictionaryGetArray(acroForm, "Fields", &fields) || fields.map(CGPDFArrayGetCount) == 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(isDynamic ? "Dynamic XFA form" : "XFA form (read-only)").font(.system(size: 12, weight: .semibold))
                Text(isDynamic
                     ? "This form is drawn by Adobe XFA, which zPDF can't render. You're seeing the PDF's fallback pages; filling and editing aren't available."
                     : "This form also contains XFA data. zPDF shows its PDF pages, but can't fill or edit it while XFA is present.")
                    .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if canConvert && !isDynamic {
                        Button(converting ? "Converting…" : "Save AcroForm Copy…") { convert() }
                            .disabled(converting)
                            .help("Save a copy without XFA that zPDF can fill and edit")
                    }
                    Button("Learn More") { appState.features.helpTopic = HelpTopicID("xfa") }
                        .buttonStyle(.link)
                    Button("Don't Show Again") { appState.preferences.showXFANotice = false }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.large).stroke(DesignTokens.Colors.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .task(id: tab.id) {
            if appState.canQuery(tab) { canConvert = await appState.availableOperations(in: tab).contains("remove_xfa") }
        }
    }

    private func convert() {
        guard let url = tab.url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (AcroForm).pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url, !SaveDestination.sameFile(destination, url) else { return }
        converting = true
        Task {
            defer { converting = false }
            do {
                _ = try await NativeDocumentBridge.transformFile(url, ops: NativeOps([["op": "remove_xfa"]]), destination: destination,
                                                                 overwrite: FileManager.default.fileExists(atPath: destination.path))
                appState.openDocument(at: destination)
            } catch { appState.reportPanelError(error, in: tab) }
        }
    }
}
