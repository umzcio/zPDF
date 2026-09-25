//
//  InspectorHost.swift
//  zPDF
//
//  Purpose: Tool detail inside the shared document sidebar. Hosts a header (panel title +
//  close button) and switches the body on AppState.activePanel across the
//  seven panels. Also defines the shared PanelSection / PanelRow /
//  PanelNote / PanelToolButton building blocks used by every panel.
//  Phase: 1 — REAL container; panel bodies vary by phase.
//

import SwiftUI

struct InspectorHost: View {
    @Environment(AppState.self) private var appState

    @FocusState private var backFocused: Bool

    var body: some View {
        if let panel = appState.activePanel {
            VStack(spacing: 0) {
                header(for: panel)
                Divider()
                ScrollView {
                    panelContent(for: panel)
                        .padding(DesignTokens.Spacing.medium)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { backFocused = true }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }
    }

    private func header(for panel: InspectorPanel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { appState.showAllTools() } label: {
                    Label("Back to all tools", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .focused($backFocused)
                .help("Back to all tools")
                Spacer()
                Button { appState.closeTools() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .help("Close tool controls")
                .accessibilityLabel("Close tool controls")
            }
            Text(panel.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private func panelContent(for panel: InspectorPanel) -> some View {
        switch panel {
        case .edit:
            EditPanel()
        case .comment:
            CommentPanel(showsComments: false)
        case .fillSign:
            FillSignPanel()
        case .export:
            ExportPanel()
        case .protect:
            ProtectPanel()
        case .organize:
            OrganizePagesPanel()
        case .prepareForm:
            PrepareFormPanel()
        case .redact:
            RedactPanel()
        case .sign:
            SignPanel()
        case .createPDF:
            CreatePDFPanel()
        case .scanOCR:
            ScanOCRPanel()
        case .optimize:
            OptimizePanel()
        case .compare:
            ComparePanel()
        case .measure:
            MeasurePanel()
        case .accessibility:
            AccessibilityPanel()
        case .standards:
            StandardsPanel()
        case .automation:
            AutomationPanel()
        }
    }
}

// MARK: - Shared panel components

/// Titled section wrapper ("FORMAT", "CONTENT", …) matching the prototype's
/// .rp-sec blocks.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .textCase(.uppercase)
            content()
        }
    }
}

/// Icon + label row matching the prototype's .rp-row.
struct PanelRow: View {
    let title: String
    let symbolName: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.text)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
    }
}

/// Muted explanation box matching the prototype's .rp-note.
struct PanelNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(DesignTokens.Colors.mutedText)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(DesignTokens.Colors.inset)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                    .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
            )
    }
}

/// Small bordered icon button used in the two-column tool grids
/// ("Add annotation", "Add field") — prototype .rp-tool.
struct PanelToolButton: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.system(size: 17))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(isActive ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
            .background(DesignTokens.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                    .stroke(isActive ? DesignTokens.Colors.accent.opacity(0.5)
                                     : DesignTokens.Colors.hairline,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Two-column grid layout shared by the tool grids in the panels.
struct PanelToolGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)],
                  spacing: 6) {
            content()
        }
    }
}
