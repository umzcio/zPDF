import SwiftUI

/// "Help for this tool" link that opens the in-app help page.
struct PanelHelpLink: View {
    let topic: String
    @Environment(AppState.self) private var appState

    var body: some View {
        Button { appState.features.helpTopic = HelpTopicID(topic) } label: {
            Label("Help for this tool", systemImage: "questionmark.circle").font(.system(size: 11))
        }
        .buttonStyle(.link)
        .help("Open zPDF Help for this tool")
    }
}
