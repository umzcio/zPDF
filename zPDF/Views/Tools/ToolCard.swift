import SwiftUI

/// Compact catalog row; descriptions are available as hover and accessibility
/// help rather than making every action a multi-line card.
struct ToolCard: View {
    let tool: ToolID
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(isEnabled ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                    .frame(width: 24)
                Text(tool.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isEnabled ? DesignTokens.Colors.text : DesignTokens.Colors.mutedText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(hovering && isEnabled ? DesignTokens.Colors.inset : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .onHover { hovering = $0 }
        .help(tool.toolDescription)
        .accessibilityLabel(tool.name)
        .accessibilityHint(tool.toolDescription)
    }
}
