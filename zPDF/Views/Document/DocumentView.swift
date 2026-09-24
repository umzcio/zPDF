//
//  DocumentView.swift
//  zPDF
//
//  Purpose: Document screen — resizable split view with the collapsible
//  sidebar, the PDF canvas (or OrganizePagesView when the organize panel is
//  active), tool controls in the left sidebar, and the status bar.
//  Hosts the signature tap-to-place overlay (SignaturePlacementOverlay):
//  while SignatureService.armedSignature is set, a transparent click-capture
//  view sits above the PDFView and converts clicks to page points.
//  Phase: 2 — layout + signature placement REAL.
//

import PDFKit
import SwiftUI

struct DocumentView: View {
    @Environment(\.appAccessibility) private var accessibility
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(AppState.self) private var appState

    @State private var canvasFrame: CGRect = .zero

    var body: some View {
        // A navigation split view ties its title-bar toggle to the sidebar's
        // trailing edge. This content split leaves title-bar placement to RootView.
        VStack(spacing: 0) {
            DocumentToolbar(canvasFrame: canvasFrame)
            Divider()
            HStack(spacing: 0) {
                HSplitView {
                    if appState.sidebarVisible {
                        ToolsView()
                            .frame(minWidth: 220, idealWidth: DesignTokens.Layout.sidebarWidth,
                                   maxWidth: 320, maxHeight: .infinity)
                    }
                    VStack(spacing: 0) {
                        if let block = appState.activeTab?.saveBlock {
                            Text(block == "XFA_EDIT_BLOCKED"
                                 ? "Read-only XFA form — existing PDF pages can be viewed; form editing is unavailable."
                                 : "Read-only — viewing is available; this document cannot be edited or saved.")
                                .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        Divider()
                        HStack(alignment: .top, spacing: 0) {
                            if appState.activeTab != nil && appState.activePanel != .organize
                                && !appState.readingPresentation.isActive {
                                DocumentQuickTools()
                                    .padding(.horizontal, 8)
                                    .padding(.top, 12)
                            }
                            canvasArea
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named("documentWorkspace"))
                                } action: { canvasFrame = $0 }
                        }
                        .background(DesignTokens.Colors.canvasBackground)
                        Divider()
                        StatusBar()
                    }
                    .frame(minWidth: 360)
                    if appState.documentPanel != nil, let tab = appState.activeTab {
                        SidebarView(tab: tab, viewStore: appState.pdfViewStore)
                            .frame(minWidth: 240, idealWidth: 280, maxWidth: 320, maxHeight: .infinity)
                    }
                }
                if !appState.readingPresentation.isActive {
                    Divider()
                    DocumentPanelRail()
                }
            }
        }
        .coordinateSpace(name: "documentWorkspace")
        // Keep the native split view off the title-bar safe-area boundary;
        // otherwise AppKit extends its divider through the document tabs.
        .padding(.top, 1)
        .onChange(of: appState.activeTab?.currentPage) { _, _ in rememberPosition() }
        .onChange(of: appState.activeTab?.zoomFactor) { _, _ in rememberPosition() }
        .onChange(of: appState.activeTab?.viewMode) { _, _ in rememberPosition() }
    }

    private func rememberPosition() {
        if let tab = appState.activeTab, tab.pendingInitialZoom == nil { appState.rememberReadingState(tab) }
    }

    @ViewBuilder
    private var canvasArea: some View {
        if let tab = appState.activeTab {
            if appState.activePanel == .organize {
                // Prototype "organizing" mode swaps the canvas for a page grid.
                OrganizePagesView(tab: tab)
            } else {
                ZStack {
                    PDFViewRepresentable(
                        document: tab.pdfDocument,
                        displayMode: tab.viewMode.pdfDisplayMode,
                        scaleFactor: tab.zoomFactor,
                        pageNumber: tab.currentPage,
                        pageRevision: tab.pageRevision,
                        viewStore: appState.pdfViewStore,
                        onPageChanged: { newPage in
                            tab.currentPage = newPage
                        }
                    )
                    if appState.signatureService.armedSignature != nil {
                        SignaturePlacementOverlay(viewStore: appState.pdfViewStore,
                                                  signatureService: appState.signatureService)
                    }
                }
                .overlay(alignment: .top) {
                    if appState.signatureService.armedSignature != nil {
                        placementBanner
                    }
                }
            }
        } else {
            emptyCanvas
        }
    }

    /// Hint banner shown over the canvas while tap-to-place is armed.
    private var placementBanner: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: InspectorPanel.fillSign.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.accent)
            Text("Click anywhere on the page to place your signature.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.text)
            Button("Cancel") {
                appState.signatureService.disarmPlacement()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.accent)
        }
        .padding(.horizontal, DesignTokens.Spacing.medium)
        .padding(.vertical, DesignTokens.Spacing.small)
        .background {
            if accessibility.reduceTransparency || systemReduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
        )
        .padding(.top, DesignTokens.Spacing.small)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var emptyCanvas: some View {
        VStack(spacing: DesignTokens.Spacing.medium) {
            Image(systemName: "doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DesignTokens.Colors.mutedText)
            Text("No document open")
                .font(.system(size: 13, weight: .medium))
            Button("Open File…") {
                appState.openFilePanel()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Colors.controlAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.canvasBackground)
    }
}

/// Transparent click-capture overlay shown while signature placement is
/// armed. Converts the click to a PDFPage + page point through the shared
/// PDFView and hands off to SignatureService (which places and disarms).
private struct SignaturePlacementOverlay: NSViewRepresentable {
    let viewStore: PDFViewStore
    let signatureService: SignatureService

    func makeNSView(context: Context) -> SignaturePlacementView {
        let view = SignaturePlacementView()
        view.onMouseDown = { [weak view] pointInOverlay in
            guard let view, let pdfView = viewStore.pdfView else { return }
            let pointInPDFView = pdfView.convert(pointInOverlay, from: view)
            guard let page = pdfView.page(for: pointInPDFView, nearest: true) else { return }
            let pagePoint = pdfView.convert(pointInPDFView, to: page)
            signatureService.placeArmedSignature(at: pagePoint, on: page)
        }
        return view
    }

    func updateNSView(_ nsView: SignaturePlacementView, context: Context) {
        // Stateless: clicks are forwarded through the onMouseDown closure.
    }
}

/// The AppKit side of the overlay: transparent, captures the first click,
/// and shows a crosshair cursor while it is on screen.
private final class SignaturePlacementView: NSView {
    var onMouseDown: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }
}
