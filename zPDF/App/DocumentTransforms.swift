import Foundation
import PDFKit

/// Native whole-document edits (redaction, watermarks, page content, security...).
/// Each applies pending on-screen edits plus the operation to the current
/// editing revision, reloads the result, and is one Undo step. The user's
/// file is only replaced by Save.
@MainActor
extension AppState {
    @discardableResult
    func applyDocumentTransform(_ ops: [[String: Any]], to tab: DocumentTab,
                                actionName: String) async throws -> [NativeJSON] {
        guard tab.allowsSaveEdits, saves[tab.id] == nil, !isResolvingClose else {
            throw NativeSaveError(code: "BUSY", message: "Wait for the current operation on this document to finish.")
        }
        guard commitFieldEditing(), let document = tab.pdfDocument, let baseline = tab.saveBaseline,
              let source = tab.editSource else {
            throw NativeSaveError(code: "NOT_EDITABLE", message: "This document can't be edited. Open a supported, unencrypted PDF first.")
        }
        tab.undoHistory?.record()
        let changes = try baseline.changes(in: document)
        tab.isSaving = true
        tab.operationLabel = actionName
        defer {
            tab.isSaving = false
            tab.operationLabel = nil
        }
        let output = try await NativeDocumentBridge.transform(source: source.url, hash: source.hash,
                                                              changes: changes, ops: NativeOps(ops))
        let revision = try await DocumentEditSource.adopt(output, name: source.url.lastPathComponent)
        let reloaded = try engine.openDocument(at: revision.url)
        let newBaseline = try await SaveBaseline.capture(reloaded)
        let page = tab.currentPage
        tab.pdfDocument = reloaded
        tab.saveBaseline = newBaseline
        tab.editSource = revision
        tab.pageRevision += 1
        tab.goToPage(page)
        tab.undoHistory?.record(name: actionName)
        tab.isSaving = false
        refreshUnsavedChanges(tab)
        tab.updateSearchResults()
        noteAnnotationsChanged()
        return output.results
    }

    /// Read-only inspection of the current revision including pending edits.
    func queryDocument(_ name: String, params: [String: Any] = [:], in tab: DocumentTab) async throws -> NativeJSON {
        guard let source = tab.editSource else {
            throw NativeSaveError(code: "NOT_EDITABLE", message: "This document isn't ready yet.")
        }
        return try await NativeDocumentBridge.query(source: source.url, hash: source.hash, name: name, params: NativeJSON(value: params))
    }

    /// Runs a transform and reports failures in the standard alert.
    func runDocumentTransform(_ ops: [[String: Any]], actionName: String, in tab: DocumentTab? = nil,
                              completion: (([NativeJSON]) -> Void)? = nil) {
        guard let tab = tab ?? activeTab else { return }
        Task {
            do {
                let results = try await applyDocumentTransform(ops, to: tab, actionName: actionName)
                completion?(results)
            } catch {
                saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            }
        }
    }
}
