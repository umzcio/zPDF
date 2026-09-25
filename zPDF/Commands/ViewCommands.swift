import SwiftUI

/// View, window, sharing, print-area, search and help commands (composed in
/// zPDFApp). Shortcuts come from ShortcutStore so users can rebind them.
struct ViewCommands: Commands {
    let appState: AppState

    private var hasDocument: Bool { appState.documentWindowIsKey && appState.activeTab != nil }
    private var canEdit: Bool { appState.documentWindowIsKey && appState.activeTab?.allowsSaveEdits == true }
    private var viewing: DocumentViewingState? { appState.activeTab.map { appState.features.viewing(for: $0) } }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(AppCommandID.advancedSearch.title) { appState.features.showingAdvancedSearch = true }
                .zShortcut(.advancedSearch)
        }
        CommandGroup(before: .toolbar) {
            pageDisplayMenu
            zoomItems
            Divider()
            Toggle(AppCommandID.rulers.title, isOn: preference(\.showRulers)).zShortcut(.rulers)
            Toggle(AppCommandID.grid.title, isOn: preference(\.showGrid)).zShortcut(.grid)
            Toggle(AppCommandID.snapToGrid.title, isOn: preference(\.snapToGrid)).zShortcut(.snapToGrid)
            Toggle(AppCommandID.guides.title, isOn: preference(\.showGuides)).zShortcut(.guides)
            Button("Clear Guides on This Page") {
                guard let tab = appState.activeTab, let viewing else { return }
                viewing.horizontalGuides[tab.currentPage - 1] = nil
                viewing.verticalGuides[tab.currentPage - 1] = nil
            }
            .disabled(!hasDocument)
            Divider()
            Toggle(AppCommandID.loupe.title, isOn: viewingBinding(\.loupeActive)).zShortcut(.loupe).disabled(!hasDocument)
            Toggle(AppCommandID.panAndZoom.title, isOn: viewingBinding(\.panZoomActive)).zShortcut(.panAndZoom).disabled(!hasDocument)
            Toggle(AppCommandID.autoScroll.title, isOn: Binding(get: { appState.features.autoScroll.isActive },
                                                               set: { _ in appState.features.autoScroll.toggle(appState: appState) }))
                .zShortcut(.autoScroll).disabled(!hasDocument)
            Toggle(AppCommandID.reflow.title, isOn: viewingBinding(\.reflowActive)).zShortcut(.reflow).disabled(!hasDocument)
            Toggle(AppCommandID.readingOrder.title, isOn: viewingBinding(\.readingOrderOverlay)).zShortcut(.readingOrder)
                .disabled(!hasDocument)
            readAloudMenu
            Divider()
            Button(AppCommandID.fullScreenMode.title) { PresentationController.shared.toggle(appState: appState) }
                .zShortcut(.fullScreenMode)
                .disabled(!hasDocument)
            Divider()
        }
        CommandGroup(before: .windowList) {
            Menu(AppCommandID.splitView.title) {
                ForEach(SplitViewMode.allCases) { mode in
                    Toggle(mode.title, isOn: Binding(get: { viewing?.split == mode }, set: { if $0 { viewing?.split = mode } }))
                }
            }
            .disabled(!hasDocument)
            NewDocumentWindowButton(appState: appState)
            Divider()
        }
        CommandGroup(replacing: .help) {
            HelpMenuItems(appState: appState)
        }
    }

    // MARK: - Pieces

    private func preference(_ key: ReferenceWritableKeyPath<AppPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { appState.preferences[keyPath: key] }, set: { appState.preferences[keyPath: key] = $0 })
    }

    private func viewingBinding(_ key: ReferenceWritableKeyPath<DocumentViewingState, Bool>) -> Binding<Bool> {
        Binding(get: { viewing?[keyPath: key] ?? false }, set: { value in viewing?[keyPath: key] = value })
    }

    @ViewBuilder
    private var zoomItems: some View {
        Button(AppCommandID.fitPage.title) {
            if let tab = appState.activeTab, let view = appState.pdfViewStore.pdfView { ZoomController.fitPage(for: tab, in: view) }
        }
        .zShortcut(.fitPage)
        .disabled(!hasDocument)
        Button(AppCommandID.fitWidth.title) {
            if let tab = appState.activeTab, let view = appState.pdfViewStore.pdfView { ZoomController.fitWidth(for: tab, in: view) }
        }
        .zShortcut(.fitWidth)
        .disabled(!hasDocument)
    }

    @ViewBuilder
    private var readAloudMenu: some View {
        let reader = appState.features.readAloud
        Menu("Read Out Loud") {
            Button(AppCommandID.readAloudPage.title) { reader.start(.page, in: appState) }.zShortcut(.readAloudPage)
            Button(AppCommandID.readAloudToEnd.title) { reader.start(.toEnd, in: appState) }.zShortcut(.readAloudToEnd)
            Button(reader.isPaused ? "Resume" : "Pause") { reader.togglePause() }
                .zShortcut(.readAloudPause).disabled(!reader.isSpeaking)
            Button(AppCommandID.readAloudStop.title) { reader.stop() }.zShortcut(.readAloudStop).disabled(!reader.isSpeaking)
        }
        .disabled(!hasDocument)
    }

    @ViewBuilder
    private var pageDisplayMenu: some View {
        let tab = appState.activeTab
        let viewing = self.viewing
        Menu("Page Display") {
            Toggle(AppCommandID.singlePage.title, isOn: Binding(
                get: { tab?.viewMode == .single }, set: { if $0 { tab?.viewMode = .single } }))
                .zShortcut(.singlePage)
            Toggle(AppCommandID.continuous.title, isOn: Binding(
                get: { tab?.viewMode == .continuous }, set: { if $0 { tab?.viewMode = .continuous } }))
                .zShortcut(.continuous)
            Toggle(AppCommandID.twoPage.title, isOn: Binding(
                get: { tab?.viewMode == .facing }, set: { if $0 { tab?.viewMode = .facing } }))
                .zShortcut(.twoPage)
            Divider()
            Toggle(AppCommandID.coverPage.title, isOn: Binding(
                get: { viewing?.showsCoverPage ?? false },
                set: { value in
                    viewing?.showsCoverPage = value
                    if value, tab?.viewMode == .single || tab?.viewMode == .continuous { tab?.viewMode = .facing }
                }))
                .zShortcut(.coverPage)
        }
        .disabled(!hasDocument)
    }
}

/// Opens the active document in another window.
private struct NewDocumentWindowButton: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AppCommandID.newWindow.title) {
            if let tab = appState.activeTab { openWindow(id: "document-window", value: tab.id) }
        }
        .zShortcut(.newWindow)
        .disabled(!appState.documentWindowIsKey || appState.activeTab == nil)
    }
}

private struct HelpMenuItems: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("zPDF Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
        Button("Show Welcome Tour") { appState.features.showingOnboarding = true }
        Button("What's New in zPDF") { appState.features.showingWhatsNew = true }
        Divider()
        Button("Keyboard Shortcuts…") {
            SettingsNavigation.shared.request(.keyboard)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

extension ViewCommands {
    /// File-menu items that follow Print (SwiftUI drops `after: .printItem`
    /// for a single `Window` scene; zPDFApp places these in its Print group).
    @MainActor @ViewBuilder
    static func printMenuExtras(_ appState: AppState) -> some View {
        Button("Print Selected Area…") { appState.beginPrintAreaSelection() }
            .disabled(!(appState.documentWindowIsKey && appState.activeTab != nil))
        Divider()
        Menu("Share") {
            Button(AppCommandID.share.title) {
                if let tab = appState.activeTab { ShareService.share(tab, appState: appState) }
            }
            .zShortcut(.share)
            Button("Email…") {
                if let tab = appState.activeTab { ShareService.share(tab, appState: appState, service: .composeEmail) }
            }
            Button("AirDrop…") {
                if let tab = appState.activeTab { ShareService.share(tab, appState: appState, service: .sendViaAirDrop) }
            }
            Button("Copy Document") {
                if let tab = appState.activeTab { ShareService.copyToPasteboard(tab, appState: appState) }
            }
        }
        .disabled(!(appState.documentWindowIsKey && appState.activeTab != nil))
        Divider()
        Button(AppCommandID.documentProperties.title) { appState.showDocumentProperties() }
            .zShortcut(.documentProperties)
            .disabled(!(appState.documentWindowIsKey && appState.activeTab != nil))
    }
}
