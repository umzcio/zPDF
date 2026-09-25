import SwiftUI

// Shared building blocks for Fill & Sign, Prepare Form, Protect and
// Certificates. They extend PanelSection/PanelRow/PanelNote/PanelToolButton
// (InspectorHost.swift) so every panel aligns to the same grid and reads the
// same in light and dark appearance.

/// Full-width bordered action with a leading symbol; always has a tooltip.
struct PanelActionButton: View {
    let title: String
    let symbolName: String
    let help: String
    var prominent = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        let button = Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .controlSize(.regular)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        if prominent {
            button.buttonStyle(.borderedProminent).tint(DesignTokens.Colors.controlAccent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// Small borderless icon control used inside list rows.
struct PanelIconButton: View {
    let symbolName: String
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? Color.red : DesignTokens.Colors.mutedText)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Status summary: symbol, headline and detail on a tinted inset.
struct PanelStatusCard: View {
    enum Tone { case neutral, good, warning, bad }
    let symbolName: String
    let title: String
    var detail: String? = nil
    var tone: Tone = .neutral

    private var tint: Color {
        switch tone {
        case .neutral: DesignTokens.Colors.mutedText
        case .good: DesignTokens.Colors.readyGreen
        case .warning: Color.orange
        case .bad: Color.red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Instruction shown while a canvas tool is armed, with a Cancel control (Esc).
struct ArmedToolBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let tool = appState.signatureService.armedTool {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .accessibilityHidden(true)
                Text(tool.instruction)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignTokens.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { appState.signatureService.disarmPlacement() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop placing (Esc)")
            }
            .padding(8)
            .background(DesignTokens.Colors.accentTint)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Label on the left, control on the right, aligned across rows.
struct PanelFormRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .frame(width: 84, alignment: .leading)
            control()
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Section-level error text that stays readable in both appearances.
struct PanelErrorText: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Standard sheet chrome: title, subtitle, content, and a trailing button row.
struct FormsSheet<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 460
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            content()
                .padding(20)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                buttons()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: width)
        .tint(DesignTokens.Colors.accent)
    }
}

extension Color {
    init(components: [Double]?) {
        guard let c = components, !c.isEmpty else { self = .clear; return }
        if c.count == 1 { self = Color(white: c[0]) }
        else if c.count == 4 {
            self = Color(red: (1 - c[0]) * (1 - c[3]), green: (1 - c[1]) * (1 - c[3]), blue: (1 - c[2]) * (1 - c[3]))
        } else { self = Color(red: c[0], green: c[1], blue: c[2]) }
    }

    var components: [Double] {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Double($0) }
    }
}
