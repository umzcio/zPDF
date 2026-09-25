import SwiftUI

/// Searchable help window (Help ▸ zPDF Help).
struct HelpView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var selection: HelpTopicID? = HelpCatalog.gettingStarted

    private var topics: [HelpTopic] {
        let all = HelpCatalog.topics
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? all : all.filter { $0.matches(query) }
    }

    private var categories: [String] {
        var seen: [String] = []
        for topic in topics where !seen.contains(topic.category) { seen.append(topic.category) }
        return seen
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(categories, id: \.self) { category in
                    Section(category) {
                        ForEach(topics.filter { $0.category == category }) { topic in
                            Label(topic.title, systemImage: topic.symbol).tag(topic.id)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search help")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .overlay {
                if topics.isEmpty { ContentUnavailableView.search(text: query) }
            }
        } detail: {
            if let id = selection, let topic = HelpCatalog.topic(id) {
                HelpPage(topic: topic)
            } else {
                ContentUnavailableView("Choose a help topic", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: appState.features.helpTopic) { _, topic in
            if let topic { selection = topic; appState.features.helpTopic = nil }
        }
        .onAppear {
            if let topic = appState.features.helpTopic { selection = topic; appState.features.helpTopic = nil }
        }
        .onChange(of: query) { _, _ in
            if let selection, !topics.contains(where: { $0.id == selection }) { self.selection = topics.first?.id }
        }
    }
}

private struct HelpPage: View {
    let topic: HelpTopic
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: topic.symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(DesignTokens.Colors.accent)
                        .frame(width: 44, height: 44)
                        .background(DesignTokens.Colors.accentTint, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(topic.summary).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                }
                ForEach(Array(topic.body.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                }
                if !topic.shortcuts.isEmpty {
                    Text("Shortcuts").font(.headline).padding(.top, 4)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        ForEach(Array(topic.shortcuts.enumerated()), id: \.offset) { _, shortcut in
                            GridRow {
                                Text(shortcut.0)
                                Text(shortcut.1).font(.system(.body, design: .monospaced)).foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                        }
                    }
                    Text("Shortcuts can be changed in Settings ▸ Keyboard Shortcuts.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                if let tool = topic.tool, tool.isImplemented {
                    Button("Open \(tool.name)") { appState.openTool(tool) }
                        .disabled(appState.activeTab == nil)
                        .help(appState.activeTab == nil ? "Open a document first" : "Show the \(tool.name) tool")
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

/// First-run tour (Help ▸ Show Welcome Tour reopens it).
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private let steps: [(String, String, String)] = [
        ("doc.richtext", "Welcome to zPDF", "Open, read, review and edit PDFs. Your file changes only when you save — every edit can be undone."),
        ("square.grid.2x2", "All your tools in one place", "Press ⌃⌘S or click All tools to see every tool. Star a tool to pin it next to the page."),
        ("sidebar.right", "Panels on the right", "Pages, bookmarks, attachments, layers and more open from the rail on the right edge."),
        ("magnifyingglass", "Find anything", "⌘F searches this document. Advanced Search (⇧⌘F) searches folders, bookmarks, comments and attachments."),
        ("gearshape", "Make it yours", "Settings (⌘,) has page display, identity, measuring, accessibility and keyboard shortcut options. Help is always in the Help menu.")
    ]

    var body: some View {
        VStack(spacing: 18) {
            let current = steps[step]
            Image(systemName: current.0)
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Colors.accent)
                .frame(height: 60)
                .accessibilityHidden(true)
            Text(current.1).font(.title2.weight(.semibold))
            Text(current.2)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle().fill(index == step ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of \(steps.count)")
            HStack {
                Button("Skip Tour") { finish() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == steps.count - 1 ? "Get Started" : "Next") {
                    if step == steps.count - 1 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.controlAccent)
            }
        }
        .padding(28)
        .frame(width: 480, height: 360)
    }

    private func finish() {
        appState.preferences.hasCompletedOnboarding = true
        appState.preferences.lastSeenWhatsNew = WhatsNew.version
        dismiss()
    }
}

struct WhatsNewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's New in zPDF").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(WhatsNew.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.0).font(.system(size: 18)).foregroundStyle(DesignTokens.Colors.accent)
                                .frame(width: 26).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.1).font(.headline)
                                Text(item.2).foregroundStyle(DesignTokens.Colors.mutedText).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            HStack {
                Toggle("Show after updates", isOn: Binding(get: { appState.preferences.showWhatsNewAfterUpdates },
                                                             set: { appState.preferences.showWhatsNewAfterUpdates = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Continue") {
                    appState.preferences.lastSeenWhatsNew = WhatsNew.version
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.controlAccent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
    }
}
