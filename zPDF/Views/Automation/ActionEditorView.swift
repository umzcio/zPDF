import SwiftUI
import UniformTypeIdentifiers

/// Edits an action: name, description and an ordered list of steps with
/// their parameters.
struct ActionEditorView: View {
    @State var action: SavedAction
    let available: Set<String>
    let onSave: (SavedAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    private var catalog: [StepDefinition] {
        StepCatalog.all.filter { available.isEmpty || $0.requires.allSatisfy(available.contains) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $action.name)
                TextField("Description", text: $action.details, prompt: Text("What this action does"))
            }
            .formStyle(.grouped)
            .frame(height: 120)
            HSplitView {
                stepList.frame(minWidth: 260, idealWidth: 280)
                stepDetail.frame(minWidth: 300)
            }
            Divider()
            HStack {
                Text("\(action.steps.count) step\(action.steps.count == 1 ? "" : "s")").foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Action") { onSave(action); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(action.name.trimmingCharacters(in: .whitespaces).isEmpty || action.steps.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 680, height: 560)
    }

    private var stepList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(action.steps.enumerated()), id: \.element.id) { index, step in
                    HStack {
                        Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .frame(width: 18).foregroundStyle(DesignTokens.Colors.mutedText)
                        Image(systemName: step.definition?.symbol ?? "questionmark").frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.definition?.title ?? "Unavailable step").font(.system(size: 12))
                            Text(step.summary).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                        }
                    }
                    .tag(step.id)
                }
                .onMove { action.steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { action.steps.remove(atOffsets: $0) }
            }
            .overlay {
                if action.steps.isEmpty {
                    ContentUnavailableView("No steps", systemImage: "list.bullet", description: Text("Add steps with the + menu below."))
                }
            }
            Divider()
            HStack(spacing: 2) {
                Menu {
                    ForEach(catalog) { definition in
                        Button { add(definition) } label: { Label(definition.title, systemImage: definition.symbol) }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Add a step")
                    .accessibilityLabel("Add a step")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    .help("Remove the selected step")
                    .accessibilityLabel("Remove step")
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(selection == nil).help("Move step up").accessibilityLabel("Move step up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).disabled(selection == nil).help("Move step down").accessibilityLabel("Move step down")
                Spacer()
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var stepDetail: some View {
        if let id = selection, let index = action.steps.firstIndex(where: { $0.id == id }), let definition = action.steps[index].definition {
            Form {
                Section {
                    Label(definition.title, systemImage: definition.symbol).font(.headline)
                    Text(definition.summary).foregroundStyle(DesignTokens.Colors.mutedText)
                    if definition.batchOnly {
                        Text("Applies only to files saved by a batch run.").font(.callout).foregroundStyle(.orange)
                    }
                }
                if !definition.parameters.isEmpty {
                    Section("Options") {
                        StepParametersForm(definition: definition, values: $action.steps[index].values)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a step", systemImage: "slider.horizontal.3", description: Text("Choose a step to change its options."))
        }
    }

    private func add(_ definition: StepDefinition) {
        let step = ActionStep(kind: definition.id, values: StepCatalog.defaults(for: definition))
        action.steps.append(step)
        selection = step.id
    }

    private func removeSelected() {
        action.steps.removeAll { $0.id == selection }
        selection = nil
    }

    private func move(_ delta: Int) {
        guard let index = action.steps.firstIndex(where: { $0.id == selection }) else { return }
        let target = index + delta
        guard action.steps.indices.contains(target) else { return }
        action.steps.swapAt(index, target)
    }
}

/// Parameter controls for one step.
struct StepParametersForm: View {
    let definition: StepDefinition
    @Binding var values: [String: StepValue]

    var body: some View {
        ForEach(definition.parameters) { parameter in
            control(parameter).help(parameter.help.isEmpty ? parameter.label : parameter.help)
        }
    }

    @ViewBuilder
    private func control(_ parameter: StepParameter) -> some View {
        switch parameter.kind {
        case .text(let prompt):
            TextField(parameter.label, text: Binding(get: { values[parameter.key]?.text ?? "" },
                                                     set: { values[parameter.key] = .text($0) }), prompt: Text(prompt))
        case .number(let range, let step, let suffix):
            Stepper("\(parameter.label): \(MeasureSession.format(values[parameter.key]?.number ?? parameter.defaultValue.number))\(suffix)",
                    value: Binding(get: { values[parameter.key]?.number ?? parameter.defaultValue.number },
                                   set: { values[parameter.key] = .number($0) }), in: range, step: step)
        case .toggle:
            Toggle(parameter.label, isOn: Binding(get: { values[parameter.key]?.flag ?? parameter.defaultValue.flag },
                                                  set: { values[parameter.key] = .flag($0) }))
        case .choice(let options):
            Picker(parameter.label, selection: Binding(get: { values[parameter.key]?.text ?? parameter.defaultValue.text },
                                                       set: { values[parameter.key] = .text($0) })) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
        }
    }
}

/// Creates or edits a single-step custom command.
struct CustomCommandEditor: View {
    @State var command: CustomCommand
    let available: Set<String>
    let onSave: (CustomCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $command.name)
                if case .step(let step) = command.kind {
                    Picker("Step", selection: Binding(get: { step.kind }, set: { kind in
                        if let definition = StepCatalog.definition(kind) {
                            command.kind = .step(ActionStep(kind: kind, values: StepCatalog.defaults(for: definition)))
                        }
                    })) {
                        ForEach(StepCatalog.all.filter { !$0.batchOnly && (available.isEmpty || $0.requires.allSatisfy(available.contains)) }) {
                            Text($0.title).tag($0.id)
                        }
                    }
                    if let definition = step.definition {
                        StepParametersForm(definition: definition, values: Binding(
                            get: { if case .step(let current) = command.kind { return current.values }; return [:] },
                            set: { values in if case .step(var current) = command.kind { current.values = values; command.kind = .step(current) } }))
                    }
                } else if case .printPreset(let name) = command.kind {
                    LabeledContent("Print preset", value: name)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Custom commands appear in All tools and can be pinned to the quick tools.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(command); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 480)
    }
}

/// Runs an action on chosen files/folders with progress, cancel and a report.
struct BatchRunView: View {
    let action: SavedAction
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var run = BatchRun()
    @State private var files: [URL] = []
    @State private var output: URL?
    @State private var suffix = " processed"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run “\(action.name)” on Files").font(.headline)
            Form {
                Section("Files") {
                    HStack {
                        Text(files.isEmpty ? "No files chosen" : "\(files.count) PDF\(files.count == 1 ? "" : "s")")
                        Spacer()
                        Button("Add Files or Folders…") { chooseFiles() }
                        if !files.isEmpty { Button("Clear") { files = [] } }
                    }
                    if !files.isEmpty {
                        Text(files.prefix(4).map(\.lastPathComponent).joined(separator: ", ") + (files.count > 4 ? ", …" : ""))
                            .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(2)
                    }
                    Button("Add Open Documents") {
                        files = BatchRun.collectPDFs(files + appState.tabs.compactMap(\.url))
                    }
                    .disabled(appState.tabs.isEmpty)
                }
                Section("Output") {
                    HStack {
                        Text(output?.path ?? "Choose a folder").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseOutput() }
                    }
                    TextField("Add to file names", text: $suffix)
                    Text("Existing files are never replaced; a number is added instead. Source files are not changed.")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
            .formStyle(.grouped)
            .disabled(run.running)
            if run.running || !run.results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: run.progress) {
                        Text(run.running ? "Processing \(run.current ?? "")…" : "Finished \(run.completed) of \(run.total)")
                            .font(.system(size: 11))
                    }
                    let failed = run.results.filter { !$0.succeeded }
                    if !run.running {
                        Text("\(run.results.count - failed.count) succeeded, \(failed.count) failed\(run.cancelled ? ", cancelled" : "").")
                            .font(.system(size: 11, weight: .medium))
                    }
                    List(run.results) { result in
                        HStack(alignment: .top) {
                            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.succeeded ? DesignTokens.Colors.readyGreen : .red)
                                .accessibilityLabel(result.succeeded ? "Succeeded" : "Failed")
                            VStack(alignment: .leading) {
                                Text(result.source.lastPathComponent).font(.system(size: 11.5))
                                if let message = result.message ?? result.note {
                                    Text(message).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 100)
                }
            }
            HStack {
                if let output, !run.running, !run.results.isEmpty {
                    Button("Show in Finder") {
                        let outputs = run.results.compactMap(\.output)
                        NSWorkspace.shared.activateFileViewerSelecting(outputs.isEmpty ? [output] : outputs)
                    }
                }
                Spacer()
                if run.running {
                    Button("Stop") { run.cancel() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Start") {
                        guard let output else { return }
                        run.start(action: action, files: files, output: output, suffix: suffix, preferences: appState.preferences,
                                  openTabs: appState.tabs)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || output == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .interactiveDismissDisabled(run.running)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose PDFs or Folders"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .folder]
        guard panel.runModal() == .OK else { return }
        files = BatchRun.collectPDFs(files + panel.urls)
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }
        output = panel.url
    }
}
