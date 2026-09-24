// Organize Pages: per-page actions and engine-backed extraction, split,
// combination and lossless compression. PDFKit only maintains the live view.

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct OrganizePagesView: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab

    /// Refresh thumbnails without replacing focused page controls.
    @State private var refreshToken = UUID()
    @FocusState private var focusedPageActions: ObjectIdentifier?
    @State private var statusMessage: String?
    @State private var dropFeedback: (page: ObjectIdentifier, revision: Int)?
    @State private var dropTarget: ObjectIdentifier?

    var body: some View {
        VStack(spacing: 0) {
            pageGrid.disabled(!tab.allowsSaveEdits)
            if let statusMessage {
                Text(statusMessage).font(.caption).padding(8)
                    .accessibilityLabel("Page operation: \(statusMessage)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.canvasBackground)
        .onChange(of: tab.id) { _, _ in clearDropFeedback() }
        .onDisappear { clearDropFeedback() }
    }

    // MARK: - Page grid (prototype #organizeGrid)

    private var pageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)],
                      spacing: 20) {
                ForEach(pages) { item in
                    OrganizePageCell(
                        page: item.page,
                        pageNumber: item.index + 1,
                        pageCount: tab.pageCount,
                        isSelected: tab.currentPage == item.index + 1,
                        thumbnailRevision: refreshToken,
                        actionFocus: $focusedPageActions,
                        showsDropFeedback: dropFeedback?.page == item.id
                            && dropFeedback?.revision == tab.pageRevision
                            && tab.currentPage == item.index + 1,
                        isDropTarget: dropTarget == item.id,
                        onSelect: { dropFeedback = nil; tab.goToPage(item.index + 1) },
                        onDrag: {
                            clearDropFeedback()
                            return NSItemProvider(object: appState.beginPageDrag(at: item.index, in: tab) as NSString)
                        },
                        onMove: { movePage(item.index, to: $0) },
                        onRotate: { rotatePage(item.index) },
                        onExtract: { extractPage(item.index) },
                        onDelete: { deletePage(item.index) }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        acceptDrop(items, at: item.index)
                    } isTargeted: { targeted in
                        if targeted, let drag = appState.pageDrag, drag.tab === tab,
                           drag.document === tab.pdfDocument, drag.page !== item.page,
                           tab.allowsSaveEdits {
                            dropTarget = item.id
                        } else if dropTarget == item.id {
                            dropTarget = nil
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private struct PageItem: Identifiable {
        let page: PDFPage
        let index: Int
        var id: ObjectIdentifier { ObjectIdentifier(page) }
    }

    private var pages: [PageItem] {
        (0..<tab.pageCount).compactMap { index in
            tab.pdfDocument?.page(at: index).map { PageItem(page: $0, index: index) }
        }
    }

    private func movePage(_ source: Int, to destination: Int) {
        dropFeedback = nil
        do {
            try appState.movePage(from: source, to: destination, in: tab)
            statusMessage = "Moved page \(source + 1) to position \(destination + 1)."
        } catch {
            statusMessage = error.localizedDescription
        }
        refresh()
    }

    private func acceptDrop(_ items: [String], at index: Int) -> Bool {
        dropTarget = nil
        guard items.count == 1, let drag = appState.pageDrag else { return false }
        let source = ObjectIdentifier(drag.page)
        let revision = tab.pageRevision
        // The existing handler owns token/document validation and the mutation.
        guard appState.dropPage(items[0], at: index, in: tab) else { return false }
        guard tab.pageRevision != revision else { return true }
        dropFeedback = (source, tab.pageRevision)
        refresh()
        return true
    }

    private func clearDropFeedback() {
        dropFeedback = nil
        dropTarget = nil
    }

    // MARK: - Page operations (REAL via PDFEngine)

    private func rotatePage(_ index: Int) {
        do {
            try appState.rotatePage(index, in: tab)
            statusMessage = "Rotated page \(index + 1)."
        } catch {
            statusMessage = error.localizedDescription
        }
        refresh()
    }

    private func deletePage(_ index: Int) {
        do {
            try appState.deletePage(index, in: tab)
            statusMessage = "Deleted page \(index + 1)."
            let nextPage = tab.pdfDocument?.page(at: min(index, tab.pageCount - 1))
            let revision = tab.pageRevision
            // Restore focus after SwiftUI removes the deleted page controls.
            focusedPageActions = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard tab.pageRevision == revision else { return }
                focusedPageActions = nextPage.map(ObjectIdentifier.init)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        refresh()
    }

    private func extractPage(_ index: Int) {
        let operation = appState.extractPages(IndexSet(integer: index), from: tab)
        Task {
            if await operation.value { statusMessage = "Extracted page \(index + 1)." }
        }
    }

    private func refresh() {
        appState.refreshUnsavedChanges(tab)
        refreshToken = UUID()
    }
}

/// Bordered chip button matching the prototype's .chipbtn.
// MARK: - Grid cell

private struct OrganizePageCell: View {
    @Environment(\.appAccessibility) private var accessibility
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppState.self) private var appState

    let page: PDFPage
    let pageNumber: Int
    let pageCount: Int
    let isSelected: Bool
    let thumbnailRevision: UUID
    let actionFocus: FocusState<ObjectIdentifier?>.Binding
    let showsDropFeedback: Bool
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onDrag: () -> NSItemProvider
    let onMove: (Int) -> Void
    let onRotate: () -> Void
    let onExtract: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Button(action: onSelect) {
                thumbnail.id(thumbnailRevision)
            }
            .buttonStyle(.plain)
            .focused(actionFocus, equals: ObjectIdentifier(page))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(actionFocus.wrappedValue == ObjectIdentifier(page)
                            ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear, lineWidth: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Page \(pageNumber)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .help("Select page \(pageNumber)")
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DesignTokens.Colors.accent, lineWidth: 2)
                    .padding(-4)
                    .opacity(isDropTarget || showsDropFeedback ? 1 : 0)
                    // Hover feedback is immediate; only successful-drop feedback fades.
                    // No translation: visual and pointer positions remain identical.
                    .animation(!accessibility.reduceMotion && !systemReduceMotion && showsDropFeedback && !isDropTarget
                               ? DesignTokens.Motion.pageDropFeedback : nil,
                               value: showsDropFeedback)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onDrag(onDrag)

            Text("\(pageNumber)")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .accessibilityHidden(true)

            HStack(spacing: 2) {
                actionButton("arrow.left", "Move page \(pageNumber) earlier") { onMove(pageNumber - 2) }
                    .disabled(pageNumber == 1)
                actionButton("arrow.right", "Move page \(pageNumber) later") { onMove(pageNumber) }
                    .disabled(pageNumber == pageCount)
                actionButton("rotate.right", "Rotate page \(pageNumber) clockwise", action: onRotate)
                actionButton("arrow.up.doc", "Extract page \(pageNumber)", action: onExtract)
                actionButton("trash", "Delete page \(pageNumber)", action: onDelete)
                    .disabled(pageCount <= 1)
            }
        }
    }

    private func actionButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .accessibilityLabel(label)
        .help(label)
    }

    private var thumbnail: some View {
        ZStack {
            Color.white
            if let image = appState.engine.thumbnail(for: page, size: CGSize(width: 280, height: 363)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(page.bounds(for: .cropBox).width / max(1, page.bounds(for: .cropBox).height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(isSelected ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline,
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }
}

// MARK: - Compact inspector content (shown alongside the grid)

/// Guidance for the organizer; page actions stay attached to each thumbnail.
struct OrganizePagesPanel: View {
    @State private var splitInterval = 1
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            if let tab = appState.activeTab {
                ExtractPagesControls(tab: tab).id(tab.id)
                PanelSection(title: "Split PDF") {
                    Stepper("Every \(splitInterval) page(s)", value: $splitInterval, in: 1...max(1, tab.pageCount))
                        .help("Number of pages in each output PDF")
                    Button("Split into PDFs…") { appState.exportDocuments(.split(splitInterval), tabs: [tab]) }
                        .disabled(!tab.allowsSaveEdits)
                }
                PanelSection(title: "Combine and compress") {
                    Button("Combine PDFs…") { appState.showingCombine = true }
                    Button("Save compressed copy…") { appState.exportDocuments(.compress, tabs: [tab]) }
                        .disabled(!tab.allowsSaveEdits)
                    PanelNote("Lossless compression preserves image quality. Already optimized files may not shrink.")
                }
                if let message = appState.exportMessage {
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if let url = appState.exportedURL {
                        Button("Show output in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            PanelSection(title: "Reorder pages") {
                PanelNote("Drag a thumbnail to its new position, or use the arrow buttons below it.")
            }
            PanelSection(title: "Rotate or delete") {
                PanelNote("Use the buttons below a page. The document must keep at least one page.")
            }
            PanelNote("Save to keep your changes. Back to all tools returns to reading the document.")
        }
    }
}

private struct ExtractPagesControls: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    @State private var pageRange = ""
    @State private var validationMessage: String?

    var body: some View {
        PanelSection(title: "Extract pages") {
            TextField("e.g. 1, 3–5", text: $pageRange)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Pages to extract")
                .help("Enter page numbers or ranges from 1 to \(tab.pageCount)")
                .onSubmit(extract)
                .onChange(of: pageRange) { _, _ in validationMessage = nil }
            Text("Pages 1–\(tab.pageCount), in document order")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
            Button("Extract pages…", action: extract)
                .disabled(pageRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tab.allowsSaveEdits)
                .help("Save these pages as a new PDF")
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            PanelNote("Creates a new PDF with current edits. Your original document stays open and unchanged on disk.")
            if let url = tab.lastExtractedURL {
                Text("Saved \(url.lastPathComponent)")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open extracted PDF") {
                    appState.showAllTools()
                    appState.openDocument(at: url)
                }
                .help("Open \(url.lastPathComponent) in a new tab")
            }
        }
    }

    private func extract() {
        do {
            let pages = try PageRangeSelection.parse(pageRange, pageCount: tab.pageCount)
            validationMessage = nil
            appState.extractPages(pages, from: tab)
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
