import SwiftUI

/// Modal dialogs for page, create, optimize, standards and compare
/// workflows. Presented by RootView from `AppState.workflowSheet`.
enum WorkflowSheet: Identifiable {
    case insertPages(InsertPagesSheet.Mode)
    case replacePages
    case pageLabels
    case pageBoxes
    case resizePages
    case transitions
    case split
    case createPDF(CreatePDFSource)
    case reduceFileSize
    case exportImages
    case outputPreview
    case compareResults(ComparisonResult)
    case scanner
    case portfolio

    var id: String {
        switch self {
        case .insertPages(let mode): "insert-\(mode)"
        case .replacePages: "replace"
        case .pageLabels: "labels"
        case .pageBoxes: "boxes"
        case .resizePages: "resize"
        case .transitions: "transitions"
        case .split: "split"
        case .createPDF(let source): "create-\(source.rawValue)"
        case .reduceFileSize: "reduce"
        case .exportImages: "images"
        case .outputPreview: "preview"
        case .compareResults(let result): "compare-\(result.id)"
        case .scanner: "scanner"
        case .portfolio: "portfolio"
        }
    }

    /// Sheets that act on the active document.
    var needsDocument: Bool {
        switch self {
        case .createPDF, .compareResults, .scanner: false
        default: true
        }
    }
}

struct WorkflowSheetHost: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let sheet: WorkflowSheet

    var body: some View {
        if sheet.needsDocument, let tab = appState.activeTab {
            documentSheet(tab).id(tab.id)
        } else if !sheet.needsDocument {
            switch sheet {
            case .createPDF(let source): CreatePDFSheet(initialSource: source)
            case .compareResults(let result): ComparisonResultsView(result: result)
            case .scanner: ScannerSheet()
            default: EmptyView()
            }
        } else {
            VStack(spacing: 12) {
                Text("Open a document first.")
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
        }
    }

    @ViewBuilder
    private func documentSheet(_ tab: DocumentTab) -> some View {
        switch sheet {
        case .insertPages(let mode): InsertPagesSheet(tab: tab, mode: mode)
        case .replacePages: ReplacePagesSheet(tab: tab)
        case .pageLabels: PageLabelsSheet(tab: tab)
        case .pageBoxes: PageBoxesSheet(tab: tab)
        case .resizePages: ResizePagesSheet(tab: tab)
        case .transitions: TransitionsSheet(tab: tab)
        case .split: SplitDocumentSheet(tab: tab)
        case .reduceFileSize: ReduceFileSizeSheet(tab: tab)
        case .exportImages: ExportImagesSheet(tab: tab)
        case .outputPreview: OutputPreviewSheet(tab: tab)
        case .portfolio: PortfolioSheet(tab: tab)
        default: EmptyView()
        }
    }
}

@MainActor
extension AppState {
    /// Opens a workflow dialog, committing any in-progress field edit first.
    func present(_ sheet: WorkflowSheet) {
        guard commitFieldEditing() else { return }
        if sheet.needsDocument {
            guard let tab = activeTab, tab.allowsSaveEdits || sheet.isReadOnlySafe else { return }
        }
        workflowSheet = sheet
    }
}

extension WorkflowSheet {
    /// Sheets that only read the document (allowed on read-only documents).
    var isReadOnlySafe: Bool {
        switch self {
        case .exportImages, .outputPreview, .portfolio: true
        default: false
        }
    }
}
