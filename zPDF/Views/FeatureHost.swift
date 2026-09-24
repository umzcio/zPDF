import PDFKit
import SwiftUI

/// Presents the sheets owned by FeatureState and runs per-document setup
/// (document-defined initial view). Attached once to the main window.
struct FeatureHost: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        @Bindable var features = appState.features
        content
            .sheet(item: Binding(get: { appState.tab(withID: features.propertiesTabID) },
                                 set: { features.propertiesTabID = $0?.id })) { tab in
                DocumentPropertiesView(tab: tab, pane: features.propertiesInitialPane)
                    .environment(appState)
            }
            .onChange(of: appState.activeTab?.pdfDocument) { _, _ in applyInitialView() }
            .onChange(of: appState.tabs.map(\.id)) { _, ids in
                for id in Array(features.appliedInitialView) where !ids.contains(id) {
                    features.appliedInitialView.remove(id)
                    features.forget(id)
                }
            }
            .onAppear { applyInitialView() }
    }

    /// Applies /PageLayout, /PageMode and /OpenAction the first time a
    /// document is shown (Settings ▸ Documents ▸ Use the document's initial
    /// view). A remembered reading position still wins for the page.
    private func applyInitialView() {
        guard let tab = appState.activeTab, let document = tab.pdfDocument,
              !appState.features.appliedInitialView.contains(tab.id) else { return }
        appState.features.appliedInitialView.insert(tab.id)
        guard appState.preferences.useDocumentInitialView, let catalog = document.documentRef?.catalog else { return }
        let initial = DocumentInitialView(catalog: catalog, document: document)
        let viewing = appState.features.viewing(for: tab)
        tab.viewHistory.isRestoring = true
        defer { tab.viewHistory.isRestoring = false }
        if let mode = initial.viewMode { tab.viewMode = mode }
        if let cover = initial.coverPage { viewing.showsCoverPage = cover }
        let remembered = appState.preferences.rememberReadingPosition && tab.url.flatMap { appState.readingHistory.position(for: $0) } != nil
        if !remembered, let page = initial.openPage, page > 0 { tab.goToPage(page + 1) }
        if !appState.readingPresentation.isActive, let panel = initial.panel, DocumentPanel.visible.contains(panel) {
            appState.documentPanel = panel
        }
    }
}

/// Initial-view entries read straight from the catalog with CoreGraphics.
struct DocumentInitialView {
    var viewMode: PDFViewMode?
    var coverPage: Bool?
    var panel: DocumentPanel?
    var openPage: Int?
    var fullScreen = false

    init(catalog: CGPDFDictionaryRef, document: PDFDocument) {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(catalog, "PageLayout", &name), let name {
            switch String(cString: name) {
            case "SinglePage": viewMode = .single; coverPage = false
            case "OneColumn": viewMode = .continuous; coverPage = false
            case "TwoPageLeft", "TwoColumnLeft": viewMode = .facing; coverPage = false
            case "TwoPageRight", "TwoColumnRight": viewMode = .facing; coverPage = true
            default: break
            }
        }
        name = nil
        if CGPDFDictionaryGetName(catalog, "PageMode", &name), let name {
            switch String(cString: name) {
            case "UseOutlines": panel = .bookmarks
            case "UseThumbs": panel = .pages
            case "UseAttachments": panel = .attachments
            case "UseOC": panel = .layers
            case "FullScreen": fullScreen = true
            default: break
            }
        }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(catalog, "OpenAction", &array), let array {
            openPage = Self.pageIndex(of: array, in: document)
        } else {
            var action: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "OpenAction", &action), let action,
               CGPDFDictionaryGetArray(action, "D", &array), let array {
                openPage = Self.pageIndex(of: array, in: document)
            }
        }
    }

    private static func pageIndex(of destination: CGPDFArrayRef, in document: PDFDocument) -> Int? {
        var pageDict: CGPDFDictionaryRef?
        if CGPDFArrayGetDictionary(destination, 0, &pageDict), let pageDict, let ref = document.documentRef {
            for index in 0..<ref.numberOfPages {
                if ref.page(at: index + 1)?.dictionary == pageDict { return index }
            }
        }
        var number: CGPDFInteger = 0
        if CGPDFArrayGetInteger(destination, 0, &number), number >= 0, number < document.pageCount { return Int(number) }
        return nil
    }
}
