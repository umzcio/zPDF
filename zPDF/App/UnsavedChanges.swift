import AppKit
import PDFKit

enum UnsavedChoice { case save, discard, cancel }

@MainActor
extension AppState {
    func refreshUnsavedChanges(_ tab: DocumentTab) {
        guard let document = tab.pdfDocument, let baseline = tab.saveBaseline else { return }
        if !tab.hasUncommittedFieldEdit && !tab.isSaving { tab.undoHistory?.record() }
        do {
            let changes = try baseline.changes(in: document)
            let changed = tab.undoHistory?.hasChangesSinceSave
                ?? (!changes.fields.isEmpty || !changes.comments.isEmpty || !changes.notes.isEmpty || !changes.newFields.isEmpty || changes.pages != nil)
            tab.hasUnsavedChanges = tab.requiresSaveAs || tab.hasUncommittedFieldEdit || changed
        } catch {
            // An edit unsupported by Save is still unsaved work.
            tab.hasUnsavedChanges = true
        }
        scheduleRecovery(for: tab)
    }

    @discardableResult
    func commitFieldEditing() -> Bool {
        guard let view = pdfViewStore.pdfView,
              let tab = tabs.first(where: { $0.pdfDocument === view.document }) else { return true }
        guard view.window?.makeFirstResponder(nil) != false else { return false }
        tab.hasUncommittedFieldEdit = false
        refreshUnsavedChanges(tab)
        return true
    }

    func requestCloseAll(preserveSession: Bool = false, completion: @escaping (Bool) -> Void) {
        requestClose(tabs, preserveSession: preserveSession, completion: completion)
    }

    func requestClose(_ requested: [DocumentTab], preserveSession: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !isResolvingClose, commitFieldEditing() else { completion(false); return }
        let closing = requested.filter { candidate in tabs.contains { $0 === candidate } }
        isResolvingClose = true
        closing.forEach { $0.isClosing = true }
        Task {
            var allowed = true
            for tab in closing {
                // Don't offer Discard while a write may already be publishing.
                if tab.isSaving, await !saveDocument(tab).value { allowed = false; break }
                refreshUnsavedChanges(tab)
                guard tab.hasUnsavedChanges else { continue }
                let choice: UnsavedChoice
                if let closeDecision { choice = await closeDecision(tab) }
                else { choice = promptToSave(tab) }
                switch choice {
                case .cancel: allowed = false
                case .discard: break
                case .save: allowed = await saveDocument(tab).value
                }
                if !allowed { break }
            }
            // A cancelled multi-document quit keeps even previously approved
            // Discard tabs intact. Only successful saves clear their dirty state.
            if allowed {
                for tab in closing {
                    checkpointTasks.removeValue(forKey: tab.id)?.cancel()
                    if let recovery { await recovery.discard(id: tab.recoveryID) }
                }
                if preserveSession { persistOpenSession(); restoringSession = true }
                closing.forEach { removeClosedTab($0) }
                if preserveSession { restoringSession = false }
            }
            closing.forEach { $0.isClosing = false }
            if !allowed { closing.forEach { scheduleRecovery(for: $0) } }
            isResolvingClose = false
            completion(allowed)
        }
    }

    private func promptToSave(_ tab: DocumentTab) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(tab.displayName)” before closing?"
        alert.informativeText = "Your changes will be lost if you discard them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
