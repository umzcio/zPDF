import SwiftUI

/// Action Wizard tool: saved actions (run on this document or a batch of
/// files), custom commands, and the document JavaScript inspector.
struct AutomationPanel: View {
    @Environment(AppState.self) private var appState
    @State private var store = ActionStore.shared
    @State private var commands = CustomCommandStore.shared
    @State private var available: Set<String> = []
    @State private var editing: SavedAction?
    @State private var batchAction: SavedAction?
    @State private var editingCommand: CustomCommand?
    @State private var showingJavaScript = false
    @State private var running: UUID?
    @State private var confirmDelete: SavedAction?

    private var tab: DocumentTab? { appState.activeTab }
    private var canEdit: Bool { tab?.allowsSaveEdits == true && tab?.editSource != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Actions") {
                ForEach(store.all) { action in actionRow(action) }
                Button {
                    editing = SavedAction(name: "New Action", details: "", steps: [])
                } label: { Label("New Action…", systemImage: "plus") }
                    .help("Build an action from zPDF's steps")
                PanelNote("Run an action on this document (one Undo step), or on files and folders to save processed copies in another folder. Source files are never changed.")
            }
            PanelSection(title: "Custom Commands") {
                if commands.commands.isEmpty {
                    Text("Save a single step, such as your standard watermark, as a one-click command in the tools list.")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                ForEach(commands.commands) { command in
                    HStack(spacing: 6) {
                        PanelRow(title: command.name, symbolName: command.symbol) { appState.runCustomCommand(command) }
                            .help(command.summary)
                            .disabled(tab == nil || (!canEdit && !isPrint(command)))
                        Menu {
                            Button("Edit…") { editingCommand = command }
                            Button("Delete", role: .destructive) { commands.remove(command.id) }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("Edit or delete “\(command.name)”")
                            .accessibilityLabel("Options for \(command.name)")
                    }
                }
                Menu {
                    Button("From a Step…") {
                        editingCommand = CustomCommand(name: "My Watermark", kind: .step(SavedAction.step("watermark")))
                    }
                    Menu("From a Print Preset") {
                        if PrintPresetStore.shared.names.isEmpty { Text("No print presets yet") }
                        ForEach(PrintPresetStore.shared.names, id: \.self) { name in
                            Button(name) { commands.save(CustomCommand(name: "Print: \(name)", kind: .printPreset(name))) }
                        }
                    }
                } label: { Label("New Custom Command", systemImage: "plus") }
                    .fixedSize()
            }
            PanelSection(title: "JavaScript") {
                PanelRow(title: "Document JavaScript…", symbolName: "curlybraces.square") { showingJavaScript = true }
                    .disabled(tab == nil)
                    .help("List, read and delete the scripts in this document")
                PanelNote("zPDF never runs document JavaScript. The inspector shows every script so you can review or remove it.")
            }
        }
        .task(id: tab?.id) { if let tab { available = await appState.availableOperations(in: tab) } }
        .sheet(item: $editing) { action in
            ActionEditorView(action: action, available: available) { store.save($0) }
        }
        .sheet(item: $batchAction) { action in
            BatchRunView(action: action)
        }
        .sheet(item: $editingCommand) { command in
            CustomCommandEditor(command: command, available: available) { commands.save($0) }
        }
        .sheet(isPresented: $showingJavaScript) {
            if let tab { JavaScriptInspectorView(tab: tab) }
        }
        .alert("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { if let action = confirmDelete { store.remove(action.id) } }
        }
    }

    private func isPrint(_ command: CustomCommand) -> Bool {
        if case .printPreset = command.kind { return true }
        return false
    }

    private func actionRow(_ action: SavedAction) -> some View {
        let missing = action.steps.contains { step in
            guard let definition = step.definition else { return true }
            return !available.isEmpty && !definition.requires.allSatisfy(available.contains)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: action.builtIn ? "wand.and.stars" : "gearshape.2")
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .accessibilityHidden(true)
                Text(action.name).font(.system(size: 12, weight: .medium))
                Spacer()
                if running == action.id { ProgressView().controlSize(.small) }
                Menu {
                    Button("Edit…") { editing = action.builtIn ? copy(of: action) : action }
                    if action.builtIn { Text("Built-in actions are copied before editing") }
                    Button("Duplicate") { store.save(copy(of: action)) }
                    if !action.builtIn { Button("Delete…", role: .destructive) { confirmDelete = action } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Edit, duplicate or delete this action")
                    .accessibilityLabel("Options for \(action.name)")
            }
            if !action.details.isEmpty {
                Text(action.details).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(action.steps.compactMap { $0.definition?.title }.joined(separator: " → "))
                .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(2)
            HStack {
                Button("Run on This Document") {
                    guard let tab else { return }
                    running = action.id
                    Task {
                        await appState.runAction(action, on: tab)
                        running = nil
                    }
                }
                .disabled(!canEdit || running != nil || missing || action.steps.isEmpty)
                .help("Apply every step to the open document as one Undo step")
                Button("Files…") { batchAction = action }
                    .disabled(missing || action.steps.isEmpty)
                    .help("Run on files or folders and save the results in an output folder")
            }
            .controlSize(.small)
            if missing {
                Text("Some steps aren't available in this version.").font(.system(size: 10.5)).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(DesignTokens.Colors.inset, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
    }

    private func copy(of action: SavedAction) -> SavedAction {
        SavedAction(name: action.name + (action.builtIn ? "" : " copy"), details: action.details,
                    steps: action.steps.map { ActionStep(kind: $0.kind, values: $0.values) })
    }
}
