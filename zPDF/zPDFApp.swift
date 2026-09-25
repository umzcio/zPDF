//
//  zPDFApp.swift
//  zPDF
//
//  Purpose: App entry point. A single SwiftUI Window hosting RootView, with the
//  shared @Observable AppState injected into the environment. Menu commands:
//  Open (⌘O), Close Tab (⌘W), All Tools (⌃⌘S).
//  Phase: 1
//  One main window owns the document tabs; Finder opens route through AppLifecycle.
//

import SwiftUI

@main
struct zPDFApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @State private var appState = AppState()
    @State private var editingCommands = EditingCommandRouter()

    init() {
        // AppKit's native tooltip delay is in milliseconds. Register an
        // app-local default before creating windows; never change the user's
        // global preferences. Keep native hover help and accessibility intact.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 350])
    }

    var body: some Scene {
        Window(Constants.appName, id: "main") {
            RootView(lifecycle: lifecycle)
                .environment(appState)
                .modifier(AppAppearanceModifier(preferences: appState.preferences))
                .frame(minWidth: 960, minHeight: 600)
                .background(WindowCloseGuard(appState: appState))
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            EditCommands(appState: appState)
            CommentCommands(appState: appState)
            FormsCommands(appState: appState)
            DocumentCommands(appState: appState)
            ViewCommands(appState: appState)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
            }
            // Close the focused document tab, or the key window when Settings
            // (or an empty main window) owns focus. performClose respects the
            // main window's existing unsaved-changes delegate.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appState.openFilePanel() }
                    .zShortcut(.open)
                DocumentCommands.createPDFMenu(appState)
                Divider()
                Button(appState.documentWindowIsKey && appState.activeTab != nil ? "Close Tab" : "Close Window") {
                    if appState.documentWindowIsKey && appState.activeTab != nil {
                        appState.closeActiveTab()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .zShortcut(.closeTab)
                // Save lives here: a single `Window` scene has no .saveItem slot.
                Divider()
                Button("Save") { appState.saveActiveDocument() }
                    .zShortcut(.save)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true)
                Button("Save As…") { appState.saveActiveDocumentAs() }
                    .zShortcut(.saveAs)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true || appState.isResolvingClose)
            }
            CommandGroup(after: .importExport) {
                Menu("Export") {
                    ForEach(ConversionFormat.allCases) { format in
                        Button(format.title + "…") { appState.showConversionExport(format: format) }
                    }
                }.disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true || appState.isResolvingClose)
                Divider()
                Button("Recover Unsaved Documents…") {
                    Task { await appState.showRecovery() }
                }
                Divider()
                Button("Combine PDFs…") { appState.showingCombine = true }
                    .disabled(!appState.documentWindowIsKey || appState.isResolvingClose)
                Button("Reduce File Size…") { appState.present(.reduceFileSize) }
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in PDF…") { appState.searchFocusRequest += 1 }
                    .zShortcut(.find)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Next Match") { appState.activeTab?.goToNextMatch() }
                    .zShortcut(.findNext)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.currentMatch == nil)
                Button("Previous Match") { appState.activeTab?.goToPreviousMatch() }
                    .zShortcut(.findPrevious)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.currentMatch == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                let _ = appState.activeTab?.undoRevision
                Button("Undo") {
                    editingCommands.perform(redo: false, appState: appState)
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(editingCommands.isEditingText ? !editingCommands.canUndo
                          : !appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true
                          || (appState.activeTab?.undoHistory?.manager.canUndo != true && appState.activeTab?.hasUncommittedFieldEdit != true))
                Button("Redo") {
                    editingCommands.perform(redo: true, appState: appState)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(editingCommands.isEditingText ? !editingCommands.canRedo
                          : !appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true
                          || appState.activeTab?.undoHistory?.manager.canRedo != true)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { appState.printActiveDocument() }
                    .zShortcut(.print)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil || appState.activeTab?.isSaving == true)
                ViewCommands.printMenuExtras(appState)
            }
            CommandMenu("Navigate") {
                Button("Previous View") { appState.navigateView(backward: true) }
                    .zShortcut(.previousView)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.viewHistory.canGoBack != true)
                Button("Next View") { appState.navigateView(backward: false) }
                    .zShortcut(.nextView)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.viewHistory.canGoForward != true)
                Divider()
                Button("Previous Page") { appState.navigatePage(.previous) }
                    .zShortcut(.previousPage)
                    .disabled(!appState.documentWindowIsKey || (appState.activeTab?.currentPage ?? 1) <= 1)
                Button("Next Page") { appState.navigatePage(.next) }
                    .zShortcut(.nextPage)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil
                              || (appState.activeTab?.currentPage ?? 1) >= (appState.activeTab?.pageCount ?? 1))
                Button("First Page") { appState.navigatePage(.first) }
                    .zShortcut(.firstPage)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Last Page") { appState.navigatePage(.last) }
                    .zShortcut(.lastPage)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Go to Page…") { appState.pageFocusRequest += 1 }
                    .zShortcut(.goToPage)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Divider()
                Button("Previous Document") { appState.cycleDocument(backward: true) }
                    .zShortcut(.previousDocument)
                    .disabled(!appState.documentWindowIsKey || appState.tabs.count < 2)
                Button("Next Document") { appState.cycleDocument(backward: false) }
                    .zShortcut(.nextDocument)
                    .disabled(!appState.documentWindowIsKey || appState.tabs.count < 2)
            }
            CommandGroup(after: .sidebar) {
                Button("All Tools") { appState.toggleAllTools() }
                    .zShortcut(.allTools)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Divider()
                Button("Zoom In") { appState.stepDocumentZoom(.in) }
                    .zShortcut(.zoomIn)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Zoom Out") { appState.stepDocumentZoom(.out) }
                    .zShortcut(.zoomOut)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Actual Size") { appState.activeTab?.setZoom(1.0) }
                    .zShortcut(.actualSize)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
            }
        }
        Settings {
            SettingsView()
                .environment(appState)
                .modifier(AppAppearanceModifier(preferences: appState.preferences))
        }
        // Help, Advanced Search and extra document windows (FeatureWindows.swift).
        FeatureWindows(appState: appState)
    }
}

/// Both scenes keep native panels in sync even when the main window is closed.
struct AppAppearanceModifier: ViewModifier {
    let preferences: AppPreferences
    private let system = SystemAccessibility.shared

    func body(content: Content) -> some View {
        let options = preferences.accessibilityOptions(system: system.options)
        content
            .tint(DesignTokens.Colors.controlAccent)
            .environment(\.appAccessibility, options)
            .transaction { transaction in
                if options.reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .onAppear { NSApp.appearance = preferences.appearance.nsAppearance }
            .onChange(of: preferences.appearance) { _, appearance in NSApp.appearance = appearance.nsAppearance }
    }
}

/// SwiftUI's custom document commands must not steal text-field undo, including
/// author/search fields in Settings and PDFKit's own field editor.
@MainActor @Observable
final class EditingCommandRouter {
    private(set) var isEditingText = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    // The app owns this router for its entire lifetime.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let names: [Notification.Name] = [
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            NSText.didChangeNotification, NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification, NSControl.textDidChangeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    func refresh() {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        isEditingText = editor?.isEditable == true
        canUndo = isEditingText && editor?.undoManager?.canUndo == true
        canRedo = isEditingText && editor?.undoManager?.canRedo == true
    }

    func perform(redo: Bool, appState: AppState) {
        // Recheck synchronously: a menu click can follow a focus change before
        // its observation task has run. Never fall back to document undo from
        // a text field whose own history is empty.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            if redo { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
        } else if appState.documentWindowIsKey {
            if redo { appState.redoDocumentEdit() } else { appState.undoDocumentEdit() }
        }
        refresh()
    }
}
