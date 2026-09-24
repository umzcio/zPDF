//
//  SidebarView.swift
//  zPDF
//
//  Purpose: Collapsible right-side document panels and their persistent rail.
//  Phase: 1 — Pages and Bookmarks are REAL.
//  Phase: 2 — Attachments is REAL: engine.embeddedFiles(for:) walks the
//  catalog's /Names /EmbeddedFiles name tree via CGPDFDocument.
//

import PDFKit
import SwiftUI

/// Document navigation and review panels in the right-hand rail.
enum DocumentPanel: String, CaseIterable, Identifiable {
    case comments, pages, bookmarks, attachments, layers, destinations, signatures, articles
    var id: String { rawValue }
    /// Panels whose content is implemented; the rail shows only these.
    static var visible: [DocumentPanel] { allCases.filter(\.isImplemented) }
    var isImplemented: Bool {
        switch self {
        case .comments: true
        case .pages: true
        case .bookmarks: true
        case .attachments: true

        case .layers: true

        case .destinations: true

        case .signatures: false

        case .articles: true
        }
    }
    var title: String {
        switch self {
        case .comments: "Comments"
        case .pages: "Pages"
        case .bookmarks: "Bookmarks"
        case .attachments: "Attachments"
        case .layers: "Layers"
        case .destinations: "Destinations"
        case .signatures: "Signatures"
        case .articles: "Content"
        }
    }
    var symbolName: String {
        switch self {
        case .comments: "text.bubble"
        case .pages: "doc.on.doc"
        case .bookmarks: "bookmark"
        case .attachments: "paperclip"
        case .layers: "square.3.layers.3d"
        case .destinations: "mappin.and.ellipse"
        case .signatures: "signature"
        case .articles: "list.bullet.indent"
        }
    }
}

struct DocumentPanelRail: View {
    @Environment(AppState.self) private var appState
    @FocusState private var focusedPanel: DocumentPanel?
    @State private var hoveredPanel: DocumentPanel?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(DocumentPanel.visible) { panel in
                Button { appState.toggleDocumentPanel(panel) } label: {
                    Image(systemName: panel.symbolName)
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(appState.documentPanel == panel
                                         ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                        .background(appState.documentPanel == panel
                                    ? DesignTokens.Colors.accentTint
                                    : hoveredPanel == panel ? DesignTokens.Colors.inset : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredPanel = $0 ? panel : nil }
                .modifier(KeyboardFocusRing())
                .focused($focusedPanel, equals: panel)
                .help("\(appState.documentPanel == panel ? "Hide" : "Show") \(panel.title.lowercased())")
                .accessibilityLabel(panel.title)
                .accessibilityValue(appState.documentPanel == panel ? "Expanded" : "Collapsed")
                .accessibilityAddTraits(appState.documentPanel == panel ? .isSelected : [])
                .disabled(appState.activeTab == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(.bar)
        .onChange(of: appState.documentPanel) { old, new in
            if new == nil { focusedPanel = old }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document panels")
    }
}

struct SidebarView: View {
    let tab: DocumentTab
    let viewStore: PDFViewStore

    @Environment(AppState.self) private var appState
    @State private var embeddedFiles: [EmbeddedFile] = []

    var body: some View {
        VStack(spacing: 0) {
            if let panel = appState.documentPanel {
                HStack {
                    Text(panel.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { appState.documentPanel = nil } label: {
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .modifier(KeyboardFocusRing())
                    .help("Close \(panel.title.lowercased())")
                    .accessibilityLabel("Close \(panel.title.lowercased())")
                }
                .padding(.horizontal, 12)
                .frame(height: DesignTokens.Layout.toolbarHeight)
                Divider()
                switch panel {
                case .comments:
                    ScrollView {
                        CommentPanel(showsTools: false)
                            .padding(12)
                    }
                case .pages: pagesContent
                case .bookmarks:
                    if usesEngine { BookmarksSidebar(tab: tab) } else { bookmarksContent }
                case .attachments:
                    if usesEngine { AttachmentsSidebar(tab: tab) } else { attachmentsContent }
                case .layers: LayersSidebar(tab: tab)
                case .destinations: DestinationsSidebar(tab: tab)
                case .signatures: SignaturesSidebar(tab: tab)
                case .articles: ArticlesSidebar(tab: tab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    /// Encrypted files have no engine revision; they keep the read-only
    /// PDFKit/CoreGraphics views below.
    private var usesEngine: Bool { !(tab.pdfDocument?.isEncrypted == true && tab.editSource == nil) }

    // MARK: - Pages (real PDFKit thumbnails)

    private var pagesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailViewRepresentable(viewStore: viewStore, pageRevision: tab.pageRevision,
                                       document: tab.pdfDocument)
        }
    }

    // MARK: - Bookmarks (real PDFOutline tree)

    private var bookmarksContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = tab.pdfDocument,
               let root = document.outlineRoot, root.numberOfChildren > 0 {
                List(OutlineNode.nodes(from: root, document: document),
                     children: \.children) { node in
                    Button {
                        if let pageIndex = node.pageIndex {
                            tab.goToPage(pageIndex + 1)
                        }
                    } label: {
                        Label(node.title, systemImage: "bookmark")
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            } else {
                SidebarEmptyState(symbolName: "bookmark",
                                  message: "This document has no bookmarks.")
            }
        }
    }

    // MARK: - Attachments (real — embedded files via PDFEngine)

    private var attachmentsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if embeddedFiles.isEmpty {
                SidebarEmptyState(symbolName: "paperclip",
                                  message: "This document has no embedded files.")
            } else {
                List(embeddedFiles) { file in
                    Label {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
                            Text(file.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            if let byteCount = file.byteCount {
                                Text(Self.byteCountFormatter.string(fromByteCount: byteCount))
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                        }
                    } icon: {
                        Image(systemName: "doc")
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .task(id: tab.url) {
            embeddedFiles = tab.url.map { appState.engine.embeddedFiles(for: $0) } ?? []
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

}

// MARK: - Outline model

/// Identifiable wrapper around PDFOutline so SwiftUI's OutlineGroup-style
/// List can render the bookmark tree.
struct OutlineNode: Identifiable {
    let id = UUID()
    let title: String
    /// Zero-based destination page index (nil for pure section headers).
    let pageIndex: Int?
    let children: [OutlineNode]?

    static func nodes(from outline: PDFOutline, document: PDFDocument) -> [OutlineNode] {
        (0..<outline.numberOfChildren).compactMap { index in
            outline.child(at: index).map { node(from: $0, document: document) }
        }
    }

    private static func node(from outline: PDFOutline, document: PDFDocument) -> OutlineNode {
        let pageIndex = outline.destination?.page.map { document.index(for: $0) }
        let children = outline.numberOfChildren > 0
            ? nodes(from: outline, document: document)
            : nil
        return OutlineNode(title: outline.label ?? "Untitled",
                           pageIndex: pageIndex,
                           children: children)
    }
}
