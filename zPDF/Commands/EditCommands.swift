import SwiftUI

/// Edit PDF and Redact menu commands (Edit menu); composed in zPDFApp.
struct EditCommands: Commands {
    let appState: AppState

    private var canEdit: Bool {
        appState.documentWindowIsKey && appState.activeTab?.allowsSaveEdits == true && !appState.isResolvingClose
    }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Menu("Edit PDF") {
                Button("Edit Text & Images") { open(.edit, tool: .edit) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Add Text") { open(.edit, tool: .addText) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Add Image…") { openPanel(.edit); appState.contentEditing.beginAddImage() }
                Button("Add or Edit Link") { open(.edit, tool: .link) }
                Button("Crop Pages") { open(.edit, tool: .crop) }
                Divider()
                Button("Find and Replace…") {
                    openPanel(.edit)
                    appState.contentEditing.findRequest += 1
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                ForEach(PageDesignKind.allCases) { kind in
                    Button(kind.title + "…") {
                        openPanel(.edit)
                        appState.contentEditing.designRequest = kind
                    }
                }
            }
            .disabled(!canEdit)
            Menu("Redact") {
                Button("Mark Text & Areas for Redaction") { open(.redact, tool: .redact) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Mark Current Page for Redaction") {
                    openPanel(.redact)
                    appState.contentEditing.markPages(.current)
                }
                Divider()
                Button("Apply Redactions") {
                    openPanel(.redact)
                    appState.contentEditing.applyRedactions()
                }
                .disabled(appState.contentEditing.marks().isEmpty)
                Button("Remove Hidden Information…") {
                    openPanel(.redact)
                    appState.contentEditing.sanitizeRequest += 1
                }
            }
            .disabled(!canEdit)
        }
    }

    private func openPanel(_ panel: InspectorPanel) {
        let tool: ToolID = panel == .redact ? .redact : .editPDF
        if appState.activePanel != panel { appState.openTool(tool) }
    }

    private func open(_ panel: InspectorPanel, tool: CanvasTool) {
        openPanel(panel)
        appState.contentEditing.activate(tool)
    }
}
