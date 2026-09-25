import SwiftUI

/// Comment menu: every comment tool (⌃⌘ shortcuts on the most used ones),
/// status for the selected comment, and review/interchange commands.
struct CommentCommands: Commands {
    let appState: AppState

    private var canEdit: Bool { appState.documentWindowIsKey && appState.activeTab?.allowsSaveEdits == true }
    private var hasDocument: Bool { appState.documentWindowIsKey && appState.activeTab != nil }

    var body: some Commands {
        CommandMenu("Comment") {
            ForEach(CommentPanelGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.tools) { tool in toolButton(tool) }
                }
            }
            Divider()
            let selected = appState.selectedCommentForPanel()
            Menu("Set Status") {
                ForEach(CommentStatus.allCases) { status in
                    Button(status.title) { if let selected { appState.setCommentStatus(status, for: selected) } }
                }
            }
            .disabled(!canEdit || selected == nil)
            Button(selected?.isMarked == true ? "Remove Checkmark" : "Add Checkmark") {
                if let selected { appState.setCommentMarked(!selected.isMarked, for: selected) }
            }
            .disabled(!canEdit || selected == nil)
            Button("Delete Selected Comment") { appState.deleteSelectedComment() }
                .disabled(!canEdit || selected == nil)
            Divider()
            Button(appState.comments.showsComments ? "Hide All Comments" : "Show All Comments") {
                appState.setCommentsVisible(!appState.comments.showsComments)
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])
            .disabled(!hasDocument)
            Button("Show Comment List") { appState.documentPanel = .comments }
                .disabled(!hasDocument)
            Divider()
            Button("Import Comments…") { Task { await appState.importComments() } }
                .disabled(!canEdit)
            Button("Export Comments as XFDF…") { Task { await appState.exportComments(format: "xfdf") } }
                .disabled(!hasDocument || appState.activeTab?.editSource == nil)
            Button("Export Comments as FDF…") { Task { await appState.exportComments(format: "fdf") } }
                .disabled(!hasDocument || appState.activeTab?.editSource == nil)
            Button("Summarize Comments…") { appState.summarizeComments(print: false) }
                .disabled(!hasDocument)
            Button("Print Comment Summary…") { appState.summarizeComments(print: true) }
                .disabled(!hasDocument)
            Button("Compare Comments…") { Task { await appState.compareComments() } }
                .disabled(!hasDocument || appState.activeTab?.editSource == nil)
            Button("Flatten Comments…") { Task { await appState.flattenComments() } }
                .disabled(!canEdit)
        }
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        let title = appState.armedAnnotationTool == tool ? "✓ \(tool.name)" : tool.name
        if let key = tool.shortcutKey {
            Button(title) { armFromMenu(tool) }
                .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .control])
                .disabled(!canEdit)
        } else {
            Button(title) { armFromMenu(tool) }
                .disabled(!canEdit)
        }
    }

    private func armFromMenu(_ tool: AnnotationTool) {
        if appState.activePanel != .comment { appState.openTool(.comment) }
        if appState.armedAnnotationTool != tool { appState.armCommentTool(tool) }
    }
}
