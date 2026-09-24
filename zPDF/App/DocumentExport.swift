import AppKit
import PDFKit

enum DocumentExportKind {
    case combine, split(Int), compress
    var title: String {
        switch self { case .combine: "Combine PDFs"; case .split: "Split PDF"; case .compress: "Compress PDF" }
    }
}

@MainActor
extension AppState {
    /// All inputs are pinned before a dialog or suspension. Existing Save jobs
    /// own the lifetime, so close/quit cannot discard an export in progress.
    @discardableResult
    func exportDocuments(_ kind: DocumentExportKind, tabs selected: [DocumentTab],
                         destination: SaveDestination? = nil) -> Task<Bool, Never> {
        let inputs: [NativeSaveBridge.Input]
        do {
            guard !selected.isEmpty, Set(selected.map(\.id)).count == selected.count,
                  selected.allSatisfy({ candidate in
                      tabs.contains { $0 === candidate } && candidate.allowsSaveEdits && saves[candidate.id] == nil
                  }),
                  !isResolvingClose, commitFieldEditing() else {
                throw NativeSaveError(code: "EDIT_BLOCKED", message: "Wait until all selected PDFs are ready.")
            }
            switch kind {
            case .combine:
                guard selected.count >= 2 else { throw NativeSaveError(code: "MISSING_INPUT", message: "Choose at least two PDFs.") }
            case .split(let interval):
                guard selected.count == 1, interval > 0 else { throw NativeSaveError(code: "INVALID_RANGE", message: "Choose a positive split interval.") }
            case .compress:
                guard selected.count == 1 else { throw NativeSaveError(code: "INVALID_INPUT", message: "Choose one PDF to compress.") }
            }
            inputs = try selected.map {
                guard let url = $0.url, let hash = $0.sourceHash, let document = $0.pdfDocument, let baseline = $0.saveBaseline else {
                    throw NativeSaveError(code: "DOCUMENT_NOT_READY", message: "Open the source PDF first.")
                }
                return .init(url: $0.editSource?.url ?? url, hash: $0.editSource?.hash ?? hash,
                             changes: try baseline.changes(in: document),
                             sourceGuard: $0.editSource == nil ? nil : NativeSourceGuard(url: url, hash: hash))
            }
        } catch {
            saveError = OpenError(fileName: kind.title, message: error.localizedDescription)
            return Task { false }
        }
        selected.forEach { $0.isSaving = true; $0.operationLabel = kind.title + "…" }
        saveError = nil
        exportMessage = nil
        exportedURL = nil
        let task = Task { () -> Bool in
            defer {
                selected.forEach {
                    $0.isSaving = false; $0.operationLabel = nil
                    saves[$0.id] = nil; saveDestinations[$0.id] = nil
                    refreshUnsavedChanges($0)
                }
            }
            do {
                guard let target = destination ?? chooseExportDestination(kind, source: inputs[0].displayURL) else { return false }
                guard !tabs.contains(where: { tab in tab.url.map { SaveDestination.sameFile($0, target.url) } == true }),
                      !saveDestinations.values.contains(where: { SaveDestination.sameFile($0, target.url) }) else {
                    throw NativeSaveError(code: "DESTINATION_OPEN", message: "Choose a new destination that is not open or being saved.")
                }
                if case .split = kind, FileManager.default.fileExists(atPath: target.url.path) {
                    throw NativeSaveError(code: "DESTINATION_EXISTS", message: "Choose a new folder name for the split PDFs. Existing folders are not replaced.")
                }
                selected.forEach { saveDestinations[$0.id] = target.url }
                let access = target.url.startAccessingSecurityScopedResource()
                defer { if access { target.url.stopAccessingSecurityScopedResource() } }
                guard try await allowStaging(in: target.url.deletingLastPathComponent(), for: selected[0]) else { return false }
                switch kind {
                case .combine:
                    _ = try await NativeSaveBridge.combine(inputs, destination: target.url, overwrite: target.overwrite)
                    exportMessage = "Combined \(inputs.count) PDFs into \(target.url.lastPathComponent)."
                case .compress:
                    var changes = inputs[0].changes
                    changes.compress = true
                    let before = try inputs[0].displayURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    _ = try await NativeSaveBridge.save(inputs[0].url, expectedHash: inputs[0].hash, changes: changes,
                                                        destination: target.url, overwrite: target.overwrite, sourceGuard: inputs[0].sourceGuard)
                    let after = try target.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    let format: (Int) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                    exportMessage = after < before
                        ? "\(format(before)) → \(format(after)). Saved \(format(before - after)) without reducing image quality."
                        : "\(format(before)) → \(format(after)). No size reduction; the original is unchanged."
                case .split(let interval):
                    let input = inputs[0]
                    let pages = input.changes.pages ?? (0..<selected[0].pageCount).map { NativePageSelection(sourceIndex: $0, rotationDelta: 0) }
                    // Publish the entire new folder only after every part passes.
                    // Failure leaves no partial collection or overwritten files.
                    let staging = target.url.deletingLastPathComponent().appendingPathComponent(".zpdf-split-\(UUID())", isDirectory: true)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    var count = 0
                    for start in stride(from: 0, to: pages.count, by: interval) {
                        var changes = input.changes
                        changes.pages = Array(pages[start..<min(start + interval, pages.count)])
                        count += 1
                        let part = staging.appendingPathComponent("\(input.displayURL.deletingPathExtension().lastPathComponent)-part\(count).pdf")
                        _ = try await NativeSaveBridge.save(input.url, expectedHash: input.hash, changes: changes, destination: part, sourceGuard: input.sourceGuard)
                    }
                    try FileManager.default.moveItem(at: staging, to: target.url)
                    exportMessage = "Saved \(count) PDFs in \(target.url.lastPathComponent)."
                }
                exportedURL = target.url
                return true
            } catch {
                saveError = OpenError(fileName: kind.title, message: error.localizedDescription)
                return false
            }
        }
        selected.forEach { saves[$0.id] = task }
        return task
    }

    private func chooseExportDestination(_ kind: DocumentExportKind, source: URL) -> SaveDestination? {
        let panel = NSSavePanel()
        panel.title = kind.title
        panel.directoryURL = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        if case .split = kind {
            panel.nameFieldStringValue = name + " split"
            panel.message = "Choose a new folder name for the complete set of split PDFs."
        } else {
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = name + (kind.title == "Compress PDF" ? " compressed.pdf" : " combined.pdf")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SaveDestination(url: url, overwrite: FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
extension AppState {
    func printOperation(for tab: DocumentTab, printInfo: NSPrintInfo = .shared) throws -> NSPrintOperation {
        guard !tab.isSaving, !isResolvingClose, commitFieldEditing(), let document = tab.pdfDocument,
              !document.isLocked, document.allowsPrinting else {
            throw NativeSaveError(code: "PRINT_BLOCKED", message: "This PDF cannot be printed right now or its permissions prohibit printing.")
        }
        refreshUnsavedChanges(tab)
        guard let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw NativeSaveError(code: "PRINT_UNAVAILABLE", message: "The print operation could not be created.")
        }
        operation.jobTitle = tab.displayName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPageRange, .showsCopies, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        return operation
    }

    func printActiveDocument() {
        guard let tab = activeTab else { return }
        do { _ = try printOperation(for: tab).run() }
        catch { saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription) }
    }
}
