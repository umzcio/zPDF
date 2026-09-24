import Foundation
import PDFKit

@MainActor
extension AppState {
    func startRecovery() async {
        guard !didStartRecovery else { return }
        didStartRecovery = true
        do {
            if recovery == nil { recovery = RecoveryCoordinator(store: RecoveryStore(directory: try RecoveryStore.defaultDirectory())) }
            await recovery?.load()
        } catch { recoveryWarning = error.localizedDescription; didStartRecovery = false }
    }

    func showRecovery() async {
        await startRecovery()
        await recovery?.load()
        for tab in tabs {
            if let item = recovery?.items.first(where: { $0.id == tab.recoveryID }) { recovery?.didRestore(item) }
        }
        recovery?.showingRecovery = true
    }

    /// A quiet checkpoint follows committed edits. It never ends field editing
    /// or takes the caret away just to serialize a recovery copy.
    func scheduleRecovery(for tab: DocumentTab) {
        guard let recovery, !tab.isSaving, !tab.isClosing else { return }
        checkpointTasks.removeValue(forKey: tab.id)?.cancel()
        guard tabs.contains(where: { $0 === tab }), tab.saveBlock == nil,
              !tab.saveChecking, !tab.hasUncommittedFieldEdit,
              tab.pdfDocument?.isEncrypted == false else { return }
        checkpointTasks[tab.id] = Task { [weak self, weak tab] in
            do {
                try await Task.sleep(for: .milliseconds(800))
                guard let self, let tab, !tab.isSaving, !tab.isClosing,
                      self.tabs.contains(where: { $0 === tab }),
                      !tab.hasUncommittedFieldEdit else { return }
                guard tab.hasUnsavedChanges else {
                    await recovery.discard(id: tab.recoveryID)
                    return
                }
                guard let source = tab.editSource, let baseline = tab.saveBaseline,
                      let document = tab.pdfDocument else { return }
                let changes = try baseline.changes(in: document)
                recovery.enqueue(RecoverySnapshot(id: tab.recoveryID, sourceURL: source.url,
                    sourceHash: source.hash, displayName: tab.displayName, changes: changes,
                    sourceLease: source))
            } catch is CancellationError { }
            catch { recovery.errorMessage = error.localizedDescription }
        }
    }

    func restoreRecovery(_ checkpoint: RecoveryCheckpoint) async -> Bool {
        guard let recovery, commitFieldEditing() else { return false }
        if let existing = tabs.first(where: { $0.recoveredCheckpointID == checkpoint.id }) {
            selectTab(existing)
            return true
        }
        guard let url = await recovery.validatedURL(for: checkpoint) else { return false }
        do {
            let info = try await NativeSaveBridge.inspect(url)
            guard info.sourceHash == checkpoint.sha256, info.writeBlock == nil else {
                throw RecoveryError(message: "This recovery copy cannot be safely edited. The checkpoint has been kept.")
            }
            let source = try await DocumentEditSource.capture(url, expectedHash: info.sourceHash)
            let document = try engine.openDocument(at: source.url)
            let baseline = try await SaveBaseline.capture(document)
            // The working input is leased independently of the checkpoint:
            // a newer checkpoint may replace/delete the published generation.
            let tab = DocumentTab(url: source.url, pdfDocument: document)
            tab.saveBaseline = baseline
            tab.editSource = source
            tab.sourceHash = info.sourceHash
            tab.recoveredName = checkpoint.displayName
            tab.recoveredCheckpointID = checkpoint.id
            tab.requiresSaveAs = true
            tab.hasUnsavedChanges = true
            applyReadingPreferences(to: tab)
            resetUndoHistory(tab)
            tabs.append(tab)
            selectTab(tab)
            return true
        } catch {
            recovery.errorMessage = error.localizedDescription
            return false
        }
    }
}
