import PDFKit

/// Retains page/annotation identities, so Undo does not look like an unsupported
/// insertion to SaveBaseline. Each revision retains its immutable engine input
/// and identity-bound baseline, including across native Save/reload.
@MainActor
final class DocumentUndoHistory {
    private struct AnnotationState {
        let annotation: PDFAnnotation
        let contents: String?
        let value: String?
        let button: PDFWidgetCellState
        /// Comment geometry/style (nil for widgets), so moves and style edits undo.
        var appearance: CommentAppearance? = nil
        func matches(_ other: Self) -> Bool {
            annotation === other.annotation && contents == other.contents && value == other.value && button == other.button
                && appearance == other.appearance
        }
    }
    private struct PageState {
        let page: PDFPage
        let rotation: Int
        let annotations: [AnnotationState]
        func matches(_ other: Self) -> Bool {
            page === other.page && rotation == other.rotation && annotations.count == other.annotations.count
                && zip(annotations, other.annotations).allSatisfy { $0.matches($1) }
        }
    }
    private struct Snapshot {
        let token: UUID
        let document: PDFDocument
        let baseline: SaveBaseline?
        let source: DocumentEditSource?
        let pages: [PageState]
        init(_ document: PDFDocument, tab: DocumentTab, token: UUID = UUID()) {
            self.token = token; self.document = document
            baseline = tab.saveBaseline; source = tab.editSource
            pages = (0..<document.pageCount).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                return PageState(page: page, rotation: page.rotation, annotations: page.annotations.map {
                    AnnotationState(annotation: $0, contents: $0.contents, value: $0.widgetStringValue, button: $0.buttonWidgetState,
                                    appearance: CommentAppearance($0))
                })
            }
        }
        func matches(_ other: Self) -> Bool {
            document === other.document && pages.count == other.pages.count && zip(pages, other.pages).allSatisfy { $0.matches($1) }
        }
        func restore(_ document: PDFDocument) {
            let wanted = Set(pages.map { ObjectIdentifier($0.page) })
            for index in (0..<document.pageCount).reversed() {
                if let page = document.page(at: index), !wanted.contains(ObjectIdentifier(page)) { document.removePage(at: index) }
            }
            for (index, state) in pages.enumerated() {
                if document.page(at: index) !== state.page {
                    let currentIndex = document.index(for: state.page)
                    if currentIndex != NSNotFound { document.removePage(at: currentIndex) }
                    document.insert(state.page, at: index)
                }
                if state.page.rotation != state.rotation { state.page.rotation = state.rotation }
                let wantedAnnotations = Set(state.annotations.map { ObjectIdentifier($0.annotation) })
                for annotation in state.page.annotations where !wantedAnnotations.contains(ObjectIdentifier(annotation)) {
                    state.page.removeAnnotation(annotation)
                }
                for item in state.annotations {
                    if item.annotation.contents != item.contents { item.annotation.contents = item.contents }
                    if let appearance = item.appearance, CommentAppearance(item.annotation) != appearance { appearance.apply(to: item.annotation) }
                    if item.annotation.type == "Widget" {
                        if item.annotation.widgetFieldType == .button {
                            if item.annotation.buttonWidgetState != item.button { item.annotation.buttonWidgetState = item.button }
                        }
                        if item.annotation.widgetStringValue != item.value { item.annotation.widgetStringValue = item.value }
                    }
                    if !state.page.annotations.contains(where: { $0 === item.annotation }) { state.page.addAnnotation(item.annotation) }
                }
            }
        }
    }
    let manager = UndoManager()
    private weak var tab: DocumentTab?
    private var current: Snapshot
    private var saved: Snapshot
    private var restoring = false
    var didRestore: (() -> Void)?

    init(tab: DocumentTab, document: PDFDocument) {
        self.tab = tab; current = Snapshot(document, tab: tab); saved = current
        manager.levelsOfUndo = 50
        manager.groupsByEvent = false
    }

    func record(name: String = "Edit PDF") {
        guard !restoring, let tab, let document = tab.pdfDocument else { return }
        let next = Snapshot(document, tab: tab)
        guard !next.matches(current) else { return }
        let previous = current
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { history in history.restore(previous) }
        manager.setActionName(name)
        manager.endUndoGrouping()
        current = next
        tab.undoRevision += 1
    }

    var hasChangesSinceSave: Bool { current.token != saved.token && !current.matches(saved) }

    /// Reloading changes PDFKit identities, not the logical edit position.
    func didSave() {
        guard let tab, let document = tab.pdfDocument else { return }
        current = Snapshot(document, tab: tab, token: current.token)
        saved = current
        tab.undoRevision += 1
    }

    private func restore(_ snapshot: Snapshot) {
        guard let tab, tab.allowsSaveEdits else { return }
        let inverse = current
        manager.registerUndo(withTarget: self) { history in history.restore(inverse) }
        restoring = true
        snapshot.restore(snapshot.document)
        if tab.pdfDocument !== snapshot.document { tab.pdfDocument = snapshot.document }
        tab.saveBaseline = snapshot.baseline
        tab.editSource = snapshot.source
        current = snapshot
        tab.pageRevision += 1
        tab.undoRevision += 1
        tab.goToPage(tab.currentPage)
        tab.updateSearchResults()
        didRestore?()
        restoring = false
    }
}

@MainActor
extension AppState {
    func resetUndoHistory(_ tab: DocumentTab) {
        guard let document = tab.pdfDocument else { return }
        let history = DocumentUndoHistory(tab: tab, document: document)
        history.didRestore = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.refreshUnsavedChanges(tab)
            self.noteAnnotationsChanged()
        }
        tab.undoHistory = history
        tab.undoRevision += 1
    }

    func undoDocumentEdit() {
        guard let tab = activeTab, tab.allowsSaveEdits, commitFieldEditing() else { return }
        tab.undoHistory?.manager.undo()
    }

    func redoDocumentEdit() {
        guard let tab = activeTab, tab.allowsSaveEdits, commitFieldEditing() else { return }
        tab.undoHistory?.manager.redo()
    }
}
