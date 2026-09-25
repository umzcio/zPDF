import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The built-in Settings categories. Every control changes real behavior.
@MainActor
enum BuiltInSettings {
    static let sections: [SettingsSection] = [
        .init(id: .general, title: "General", symbol: "gearshape",
              keywords: "default pdf app viewer finder open with services welcome tour whats new updates", order: 0) { AnyView(GeneralSettings(appState: $0)) },
        .init(id: .appearance, title: "Appearance", symbol: "paintpalette",
              keywords: "theme system light dark color scheme accent blue red purple green orange pink", order: 10) { AnyView(AppearanceSettings(appState: $0)) },
        .init(id: .documents, title: "Documents", symbol: "doc.on.doc",
              keywords: "history recent files clear restore reopen startup tabs remember reading position page zoom initial view xfa", order: 20) { AnyView(DocumentsSettings(appState: $0)) },
        .init(id: .display, title: "Page Display", symbol: "rectangle.on.rectangle",
              keywords: "default zoom actual size fit page width single continuous facing gaps sidebar smoothing images shadows page labels zoom steps", order: 30) { AnyView(DisplaySettings(appState: $0)) },
        .init(id: .fullScreen, title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right",
              keywords: "presentation slideshow advance timer loop click transition background navigation", order: 40) { AnyView(FullScreenSettings(appState: $0)) },
        .init(id: .units, title: "Units & Guides", symbol: "ruler",
              keywords: "units inches millimeters points picas rulers grid spacing subdivisions guides color snap", order: 50) { AnyView(UnitsSettings(appState: $0)) },
        .init(id: .reading, title: "Reading", symbol: "speaker.wave.2",
              keywords: "read out loud voice speech rate speed highlight words auto scroll speed", order: 60) { AnyView(ReadingSettings(appState: $0)) },
        .init(id: .accessibility, title: "Accessibility", symbol: "accessibility",
              keywords: "keyboard voiceover contrast transparency motion system replace document colors night high contrast page background text", order: 70) { AnyView(AccessibilitySettings(appState: $0)) },
        .init(id: .commenting, title: "Commenting", symbol: "text.bubble",
              keywords: "author name highlight underline sticky note colors keep tool selected automatically comments", order: 80) { AnyView(CommentingSettings(appState: $0)) },
        .init(id: .forms, title: "Forms", symbol: "list.bullet.rectangle",
              keywords: "field highlighting fill editable readonly read-only XFA password", order: 90) { AnyView(FormsSettings(appState: $0)) },
        .init(id: .identity, title: "Identity", symbol: "person.crop.circle",
              keywords: "name email organization title author identity", order: 100) { AnyView(IdentitySettings(appState: $0)) },
        .init(id: .measuring, title: "Measuring", symbol: "ruler.fill",
              keywords: "measure scale ratio units precision snap endpoints midpoints intersections annotation color", order: 110) { AnyView(MeasuringSettings(appState: $0)) },
        .init(id: .search, title: "Search", symbol: "magnifyingglass",
              keywords: "find bookmarks comments attachments diacritics accents results context index", order: 120) { AnyView(SearchSettings(appState: $0)) },
        .init(id: .spelling, title: "Spelling", symbol: "textformat.abc",
              keywords: "spell check spelling correct autocorrect language dictionary", order: 130) { AnyView(SpellingSettings(appState: $0)) },
        .init(id: .signatures, title: "Signatures", symbol: "signature",
              keywords: "saved signatures delete manage", order: 140) { AnyView(SignatureSettings(appState: $0)) },
        .init(id: .security, title: "Security", symbol: "lock.shield",
              keywords: "links web urls javascript scripts trust", order: 150) { AnyView(SecuritySettings(appState: $0)) },
        .init(id: .print, title: "Print", symbol: "printer",
              keywords: "print presets booklet poster multiple save as pdf", order: 160) { _ in AnyView(PrintSettings()) },
        .init(id: .tools, title: "Tools", symbol: "square.grid.2x2",
              keywords: "quick tools favorites pinned custom commands toolbar", order: 170) { AnyView(ToolsSettings(appState: $0)) },
        .init(id: .keyboard, title: "Keyboard Shortcuts", symbol: "keyboard",
              keywords: "keyboard shortcuts keys rebind hotkeys commands conflicts", order: 180) { _ in AnyView(KeyboardShortcutSettings()) }
    ]
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(DesignTokens.Colors.mutedText).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let appState: AppState
    @State private var defaultStatus: String?
    @State private var working = false

    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Default PDF App") {
            LabeledContent("Opens PDFs in Finder") {
                Text(DefaultApp.currentHandlerName ?? "Unknown")
            }
            HStack {
                Button(DefaultApp.isDefault ? "zPDF Is the Default PDF App" : "Make zPDF the Default PDF App") {
                    working = true
                    Task {
                        defaultStatus = await DefaultApp.makeDefault()
                        working = false
                    }
                }
                .disabled(DefaultApp.isDefault || working)
                if working { ProgressView().controlSize(.small) }
            }
            if let defaultStatus { Footnote(defaultStatus) }
            Footnote("Finder's Services menu also offers “Open in zPDF” for selected PDFs.")
        }
        Section("Welcome") {
            Toggle("Show What's New after updates", isOn: $preferences.showWhatsNewAfterUpdates)
            HStack {
                Button("Show Welcome Tour") { appState.features.showingOnboarding = true }
                Button("Show What's New") { appState.features.showingWhatsNew = true }
            }
        }
    }
}

private struct AppearanceSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Appearance") {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
                .accessibilityLabel("Appearance")
            Picker("Accent color", selection: $preferences.accent) {
                ForEach(AppAccent.allCases) { Text($0.title).tag($0) }
            }.accessibilityLabel("Accent color")
            Footnote("Changes apply immediately to zPDF windows and controls. PDF page colors stay as authored; see Accessibility ▸ Page colors.")
        }
    }
}

private struct DocumentsSettings: View {
    let appState: AppState
    @State private var showingClear = false

    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Documents") {
            Stepper("Recent files: \(preferences.recentFileLimit)", value: $preferences.recentFileLimit, in: 0...100, step: 1)
                .accessibilityLabel("Recent-file history limit")
                .accessibilityValue("\(preferences.recentFileLimit) files")
                .help("Maximum files in recent history. Set to zero to stop keeping recent files.")
            Button("Clear Recent History…") { showingClear = true }
                .disabled(appState.recentFiles.files.isEmpty)
            Toggle("Remember page and zoom for each document", isOn: $preferences.rememberReadingPosition)
            Toggle("Reopen documents from the last session", isOn: $preferences.restoreOpenDocuments)
            Toggle("Use the document's initial view when opening", isOn: $preferences.useDocumentInitialView)
                .help("Apply the page layout, navigation panel and opening page stored in the PDF (Document Properties ▸ Initial View)")
            Toggle("Explain limitations when opening XFA forms", isOn: $preferences.showXFANotice)
            Footnote("Reopening restores saved files, not unsaved edits. Passwords are never remembered. A remembered reading position wins over the document's opening page.")
        }
        .alert("Clear recent-file history?", isPresented: $showingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { appState.recentFiles.clear() }
        } message: { Text("Recent and starred entries will be removed from Home. PDF files on disk are not deleted.") }
    }
}

private struct DisplaySettings: View {
    let appState: AppState
    @State private var stepsText = ""

    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Page Display") {
            Picker("Default zoom", selection: $preferences.defaultZoom) {
                ForEach(DefaultPDFZoom.allCases) { Text($0.title).tag($0) }
            }
            Picker("Default page layout", selection: $preferences.defaultViewMode) {
                ForEach(PDFViewMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show gaps between pages", isOn: $preferences.showPageGaps)
            Toggle("Show page shadows", isOn: $preferences.pageShadows)
            Toggle("Smooth images", isOn: $preferences.smoothImages)
                .help("High-quality image interpolation. Turn off to see image pixels exactly.")
            Toggle("Show page labels (for example iv or A-3)", isOn: $preferences.showPageLabels)
            Toggle("Remember tools drawer visibility", isOn: $preferences.rememberSidebar)
        }
        Section("Zoom Steps") {
            TextField("Zoom In/Out steps (%)", text: $stepsText, prompt: Text("50, 75, 100, 125, 150, 200"))
                .onSubmit(applySteps)
                .help("Comma-separated percentages used by Zoom In (⌘=) and Zoom Out (⌘−), between 50% and 200%.")
            HStack {
                Button("Apply") { applySteps() }.disabled(stepsText.isEmpty)
                Button("Restore Default Steps") {
                    preferences.zoomSteps = AppPreferences.defaultZoomSteps
                    stepsText = Self.text(preferences.zoomSteps)
                }
            }
            Footnote("Default zoom and layout apply when opening documents. Remembered reading positions take precedence over default zoom.")
        }
        .onAppear { stepsText = Self.text(preferences.zoomSteps) }
    }

    static func text(_ steps: [Double]) -> String { steps.map { String(Int(($0 * 100).rounded())) }.joined(separator: ", ") }

    private func applySteps() {
        let values = stepsText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        appState.preferences.zoomSteps = values.map { $0 / 100 }
        stepsText = Self.text(appState.preferences.zoomSteps)
    }
}

private struct FullScreenSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Full Screen Mode (⌘L)") {
            Toggle("Advance every", isOn: $preferences.fullScreenAdvance)
            Stepper("\(Int(preferences.fullScreenAdvanceSeconds)) seconds", value: $preferences.fullScreenAdvanceSeconds, in: 1...120)
                .disabled(!preferences.fullScreenAdvance)
            Toggle("Loop after last page", isOn: $preferences.fullScreenLoop)
            Toggle("Left click to go forward one page, right click to go back", isOn: $preferences.fullScreenClickAdvances)
            Toggle("Show navigation bar when the pointer moves", isOn: $preferences.fullScreenShowNavigation)
            Picker("Background", selection: $preferences.fullScreenBackground) {
                ForEach(FullScreenBackground.allCases) { Text($0.title).tag($0) }
            }
            Picker("Default transition", selection: $preferences.fullScreenTransition) {
                ForEach(PageTransitionStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Use the document's own transitions and timings", isOn: $preferences.fullScreenUseDocumentTransitions)
            Footnote("Escape always exits. Transitions are skipped when Reduce Motion is on.")
        }
    }
}

private struct UnitsSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Units") {
            Picker("Page and ruler units", selection: $preferences.pageUnits) {
                ForEach(PageUnit.allCases) { Text($0.title).tag($0) }
            }
        }
        Section("Rulers, Grid and Guides") {
            Toggle("Show rulers (⌘R)", isOn: $preferences.showRulers)
            Toggle("Show grid (⌘U)", isOn: $preferences.showGrid)
            Toggle("Snap to grid (⇧⌘U)", isOn: $preferences.snapToGrid)
            Toggle("Show guides (⌘;)", isOn: $preferences.showGuides)
            HStack {
                Text("Grid lines every")
                TextField("Spacing", value: $preferences.gridSpacing, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Grid spacing")
                Text(preferences.pageUnits.symbol)
            }
            Stepper("Subdivisions: \(preferences.gridSubdivisions)", value: $preferences.gridSubdivisions, in: 1...10)
            Picker("Grid color", selection: $preferences.gridColor) { ForEach(OverlayColor.allCases) { Text($0.title).tag($0) } }
            Picker("Guide color", selection: $preferences.guideColor) { ForEach(OverlayColor.allCases) { Text($0.title).tag($0) } }
            Footnote("Drag from a ruler onto the page to add a guide; drag it back to the ruler to remove it. Grids and guides are never printed or saved.")
        }
    }
}

private struct ReadingSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Read Out Loud") {
            Picker("Voice", selection: $preferences.readAloudVoice) {
                Text("Match the document's language").tag("")
                ForEach(ReadAloudController.voices, id: \.identifier) { voice in
                    Text("\(voice.name) (\(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language))").tag(voice.identifier)
                }
            }
            HStack {
                Text("Speed")
                Slider(value: $preferences.readAloudRate, in: 0...1) { Text("Speed") } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: { Image(systemName: "hare") }
                    .accessibilityLabel("Reading speed")
            }
            Toggle("Highlight each word while reading", isOn: $preferences.readAloudHighlight)
            Button("Preview Voice") {
                let utterance = AVSpeechUtterance(string: "This is how zPDF reads your documents.")
                if let voice = AVSpeechSynthesisVoice(identifier: preferences.readAloudVoice) { utterance.voice = voice }
                utterance.rate = Float(AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * Float(preferences.readAloudRate))
                VoicePreview.synthesizer.speak(utterance)
            }
        }
        Section("Automatic Scrolling") {
            HStack {
                Text("Speed")
                Slider(value: $preferences.autoScrollSpeed, in: 10...300)
                    .accessibilityLabel("Automatic scrolling speed")
                Text("\(Int(preferences.autoScrollSpeed)) pt/s").monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            Footnote("While scrolling, press 1–9 to change speed, − to reverse and Esc to stop.")
        }
    }
}

@MainActor
private enum VoicePreview {
    static let synthesizer = AVSpeechSynthesizer()
}

private struct AccessibilitySettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Interface") {
            accessibilityToggle("Increase contrast", detail: "Make interface text and controls easier to distinguish.",
                                value: $preferences.increaseContrast,
                                systemEnabled: SystemAccessibility.shared.options.increaseContrast)
            accessibilityToggle("Reduce motion", detail: "Turn off animated feedback, page transitions and search-selection movement.",
                                value: $preferences.reduceMotion,
                                systemEnabled: SystemAccessibility.shared.options.reduceMotion)
            accessibilityToggle("Reduce transparency", detail: "Use solid backgrounds in the settings sidebar and document overlays.",
                                value: $preferences.reduceTransparency,
                                systemEnabled: SystemAccessibility.shared.options.reduceTransparency)
            LabeledContent("VoiceOver", value: SystemAccessibility.shared.voiceOverEnabled ? "On" : "Off")
            Button("Open VoiceOver Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?VoiceOver")!)
            }
            .help("Open macOS settings to enable or configure VoiceOver. You can also press Command-F5.")
        }
        Section("Page Colors") {
            Picker("Page colors", selection: $preferences.documentColorMode) {
                ForEach(DocumentColorMode.allCases) { Text($0.title).tag($0) }
            }
            if preferences.documentColorMode == .custom {
                ColorPicker("Text color", selection: hexBinding(\.customPageTextColor), supportsOpacity: false)
                ColorPicker("Page background", selection: hexBinding(\.customPageBackgroundColor), supportsOpacity: false)
            }
            Footnote("Replaces how pages look on screen only. Printing, sharing and saved files keep the original colors.")
        }
    }

    private func hexBinding(_ key: ReferenceWritableKeyPath<AppPreferences, UInt32>) -> Binding<Color> {
        Binding(get: { Color(hex: appState.preferences[keyPath: key]) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let value = (UInt32((rgb.redComponent * 255).rounded()) << 16) | (UInt32((rgb.greenComponent * 255).rounded()) << 8)
                | UInt32((rgb.blueComponent * 255).rounded())
            appState.preferences[keyPath: key] = value
        })
    }

    private func accessibilityToggle(_ title: String, detail: String, value: Binding<Bool>, systemEnabled: Bool) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue || systemEnabled }, set: { value.wrappedValue = $0 })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(systemEnabled ? "Enabled in macOS" : detail).font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
        .disabled(systemEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(systemEnabled ? "Enabled in macOS accessibility settings" : detail)
    }
}

private struct CommentingSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Commenting") {
            TextField("Author name", text: $preferences.commentAuthor)
                .help("Written into new comments. This is also your Identity name.")
            colorPicker("Highlight color", $preferences.highlightColor)
            colorPicker("Underline color", $preferences.underlineColor)
            colorPicker("Sticky-note color", $preferences.noteColor)
            Toggle("Keep annotation tool selected after use", isOn: $preferences.keepAnnotationToolSelected)
            Toggle("Show comments when opening a PDF with comments", isOn: $preferences.openCommentsAutomatically)
            Footnote("Colors and author name apply to new annotations.")
        }
    }

    private func colorPicker(_ title: String, _ selection: Binding<AnnotationPreferenceColor>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AnnotationPreferenceColor.allCases) { Text($0.title).tag($0) }
        }
    }
}

private struct FormsSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Forms") {
            Toggle("Highlight editable form fields", isOn: $preferences.highlightFormFields)
            Footnote("Highlights help locate form fields and are not saved into the PDF. Encrypted files and XFA forms remain read-only.")
        }
    }
}

private struct IdentitySettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Identity") {
            TextField("Name", text: $preferences.commentAuthor)
            TextField("Title", text: $preferences.identityTitle)
            TextField("Organization", text: $preferences.identityOrganization)
            TextField("Email", text: $preferences.identityEmail)
            Footnote("Your name is the author of new comments and measurements and can fill in a document's Author. In Action Wizard text you can use <<author>>, <<title>>, <<organization>> and <<email>>. Identity stays on this Mac.")
        }
    }
}

private struct MeasuringSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Scale") {
            HStack {
                TextField("Page", value: $preferences.measureScalePage, format: .number).frame(width: 70)
                Picker("Page unit", selection: $preferences.measureScalePageUnit) { ForEach(MeasureUnit.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 120)
                Text("=")
                TextField("Real", value: $preferences.measureScaleReal, format: .number).frame(width: 70)
                Picker("Real unit", selection: $preferences.measureScaleRealUnit) { ForEach(MeasureUnit.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 120)
            }
            Toggle("Use the scale stored in the document when present", isOn: $preferences.measureUseDocumentScale)
            Stepper("Precision: \(preferences.measurePrecision) decimal places", value: $preferences.measurePrecision, in: 0...4)
        }
        Section("Snapping") {
            Toggle("Snap to endpoints", isOn: $preferences.measureSnapEndpoints)
            Toggle("Snap to midpoints", isOn: $preferences.measureSnapMidpoints)
            Toggle("Snap to intersections", isOn: $preferences.measureSnapIntersections)
            Toggle("Snap along paths", isOn: $preferences.measureSnapPaths)
        }
        Section("Annotations") {
            Toggle("Add measurements to the document", isOn: $preferences.measureAddAnnotations)
            Picker("Line color", selection: $preferences.measureColor) { ForEach(AnnotationPreferenceColor.allCases) { Text($0.title).tag($0) } }
            Footnote("Measurements are saved as standard PDF measurement annotations that Acrobat and other viewers recognize.")
        }
    }
}

private struct SearchSettings: View {
    let appState: AppState
    @State private var index = SearchIndexStore.shared

    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Advanced Search") {
            Toggle("Include bookmarks", isOn: $preferences.searchIncludeBookmarks)
            Toggle("Include comments", isOn: $preferences.searchIncludeComments)
            Toggle("Include PDF attachments", isOn: $preferences.searchIncludeAttachments)
            Toggle("Ignore accents and diacritics", isOn: $preferences.searchIgnoreDiacritics)
            Stepper("Maximum results: \(preferences.searchMaxResults)", value: $preferences.searchMaxResults, in: 50...5000, step: 50)
            Stepper("Context: \(preferences.searchContextWords) words around each match", value: $preferences.searchContextWords, in: 2...30)
        }
        Section("Indexes") {
            if index.folders.isEmpty {
                Text("No indexed folders. Build one from Advanced Search.").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(index.folders, id: \.path) { folder in
                HStack {
                    Image(systemName: "folder")
                    VStack(alignment: .leading) {
                        Text(folder.name)
                        Text("\(folder.documentCount) PDFs · updated \(folder.updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    Spacer()
                    Button("Delete Index", role: .destructive) { index.remove(folder.path) }
                }
            }
            Footnote("Indexes are stored privately on this Mac and contain the text of the indexed PDFs.")
        }
    }
}

private struct SpellingSettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Spelling") {
            Toggle("Check spelling while typing", isOn: $preferences.checkSpellingWhileTyping)
            Toggle("Correct spelling automatically", isOn: $preferences.correctSpellingAutomatically)
            Picker("Language", selection: $preferences.spellingLanguage) {
                Text("Automatic by Language").tag("")
                ForEach(NSSpellChecker.shared.availableLanguages, id: \.self) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }
            Footnote("Applies to comments, form fields and every text field in zPDF.")
        }
    }
}

private struct SignatureSettings: View {
    let appState: AppState
    var body: some View {
        Section("Saved Signatures") {
            if appState.signatureService.signatures.isEmpty {
                Text("No saved signatures.").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(appState.signatureService.signatures) { signature in
                HStack {
                    if let image = signature.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 90, height: 32)
                            .accessibilityHidden(true)
                    }
                    Text(signature.name)
                    Spacer()
                    Text(signature.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(DesignTokens.Colors.mutedText)
                    Button("Delete", role: .destructive) { appState.signatureService.remove(signature) }
                }
            }
            Footnote("Saved signatures stay on this Mac. Create them with Fill forms ▸ Sign.")
        }
    }
}

private struct SecuritySettings: View {
    let appState: AppState
    var body: some View {
        @Bindable var preferences = appState.preferences
        Section("Links") {
            Picker("Web and email links in documents", selection: $preferences.linkPolicy) {
                ForEach(LinkOpeningPolicy.allCases) { Text($0.title).tag($0) }
            }
            Footnote("Links inside a PDF can lead anywhere. “Ask” shows the address before your browser or mail app opens it.")
        }
        Section("JavaScript") {
            LabeledContent("Document JavaScript", value: "Never run")
            Footnote("zPDF doesn't run scripts embedded in PDFs. Use Action Wizard ▸ Document JavaScript to review and remove them.")
        }
    }
}

private struct PrintSettings: View {
    @State private var store = PrintPresetStore.shared
    var body: some View {
        Section("Print Presets") {
            if store.names.isEmpty {
                Text("No presets. Save one from the Print dialog (⌘P).").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(store.names, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    if let preset = store.presets[name] {
                        Text(summary(preset)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    Button("Delete", role: .destructive) { store.remove(name) }
                }
            }
            Footnote("Printing always uses a copy with your current edits. Presets can also be run as custom commands in the Tools list.")
        }
    }

    private func summary(_ options: PrintOptions) -> String {
        [options.sizing.title, options.content.title].joined(separator: " · ")
    }
}
