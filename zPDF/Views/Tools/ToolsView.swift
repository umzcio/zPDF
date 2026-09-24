import SwiftUI

/// Document-side catalog. Availability follows the native Save workflow.
struct ToolsView: View {
    @Environment(AppState.self) private var appState

    @State private var lastTool: ToolID?
    @FocusState private var focusedTool: ToolID?

    var body: some View {
        Group {
            if appState.activePanel != nil {
                InspectorHost()
            } else {
                catalog
            }
        }
        .onExitCommand { appState.closeTools() }
        .onChange(of: appState.activePanel) { _, panel in
            if panel == nil { focusedTool = lastTool }
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("All tools").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { appState.closeTools() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .help("Close All tools")
                .accessibilityLabel("Close All tools")
            }
            .padding(12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ToolID.available) { tool in
                        ToolCard(tool: tool) {
                            lastTool = tool
                            appState.openTool(tool)
                        }
                            .focused($focusedTool, equals: tool)
                            .disabled(appState.activeTab == nil || (tool != .comment && appState.activeTab?.allowsSaveEdits != true))
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
