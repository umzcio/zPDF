import PDFKit
import SwiftUI

/// Wraps the main canvas; Window ▸ Split View adds a second, independently
/// scrolling pane of the same document beside or below it.
struct SplitCanvas<Primary: View>: View {
    let tab: DocumentTab
    @ViewBuilder let primary: () -> Primary
    @Environment(AppState.self) private var appState

    var body: some View {
        let viewing = appState.features.viewing(for: tab)
        switch viewing.split {
        case .none:
            primary()
        case .vertical:
            HSplitView {
                primary().frame(minWidth: 240)
                SecondaryPane(tab: tab).frame(minWidth: 240)
            }
        case .horizontal:
            VSplitView {
                primary().frame(minHeight: 180)
                SecondaryPane(tab: tab).frame(minHeight: 180)
            }
        }
    }
}

private struct SecondaryPane: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            SecondaryPDFView(tab: tab, preferences: appState.preferences,
                             coverPage: appState.features.viewing(for: tab).showsCoverPage)
            Divider()
            HStack {
                Text("Second pane").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button { appState.features.viewing(for: tab).split = .none } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close the second pane")
                    .accessibilityLabel("Close the second pane")
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.bar)
        }
    }
}

/// A plain PDFView on the same PDFDocument (edits appear in both panes).
struct SecondaryPDFView: NSViewRepresentable {
    let tab: DocumentTab
    let preferences: AppPreferences
    var coverPage = false

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = tab.viewMode.pdfDisplayMode
        view.acceptsDraggedFiles = false
        view.document = tab.pdfDocument
        if let page = tab.pdfDocument?.page(at: tab.currentPage - 1) { view.go(to: page) }
        view.setAccessibilityLabel("Second pane of \(tab.displayName)")
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== tab.pdfDocument {
            let page = view.currentPage.flatMap { view.document?.index(for: $0) } ?? tab.currentPage - 1
            view.document = tab.pdfDocument
            if let target = tab.pdfDocument?.page(at: min(page, max(0, tab.pageCount - 1))) { view.go(to: target) }
        }
        if view.displayMode != tab.viewMode.pdfDisplayMode { view.displayMode = tab.viewMode.pdfDisplayMode }
        view.displaysPageBreaks = preferences.showPageGaps
        DocumentDisplay.apply(to: view, coverPage: coverPage, preferences: preferences)
    }
}

/// Window ▸ New Window: the same document in another window, synced with the
/// main window's edits. Editing tools stay in the main window.
struct DocumentWindowView: View {
    let tabID: UUID?
    @Environment(AppState.self) private var appState
    @State private var zoomTrigger = 0

    var body: some View {
        if let tab = appState.tab(withID: tabID), tab.pdfDocument != nil {
            VStack(spacing: 0) {
                SecondaryPDFView(tab: tab, preferences: appState.preferences,
                                 coverPage: appState.features.viewing(for: tab).showsCoverPage)
                Divider()
                HStack {
                    Image(systemName: "doc.on.doc").foregroundStyle(DesignTokens.Colors.mutedText)
                    Text("\(tab.displayName) — additional window. Edit in the main window; changes appear here.")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.bar)
            }
            .navigationTitle(tab.displayName)
        } else {
            ContentUnavailableView("Document closed", systemImage: "doc",
                                   description: Text("The document shown in this window was closed in the main window."))
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
