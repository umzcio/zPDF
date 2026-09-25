import SwiftUI

/// Menu commands owned by one feature area; composed in zPDFApp.
/// File ▸ Create PDF, File ▸ Export Pages as Images, and the Document menu
/// (pages, OCR, optimization, standards and comparison).
struct DocumentCommands: Commands {
    let appState: AppState

    private var editable: Bool {
        appState.documentWindowIsKey && appState.activeTab?.allowsSaveEdits == true && !appState.isResolvingClose
    }
    private var hasDocument: Bool { appState.documentWindowIsKey && appState.activeTab != nil }

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Pages as Images…") { appState.present(.exportImages) }
                .disabled(!hasDocument)
        }
        CommandMenu("Document") {
            Menu("Insert Pages") {
                Button("Blank Page…") { appState.present(.insertPages(.blank)) }
                    .keyboardShortcut("b", modifiers: [.command, .option]) // ⇧⌘B is Read to End (Acrobat)
                Button("From File…") { appState.present(.insertPages(.file)) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            .disabled(!editable)
            Button("Replace Pages…") { appState.present(.replacePages) }
                .disabled(!editable)
            Button("Duplicate Page") {
                if let tab = appState.activeTab { Task { await appState.duplicatePages([tab.currentPage - 1], in: tab) } }
            }
            .disabled(!editable)
            Button("Delete Page") {
                guard let tab = appState.activeTab else { return }
                do { try appState.deletePage(tab.currentPage - 1, in: tab) }
                catch { appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!editable || (appState.activeTab?.pageCount ?? 0) <= 1)
            Button("Extract Pages…") { appState.openTool(.organizePages) }
                .disabled(!editable)
            Menu("Rotate Pages") {
                Button("Current Page Clockwise") { rotate(current: true, 90) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Current Page Counterclockwise") { rotate(current: true, -90) }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                Divider()
                Button("All Pages Clockwise") { rotate(current: false, 90) }
                Button("All Pages Counterclockwise") { rotate(current: false, -90) }
            }
            .disabled(!editable)
            Button("Split Document…") { appState.present(.split) }
                .disabled(!editable)
            Divider()
            Button("Number Pages…") { appState.present(.pageLabels) }
                .disabled(!editable)
            Button("Set Page Boxes…") { appState.present(.pageBoxes) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!editable)
            Button("Change Page Size…") { appState.present(.resizePages) }
                .disabled(!editable)
            Button("Page Transitions…") { appState.present(.transitions) }
                .disabled(!editable)
            Divider()
            Button("Recognize Text (OCR)…") { appState.openTool(.scanAndOCR) }
                .disabled(!editable)
            Button("Optimize PDF…") { appState.openTool(.optimizePDF) }
                .disabled(!editable)
            Button("Standards & Preflight…") { appState.openTool(.archivePDFA) }
                .disabled(!editable)
            Button("Output Preview…") { appState.present(.outputPreview) }
                .disabled(!hasDocument)
            Divider()
            Button("Compare Files…") { appState.openTool(.compareFiles) }
                .disabled(!hasDocument)
        }
    }

    private func rotate(current: Bool, _ angle: Int) {
        guard let tab = appState.activeTab else { return }
        Task { await appState.rotatePages(current ? [tab.currentPage - 1] : nil, by: angle, in: tab) }
    }

    /// File ▸ Create PDF. SwiftUI drops `after: .newItem` groups for a single
    /// `Window` scene, so zPDFApp places this inside its File group.
    @MainActor @ViewBuilder
    static func createPDFMenu(_ appState: AppState) -> some View {
        Menu("Create PDF") {
            Button("From Files…") { appState.present(.createPDF(.files)) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("From Web Page…") { appState.present(.createPDF(.web)) }
            Button("From Clipboard") { Task { _ = await appState.createPDFFromClipboard() } }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("From Scanner…") { appState.present(.scanner) }
            Divider()
            Button("Blank PDF…") { appState.present(.createPDF(.blank)) }
            Button("PDF Portfolio…") { appState.present(.createPDF(.portfolio)) }
        }
        .disabled(appState.isResolvingClose)
    }
}
