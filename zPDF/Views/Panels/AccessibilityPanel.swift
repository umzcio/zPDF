import AVFoundation
import PDFKit
import SwiftUI

/// Accessibility tool: Full Check with fixes, autotagging, title/language,
/// tags, reading order, alternate text, Read Out Loud, Reflow and PDF/UA.
struct AccessibilityPanel: View {
    @Environment(AppState.self) private var appState
    @State private var report: AccessibilityReport?
    @State private var checking = false
    @State private var checkedAt: Date?
    @State private var expanded: Set<String> = ["Document"]
    @State private var showingTitleLanguage = false
    @State private var showingTags = false
    @State private var showingAltText = false
    @State private var confirmRetag = false
    @State private var working: String?

    private var tab: DocumentTab? { appState.activeTab }
    private var canEdit: Bool { tab?.allowsSaveEdits == true && tab?.editSource != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            checkSection
            prepareSection
            tagsSection
            readSection
            if let report { pdfuaSection(report) }
            PanelHelpLink(topic: "accessibility")
        }
        .task(id: tab?.editSource?.hash) {
            // Re-run a previous check after edits so the report stays current.
            if report != nil { await runCheck() }
        }
        .sheet(isPresented: $showingTitleLanguage) {
            if let tab { TitleLanguageSheet(tab: tab) { Task { await runCheck() } } }
        }
        .sheet(isPresented: $showingTags) {
            if let tab { TagsEditorView(tab: tab) }
        }
        .sheet(isPresented: $showingAltText) {
            if let tab { AltTextEditorView(tab: tab) }
        }
        .alert("Replace the existing tags?", isPresented: $confirmRetag) {
            Button("Cancel", role: .cancel) {}
            Button("Replace Tags", role: .destructive) { autotag(replace: true) }
        } message: {
            Text("This document is already tagged. Autotag removes the current tags and builds new ones from the page layout. You can undo this.")
        }
    }

    // MARK: - Check

    private var checkSection: some View {
        PanelSection(title: "Accessibility Check") {
            HStack {
                Button { Task { await runCheck() } } label: {
                    Label(report == nil ? "Run Full Check" : "Check Again", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.controlAccent)
                .disabled(tab == nil || checking || !(tab.map(appState.canQuery) ?? false))
                .help("Check tags, title, language, reading order, alternate text, tables, lists, forms and more")
                if checking { ProgressView().controlSize(.small) }
            }
            if let report {
                summary(report)
                if !report.fixable.isEmpty && canEdit {
                    Button { fixAll(report) } label: {
                        Label("Fix \(report.fixable.count) Issue\(report.fixable.count == 1 ? "" : "s") Automatically", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(working != nil)
                    .help("Runs every automatic fix; title and language use the file name and your system language.")
                }
                ForEach(report.categories, id: \.self) { category in
                    categoryGroup(category, items: report.items.filter { $0.category == category })
                }
                if let checkedAt {
                    Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened)). Items marked “manual” need a person to verify them.")
                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
            } else {
                PanelNote("Full Check reviews the document the way Acrobat's accessibility checker does, and offers fixes where zPDF can make them.")
            }
        }
    }

    private func summary(_ report: AccessibilityReport) -> some View {
        HStack(spacing: 6) {
            chip("\(report.summary.failed)", "Failed", .red)
            chip("\(report.summary.manual)", "Manual", .orange)
            chip("\(report.summary.passed)", "Passed", DesignTokens.Colors.readyGreen)
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(DesignTokens.Colors.inset)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
    }

    private func categoryGroup(_ category: String, items: [AccessibilityCheckItem]) -> some View {
        let failed = items.filter { $0.status == .failed }.count
        return DisclosureGroup(isExpanded: Binding(get: { expanded.contains(category) },
                                                   set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } })) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in checkRow(item) }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(category).font(.system(size: 12, weight: .medium))
                Spacer()
                if failed > 0 {
                    Text("\(failed) failed").font(.system(size: 10.5)).foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.readyGreen)
                        .accessibilityLabel("No failures")
                }
            }
        }
    }

    private func checkRow(_ item: AccessibilityCheckItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.status.symbol)
                .font(.system(size: 11))
                .foregroundStyle(color(item.status))
                .frame(width: 14)
                .accessibilityLabel(item.status.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 11.5))
                if item.status == .failed || item.status == .manual {
                    Text(item.detail).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if item.status == .failed, let fixID = item.fix, let fix = AccessibilityFix(rawValue: fixID), canEdit {
                        Button(fix.title) { run(fix) }
                            .controlSize(.mini)
                            .disabled(working != nil)
                            .help("Fix: \(item.title)")
                    }
                    if let page = item.pages.first, item.status != .passed {
                        Button("Page \(page + 1)\(item.pages.count > 1 ? " +\(item.pages.count - 1)" : "")") {
                            tab?.goToPage(page + 1)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                        .help("Go to the first affected page")
                    }
                }
            }
        }
        .help(item.detail)
    }

    private func color(_ status: AccessibilityCheckItem.Status) -> Color {
        switch status {
        case .passed: DesignTokens.Colors.readyGreen
        case .failed: .red
        case .manual: .orange
        case .skipped: DesignTokens.Colors.mutedText
        }
    }

    // MARK: - Prepare

    private var prepareSection: some View {
        PanelSection(title: "Prepare") {
            VStack(spacing: 0) {
                PanelRow(title: "Autotag Document", symbolName: "tag") {
                    if report?.tagged == true || tagged { confirmRetag = true } else { autotag(replace: false) }
                }
                .help("Build tags (headings, paragraphs, lists, tables, figures) from the page layout")
                PanelRow(title: "Set Title and Language…", symbolName: "character.book.closed") { showingTitleLanguage = true }
                    .help("Set the document title shown to assistive technology and its primary language")
                PanelRow(title: "Add Form Field Descriptions", symbolName: "text.cursor") { run(.fieldTooltips) }
                    .help("Give form fields without a tooltip a description derived from the field name")
                PanelRow(title: "Set Tab Order to Structure", symbolName: "arrow.right.to.line") { run(.setTabOrder) }
                    .help("Make Tab move through links and fields in reading order")
                PanelRow(title: "Tag Annotations", symbolName: "text.bubble") { run(.tagAnnotations) }
                    .help("Add tags for links, fields and comments that aren't tagged yet")
                PanelRow(title: "Bookmarks from Headings", symbolName: "bookmark") { run(.bookmarks) }
                    .help("Long documents need bookmarks; create them from the heading text")
            }
            .disabled(!canEdit || working != nil)
            if let working {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(working).font(.system(size: 11)) }
            }
            PanelNote("Autotag is best effort: complex tables, multi-column layouts and forms may need corrections in the Tags editor.")
        }
    }

    // MARK: - Tags and reading order

    private var tagged: Bool { report?.tagged ?? false }

    private var tagsSection: some View {
        let viewing = tab.map { appState.features.viewing(for: $0) }
        return PanelSection(title: "Tags and Reading Order") {
            VStack(spacing: 0) {
                PanelRow(title: "Edit Tags…", symbolName: "list.bullet.indent") { showingTags = true }
                    .help("View and edit the tag tree: type, order, alternate text and language")
                PanelRow(title: "Alternate Text for Figures…", symbolName: "photo.badge.checkmark") { showingAltText = true }
                    .help("Describe images for people who can't see them")
                PanelToggleRow(title: "Show Reading Order on Page", symbolName: "list.number",
                               isOn: Binding(get: { viewing?.readingOrderOverlay ?? false },
                                             set: { viewing?.readingOrderOverlay = $0 }))
                    .help("Number the tagged content on the current page in reading order (⌥⌘R)")
            }
            .disabled(tab == nil)
            if viewing?.readingOrderOverlay == true, let tab {
                ReadingOrderList(tab: tab)
            }
        }
    }

    // MARK: - Read Out Loud & Reflow

    private var readSection: some View {
        let reader = appState.features.readAloud
        let viewing = tab.map { appState.features.viewing(for: $0) }
        return PanelSection(title: "Read Out Loud & Reflow") {
            PanelToolGrid {
                PanelToolButton(title: "Read Page", symbolName: "speaker.wave.2", isActive: reader.isSpeaking) {
                    reader.start(.page, in: appState)
                }
                .help("Read this page aloud (⇧⌘V)")
                PanelToolButton(title: "Read to End", symbolName: "text.line.first.and.arrowtriangle.forward", isActive: false) {
                    reader.start(.toEnd, in: appState)
                }
                .help("Read from this page to the end (⇧⌘B)")
                PanelToolButton(title: reader.isPaused ? "Resume" : "Pause", symbolName: reader.isPaused ? "play" : "pause",
                                isActive: reader.isPaused) { reader.togglePause() }
                    .disabled(!reader.isSpeaking)
                    .help("Pause or resume reading (⇧⌘C)")
                PanelToolButton(title: "Stop", symbolName: "stop", isActive: false) { reader.stop() }
                    .disabled(!reader.isSpeaking)
                    .help("Stop reading (⇧⌘E)")
            }
            .disabled(tab == nil)
            PanelToggleRow(title: "Reflow Text", symbolName: "text.alignleft",
                           isOn: Binding(get: { viewing?.reflowActive ?? false }, set: { viewing?.reflowActive = $0 }))
            .disabled(tab == nil)
            .help("Show the page as readable, resizable text (⌘4)")
            PanelNote("Voice, speed and word highlighting are in Settings ▸ Reading.")
        }
    }

    // MARK: - PDF/UA

    private func pdfuaSection(_ report: AccessibilityReport) -> some View {
        PanelSection(title: "PDF/UA") {
            HStack {
                Image(systemName: report.pdfua.claimed ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(report.pdfua.claimed ? DesignTokens.Colors.readyGreen : DesignTokens.Colors.mutedText)
                Text(report.pdfua.claimed ? "Identified as PDF/UA-1" : "Not identified as PDF/UA")
                    .font(.system(size: 12))
                Spacer()
            }
            Button(report.pdfua.claimed ? "Remove PDF/UA Identifier" : "Identify as PDF/UA-1") {
                Task {
                    guard let tab else { return }
                    await appState.performDocumentEdit([["op": "mark_pdfua", "enabled": !report.pdfua.claimed]],
                                                       actionName: report.pdfua.claimed ? "Remove PDF/UA Identifier" : "Identify as PDF/UA",
                                                       in: tab)
                }
            }
            .disabled(!canEdit || (!report.pdfua.claimed && (!report.tagged || report.summary.failed > 0)))
            .help(report.summary.failed > 0 ? "Fix the failed checks first; PDF/UA requires a tagged, accessible document."
                  : "Adds the PDF/UA-1 identifier to the document metadata")
            PanelNote("The identifier is a claim, not a certification. Items marked for manual checking must still be reviewed.")
        }
    }

    // MARK: - Actions

    private func runCheck() async {
        guard let tab, appState.canQuery(tab) else { return }
        checking = true
        defer { checking = false }
        do {
            report = try await appState.documentQuery("accessibility_check", in: tab, as: AccessibilityReport.self)
            checkedAt = Date()
            if let report {
                expanded.formUnion(report.categories.filter { category in
                    report.items.contains { $0.category == category && $0.status == .failed }
                })
            }
        } catch {
            appState.reportPanelError(error, in: tab)
        }
    }

    private func autotag(replace: Bool) {
        guard let tab else { return }
        var op: [String: Any] = ["op": "autotag", "replace": replace]
        if let language = TitleLanguageSheet.defaultLanguage { op["language"] = language }
        perform([op], "Autotag Document", then: true)
        _ = tab
    }

    private func run(_ fix: AccessibilityFix) {
        switch fix {
        case .setTitle, .setLanguage: showingTitleLanguage = true
        case .autotag: if tagged { confirmRetag = true } else { autotag(replace: false) }
        case .setTabOrder: perform([["op": "set_tab_order", "order": "S"]], "Set Tab Order")
        case .fieldTooltips: perform([["op": "set_field_tooltips"]], "Add Field Descriptions")
        case .tagAnnotations: perform([["op": "tag_annotations"]], "Tag Annotations")
        case .bookmarks: perform([["op": "outline_from_headings", "replace": false]], "Bookmarks from Headings")
        }
    }

    private func fixAll(_ report: AccessibilityReport) {
        let fixes = Set(report.fixable.compactMap { $0.fix.flatMap(AccessibilityFix.init(rawValue:)) })
        var ops: [[String: Any]] = []
        if fixes.contains(.autotag) {
            var op: [String: Any] = ["op": "autotag", "replace": report.tagged]
            if let language = TitleLanguageSheet.defaultLanguage { op["language"] = language }
            ops.append(op)
        }
        if fixes.contains(.setTitle), let tab {
            ops.append(["op": "set_title", "title": TitleLanguageSheet.suggestedTitle(for: tab), "display_doc_title": true])
        }
        if fixes.contains(.setLanguage), let language = TitleLanguageSheet.defaultLanguage {
            ops.append(["op": "set_language", "lang": language])
        }
        if fixes.contains(.fieldTooltips) { ops.append(["op": "set_field_tooltips"]) }
        if fixes.contains(.tagAnnotations) && !fixes.contains(.autotag) { ops.append(["op": "tag_annotations"]) }
        if fixes.contains(.setTabOrder) && !fixes.contains(.autotag) { ops.append(["op": "set_tab_order", "order": "S"]) }
        guard !ops.isEmpty else { return }
        perform(ops, "Fix Accessibility Issues")
        // Bookmarks can fail when no headings exist; run separately so the
        // other fixes still apply.
        if fixes.contains(.bookmarks) { perform([["op": "outline_from_headings", "replace": false]], "Bookmarks from Headings") }
    }

    private func perform(_ ops: [[String: Any]], _ action: String, then check: Bool = true) {
        guard let tab else { return }
        working = action + "…"
        Task {
            let ok = await appState.performDocumentEdit(ops, actionName: action, in: tab)
            working = nil
            if ok && check { await runCheck() }
        }
    }
}

// MARK: - Title & language

struct TitleLanguageSheet: View {
    let tab: DocumentTab
    let onApplied: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var language = ""
    @State private var showTitle = true
    @State private var loaded = false
    @State private var applying = false

    static var defaultLanguage: String? {
        let locale = Locale.current
        guard let code = locale.language.languageCode?.identifier else { return nil }
        if let region = locale.region?.identifier { return "\(code)-\(region)" }
        return code
    }

    static func suggestedTitle(for tab: DocumentTab) -> String {
        if let title = tab.pdfDocument?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return (tab.displayName as NSString).deletingPathExtension
    }

    static let commonLanguages: [(String, String)] = [
        ("en-US", "English (United States)"), ("en-GB", "English (United Kingdom)"), ("es-ES", "Spanish (Spain)"),
        ("es-MX", "Spanish (Mexico)"), ("fr-FR", "French (France)"), ("fr-CA", "French (Canada)"), ("de-DE", "German"),
        ("it-IT", "Italian"), ("pt-BR", "Portuguese (Brazil)"), ("nl-NL", "Dutch"), ("sv-SE", "Swedish"), ("da-DK", "Danish"),
        ("nb-NO", "Norwegian"), ("fi-FI", "Finnish"), ("pl-PL", "Polish"), ("ru-RU", "Russian"), ("uk-UA", "Ukrainian"),
        ("ja-JP", "Japanese"), ("zh-CN", "Chinese (Simplified)"), ("zh-TW", "Chinese (Traditional)"), ("ko-KR", "Korean"),
        ("ar", "Arabic"), ("he-IL", "Hebrew"), ("hi-IN", "Hindi")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Title and Language").font(.headline)
            Text("Screen readers announce the title and pick pronunciation from the language.")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            Form {
                TextField("Title", text: $title)
                Toggle("Show the title instead of the file name in viewer title bars", isOn: $showTitle)
                Picker("Language", selection: $language) {
                    ForEach(Self.commonLanguages, id: \.0) { Text("\($0.1) — \($0.0)").tag($0.0) }
                    if !Self.commonLanguages.contains(where: { $0.0 == language }) && !language.isEmpty {
                        Text(language).tag(language)
                    }
                }
                TextField("Language tag", text: $language, prompt: Text("e.g. en-US"))
                    .help("Any BCP 47 language tag")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || language.isEmpty || applying)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .task {
            guard !loaded else { return }
            loaded = true
            title = Self.suggestedTitle(for: tab)
            language = Self.defaultLanguage ?? "en-US"
            if let json = try? await appState.documentQueryJSON("document_properties", in: tab),
               let model = try? DocumentPropertiesModel.load(json) {
                if let lang = model.lang, !lang.isEmpty { language = lang }
                if let docTitle = model.info.title, !docTitle.isEmpty { title = docTitle }
            }
        }
    }

    private func apply() {
        applying = true
        Task {
            let ok = await appState.performDocumentEdit([
                ["op": "set_title", "title": title.trimmingCharacters(in: .whitespaces), "display_doc_title": showTitle],
                ["op": "set_language", "lang": language.trimmingCharacters(in: .whitespaces)]
            ], actionName: "Set Title and Language", in: tab)
            applying = false
            if ok { onApplied(); dismiss() }
        }
    }
}

// MARK: - Reading order list (panel) and overlay data

/// Reading order of the current page. Drag to reorder; the canvas overlay
/// numbers the same items.
struct ReadingOrderList: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var items: [ReadingOrderItem] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loading && items.isEmpty {
                ProgressView().controlSize(.small)
            } else if let message {
                PanelNote(message)
            } else {
                Text("Page \(tab.currentPage): drag to change the order.")
                    .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                List {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Text("\(item.order)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .frame(width: 20, height: 16)
                                .background(DesignTokens.Colors.accentTint)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(item.type).font(.system(size: 10.5, weight: .medium)).frame(width: 40, alignment: .leading)
                            Text(item.text ?? "").font(.system(size: 10.5)).lineLimit(1)
                        }
                        .help(item.text ?? item.type)
                    }
                    .onMove(perform: move)
                }
                .frame(height: min(260, CGFloat(items.count) * 24 + 12))
                .listStyle(.plain)
                .accessibilityLabel("Reading order")
            }
        }
        .task(id: "\(tab.editSource?.hash ?? "")-\(tab.currentPage)") { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await appState.documentQuery("reading_order", params: ["page": tab.currentPage - 1], in: tab,
                                                          as: ReadingOrderResult.self)
            items = result.items
            message = items.isEmpty ? "No tagged content on this page. Autotag the document to create a reading order." : nil
            appState.features.readingOrder = (tab.id, tab.currentPage - 1, items)
        } catch {
            message = error.localizedDescription
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard tab.allowsSaveEdits else { return }
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        items = reordered
        Task {
            await appState.performDocumentEdit([["op": "set_reading_order", "page": tab.currentPage - 1, "ids": reordered.map(\.id)]],
                                               actionName: "Change Reading Order", in: tab)
        }
    }
}
