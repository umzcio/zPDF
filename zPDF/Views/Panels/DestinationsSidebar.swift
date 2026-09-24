import SwiftUI

/// Placeholder until this sidebar panel is implemented (see DocumentPanel.isImplemented).
struct DestinationsSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState

    var body: some View {
        Text("Not available yet.").font(.system(size: 11)).padding()
    }
}
