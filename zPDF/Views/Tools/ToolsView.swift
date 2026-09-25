import SwiftUI

/// All tools: every available tool grouped like Acrobat, searchable, with
/// favorites (star) pinned to the quick tools beside the page, plus the
/// user's custom commands. The list is built from `ToolID.isImplemented`.
struct ToolsView: View {
    @Environment(AppState.self) private var appState

    @State private var lastTool: ToolID?
    @State private var query = ""
    @FocusState private var focusedTool: ToolID?
    @FocusState private var searchFocused: Bool

    private var tools: [ToolID] {
        ToolID.available.filter { query.isEmpty || $0.matches(query) }
    }

    private var groups: [ToolGroup] {
        ToolGroup.allCases.filter { group in tools.contains { $0.group == group } }
    }

    private var commands: [CustomCommand] {
        CustomCommandStore.shared.commands.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

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
            .padding(.horizontal, 12)
            .padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                TextField("Find a tool", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .accessibilityLabel("Find a tool")
                    .onSubmit { if let first = tools.first { run(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DesignTokens.Colors.mutedText) }
                        .buttonStyle(.plain).help("Clear").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(DesignTokens.Colors.inset, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(DesignTokens.Colors.mutedText)
                                .textCase(.uppercase)
                                .padding(.horizontal, 10)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(tools.filter { $0.group == group }) { tool in
                                ToolCard(tool: tool, isFavorite: isFavorite(tool),
                                         toggleFavorite: { QuickTools.toggleFavorite(tool, preferences: appState.preferences) }) {
                                    run(tool)
                                }
                                .focused($focusedTool, equals: tool)
                                .disabled(!canUse(tool))
                            }
                        }
                    }
                    if !commands.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom Commands")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(DesignTokens.Colors.mutedText)
                                .textCase(.uppercase)
                                .padding(.horizontal, 10)
                            ForEach(commands) { command in
                                CustomCommandCard(command: command) { appState.runCustomCommand(command) }
                                    .disabled(appState.activeTab == nil)
                            }
                        }
                    }
                    if groups.isEmpty && commands.isEmpty {
                        Text("No tools match “\(query)”.")
                            .font(.system(size: 11.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func isFavorite(_ tool: ToolID) -> Bool { appState.preferences.favoriteTools.contains(tool.rawValue) }

    private func canUse(_ tool: ToolID) -> Bool {
        guard appState.activeTab != nil else { return false }
        return QuickTools.worksReadOnly(tool) || appState.activeTab?.allowsSaveEdits == true
    }

    private func run(_ tool: ToolID) {
        guard canUse(tool) else { return }
        lastTool = tool
        QuickTools.run(tool, appState: appState)
    }
}

extension ToolID {
    func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let haystack = (name + " " + toolDescription + " " + group.title).lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

/// Favorites pinned to the quick tools and shared tool launching rules.
@MainActor
enum QuickTools {
    static func toggleFavorite(_ tool: ToolID, preferences: AppPreferences) {
        var list = preferences.favoriteTools
        if let index = list.firstIndex(of: tool.rawValue) { list.remove(at: index) } else { list.append(tool.rawValue) }
        preferences.favoriteTools = list
    }

    /// Tools that don't edit the document work on read-only files too.
    static func worksReadOnly(_ tool: ToolID) -> Bool { tool == .comment || tool == .share }

    static func run(_ tool: ToolID, appState: AppState) {
        if tool == .share {
            if let tab = appState.activeTab { ShareService.share(tab, appState: appState) }
            return
        }
        appState.openTool(tool)
    }
}

/// Pinned favorites shown in the quick tools beside the page.
struct FavoriteQuickTools: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let favorites = appState.preferences.favoriteTools.compactMap(ToolID.init(rawValue:)).filter { $0.isImplemented }
        if !favorites.isEmpty {
            Divider().padding(.horizontal, 5)
            ForEach(favorites) { tool in
                let selected = tool.inspectorPanel != nil && appState.activePanel == tool.inspectorPanel
                Button { QuickTools.run(tool, appState: appState) } label: {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 17))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(selected ? Color.white : DesignTokens.Colors.text)
                        .background(selected ? DesignTokens.Colors.controlAccent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .help(tool.name)
                .accessibilityLabel(tool.name)
                .accessibilityHint(tool.toolDescription)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .disabled(appState.activeTab == nil || (!QuickTools.worksReadOnly(tool) && appState.activeTab?.allowsSaveEdits != true))
                .contextMenu {
                    Button("Unpin from Quick Tools") { QuickTools.toggleFavorite(tool, preferences: appState.preferences) }
                }
            }
        }
    }
}
