import SwiftUI

/// View, navigation-panel and document-information commands (menus composed
/// in zPDFApp). Shortcuts come from ShortcutStore so users can rebind them.
struct ViewCommands: Commands {
    let appState: AppState

    private var hasDocument: Bool { appState.documentWindowIsKey && appState.activeTab != nil }
    private var canEdit: Bool { appState.documentWindowIsKey && appState.activeTab?.allowsSaveEdits == true }

    var body: some Commands {
        CommandGroup(after: .printItem) {
            Divider()
            Button(AppCommandID.documentProperties.title) { appState.showDocumentProperties() }
                .zShortcut(.documentProperties)
                .disabled(!hasDocument)
        }
        CommandGroup(before: .toolbar) {
            pageDisplayMenu
            Divider()
        }
        CommandMenu("Bookmarks") {
            Button(AppCommandID.addBookmark.title) {
                appState.documentPanel = .bookmarks
                DispatchQueue.main.async { NotificationCenter.default.post(name: .zpdfAddBookmark, object: nil) }
            }
            .zShortcut(.addBookmark)
            .disabled(!canEdit)
            Divider()
            ForEach([DocumentPanel.bookmarks, .attachments, .layers, .destinations, .articles].filter(\.isImplemented)) { panel in
                Button("Show \(panel.title)") { appState.documentPanel = panel }
                    .disabled(!hasDocument)
            }
        }
    }

    @ViewBuilder
    private var pageDisplayMenu: some View {
        let tab = appState.activeTab
        let viewing = tab.map { appState.features.viewing(for: $0) }
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
