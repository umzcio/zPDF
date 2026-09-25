import AppKit
import SwiftUI

/// Settings ▸ Keyboard Shortcuts: every customizable command, grouped, with
/// a key recorder, conflict warnings, per-command reset and Restore Defaults.
struct KeyboardShortcutSettings: View {
    @State private var store = ShortcutStore.shared
    @State private var filter = ""
    @State private var recording: AppCommandID?
    @State private var message: String?
    @State private var monitor: Any?

    private var categories: [String] {
        var seen: [String] = []
        for command in AppCommandID.allCases where !seen.contains(command.category) { seen.append(command.category) }
        return seen
    }

    private func commands(in category: String) -> [AppCommandID] {
        AppCommandID.allCases.filter { command in
            command.category == category && (filter.isEmpty || command.title.localizedCaseInsensitiveContains(filter)
                                             || (store.binding(for: command)?.displayText ?? "").localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        Section {
            TextField("Filter commands", text: $filter)
                .accessibilityLabel("Filter commands")
            if let message {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Text("Click a shortcut, then press the new keys. Press Delete to remove it or Esc to cancel.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button("Restore Defaults") { store.resetAll(); message = nil }
                    .disabled(!store.isCustomized)
            }
        }
        ForEach(categories, id: \.self) { category in
            let items = commands(in: category)
            if !items.isEmpty {
                Section(category) {
                    ForEach(items) { command in row(command) }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func row(_ command: AppCommandID) -> some View {
        let binding = store.binding(for: command)
        let customized = store.overrides[command] != nil
        return HStack {
            Text(command.title)
            if customized {
                Text("Custom").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DesignTokens.Colors.accentTint, in: Capsule())
                    .foregroundStyle(DesignTokens.Colors.accent)
            }
            Spacer()
            Button {
                recording == command ? stopRecording() : startRecording(command)
            } label: {
                Text(recording == command ? "Press keys…" : (binding?.displayText ?? "None"))
                    .font(.system(size: 12, design: .rounded))
                    .frame(minWidth: 96)
                    .foregroundStyle(binding == nil && recording != command ? DesignTokens.Colors.mutedText : DesignTokens.Colors.text)
            }
            .buttonStyle(.bordered)
            .tint(recording == command ? DesignTokens.Colors.accent : nil)
            .help(recording == command ? "Press the new shortcut, Delete to remove, or Esc to cancel" : "Change the shortcut for \(command.title)")
            .accessibilityLabel("Shortcut for \(command.title)")
            .accessibilityValue(binding?.displayText ?? "None")
            Button { store.reset(command); message = nil } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .disabled(!customized)
                .help("Restore the default shortcut (\(command.defaultBinding?.displayText ?? "none"))")
                .accessibilityLabel("Restore default for \(command.title)")
        }
    }

    private func startRecording(_ command: AppCommandID) {
        stopRecording()
        recording = command
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let local = event
            MainActor.assumeIsolated { handle(local, for: command) }
            return nil
        }
    }

    private func handle(_ event: NSEvent, for command: AppCommandID) {
        if event.keyCode == 53 { stopRecording(); return }
        if [51, 117].contains(event.keyCode) && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            store.set(nil, for: command)
            stopRecording()
            return
        }
        guard let binding = ShortcutBinding(event: event) else {
            message = "Shortcuts need ⌘ or ⌃ with another key."
            return
        }
        if store.isReserved(binding) {
            message = "\(binding.displayText) is reserved by macOS or standard editing."
            return
        }
        let conflicts = store.conflicts(for: binding, excluding: command)
        store.set(binding, for: command)
        message = conflicts.isEmpty ? nil : "\(binding.displayText) was removed from \(conflicts.map(\.title).joined(separator: ", "))."
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

/// Settings ▸ Tools: quick-tool favorites and custom commands.
struct ToolsSettings: View {
    let appState: AppState
    @State private var commands = CustomCommandStore.shared

    var body: some View {
        Section("Quick Tools") {
            let favorites = appState.preferences.favoriteTools.compactMap(ToolID.init(rawValue:)).filter(\.isImplemented)
            if favorites.isEmpty {
                Text("No pinned tools. Star a tool in All tools to pin it beside the page.").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(favorites) { tool in
                HStack {
                    Label(tool.name, systemImage: tool.symbolName)
                    Spacer()
                    Button { move(tool, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless).help("Move up").accessibilityLabel("Move \(tool.name) up")
                        .disabled(favorites.first == tool)
                    Button { move(tool, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless).help("Move down").accessibilityLabel("Move \(tool.name) down")
                        .disabled(favorites.last == tool)
                    Button { QuickTools.toggleFavorite(tool, preferences: appState.preferences) } label: { Image(systemName: "star.slash") }
                        .buttonStyle(.borderless).help("Unpin \(tool.name)").accessibilityLabel("Unpin \(tool.name)")
                }
            }
            Menu("Pin a Tool") {
                ForEach(ToolID.allCases.filter { $0.isImplemented && !favorites.contains($0) }) { tool in
                    Button(tool.name) { QuickTools.toggleFavorite(tool, preferences: appState.preferences) }
                }
            }
            .fixedSize()
        }
        Section("Custom Commands") {
            if commands.commands.isEmpty {
                Text("No custom commands. Create them in Action Wizard ▸ Custom Commands.").foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(commands.commands) { command in
                HStack {
                    Label(command.name, systemImage: command.symbol)
                    Spacer()
                    Text(command.summary).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                    Button("Delete", role: .destructive) { commands.remove(command.id) }
                }
            }
        }
    }

    private func move(_ tool: ToolID, by delta: Int) {
        var list = appState.preferences.favoriteTools
        guard let index = list.firstIndex(of: tool.rawValue) else { return }
        let target = index + delta
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        appState.preferences.favoriteTools = list
    }
}
