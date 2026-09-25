import AppKit
import PDFKit
import SwiftUI

/// Redact: mark text, areas and pages (standard /Redact annotations that
/// save with the document), search for text and patterns, then apply —
/// which removes the underlying text, image pixels, artwork, comments and
/// form fields — and remove hidden information.
struct RedactPanel: View {
    @Environment(AppState.self) private var appState
    @State private var showingSanitize = false
    @State private var pageScope: ScopeChoice = .current
    @State private var pageRange = ""
    @State private var showingPageMarks = false

    private var controller: ContentEditingController { appState.contentEditing }
    private var editable: Bool { appState.activeTab?.allowsSaveEdits == true }

    var body: some View {
        let _ = appState.annotationRevision
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            markSection
            SearchRedactSection()
            AppearanceSection()
            MarksListSection()
            applySection
            PanelSection(title: "Hidden information") {
                PanelRow(title: "Remove Hidden Information…", symbolName: "eye.trianglebadge.exclamationmark") {
                    showingSanitize = true
                }
                .help("Find and remove metadata, attachments, scripts, hidden layers and hidden text")
                if let summary = controller.sanitizeSummary {
                    Text(summary).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
        }
        .disabled(!editable)
        .sheet(isPresented: $showingSanitize) {
            SanitizeSheet().environment(appState)
        }
        .onDisappear { if appState.activePanel != .redact { controller.deactivate() } }
    }

    private var markSection: some View {
        PanelSection(title: "Mark for redaction") {
            PanelToolGrid {
                PanelToolButton(title: "Text & Areas", symbolName: CanvasTool.redact.symbolName,
                                isActive: controller.isActive && controller.tool == .redact) {
                    controller.toggle(.redact)
                }
                .help("Mark text by dragging across it, or drag a rectangle (⇧⌘R)")
                PanelToolButton(title: "Whole Pages", symbolName: "doc.badge.ellipsis", isActive: showingPageMarks) {
                    showingPageMarks.toggle()
                }
                .help("Mark entire pages for redaction")
            }
            if controller.isActive && controller.tool == .redact {
                PanelNote(CanvasTool.redact.hint)
            }
            if showingPageMarks {
                VStack(alignment: .leading, spacing: 8) {
                    PageScopePicker(choice: $pageScope, range: $pageRange)
                    HStack {
                        Spacer()
                        Button("Mark Pages") {
                            controller.markPages(pageScope.scope(range: pageRange))
                            showingPageMarks = false
                        }
                        .controlSize(.small)
                        .help("Add a redaction mark covering each chosen page")
                    }
                }
                .padding(10)
                .background(DesignTokens.Colors.inset)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
            }
        }
    }

    private var applySection: some View {
        let count = controller.marks().count
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                confirmApply(count: count)
            } label: {
                Label(count == 0 ? "Apply Redactions" : "Apply \(count) Redaction\(count == 1 ? "" : "s")…", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: RedactionMarkAnnotation.markColor))
            .controlSize(.large)
            .disabled(count == 0 || controller.isBusy)
            .help("Permanently remove everything under the marks")
            if controller.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
            if let report = controller.lastReport {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.summary, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.text)
                    if report.checked > 0 {
                        if report.stillFound.isEmpty {
                            Label("Verified: the redacted text can no longer be found, selected or copied.", systemImage: "checkmark.seal")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.Colors.readyGreen)
                        } else {
                            Label("Still found in the page text: \(report.stillFound.prefix(5).joined(separator: ", ")). Check these areas.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("Save the document to make the redactions permanent.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Colors.inset)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
            }
        }
    }

    private func confirmApply(count: Int) {
        let alert = NSAlert()
        alert.messageText = "Apply \(count) redaction mark\(count == 1 ? "" : "s")?"
        alert.informativeText = "Text, images, drawings, comments and form fields under the marks will be removed from the document. You can undo this until you close the document; saving makes it permanent."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply Redactions")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also remove hidden information (metadata, scripts, hidden text)"
        alert.suppressionButton?.state = .off
        let run: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let sanitize: [String: Any]? = alert.suppressionButton?.state == .on ? [:] : nil
            controller.applyRedactions(sanitize: sanitize)
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }
}

// MARK: - Search & Redact

private struct SearchRedactSection: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var pattern: RedactionPattern?
    @State private var regex = false
    @State private var matchCase = false
    @State private var wholeWords = false
    @State private var results: [RedactionMatch]?

    private var controller: ContentEditingController { appState.contentEditing }

    var body: some View {
        PanelSection(title: "Search & redact") {
            HStack(spacing: 6) {
                if let pattern {
                    HStack(spacing: 4) {
                        Image(systemName: pattern.symbolName).accessibilityHidden(true)
                        Text(pattern.title).lineLimit(1)
                        Button { self.pattern = nil; results = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .help("Search for text instead")
                            .accessibilityLabel("Clear pattern")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DesignTokens.Colors.accentTint)
                    .clipShape(Capsule())
                    Spacer(minLength: 0)
                } else {
                    TextField(regex ? "Regular expression" : "Text to find", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search() }
                        .accessibilityLabel("Text to find and redact")
                }
                Menu {
                    ForEach(RedactionPattern.allCases) { item in
                        Button { pattern = item; search() } label: { Label(item.title, systemImage: item.symbolName) }
                    }
                } label: {
                    Image(systemName: "text.magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Find a common pattern: Social Security, phone, email, credit card numbers or dates")
                .accessibilityLabel("Patterns")
            }
            if pattern == nil {
                HStack(spacing: 10) {
                    Toggle("Match case", isOn: $matchCase)
                    Toggle("Whole words", isOn: $wholeWords).disabled(regex)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                Toggle("Regular expression", isOn: $regex)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            HStack {
                if let results {
                    Text(results.isEmpty ? "No matches" : "\(results.count) match\(results.count == 1 ? "" : "es")")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
                Button("Find") { search() }
                    .controlSize(.small)
                    .disabled(pattern == nil && query.isEmpty)
                    .help("Find every match in the document")
            }
            if let results, !results.isEmpty {
                resultsList(results)
            }
        }
    }

    private func resultsList(_ items: [RedactionMatch]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Select All") { setAll(true) }.buttonStyle(.link).font(.system(size: 11))
                Button("None") { setAll(false) }.buttonStyle(.link).font(.system(size: 11))
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { match in
                        let binding = Binding(get: { results?.first { $0.id == match.id }?.isSelected ?? false },
                                              set: { value in
                                                  if let i = results?.firstIndex(where: { $0.id == match.id }) { results?[i].isSelected = value }
                                              })
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Toggle(isOn: binding) { EmptyView() }
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .accessibilityLabel("Include match on page \(match.page + 1)")
                            Button {
                                appState.activeTab?.goToPage(match.page + 1)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(match.text).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text("Page \(match.page + 1) · \(match.context)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DesignTokens.Colors.mutedText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show page \(match.page + 1)")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding(6)
            .background(DesignTokens.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).stroke(DesignTokens.Colors.hairline, lineWidth: 1))
            let selected = items.filter(\.isSelected).count
            HStack {
                Spacer()
                Button("Mark \(selected) for Redaction") {
                    let added = controller.mark(items)
                    results = nil
                    controller.notice = added > 0 ? "Marked \(added) item\(added == 1 ? "" : "s"). Review the marks, then apply." : nil
                }
                .controlSize(.small)
                .disabled(selected == 0)
                .help("Add redaction marks for the selected matches")
            }
        }
    }

    private func setAll(_ value: Bool) {
        guard var list = results else { return }
        for i in list.indices { list[i].isSelected = value }
        results = list
    }

    private func search() {
        guard pattern != nil || !query.isEmpty else { return }
        results = controller.findMatches(query: query, pattern: pattern, regex: regex, matchCase: matchCase, wholeWords: wholeWords)
    }
}

// MARK: - Appearance

private struct AppearanceSection: View {
    @Environment(AppState.self) private var appState
    @State private var useText = false
    private var controller: ContentEditingController { appState.contentEditing }

    var body: some View {
        @Bindable var controller = appState.contentEditing
        PanelSection(title: "Appearance") {
            HStack(spacing: 8) {
                Text("Fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .frame(width: 44, alignment: .leading)
                ColorPicker("Fill color", selection: Binding(get: { Color(nsColor: controller.redactionAppearance.fill) },
                                                             set: { controller.redactionAppearance.fill = NSColor($0) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .help("Color of the box drawn over redacted areas")
                Spacer()
                ForEach([NSColor.black, .white, NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)], id: \.self) { color in
                    Button { controller.redactionAppearance.fill = color } label: {
                        Circle().fill(Color(nsColor: color))
                            .overlay(Circle().stroke(DesignTokens.Colors.hairline, lineWidth: 1))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(color == .black ? "Black" : color == .white ? "White" : "Red")
                    .accessibilityLabel(color == .black ? "Black fill" : color == .white ? "White fill" : "Red fill")
                }
            }
            Toggle("Overlay text", isOn: Binding(get: { !controller.redactionAppearance.overlayText.isEmpty || useText },
                                                 set: { on in
                                                     useText = on
                                                     if !on { controller.redactionAppearance.overlayText = "" }
                                                     else if controller.redactionAppearance.overlayText.isEmpty { controller.redactionAppearance.overlayText = "REDACTED" }
                                                 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            if !controller.redactionAppearance.overlayText.isEmpty || useText {
                HStack(spacing: 6) {
                    TextField("Overlay text", text: $controller.redactionAppearance.overlayText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Overlay text")
                    Menu {
                        ForEach(RedactionCodeSet.allCases) { set in
                            Menu(set.title) {
                                ForEach(set.codes, id: \.code) { item in
                                    Button("\(item.code)  \(item.meaning)") { controller.redactionAppearance.overlayText = item.code }
                                }
                            }
                        }
                    } label: { Text("Code") }
                    .fixedSize()
                    .help("Insert a redaction code (FOIA or Privacy Act exemption)")
                }
                Toggle("Repeat text to fill the area", isOn: $controller.redactionAppearance.repeatText)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            let marks = controller.marks().map(\.mark)
            if let selected = controller.selectedMark {
                Button("Apply to Selected Mark") { controller.applyAppearanceToMarks([selected]) }
                    .controlSize(.small)
                    .help("Use these settings for the selected mark")
            } else if !marks.isEmpty {
                Button("Apply to All Marks") { controller.applyAppearanceToMarks(marks) }
                    .controlSize(.small)
                    .help("Use these settings for every mark in the document")
            }
        }
    }
}

// MARK: - Marks list

private struct MarksListSection: View {
    @Environment(AppState.self) private var appState
    private var controller: ContentEditingController { appState.contentEditing }

    var body: some View {
        let marks = controller.marks()
        PanelSection(title: "Marks (\(marks.count))") {
            if marks.isEmpty {
                Text("Nothing is marked yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(marks.prefix(200).enumerated()), id: \.offset) { _, entry in
                        MarkRow(page: entry.page, mark: entry.mark,
                                selected: controller.selectedMark === entry.mark,
                                onSelect: {
                                    appState.activeTab?.goToPage(entry.page + 1)
                                    if controller.tool != .redact || !controller.isActive { controller.activate(.redact) }
                                    controller.selectedMark = entry.mark
                                    controller.overlay.needsDisplay = true
                                },
                                onRemove: { controller.removeMark(entry.mark) })
                    }
                }
                HStack {
                    Spacer()
                    Button("Remove All Marks", role: .destructive) { controller.removeAllMarks() }
                        .controlSize(.small)
                        .help("Delete every redaction mark without applying it")
                }
            }
        }
    }
}

private struct MarkRow: View {
    let page: Int
    let mark: RedactionMarkAnnotation
    let selected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: RedactionMarkAnnotation.markColor), lineWidth: 1.5)
                        .background(Color(nsColor: mark.interiorColor ?? .black).opacity(0.25))
                        .frame(width: 14, height: 10)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snippet).font(.system(size: 11.5)).lineLimit(1)
                        Text("Page \(page + 1)" + ((mark.overlayText ?? "").isEmpty ? "" : " · “\(mark.overlayText ?? "")”"))
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this mark")
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.mutedText)
            .help("Remove this mark")
            .accessibilityLabel("Remove mark on page \(page + 1)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? DesignTokens.Colors.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
    }

    private var snippet: String {
        guard let page = mark.page else { return "Area" }
        let text = mark.markRects.compactMap { page.selection(for: $0)?.string }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let crop = page.bounds(for: .cropBox)
        if mark.markRects.contains(where: { $0.contains(crop.insetBy(dx: 1, dy: 1)) }) { return "Whole page" }
        return text.isEmpty ? "Area" : text
    }
}

// MARK: - Sanitize

struct SanitizeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var counts: [String: Int]?
    @State private var options: [String: Bool] = Dictionary(uniqueKeysWithValues: SanitizeSheet.items.map { ($0.key, $0.default) })

    static let items: [(key: String, title: String, detail: String, default: Bool)] = [
        ("metadata", "Metadata", "Title, author, dates and XMP document information", true),
        ("embedded_files", "Attached files", "Files embedded in the PDF and file attachments", true),
        ("javascript", "Scripts and actions", "JavaScript, launch and form-submission actions", true),
        ("hidden_layers", "Hidden layers", "Content in layers that are turned off", true),
        ("hidden_text", "Hidden text", "Invisible text and text outside the page, including OCR text layers", true),
        ("private_data", "Private application data", "Data other apps stored in the file", true),
        ("bookmarks", "Bookmarks", "The document outline", false),
        ("comments", "Comments and markup", "Notes, highlights, drawings and redaction marks", false),
        ("form_fields", "Form fields", "Fields are flattened into the page as they appear", false),
        ("links", "Links", "Web and page links", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove Hidden Information").font(.headline)
                Text("Choose what to remove. Items found in this document are counted.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
            }
            .padding(DesignTokens.Spacing.large)
            Divider()
            Form {
                ForEach(Self.items, id: \.key) { item in
                    Toggle(isOn: Binding(get: { options[item.key] ?? false }, set: { options[item.key] = $0 })) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                            Spacer()
                            if let counts {
                                let n = counts[item.key] ?? 0
                                Text(n == 0 ? "None found" : "\(n) found")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(n == 0 ? DesignTokens.Colors.mutedText : DesignTokens.Colors.text)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 440)
            Divider()
            HStack {
                Button("Select Recommended") {
                    options = Dictionary(uniqueKeysWithValues: Self.items.map { ($0.key, $0.default) })
                }
                .help("Keep bookmarks, comments, fields and links; remove everything else")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove") {
                    appState.contentEditing.sanitize(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!options.values.contains(true))
            }
            .padding(DesignTokens.Spacing.large)
        }
        .frame(width: 480)
        .task { counts = await appState.contentEditing.scanHiddenInformation() }
    }
}
