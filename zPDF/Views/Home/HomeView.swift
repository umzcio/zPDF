//
//  HomeView.swift
//  zPDF
//
//  Purpose: Home screen — left filter column (Recent / Starred / Shared +
//  storage shortcuts), welcome header, Open File / Create PDF / Combine
//  Files actions, and the recent-files grid.
//  Phase: 1 — REAL, driven by RecentFilesStore.
//  TODO(phase-2): "Shared" filter and "Cloud storage" require an account
//  backend (phase 6); "View all" paging for >24 recents.
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            filterColumn
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xLarge) {
                    header
                    actionRow
                    recentSection
                }
                .padding(DesignTokens.Spacing.xxLarge)
            }
        }
    }

    // MARK: - Left filter column

    private var filterColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text("Files")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .textCase(.uppercase)
                .padding(.horizontal, DesignTokens.Spacing.small)
                .padding(.top, DesignTokens.Spacing.medium)

            ForEach([HomeFilter.recent, .starred]) { filter in
                FilterRow(filter: filter,
                          count: count(for: filter),
                          isActive: appState.homeFilter == filter) {
                    appState.homeFilter = filter
                }
            }

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
        .frame(width: DesignTokens.Layout.homeSidebarWidth)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func count(for filter: HomeFilter) -> Int? {
        switch filter {
        case .recent: appState.recentFiles.files.count
        case .starred: appState.recentFiles.starred.count
        case .shared: nil // TODO(phase-6): shared-file backend
        }
    }

    // MARK: - Main column

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text("Welcome back")
                .font(.system(size: 22, weight: .bold))
            Text("Pick up where you left off, or start something new.")
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }

    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Button {
                appState.openFilePanel()
            } label: {
                Label("Open File", systemImage: "doc")
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Colors.controlAccent)
            .help("Open a PDF (⌘O)")
            Button("Combine PDFs…") { appState.showingCombine = true }
                .help("Choose and arrange PDFs to combine into a new file")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack {
                Text(appState.homeFilter.title + " files")
                    .font(.system(size: 14, weight: .semibold))
                // TODO(phase-2): "View all" for large recents lists.
            }

            if filteredFiles.isEmpty {
                emptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: DesignTokens.Layout.recentCardMinWidth),
                                       spacing: DesignTokens.Spacing.large)],
                    spacing: DesignTokens.Spacing.large
                ) {
                    ForEach(filteredFiles) { file in
                        RecentFileCard(file: file)
                    }
                }
            }
        }
    }

    private var filteredFiles: [RecentFile] {
        switch appState.homeFilter {
        case .recent: appState.recentFiles.files
        case .starred: appState.recentFiles.starred
        case .shared: [] // TODO(phase-6): shared-file backend
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(DesignTokens.Colors.mutedText)
            Text(appState.homeFilter == .starred ? "No starred PDFs" : "No files yet")
                .font(.system(size: 12.5, weight: .medium))
            Text(appState.homeFilter == .starred ? "Star a recent PDF to find it here." : "Open a PDF and it will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.xxLarge)
    }
}

private struct FilterRow: View {
    let filter: HomeFilter
    let count: Int?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: filter.symbolName)
                Text(filter.title)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                }
            }
            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? DesignTokens.Colors.accent : DesignTokens.Colors.text)
            .padding(.horizontal, DesignTokens.Spacing.small)
            .frame(height: 30)
            .background(isActive ? DesignTokens.Colors.accentTint : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .help("Show \(filter.title.lowercased()) PDFs")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct StorageRow: View {
    let title: String
    let symbolName: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: symbolName)
            Text(title)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(DesignTokens.Colors.text)
        .padding(.horizontal, DesignTokens.Spacing.small)
        .frame(height: 30)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
