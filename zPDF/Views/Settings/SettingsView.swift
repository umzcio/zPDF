import SwiftUI

/// Identifies a Settings category. Features add categories by registering a
/// `SettingsSection` (see SettingsRegistry) — no edits to this view needed.
struct SettingsSectionID: Hashable, Identifiable, RawRepresentable {
    let rawValue: String
    var id: String { rawValue }
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let general = Self("general"), appearance = Self("appearance"), documents = Self("documents")
    static let display = Self("display"), fullScreen = Self("fullScreen"), units = Self("units")
    static let reading = Self("reading"), accessibility = Self("accessibility"), commenting = Self("commenting")
    static let forms = Self("forms"), identity = Self("identity"), measuring = Self("measuring")
    static let search = Self("search"), spelling = Self("spelling"), signatures = Self("signatures")
    static let security = Self("security"), print = Self("print"), tools = Self("tools"), keyboard = Self("keyboard")
}

/// One Settings category: sidebar entry, search keywords and its Form rows.
struct SettingsSection: Identifiable {
    let id: SettingsSectionID
    let title: String
    let symbol: String
    let keywords: String
    /// Sidebar order; built-in sections use multiples of 10.
    let order: Int
    let content: @MainActor (AppState) -> AnyView

    func matches(_ terms: [Substring]) -> Bool {
        terms.allSatisfy { (title + " " + keywords).localizedCaseInsensitiveContains(String($0)) }
    }
}

@MainActor
enum SettingsRegistry {
    private static var registered: [SettingsSection] = []

    /// Adds (or replaces) a category, e.g. from a feature's setup code.
    static func register(_ section: SettingsSection) {
        registered.removeAll { $0.id == section.id }
        registered.append(section)
    }

    static var sections: [SettingsSection] {
        var all = BuiltInSettings.sections
        for section in registered {
            all.removeAll { $0.id == section.id }
            all.append(section)
        }
        return all.sorted { $0.order < $1.order }
    }
}

/// Lets menus open Settings on a specific category.
@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var requested: SettingsSectionID?
    func request(_ id: SettingsSectionID) { requested = id }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appAccessibility) private var accessibility
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsSectionID? = .general
    @State private var query = ""
    @State private var showingReset = false

    private var sections: [SettingsSection] { SettingsRegistry.sections }

    private var matching: [SettingsSection] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return sections.filter { $0.id == (selection ?? .general) } }
        return sections.filter { $0.matches(terms) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search settings", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search settings")
                    .help("Find settings by name, such as zoom, units, voice or shortcuts.")
                    .padding(12)
                List(sections, selection: $selection) { section in
                    Label(section.title, systemImage: section.symbol).tag(section.id)
                }
                .onChange(of: selection) { _, _ in query = "" }
                .listStyle(.sidebar)
                .scrollContentBackground(accessibility.reduceTransparency ? .hidden : .automatic)
                .background {
                    if accessibility.reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                }
                .accessibilityLabel("Settings categories")
                Divider()
                Button("Restore Defaults…") { showingReset = true }
                    .tint(DesignTokens.Colors.accent)
                    .help("Reset zPDF preferences (recent files, identity and saved presets are kept). PDF files are not changed.")
                    .padding(12)
            }
            .frame(width: 200)
            Divider()
            if matching.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(matching) { section in
                        if !query.isEmpty {
                            Section { EmptyView() } header: {
                                Label(section.title, systemImage: section.symbol).font(.headline)
                            }
                        }
                        section.content(appState)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 560, idealHeight: 620)
        .onAppear { consumeRequest() }
        .onChange(of: SettingsNavigation.shared.requested) { _, _ in consumeRequest() }
        .onExitCommand {
            guard !showingReset else { return }
            dismiss()
        }
        .alert("Restore default settings?", isPresented: $showingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) {
                appState.preferences.reset()
                ShortcutStore.shared.resetAll()
            }
        } message: {
            Text("This resets zPDF preferences and keyboard shortcuts, and limits recent-file history to the 20 most recent entries. Your identity, print presets, actions, PDF files and open documents are kept.")
        }
    }

    private func consumeRequest() {
        if let requested = SettingsNavigation.shared.requested {
            selection = requested
            query = ""
            SettingsNavigation.shared.requested = nil
        }
    }
}
