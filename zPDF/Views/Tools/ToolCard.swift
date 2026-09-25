import SwiftUI

/// Compact catalog row with a favorite star. Descriptions are available as
/// hover and accessibility help rather than making every row multi-line.
struct ToolCard: View {
    let tool: ToolID
    var isFavorite = false
    var toggleFavorite: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
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
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help(tool.toolDescription)
            .accessibilityLabel(tool.name)
            .accessibilityHint(tool.toolDescription)
            if let toggleFavorite {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavorite ? DesignTokens.Colors.starActive : DesignTokens.Colors.mutedText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .opacity(isFavorite || hovering ? 1 : 0)
                .help(isFavorite ? "Unpin \(tool.name) from the quick tools" : "Pin \(tool.name) to the quick tools beside the page")
                .accessibilityLabel(isFavorite ? "Unpin \(tool.name)" : "Pin \(tool.name)")
                .padding(.trailing, 4)
            }
        }
        .background(hovering && isEnabled ? DesignTokens.Colors.inset : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        .onHover { hovering = $0 }
    }
}

struct CustomCommandCard: View {
    let command: CustomCommand
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: command.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(isEnabled ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                    .frame(width: 24)
                Text(command.name).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(isEnabled ? DesignTokens.Colors.text : DesignTokens.Colors.mutedText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(hovering && isEnabled ? DesignTokens.Colors.inset : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .onHover { hovering = $0 }
        .help(command.summary)
        .accessibilityLabel(command.name)
        .accessibilityHint(command.summary)
    }
}
