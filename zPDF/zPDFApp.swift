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
            // Close the focused document tab, or the key window when Settings
            // (or an empty main window) owns focus. performClose respects the
            // main window's existing unsaved-changes delegate.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appState.openFilePanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button(appState.documentWindowIsKey && appState.activeTab != nil ? "Close Tab" : "Close Window") {
                    if appState.documentWindowIsKey && appState.activeTab != nil {
                        appState.closeActiveTab()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
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
                Button("Compress PDF…") {
                    if let tab = appState.activeTab { appState.exportDocuments(.compress, tabs: [tab]) }
                }.disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in PDF…") { appState.searchFocusRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Next Match") { appState.activeTab?.goToNextMatch() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.currentMatch == nil)
                Button("Previous Match") { appState.activeTab?.goToPreviousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
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
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil || appState.activeTab?.isSaving == true)
            }
            // View menu additions.
            CommandGroup(replacing: .saveItem) {
                Button("Save") { appState.saveActiveDocument() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true)
                Button("Save As…") { appState.saveActiveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.allowsSaveEdits != true || appState.isResolvingClose)
            }
            CommandMenu("Navigate") {
                Button("Previous View") { appState.navigateView(backward: true) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.viewHistory.canGoBack != true)
                Button("Next View") { appState.navigateView(backward: false) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab?.viewHistory.canGoForward != true)
                Divider()
                Button("Previous Page") { appState.navigatePage(.previous) }
                    .keyboardShortcut(.pageUp, modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || (appState.activeTab?.currentPage ?? 1) <= 1)
                Button("Next Page") { appState.navigatePage(.next) }
                    .keyboardShortcut(.pageDown, modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil
                              || (appState.activeTab?.currentPage ?? 1) >= (appState.activeTab?.pageCount ?? 1))
                Button("First Page") { appState.navigatePage(.first) }
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Last Page") { appState.navigatePage(.last) }
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Go to Page…") { appState.pageFocusRequest += 1 }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Divider()
                Button("Previous Document") { appState.cycleDocument(backward: true) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(!appState.documentWindowIsKey || appState.tabs.count < 2)
                Button("Next Document") { appState.cycleDocument(backward: false) }
                    .keyboardShortcut(.tab, modifiers: .control)
                    .disabled(!appState.documentWindowIsKey || appState.tabs.count < 2)
            }
            CommandGroup(after: .sidebar) {
                Button("All Tools") { appState.toggleAllTools() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Divider()
                Button("Zoom In") { appState.stepDocumentZoom(.in) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Zoom Out") { appState.stepDocumentZoom(.out) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
                Button("Actual Size") { appState.activeTab?.setZoom(1.0) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
            }
        }
        Settings {
            SettingsView()
                .environment(appState)
                .modifier(AppAppearanceModifier(preferences: appState.preferences))
        }
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
