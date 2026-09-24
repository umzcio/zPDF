import SwiftUI

/// Supported canvas actions stay beside the page whether the tools drawer is
/// open or closed. The gutter reserves space so controls never cover PDF text.
struct DocumentQuickTools: View {
    @Environment(AppState.self) private var appState

    private var canEdit: Bool { appState.activeTab?.allowsSaveEdits == true }
    private var isSelecting: Bool {
        appState.armedAnnotationTool == nil && appState.armedFormFieldTool == nil
            && !appState.textEditingModeActive && appState.signatureService.armedSignature == nil
    }

    var body: some View {
        VStack(spacing: 4) {
            tool("Select text", symbol: "cursorarrow", selected: isSelecting,
                 help: "Select text", hint: "Stop adding annotations and select text on the page.", action: appState.selectDocumentText)
            tool("Sticky note", symbol: "text.bubble", selected: appState.armedAnnotationTool == .stickyNote,
                 help: appState.armedAnnotationTool == .stickyNote ? "Cancel sticky note" : "Add sticky note",
                 hint: "Click the page to place a note.") {
                appState.useQuickAnnotation(.stickyNote)
            }.disabled(!canEdit)
            tool("Highlight text", symbol: "highlighter", selected: appState.armedAnnotationTool == .highlight,
                 help: appState.armedAnnotationTool == .highlight ? "Stop highlighting" : "Highlight text",
                 hint: "Apply to selected text, or drag across text on the page.") {
                appState.useQuickAnnotation(.highlight)
            }.disabled(!canEdit)
            tool("Underline text", symbol: "underline", selected: appState.armedAnnotationTool == .underline,
                 help: appState.armedAnnotationTool == .underline ? "Stop underlining" : "Underline text",
                 hint: "Apply to selected text, or drag across text on the page.") {
                appState.useQuickAnnotation(.underline)
            }.disabled(!canEdit)
            Divider().padding(.horizontal, 5)
            tool("Fill forms", symbol: "list.bullet.rectangle", selected: appState.activePanel == .fillSign,
                 help: "Fill form fields") {
                appState.openTool(.fillAndSign)
            }.disabled(!canEdit)
            tool("More tools", symbol: "ellipsis", selected: false,
                 help: "All tools (⌃⌘S)", action: appState.showAllTools)
        }
        .padding(5)
        .frame(width: 44)
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick tools")
    }

    private func tool(_ title: String, symbol: String, selected: Bool,
                      help: String, hint: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Color.white : DesignTokens.Colors.text)
                .background(selected ? DesignTokens.Colors.controlAccent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(hint.isEmpty ? help : hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
