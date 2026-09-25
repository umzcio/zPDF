import SwiftUI

/// Secondary scenes: Help, Advanced Search and additional document windows.
struct FeatureWindows: Scene {
    let appState: AppState

    var body: some Scene {
        Window("zPDF Help", id: "help") {
            HelpView()
                .environment(appState)
                .modifier(AppAppearanceModifier(preferences: appState.preferences))
        }
        .defaultSize(width: 860, height: 600)
        Window("Advanced Search", id: "advanced-search") {
            AdvancedSearchView()
                .environment(appState)
                .modifier(AppAppearanceModifier(preferences: appState.preferences))
        }
        .defaultSize(width: 680, height: 620)
        WindowGroup("Document", id: "document-window", for: UUID.self) { $tabID in
            DocumentWindowView(tabID: tabID)
                .environment(appState)
                .modifier(AppAppearanceModifier(preferences: appState.preferences))
                .frame(minWidth: 420, minHeight: 360)
        }
        .defaultSize(width: 760, height: 900)
    }
}
