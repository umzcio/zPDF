import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "Appearance", documents = "Documents", display = "Page Display", commenting = "Commenting", forms = "Forms", accessibility = "Accessibility"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .documents: "doc.on.doc"
        case .display: "rectangle.on.rectangle"
        case .commenting: "text.bubble"
        case .forms: "list.bullet.rectangle"
        case .accessibility: "accessibility"
        }
    }
    var keywords: String {
        switch self {
        case .appearance: "theme system light dark color scheme accent blue red purple green orange pink"
        case .documents: "general history recent files clear restore reopen startup tabs remember reading position page zoom"
        case .display: "default zoom actual size fit page width single continuous facing gaps sidebar"
        case .commenting: "author name highlight underline sticky note colors keep tool selected automatically comments"
        case .forms: "field highlighting fill editable readonly read-only XFA password"
        case .accessibility: "keyboard voiceover contrast transparency motion system"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appAccessibility) private var accessibility
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsCategory? = .appearance
    @State private var query = ""
    @State private var showingReset = false
    @State private var showingClear = false

    private var matchingCategories: [SettingsCategory] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [selection ?? .appearance] }
        return SettingsCategory.allCases.filter { category in
            terms.allSatisfy { (category.rawValue + " " + category.keywords).localizedCaseInsensitiveContains(String($0)) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search settings", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search settings")
                    .help("Find settings by name, such as appearance, zoom or comments.")
                    .padding(12)
                List(SettingsCategory.allCases, selection: $selection) { category in
                    Label(category.rawValue, systemImage: category.symbol).tag(category)
                }
                .onChange(of: selection) { _, _ in query = "" }
                .listStyle(.sidebar)
                .scrollContentBackground(accessibility.reduceTransparency ? .hidden : .automatic)
                .background {
                    if accessibility.reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                }
                .accessibilityLabel("Settings categories")
                Divider()
                Button("Restore Defaults…") { showingReset = true }
                    .tint(DesignTokens.Colors.accent)
                    .help("Reset all zPDF preferences, including the recent-history limit of 20. PDF files are not changed.")
                    .padding(12)
            }
            .frame(width: 190)
            Divider()
            if matchingCategories.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(matchingCategories) { category in
                        Section(category.rawValue) { rows(for: category) }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 740, idealWidth: 800, minHeight: 540, idealHeight: 590)
        .onExitCommand {
            // An open confirmation owns Escape until it has been dismissed.
            guard !showingReset && !showingClear else { return }
            dismiss()
        }
        .alert("Restore default settings?", isPresented: $showingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) { appState.preferences.reset() }
        } message: { Text("This resets all zPDF preferences and limits recent-file history to the 20 most recent entries. Your PDF files and open documents are kept.") }
        .alert("Clear recent-file history?", isPresented: $showingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { appState.recentFiles.clear() }
        } message: { Text("Recent and starred entries will be removed from Home. PDF files on disk are not deleted.") }
    }

    @ViewBuilder
    private func rows(for category: SettingsCategory) -> some View {
        @Bindable var preferences = appState.preferences
        switch category {
        case .appearance:
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
                .accessibilityLabel("Appearance")
            Picker("Accent color", selection: $preferences.accent) {
                ForEach(AppAccent.allCases) { Text($0.title).tag($0) }
            }.accessibilityLabel("Accent color")
            Text("Changes apply immediately to zPDF windows and controls. PDF page colors stay as authored.")
                .font(.callout).foregroundStyle(.secondary)
        case .documents:
            Stepper("Recent files: \(preferences.recentFileLimit)", value: $preferences.recentFileLimit, in: 0...100, step: 1)
                .accessibilityLabel("Recent-file history limit")
                .accessibilityValue("\(preferences.recentFileLimit) files")
                .help("Maximum files in recent history. Set to zero to stop keeping recent files.")
            Button("Clear Recent History…") { showingClear = true }
                .disabled(appState.recentFiles.files.isEmpty)
            Toggle("Remember page and zoom for each document", isOn: $preferences.rememberReadingPosition)
                .accessibilityLabel("Remember page and zoom for each document")
            Toggle("Reopen documents from the last session", isOn: $preferences.restoreOpenDocuments)
                .accessibilityLabel("Reopen documents from the last session")
            Text("Reopening restores saved files, not unsaved edits. Passwords are never remembered.")
                .font(.callout).foregroundStyle(.secondary)
        case .display:
            Picker("Default zoom", selection: $preferences.defaultZoom) {
                ForEach(DefaultPDFZoom.allCases) { Text($0.title).tag($0) }
            }.accessibilityLabel("Default zoom")
            Picker("Default page layout", selection: $preferences.defaultViewMode) {
                ForEach(PDFViewMode.allCases) { Text($0.title).tag($0) }
            }.accessibilityLabel("Default page layout")
            Toggle("Show gaps between pages", isOn: $preferences.showPageGaps)
                .accessibilityLabel("Show gaps between pages")
            Toggle("Remember tools drawer visibility", isOn: $preferences.rememberSidebar)
                .accessibilityLabel("Remember tools drawer visibility")
            Text("Default zoom and layout apply when opening documents. Remembered reading positions take precedence over default zoom.")
                .font(.callout).foregroundStyle(.secondary)
        case .commenting:
            TextField("Author name", text: $preferences.commentAuthor)
                .accessibilityLabel("Comment author name")
                .help("Written into new comments. Existing comment authors are unchanged.")
            annotationColorPicker("Highlight color", selection: $preferences.highlightColor)
            annotationColorPicker("Underline color", selection: $preferences.underlineColor)
            annotationColorPicker("Sticky-note color", selection: $preferences.noteColor)
            Toggle("Keep annotation tool selected after use", isOn: $preferences.keepAnnotationToolSelected)
                .accessibilityLabel("Keep annotation tool selected after use")
            Toggle("Show comments when opening a PDF with comments", isOn: $preferences.openCommentsAutomatically)
                .accessibilityLabel("Show comments when opening a PDF with comments")
            Text("Colors and author name apply to new annotations.")
                .font(.callout).foregroundStyle(.secondary)
        case .forms:
            Toggle("Highlight editable form fields", isOn: $preferences.highlightFormFields)
                .accessibilityLabel("Highlight editable form fields")
            Text("Highlights help locate form fields and are not saved into the PDF. Encrypted files and XFA forms remain read-only.")
                .font(.callout).foregroundStyle(.secondary)
        case .accessibility:
            accessibilityToggle("Increase contrast", detail: "Make interface text and controls easier to distinguish.",
                                value: $preferences.increaseContrast,
                                systemEnabled: SystemAccessibility.shared.options.increaseContrast)
            accessibilityToggle("Reduce motion", detail: "Turn off animated feedback and search-selection movement.",
                                value: $preferences.reduceMotion,
                                systemEnabled: SystemAccessibility.shared.options.reduceMotion)
            accessibilityToggle("Reduce transparency", detail: "Use solid backgrounds in the settings sidebar and document overlays.",
                                value: $preferences.reduceTransparency,
                                systemEnabled: SystemAccessibility.shared.options.reduceTransparency)
            Text("Changes apply immediately to zPDF. Accommodations enabled in macOS stay on. PDF page colors are unchanged.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            LabeledContent("VoiceOver", value: SystemAccessibility.shared.voiceOverEnabled ? "On" : "Off")
            Button("Open VoiceOver Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?VoiceOver")!)
            }
            .tint(DesignTokens.Colors.accent)
            .help("Open macOS settings to enable or configure VoiceOver. You can also press Command-F5.")
            Text("VoiceOver is the macOS screen reader. Turn it on or off with ⌘F5.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private func accessibilityToggle(_ title: String, detail: String,
                                     value: Binding<Bool>, systemEnabled: Bool) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue || systemEnabled },
                             set: { value.wrappedValue = $0 })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(systemEnabled ? "Enabled in macOS" : detail)
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
        .disabled(systemEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(systemEnabled ? "Enabled in macOS accessibility settings" : detail)
    }

    private func annotationColorPicker(_ title: String, selection: Binding<AnnotationPreferenceColor>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AnnotationPreferenceColor.allCases) { color in Text(color.title).tag(color) }
        }.accessibilityLabel(title)
    }
}
