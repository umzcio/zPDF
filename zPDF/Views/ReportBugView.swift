import SwiftUI

/// Help ▸ Report a Bug… — files a GitHub issue through the zPDF feedback
/// relay, so testers don't need a GitHub account. Shows exactly what is sent.
struct ReportBugView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable private var draft = FeedbackDraft.shared

    @State private var steps = ""
    @State private var expected = ""
    @State private var email = ""
    @State private var includeDiagnostics = true
    @State private var includeScreenshot = false
    @State private var diagnostics = FeedbackDiagnostics.current()
    @State private var screenshot: Data?
    @State private var sending = false
    @State private var error: String?
    @State private var result: FeedbackResult?

    private var canSend: Bool {
        !sending && !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let result { sent(result) } else { form }
        }
        .frame(width: 560)
        .onAppear { diagnostics = FeedbackDiagnostics.current() }
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $draft.kind) {
                        Text("Bug").tag(FeedbackReport.Kind.bug)
                        Text("Suggestion").tag(FeedbackReport.Kind.suggestion)
                    }
                    .pickerStyle(.segmented)
                    TextField("Title", text: $draft.title, prompt: Text("Short summary"))
                    LabeledTextEditor(title: draft.kind == .bug ? "What happened?" : "What would you like?", text: $draft.description, height: 90)
                    if draft.kind == .bug {
                        LabeledTextEditor(title: "Steps to reproduce (optional)", text: $steps, height: 60)
                        TextField("Expected result (optional)", text: $expected)
                    }
                }
                Section {
                    TextField("Email (optional)", text: $email, prompt: Text("you@example.com"))
                        .textContentType(.emailAddress)
                    Text("Only the zPDF team can see your email — it's never added to the public report.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Include diagnostics", isOn: $includeDiagnostics)
                    if includeDiagnostics {
                        ForEach(diagnostics.rows, id: \.0) { row in
                            LabeledContent(row.0) {
                                Text(row.1).textSelection(.enabled).lineLimit(row.0 == "Last error" ? 4 : 1)
                                    .font(.callout).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    Toggle("Attach a screenshot of the zPDF window", isOn: $includeScreenshot)
                        .onChange(of: includeScreenshot) { _, on in screenshot = on ? FeedbackService.mainWindowScreenshot() : nil }
                    if includeScreenshot {
                        if let screenshot, let image = NSImage(data: screenshot) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Screenshot preview")
                        }
                        Label("The screenshot is visible to anyone who can see the report. Don't attach it if the document is confidential.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Reports never include your PDFs, file names or document text.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 560)
            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                        .lineLimit(2)
                }
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send Report") { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
                    .help("Send this report to the zPDF team")
            }
            .padding(16)
        }
    }

    private func sent(_ result: FeedbackResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text("Thanks — your report was sent").font(.title3.weight(.semibold))
            Text("It's report #\(result.issueNumber). The zPDF team will follow up\(email.isEmpty ? "." : " by email if they need more details.")")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                if let url = result.issueURL { Button("View Report") { openURL(url) } }
                Button("Done") { reset(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func send() async {
        sending = true; error = nil
        defer { sending = false }
        let report = FeedbackReport(kind: draft.kind, title: draft.title, description: draft.description,
                                    steps: steps, expected: expected, email: email,
                                    diagnostics: includeDiagnostics ? diagnostics : nil,
                                    screenshotPNG: includeScreenshot ? screenshot : nil)
        do { result = try await FeedbackService.send(report) }
        catch { self.error = error.localizedDescription }
    }

    private func reset() {
        draft.title = ""; draft.description = ""; steps = ""; expected = ""
        includeScreenshot = false; screenshot = nil; result = nil
    }
}

private struct LabeledTextEditor: View {
    let title: String
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: height)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel(title)
        }
    }
}
