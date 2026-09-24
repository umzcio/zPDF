import SwiftUI

/// Placeholder until this tool's workflow is implemented (see ToolID.isImplemented).
struct AutomationPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PanelNote("This tool is not available yet.")
    }
}
