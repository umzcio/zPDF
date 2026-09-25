//
//  AppState.swift
//  zPDF
//
//  Purpose: Root @Observable application state: rail selection, document
//  tabs, active tab, active inspector panel, sidebar visibility, home
//  filter, the armed annotation and form-field tools, plus the shared
//  service singletons. Also defines InspectorPanel (the 7 right-hand
//  panels) and HomeFilter (Recent/Starred/Shared).
//  Phase: 1 — REAL (navigation/tab/panel logic, open-error alerts),
//  services injected. Phase 2 — armed annotation tool + selection markup.
//  Phase 3 — armed form-field tool (Prepare Form widget placement).
//  Phase 4 — text-editing mode + selected text run (Edit panel canvas
//  interaction, wired to PDFEngine.textRuns/replaceTextRun).
//

import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The seven right-hand inspector panels, mirroring the prototype's
/// PANELS table (edit / comment / fill / protect / export / form / organize).
enum InspectorPanel: String, CaseIterable, Identifiable {
    case edit
    case comment
    case fillSign
    case export
    case protect
    case organize
    case prepareForm
    case redact
    case sign
    case createPDF
    case scanOCR
    case optimize
    case compare
    case measure
    case accessibility
    case standards
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Edit PDF"
        case .comment: "Comment"
        case .fillSign: "Fill forms"
        case .export: "Export PDF"
        case .protect: "Protect"
        case .organize: "Organize Pages"
        case .prepareForm: "Prepare Form"
        case .redact: "Redact"
        case .sign: "Certificates"
        case .createPDF: "Create PDF"
        case .scanOCR: "Scan & OCR"
        case .optimize: "Optimize PDF"
        case .compare: "Compare Files"
        case .measure: "Measure"
        case .accessibility: "Accessibility"
        case .standards: "Standards & Print Production"
        case .automation: "Action Wizard"
        }
    }

    var symbolName: String {
        switch self {
        case .edit: "square.and.pencil"
        case .comment: "text.bubble"
        case .fillSign: "list.bullet.rectangle"
        case .export: "square.and.arrow.up"
        case .protect: "lock.shield"
        case .organize: "rectangle.on.rectangle"
        case .prepareForm: "list.bullet.rectangle"
        case .redact: "eye.slash"
        case .sign: "checkmark.seal"
        case .createPDF: "doc.badge.plus"
        case .scanOCR: "doc.viewfinder"
        case .optimize: "speedometer"
        case .compare: "rectangle.split.2x1"
        case .measure: "ruler"
        case .accessibility: "accessibility"
        case .standards: "archivebox"
        case .automation: "wand.and.stars"
        }
    }

    /// Workflows with a supported native Save path, shared with All tools.
    static let toolbarOrder: [InspectorPanel] = ToolID.available.compactMap(\.inspectorPanel)
}

/// Left-column filters on the Home screen.
enum HomeFilter: String, CaseIterable, Identifiable {
    case recent
    case starred
    case shared

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .starred: "Starred"
        case .shared: "Shared"
        }
    }

    var symbolName: String {
        switch self {
        case .recent: "clock"
        case .starred: "star"
        case .shared: "person.2"
        }
    }
}

/// A file-open failure surfaced as an alert (presented from RootView).
/// When the failure came from a recents entry, `staleRecentFile` lets the
/// alert offer to remove the entry.
struct OpenError: Identifiable {
    let id = UUID()
    let fileName: String
    let message: String
    var staleRecentFile: RecentFile?
}

@MainActor
@Observable
final class AppState {
    // MARK: - Navigation state

    var documentPanel: DocumentPanel?
    let readingPresentation = ReadingPresentationState()
    var railSelection: RailDestination = .home
    var tabs: [DocumentTab] = []
    var activeTabID: UUID?
    var documentWindowIsKey = true
    var activePanel: InspectorPanel?
    var toolsFocusRequest = 0
    var sidebarVisible = true {
        didSet { if preferences.rememberSidebar && !readingPresentation.isActive { preferences.sidebarVisible = sidebarVisible } }
    }
    var homeFilter: HomeFilter = .recent
    /// Non-nil while a file-open failure alert is being presented.
    var openError: OpenError?

    // MARK: - Annotation tools (phase 2)

    /// Tool armed in the Comment panel's Add-annotation grid. The next text
    /// selection (markup tools) or click/drag on the canvas (point and ink
    /// tools) applies it; cleared after applying. Read by
    /// PDFViewRepresentable's coordinator during hit-testing.
    var armedAnnotationTool: AnnotationTool?
    /// Bumped whenever annotations are added/edited/removed so views
    /// re-derive comments from the (non-observable) PDFDocument.
    private(set) var annotationRevision = 0

    // MARK: - Form field tools (phase 3)

    /// Field kind armed in the Prepare Form panel's Add-field grid. The
    /// next click on the page canvas places a widget annotation of that
    /// kind; cleared after placing. Read by PDFViewRepresentable's
    /// coordinator during hit-testing.
    var armedFormFieldTool: DetectedFormField.Kind?

    // MARK: - Text editing mode (phase 4)

    /// While true, the Edit panel's content-editing mode is live: clicks
    /// on the page canvas select the text run under the click (via
    /// `PDFEngine.textRuns(onPageAt:in:)`) instead of starting a PDFKit
    /// text selection, and the Edit panel's Format section edits the
    /// selected run. Mutually exclusive with the armed annotation and
    /// form-field tools; cleared when the last tab closes.
    var textEditingModeActive = false
    /// The text run last clicked in editing mode; nil when nothing is
    /// selected. The run carries its own 0-based page index
    /// (`EditableTextRun.pageIndex`). Run ids are only stable until the
    /// next successful replace — the panel clears this on commit.
    var selectedTextRun: EditableTextRun?

    // MARK: - Services (see SPEC.md §2.1)

    let engine: any PDFEngine
    let annotationService: any AnnotationService
    let signatureService: SignatureService
    let exportService: any ExportService
    let recentFiles: RecentFilesStore
    let preferences: AppPreferences
    let readingHistory: ReadingHistoryStore
    var restoringSession = false
    var didRestoreSession = false
    var saveError: OpenError?
    var recovery: RecoveryCoordinator?
    var recoveryWarning: String?
    @ObservationIgnored var didStartRecovery = false
    @ObservationIgnored var checkpointTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var saves: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored var saveDestinations: [UUID: URL] = [:]
    @ObservationIgnored var pageDrag: PageDrag?
    @ObservationIgnored var saveAsDestination: (@MainActor (DocumentTab) async -> SaveDestination?)?
    var isResolvingClose = false
    /// Injectable decision only; production uses the standard AppKit prompt.
    @ObservationIgnored var closeDecision: (@MainActor (DocumentTab) async -> UnsavedChoice)?
    /// Reference box holding the live PDFView (set by PDFViewRepresentable).
    let pdfViewStore = PDFViewStore()

    init(engine: any PDFEngine = PDFKitEngine(),
         annotationService: any AnnotationService = PDFKitAnnotationService(),
         signatureService: SignatureService = SignatureService(),
         exportService: any ExportService = BasicExportService(),
         recentFiles: RecentFilesStore = RecentFilesStore(),
         preferences: AppPreferences = .shared,
         readingHistory: ReadingHistoryStore = ReadingHistoryStore()) {
        self.engine = engine
        self.annotationService = annotationService
        self.signatureService = signatureService
        self.exportService = exportService
        self.recentFiles = recentFiles
        self.preferences = preferences
        self.readingHistory = readingHistory
        if let service = annotationService as? PDFKitAnnotationService { service.preferences = preferences }
        self.sidebarVisible = preferences.rememberSidebar ? preferences.sidebarVisible : true
        self.recentFiles.maximumCount = preferences.recentFileLimit
        self.recentFiles.reload()
    }

    var activeTab: DocumentTab? {
        tabs.first { $0.id == activeTabID }
    }

    // MARK: - Tabs

    func selectTab(_ tab: DocumentTab) {
        guard commitFieldEditing() else { return }
        if let previous = activeTab { rememberReadingState(previous) }
        if activeTabID != tab.id { resetDocumentTools() }
        activeTabID = tab.id
        railSelection = .document
    }

    func showHome() {
        guard commitFieldEditing() else { return }
        if let tab = activeTab { rememberReadingState(tab) }
        resetDocumentTools()
        railSelection = .home
    }

    private func resetDocumentTools() {
        activePanel = nil
        armedAnnotationTool = nil
        armedFormFieldTool = nil
        textEditingModeActive = false
        selectedTextRun = nil
        pageDrag = nil
        signatureService.disarmPlacement()
    }

    func closeTab(_ tab: DocumentTab) {
        requestClose([tab]) { _ in }
    }

    func removeClosedTab(_ tab: DocumentTab) {
        checkpointTasks.removeValue(forKey: tab.id)?.cancel()
        rememberReadingState(tab)
        tab.cancelSearch()
        tab.undoHistory?.manager.removeAllActions()
        tab.undoHistory = nil
        if pageDrag?.tab === tab { pageDrag = nil }
        tabs.removeAll { $0.id == tab.id }
        persistOpenSession()
        if activeTabID == tab.id {
            resetDocumentTools()
            activeTabID = tabs.last?.id
        }
        if tabs.isEmpty {
            pdfViewStore.pdfView = nil
            activePanel = nil
            armedAnnotationTool = nil
            armedFormFieldTool = nil
            textEditingModeActive = false
            selectedTextRun = nil
            railSelection = .home
        }
    }

    func closeActiveTab() {
        if let tab = activeTab {
            closeTab(tab)
        }
    }

    // MARK: - Opening documents

    /// Present an NSOpenPanel for PDF files and open each selection in a tab.
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            // Panel completion handlers run on the main thread; assert it
            // explicitly so we can touch @MainActor state synchronously.
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                panel.urls.forEach { self?.openDocument(at: $0) }
            }
        }
    }

    /// Open (or focus) a PDF in a new tab and record it in recents.
    /// Failures set `openError`, which RootView presents as an alert.
    /// Test seam; production passwords are entered in a secure field and never stored.
    var showingCombine = false
    var searchFocusRequest = 0
    var pageFocusRequest = 0
    var exportMessage: String?
    var exportedURL: URL?
    var conversionExport: ConversionExport?

    var passwordPrompt: ((URL) -> String?)?

    private func requestPassword(for url: URL) -> String? {
        if let passwordPrompt { return passwordPrompt(url) }
        let alert = NSAlert()
        alert.messageText = "Unlock “\(url.lastPathComponent)”"
        alert.informativeText = "Enter the password to read this PDF. The file will remain encrypted on disk."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Password"
        field.setAccessibilityLabel("PDF password")
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func openDocument(at url: URL, restoringSession: Bool = false) {
        guard !isResolvingClose, commitFieldEditing() else { return }
        if let existing = tabs.first(where: { $0.url.map { SaveDestination.sameFile($0, url) } == true }) {
            selectTab(existing)
            return
        }
        guard !saveDestinations.values.contains(where: { SaveDestination.sameFile($0, url) }) else {
            openError = OpenError(fileName: url.lastPathComponent, message: "This file is being saved. Open it after Save finishes.")
            return
        }
        do {
            let openedHash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            let document = try engine.openDocument(at: url)
            var password: String?
            if document.isLocked {
                // Session restoration must not prompt for passwords at startup.
                guard !restoringSession else { return }
                guard let entered = requestPassword(for: url) else { return }
                guard document.unlock(withPassword: entered) else {
                    throw NativeSaveError(code: "INVALID_PASSWORD", message: "The password did not unlock this PDF. Open the file again to retry.")
                }
                password = entered
            }
            guard document.pageCount > 0 else {
                throw NativeSaveError(code: "EMPTY_DOCUMENT", message: "This file does not contain readable PDF pages.")
            }
            let tab = DocumentTab(url: url, pdfDocument: document)
            applyReadingPreferences(to: tab)
            tab.securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
            tab.saveChecking = true
            tabs.append(tab)
            resetDocumentTools()
            activeTabID = tab.id
            railSelection = .document
            recentFiles.add(url: url)
            persistOpenSession()
            if preferences.openCommentsAutomatically,
               !annotationService.comments(for: tab).isEmpty {
                documentPanel = .comments
            }
            Task {
                do {
                    let info = try await NativeSaveBridge.inspect(url, password: password)
                    guard info.sourceHash == openedHash else {
                        throw NativeSaveError(code: "SOURCE_CHANGED", message: "The file changed while opening. Reopen it before editing.")
                    }
                    guard tabs.contains(where: { $0 === tab }) else { return }
                    tab.sourceHash = info.sourceHash
                    tab.saveBlock = info.writeBlock
                    if info.writeBlock == "UNSUPPORTED_ENCRYPTED_WRITE" {
                        // Forms & Signatures: edit through a decrypted private revision.
                        // A failure leaves the document read-only, exactly as before.
                        try? await prepareEncryptedEditing(tab, url: url, password: password ?? "", hash: info.sourceHash)
                    } else if info.writeBlock == nil {
                        let source = try await DocumentEditSource.capture(url, expectedHash: info.sourceHash)
                        let editableDocument = try engine.openDocument(at: source.url)
                        tab.editSource = source
                        tab.pdfDocument = editableDocument
                        tab.saveBaseline = try await SaveBaseline.capture(editableDocument) { [weak self, weak tab] in
                            guard let self, let tab else { return false }
                            return self.tabs.contains { $0 === tab } && tab.pdfDocument === editableDocument
                        }
                        resetUndoHistory(tab)
                    }
                    tab.saveChecking = false
                    profileDocument(tab)
                } catch {
                    guard tabs.contains(where: { $0 === tab }) else { return }
                    tab.saveChecking = false
                    tab.saveBlock = "ENGINE_UNAVAILABLE"
                    saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
                }
            }
        } catch {
            guard !restoringSession else { return }
            openError = OpenError(fileName: url.lastPathComponent,
                                  message: error.localizedDescription)
        }
    }

    /// Open a recents entry, resolving its security-scoped bookmark. A
    /// missing file surfaces an alert offering to remove the entry.
    func openRecent(_ file: RecentFile) {
        guard let url = file.resolveURL() else {
            openError = OpenError(fileName: file.name,
                                  message: "The file could not be found. It may have been moved or deleted.",
                                  staleRecentFile: file)
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        openDocument(at: url)
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Joining an active Save lets close/quit wait for the same operation.
    func saveActiveDocument() {
        guard let tab = activeTab else { return }
        _ = saveDocument(tab)
    }

    func saveActiveDocumentAs() {
        guard let tab = activeTab, !isResolvingClose else { return }
        _ = saveDocumentAs(tab)
    }

    @discardableResult
    func saveDocument(_ tab: DocumentTab) -> Task<Bool, Never> {
        if let existing = saves[tab.id] { return existing }
        return beginSave(tab, destination: nil, saveAs: tab.requiresSaveAs)
    }

    @discardableResult
    func saveDocumentAs(_ tab: DocumentTab, to destination: SaveDestination? = nil) -> Task<Bool, Never> {
        guard saves[tab.id] == nil else {
            saveError = OpenError(fileName: tab.displayName, message: "Wait for the current Save to finish before using Save As.")
            return Task { false }
        }
        return beginSave(tab, destination: destination, saveAs: true)
    }

    /// Export a subset of the current page order without rebinding or saving
    /// the source tab. It shares Save's staged writer and close/quit tracking.
    @discardableResult
    func extractPages(_ indexes: IndexSet, from tab: DocumentTab,
                      to destination: SaveDestination? = nil) -> Task<Bool, Never> {
        guard tab.allowsSaveEdits, saves[tab.id] == nil, !isResolvingClose else {
            saveError = OpenError(fileName: tab.displayName, message: "Wait for the document to be ready before extracting pages.")
            return Task { false }
        }
        return beginSave(tab, destination: destination, saveAs: true, extracting: indexes)
    }

    private func beginSave(_ tab: DocumentTab, destination: SaveDestination?, saveAs: Bool, extracting: IndexSet? = nil) -> Task<Bool, Never> {
        guard commitFieldEditing(), let url = tab.url, let document = tab.pdfDocument,
              let baseline = tab.saveBaseline, let hash = tab.sourceHash,
              !tab.saveChecking, tab.saveBlock == nil else {
            saveError = OpenError(fileName: tab.displayName, message: tab.saveChecking
                ? "The Save engine is still checking this file. Try again shortly."
                : "This document cannot be saved. Finish editing and open a supported, unencrypted PDF first.")
            return Task { false }
        }
        var changes: NativeSaveChanges
        do {
            // Includes edits in inactive tabs as well as the current field.
            tab.undoHistory?.record()
            changes = try baseline.changes(in: document)
            if let extracting {
                guard !extracting.isEmpty, extracting.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
                    throw NativeSaveError(code: "INVALID_PAGE_RANGE", message: "Choose at least one page within this document.")
                }
                let currentOrder = changes.pages ?? (0..<document.pageCount).map {
                    NativePageSelection(sourceIndex: $0, rotationDelta: 0)
                }
                changes.pages = extracting.map { currentOrder[$0] }
            }
        }
        catch {
            refreshUnsavedChanges(tab)
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return Task { false }
        }
        tab.isSaving = true
        tab.isExtracting = extracting != nil
        if extracting != nil { tab.lastExtractedURL = nil }
        saveError = nil
        let task = Task { () -> Bool in
            defer {
                tab.isSaving = false
                tab.isExtracting = false
                saves[tab.id] = nil
                saveDestinations[tab.id] = nil
                refreshUnsavedChanges(tab)
            }
            do {
                let target: SaveDestination
                if saveAs {
                    if let destination { target = destination }
                    else {
                        let selection: SaveDestination?
                        if let saveAsDestination { selection = await saveAsDestination(tab) }
                        else { selection = await chooseSaveDestination(tab, extracting: extracting != nil) }
                        guard let selection else { return false }
                        target = selection
                    }
                } else { target = SaveDestination(url: url, overwrite: true) }
                if extracting != nil, SaveDestination.sameFile(url, target.url) {
                    throw NativeSaveError(code: "SOURCE_DESTINATION", message: "Choose a different file for the extracted pages. The source document will not be replaced.")
                }
                if tab.requiresSaveAs, SaveDestination.sameFile(url, target.url) {
                    throw NativeSaveError(code: "RECOVERY_DESTINATION", message: "Choose a new location to save the recovered document.")
                }
                guard !tabs.contains(where: { $0 !== tab && $0.url.map { SaveDestination.sameFile($0, target.url) } == true }),
                      !saveDestinations.contains(where: { $0.key != tab.id && SaveDestination.sameFile($0.value, target.url) }) else {
                    throw NativeSaveError(code: "DESTINATION_OPEN", message: "That file is open in another tab or is being saved. Choose a different destination.")
                }
                saveDestinations[tab.id] = target.url
                let access = target.url.startAccessingSecurityScopedResource()
                var retainedAccess = false
                defer { if access && !retainedAccess { target.url.stopAccessingSecurityScopedResource() } }
                guard try await allowStaging(in: target.url.deletingLastPathComponent(), for: tab) else { return false }
                let editSource = tab.editSource
                let savedHash = try await ProtectedSave.save(editSource?.url ?? url, expectedHash: editSource?.hash ?? hash, changes: changes,
                                                             destination: target.url, overwrite: target.overwrite,
                                                             sourceGuard: editSource == nil ? nil : NativeSourceGuard(url: url, hash: hash),
                                                             context: tab.protection.saveContext)
                if extracting != nil {
                    tab.lastExtractedURL = target.url
                    return true
                }
                // Encrypted results reopen through a decrypted revision (DocumentProtection).
                let (newSource, reloaded, baseline) = try await reloadSavedRevision(tab, url: target.url, hash: savedHash)
                if target.url != url {
                    tab.securityScopedURL?.stopAccessingSecurityScopedResource()
                    tab.securityScopedURL = access ? target.url : nil
                    retainedAccess = access
                    tab.url = target.url
                    recentFiles.add(url: target.url)
                }
                tab.pdfDocument = reloaded
                if pageDrag?.tab === tab { pageDrag = nil }
                tab.sourceHash = savedHash
                tab.saveBaseline = baseline
                tab.editSource = newSource
                tab.requiresSaveAs = false
                checkpointTasks.removeValue(forKey: tab.id)?.cancel()
                if let recovery { await recovery.discard(id: tab.recoveryID) }
                tab.recoveredCheckpointID = nil
                tab.recoveredName = nil
                persistOpenSession()
                if let history = tab.undoHistory { history.didSave() } else { resetUndoHistory(tab) }
                tab.hasUncommittedFieldEdit = false
                tab.goToPage(tab.currentPage)
                tab.updateSearchResults()
                if activeTab === tab { selectedTextRun = nil }
                noteAnnotationsChanged()
                return true
            } catch {
                saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
                return false
            }
        }
        saves[tab.id] = task
        return task
    }

    private func chooseSaveDestination(_ tab: DocumentTab, extracting: Bool = false) async -> SaveDestination? {
        let panel = NSSavePanel()
        panel.title = extracting ? "Extract Pages" : "Save PDF As"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (tab.displayName as NSString).deletingPathExtension + (extracting ? " extracted.pdf" : " copy.pdf")
        panel.directoryURL = tab.requiresSaveAs ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            : tab.url?.deletingLastPathComponent()
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        // NSSavePanel asks the user before accepting an existing destination.
        return SaveDestination(url: url, overwrite: FileManager.default.fileExists(atPath: url.path))
    }

    func allowStaging(in folder: URL, for tab: DocumentTab) async throws -> Bool {
        // The facade stages beside the destination; file-only sandbox access
        // does not grant sibling creation. Ask once, and never replace on cancel.
        func probe() throws {
            let url = folder.appendingPathComponent(".zpdf-save-access-\(UUID().uuidString)")
            try Data().write(to: url, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: url)
        }
        do { try probe(); return true }
        catch {
            let failure = error as NSError
            let permissionDenied = (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteNoPermissionError)
                || (failure.domain == NSPOSIXErrorDomain && [1, 13].contains(failure.code))
            guard permissionDenied else { throw error }
        }
        let panel = NSOpenPanel()
        panel.title = "Allow Save in This Folder"
        panel.message = "Allow zPDF to write files in “\(folder.lastPathComponent)”. Select this destination folder to continue."
        panel.prompt = "Allow Save"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let selected = panel.url else { return false }
        guard selected.resolvingSymlinksInPath().standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else {
            throw NativeSaveError(code: "SAVE_ACCESS", message: "Select the destination folder to continue.")
        }
        if selected.startAccessingSecurityScopedResource() {
            tab.saveDirectoryAccessURL?.stopAccessingSecurityScopedResource()
            tab.saveDirectoryAccessURL = selected
        }
        try probe()
        return true
    }

    // MARK: - Tools & panels

    /// Replace the catalog with tool controls in the same sidebar.
    func openTool(_ tool: ToolID) {
        guard ToolID.available.contains(tool), activeTab != nil,
              tool == .comment || activeTab?.allowsSaveEdits == true,
              commitFieldEditing() else { return }
        railSelection = .document
        armedAnnotationTool = nil
        armedFormFieldTool = nil
        textEditingModeActive = false
        if tool == .combineFiles { showingCombine = true; return }
        if tool == .exportPDF { showConversionExport(); return }
        if tool == .compressPDF, let tab = activeTab { exportDocuments(.compress, tabs: [tab]); return }
        if tool == .comment { documentPanel = .comments }
        activePanel = tool.inspectorPanel
        sidebarVisible = true
    }

    /// The rail toggles document panels independently of the editing sidebar.
    func toggleDocumentPanel(_ panel: DocumentPanel) {
        guard activeTab != nil, commitFieldEditing() else { return }
        documentPanel = documentPanel == panel ? nil : panel
    }

    func showAllTools() {
        guard activeTab != nil, commitFieldEditing() else { return }
        railSelection = .document
        armedAnnotationTool = nil
        armedFormFieldTool = nil
        textEditingModeActive = false
        activePanel = nil
        sidebarVisible = true
    }

    /// The persistent All tools control returns from a detail panel to the
    /// catalog; pressing it again closes the catalog.
    func toggleAllTools() {
        if railSelection == .document && sidebarVisible && activePanel == nil {
            closeTools()
        } else { showAllTools() }
    }

    func closeTools() {
        guard commitFieldEditing() else { return }
        resetDocumentTools()
        sidebarVisible = false
        toolsFocusRequest += 1
    }

    func selectDocumentText() {
        guard activeTab != nil, commitFieldEditing() else { return }
        armedAnnotationTool = nil
        armedFormFieldTool = nil
        textEditingModeActive = false
        selectedTextRun = nil
        signatureService.disarmPlacement()
        if let view = pdfViewStore.pdfView { view.window?.makeFirstResponder(view) }
    }

    func useQuickAnnotation(_ tool: AnnotationTool) {
        guard activeTab?.allowsSaveEdits == true, commitFieldEditing() else { return }
        signatureService.disarmPlacement()
        toggleArmedAnnotationTool(tool)
        if tool == .stickyNote && armedAnnotationTool != nil { documentPanel = .comments }
        if let view = pdfViewStore.pdfView { view.window?.makeFirstResponder(view) }
    }

    // MARK: - Annotation tools (phase 2)

    func noteAnnotationsChanged() {
        if let tab = activeTab { refreshUnsavedChanges(tab) }
        annotationRevision += 1
    }

    /// Toggle the armed annotation tool (Comment panel grid). Arming a
    /// markup tool applies immediately when the canvas already has a text
    /// selection.
    func toggleArmedAnnotationTool(_ tool: AnnotationTool) {
        // TODO(phase-2): file attachments need an NSOpenPanel picker.
        guard activeTab?.allowsSaveEdits == true,
              [.highlight, .underline, .stickyNote].contains(tool) else { return }
        armedAnnotationTool = (armedAnnotationTool == tool) ? nil : tool
        // Only one canvas interaction is live at a time.
        if armedAnnotationTool != nil {
            armedFormFieldTool = nil
            textEditingModeActive = false
            selectedTextRun = nil
        }
        if armedAnnotationTool?.isMarkup == true {
            applyArmedMarkupTool()
        }
    }

    /// If a markup tool is armed and the canvas has a text selection, wrap
    /// the selection in a real annotation and disarm. Called when a tool is
    /// armed (CommentPanel) and when the PDFView selection changes or a drag
    /// selection finishes (PDFViewRepresentable.Coordinator).
    func applyArmedMarkupTool() {
        // Ignore mid-drag selection updates; apply once the mouse is up.
        guard activeTab?.allowsSaveEdits == true, NSEvent.pressedMouseButtons == 0,
              let tool = armedAnnotationTool, tool.isMarkup,
              let tab = activeTab,
              let pdfView = pdfViewStore.pdfView,
              let selection = pdfView.currentSelection,
              !selection.pages.isEmpty else { return }
        annotationService.addMarkupAnnotation(tool, over: selection, in: tab)
        if !preferences.keepAnnotationToolSelected { armedAnnotationTool = nil }
        pdfView.clearSelection()
        noteAnnotationsChanged()
    }

    // MARK: - Form field tools (phase 3)

    /// Toggle the armed form-field tool (Prepare Form panel grid). Arming
    /// one disarms any armed annotation tool so a single canvas
    /// interaction is live at a time. Placement and disarm-after-apply
    /// happen in PDFViewRepresentable's click hit-testing.
    func toggleArmedFormFieldTool(_ kind: DetectedFormField.Kind) {
        armedFormFieldTool = (armedFormFieldTool == kind) ? nil : kind
        if armedFormFieldTool != nil {
            armedAnnotationTool = nil
            textEditingModeActive = false
            selectedTextRun = nil
        }
    }

    // MARK: - Text editing mode (phase 4)

    /// Toggle the Edit panel's content-editing mode. Arming it disarms
    /// the annotation and form-field tools so a single canvas interaction
    /// is live at a time; disarming clears the selected text run.
    /// Click hit-testing lives in PDFViewRepresentable's coordinator.
    func toggleTextEditingMode() {
        textEditingModeActive.toggle()
        if textEditingModeActive {
            armedAnnotationTool = nil
            armedFormFieldTool = nil
        } else {
            selectedTextRun = nil
        }
    }
}
