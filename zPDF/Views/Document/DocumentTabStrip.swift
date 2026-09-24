//
//  DocumentTabStrip.swift
//  zPDF
//
//  Purpose: Document tabs hosted in the native window title bar:
//  one item per open tab with a close button, plus a "+" file-open button.
//  Phase: 1 — REAL. No TODOs.
//

import AppKit
import SwiftUI

struct DocumentTabStrip: View {
    @Environment(AppState.self) private var appState
    var availableWidth: CGFloat = 760

    private var tabsWidth: CGFloat {
        appState.tabs.reduce(0) { $0 + documentTabWidth(for: $1) }
            + CGFloat(max(0, appState.tabs.count - 1)) * 4
    }

    private var overflows: Bool {
        tabsWidth > availableWidth - 36
    }

    var body: some View {
        HStack(spacing: 3) {
            if !appState.tabs.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(appState.tabs) { tab in
                                TabItem(tab: tab, isActive: tab.id == appState.activeTabID
                                        && appState.railSelection == .document)
                                    .id(tab.id)
                            }
                        }
                    }
                    .onChange(of: appState.activeTabID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: availableWidth) { _, _ in
                        if let id = appState.activeTabID { proxy.scrollTo(id) }
                    }
                }
                .frame(width: min(tabsWidth,
                                  max(0, availableWidth - (overflows ? 64 : 36))))
            }

            if overflows {
                Menu {
                    ForEach(appState.tabs) { tab in
                        Button {
                            appState.selectTab(tab)
                        } label: {
                            Label(tab.displayName, systemImage: tab.id == appState.activeTabID
                                  ? "checkmark" : "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open documents")
                .accessibilityLabel("Open documents")
            }

            Button {
                appState.openFilePanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help("Open PDF (⌘O)")
            .accessibilityLabel("Open file")
        }
        .frame(height: 28)
    }
}

private struct TabItem: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Button {
                appState.selectTab(tab)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                    if tab.hasUnsavedChanges {
                        Circle().fill(Color.primary).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                    }
                    Text(tab.displayName)
                        .font(.system(size: 12))
                        .fontWeight(.regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help(tab.url?.path ?? tab.displayName)
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Button {
                appState.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help("Close \(tab.displayName) (⌘W)")
            .accessibilityLabel("Close \(tab.displayName)")
        }
        .padding(.horizontal, 12)
        .frame(width: documentTabWidth(for: tab), height: 28)
        .foregroundStyle(isActive ? DesignTokens.Colors.text : DesignTokens.Colors.mutedText)
        .background(isActive ? DesignTokens.Colors.inset : Color.clear)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7,
                                          bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0,
                                          topTrailingRadius: 7))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 7,
                                   bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: 7)
                .stroke(isActive ? DesignTokens.Colors.hairline : Color.clear, lineWidth: 1)
        )
    }
}

/// Match the displayed font, allowing room for the icon, close target, and
/// unsaved indicator. Long filenames truncate without stretching every tab.
@MainActor
private func documentTabWidth(for tab: DocumentTab) -> CGFloat {
    let titleWidth = (tab.displayName as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: 12)
    ]).width
    return min(200, max(110, ceil(titleWidth) + 80 + (tab.hasUnsavedChanges ? 13 : 0)))
}

#Preview {
    DocumentTabStrip()
        .environment(AppState())
}
