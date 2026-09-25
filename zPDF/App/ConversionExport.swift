import AppKit

@MainActor
@Observable
final class ConversionExport: Identifiable {
    let id = UUID()
    let tab: DocumentTab
    var format: ConversionFormat
    var selection = "all"
    var range = ""
    var layoutMode = "preserve"
    var pptxMode = "editable"
    var stage = "Preparing document"
    var dpi = 150
    var quality = 0.85
    var isRunning = false
    var isCanceling = false
    var completedPages = 0
    var totalPages = 0
    var error: String?
    var result: ConversionResult?
    @ObservationIgnored let cancellation = ConversionCancellation()

    init(tab: DocumentTab, format: ConversionFormat = .docx) { self.tab = tab; self.format = format }
    func options() throws -> ConversionOptions {
        let pages: IndexSet
        switch selection {
        case "current": pages = IndexSet(integer: tab.currentPage - 1)
        case "range": pages = try PageRangeSelection.parse(range, pageCount: tab.pageCount)
        default: pages = IndexSet(integersIn: 0..<tab.pageCount)
        }
        return ConversionOptions(format: format, pages: pages, dpi: dpi, jpegQuality: quality, layoutMode: layoutMode, pptxMode: pptxMode)
    }
    func cancel() { isCanceling = true; cancellation.cancel() }
}

@MainActor
extension AppState {
    func showConversionExport(format: ConversionFormat = .docx) {
        guard let tab = activeTab, tab.allowsSaveEdits, !isResolvingClose, commitFieldEditing() else { return }
        conversionExport = ConversionExport(tab: tab, format: format)
    }

    @discardableResult
    func runConversionExport(_ request: ConversionExport, destination: SaveDestination? = nil) -> Task<Bool, Never> {
        let tab = request.tab
        let options: ConversionOptions
        let input: NativeSaveBridge.Input
        let lease: DocumentEditSource
        do {
            guard tabs.contains(where: { $0 === tab }), tab.allowsSaveEdits,
                  saves[tab.id] == nil, !request.isRunning, !isResolvingClose,
                  commitFieldEditing(), let document = tab.pdfDocument,
                  let baseline = tab.saveBaseline, let source = tab.editSource,
                  let url = tab.url, let hash = tab.sourceHash else {
                throw NativeSaveError(code: "EXPORT_NOT_READY", message: "Wait until this document is ready. Encrypted and XFA documents are not supported by this export yet.")
            }
            options = try request.options()
            lease = source
            input = .init(url: source.url, hash: source.hash, changes: try baseline.changes(in: document),
                          sourceGuard: NativeSourceGuard(url: url, hash: hash))
        } catch {
            request.error = error.localizedDescription
            return Task { false }
        }
        tab.isSaving = true
        tab.operationLabel = "Exporting"
        request.isRunning = true
        request.error = nil
        request.completedPages = 0
        request.totalPages = options.pages.count
        let task = Task { () -> Bool in
            defer {
                withExtendedLifetime(lease) {}
                tab.isSaving = false
                tab.operationLabel = nil
                saves[tab.id] = nil
                saveDestinations[tab.id] = nil
                request.isRunning = false
                refreshUnsavedChanges(tab)
            }
            do {
                guard let target = destination ?? chooseConversionDestination(request, options: options) else { return false }
                guard !SaveDestination.sameFile(input.displayURL, target.url),
                      !SaveDestination.sameFile(input.url, target.url),
                      !tabs.contains(where: { $0.url.map { SaveDestination.sameFile($0, target.url) } == true }),
                      !saveDestinations.values.contains(where: { SaveDestination.sameFile($0, target.url) }) else {
                    throw NativeSaveError(code: "SOURCE_DESTINATION", message: "Choose a separate location. Export cannot replace an open PDF.")
                }
                if options.producesFolder, FileManager.default.fileExists(atPath: target.url.path) {
                    throw NativeSaveError(code: "DESTINATION_EXISTS", message: "Choose a new folder name for these images. Existing folders are never replaced.")
                }
                saveDestinations[tab.id] = target.url
                let access = target.url.startAccessingSecurityScopedResource()
                defer { if access { target.url.stopAccessingSecurityScopedResource() } }
                guard try await allowStaging(in: target.url.deletingLastPathComponent(), for: tab) else { return false }
                try request.cancellation.check()
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-conversion-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: temporary) }
                let candidate = temporary.appendingPathComponent("snapshot.pdf")
                _ = try await NativeSaveBridge.save(input.url, expectedHash: input.hash, changes: input.changes,
                                                    destination: candidate, sourceGuard: input.sourceGuard)
                try request.cancellation.check()
                if options.format.usesWorker {
                    request.result = try await ExportWorkerBridge.export(input: candidate, options: options, destination: target,
                        cancellation: request.cancellation) { stage, completed, total in
                            Task { @MainActor in
                                request.stage = stage; request.completedPages = completed; request.totalPages = total
                            }
                        }
                } else {
                    request.result = try await DocumentConversion.export(input: candidate, options: options, destination: target,
                        cancellation: request.cancellation) { completed, total in
                            await MainActor.run { request.stage = "Exporting pages"; request.completedPages = completed; request.totalPages = total }
                        }
                }
                return true
            } catch is CancellationError {
                if conversionExport === request { conversionExport = nil }
                return false
            } catch {
                request.error = error.localizedDescription
                return false
            }
        }
        saves[tab.id] = task
        return task
    }

    private func chooseConversionDestination(_ request: ConversionExport, options: ConversionOptions) -> SaveDestination? {
        let panel = NSSavePanel()
        panel.title = "Export \(request.format.title)"
        panel.prompt = "Export"
        panel.directoryURL = request.tab.requiresSaveAs ? nil : request.tab.url?.deletingLastPathComponent()
        let name = (request.tab.displayName as NSString).deletingPathExtension
        if options.producesFolder {
            panel.nameFieldStringValue = name + " images"
            panel.message = "Choose a new folder name. Each selected page will be saved as a separate image."
        } else {
            panel.allowedContentTypes = [options.format.contentType]
            panel.nameFieldStringValue = name + "." + options.format.fileExtension
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SaveDestination(url: url, overwrite: FileManager.default.fileExists(atPath: url.path))
    }
}
