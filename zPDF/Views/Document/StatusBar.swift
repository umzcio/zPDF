//
//  StatusBar.swift
//  zPDF
//
//  Purpose: Bottom status bar mirroring the prototype: Ready state, file
//  size, page dimensions (inches), "Page x of y", zoom %.
//  Phase: 1 — REAL (file size/dimensions from the live document).
//  Document accessibility is not asserted without a structure-tree audit.
//

import PDFKit
import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 16) {
            Text(statusText)
                .foregroundStyle(DesignTokens.Colors.text)
                .accessibilityLabel("Document status: \(statusText)")
                .help(statusHelp)

            if appState.recovery?.errorMessage != nil || appState.recoveryWarning != nil {
                Button("Recovery unavailable") { Task { await appState.showRecovery() } }
                    .help(appState.recovery?.errorMessage ?? appState.recoveryWarning ?? "")
            }

            if let tab = appState.activeTab {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Label(fileSizeText(for: tab), systemImage: "doc")
                        Text(dimensionsText(for: tab))
                    }.fixedSize()
                    Label(fileSizeText(for: tab), systemImage: "doc").fixedSize()
                    Color.clear.frame(width: 0)
                }
                Spacer()
                StatusNavigationControls(tab: tab)
                    .fixedSize(horizontal: true, vertical: false)
                    .id(tab.id)
            } else {
                Spacer()
                Text("No document")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(DesignTokens.Colors.mutedText)
        .padding(.horizontal, 12)
        .frame(height: DesignTokens.Layout.statusBarHeight)
        .background(.bar)
    }

    private var statusHelp: String {
        switch appState.activeTab?.saveBlock {
        case "XFA_EDIT_BLOCKED": "XFA form: editing and saving are unavailable"
        case "ENGINE_UNAVAILABLE": "PDF engine unavailable: editing and saving are disabled"
        case .some: "Read-only: editing and saving are unavailable"
        case .none: statusText
        }
    }

    private var statusText: String {
        guard let tab = appState.activeTab else { return "No document" }
        if let label = tab.operationLabel { return label }
        if tab.isExtracting { return "Extracting pages…" }
        if tab.isSaving { return "Saving…" }
        if tab.saveChecking { return "Checking document…" }
        if tab.saveBlock != nil { return "Read-only" }
        if tab.requiresSaveAs { return "Recovered — Save As to keep" }
        if tab.hasUnsavedChanges || tab.hasUncommittedFieldEdit { return "Unsaved changes" }
        return "Ready"
    }

    private func fileSizeText(for tab: DocumentTab) -> String {
        guard let url = tab.url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// "8.50 × 11.00 in" from the current page's media box (points → inches).
    private func dimensionsText(for tab: DocumentTab) -> String {
        guard let size = tab.currentPageSize else { return "—" }
        let widthInches = size.width / 72.0
        let heightInches = size.height / 72.0
        return String(format: "%.2f × %.2f in", widthInches, heightInches)
    }
}

/// Bind popover actions to this document, including when the active tab changes.
private struct StatusNavigationControls: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var showingPage = false
    @State private var showingZoom = false
    @State private var pageText = ""
    @State private var zoomText = ""
    @State private var zoomInputError = false
    @FocusState private var pageFocused: Bool
    @FocusState private var zoomFocused: Bool

    /// "Page iv (4 of 12)" when the PDF defines page labels (Settings ▸
    /// Page Display ▸ Show page labels), otherwise "Page 4 of 12".
    private var pageLabelText: String {
        let number = "\(tab.currentPage) of \(max(tab.pageCount, 1))"
        guard appState.preferences.showPageLabels,
              let label = tab.pdfDocument?.page(at: tab.currentPage - 1)?.label,
              !label.isEmpty, label != "\(tab.currentPage)" else { return "Page \(number)" }
        return "Page \(label) (\(number))"
    }

    private var requestedPage: Int? {
        guard let value = Int(pageText.trimmingCharacters(in: .whitespaces)),
              (1...max(1, tab.pageCount)).contains(value) else { return nil }
        return value
    }

    private var requestedZoom: Double? {
        var text = zoomText.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%") { text.removeLast() }
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite,
              (ZoomController.minimumZoom * 100...ZoomController.maximumZoom * 100).contains(value)
        else { return nil }
        return value / 100
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                pageText = "\(tab.currentPage)"
                showingPage = true
            } label: {
                Text(pageLabelText)
                    .frame(height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help("Go to page (⇧⌘N)")
            .accessibilityLabel("Go to page")
            .accessibilityValue("Page \(tab.currentPage) of \(tab.pageCount)")
            .popover(isPresented: $showingPage, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Go to page").font(.headline)
                    HStack {
                        TextField("Page", text: $pageText)
                            .frame(width: 70).focused($pageFocused)
                            .accessibilityLabel("Destination page")
                            .onSubmit { navigate() }
                        Text("of \(tab.pageCount)")
                        Button("Go") { navigate() }.disabled(requestedPage == nil)
                    }
                    if requestedPage == nil {
                        Text("Enter a page from 1 to \(tab.pageCount).")
                            .font(.caption)
                    }
                }
                .font(.body)
                .foregroundStyle(.primary)
                .padding(14)
                .onAppear { pageFocused = true }
                .onExitCommand { showingPage = false }
            }

            Button {
                zoomText = ZoomController.percentString(tab.zoomFactor)
                zoomInputError = false
                showingZoom = true
            } label: {
                Text(ZoomController.percentString(tab.zoomFactor))
                    .frame(minWidth: 34, minHeight: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help("Zoom options")
            .accessibilityLabel("Set zoom")
            .accessibilityValue(ZoomController.percentString(tab.zoomFactor))
            .popover(isPresented: $showingZoom, arrowEdge: .top) {
                VStack(spacing: 2) {
                    HStack {
                        Text("Zoom")
                        Spacer()
                        TextField("Percent", text: $zoomText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 68)
                            .focused($zoomFocused)
                            .accessibilityLabel("Zoom percentage")
                            .help("Enter a percentage and press Return")
                            .onSubmit { applyZoom() }
                            .onChange(of: zoomText) { _, _ in zoomInputError = false }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    if zoomInputError {
                        Text("Enter a supported percentage.")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Colors.mutedText)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                    }
                    Divider().padding(.vertical, 4)
                    ZoomOptionRow(title: "Actual Size", selected: abs(tab.zoomFactor - 1) < 0.001) {
                        guard appState.activeTabID == tab.id else { return }
                        tab.setZoom(1)
                        showingZoom = false
                    }
                    ZoomOptionRow(title: "Fit Page") {
                        guard appState.activeTabID == tab.id,
                              let view = appState.pdfViewStore.pdfView else { return }
                        ZoomController.fitPage(for: tab, in: view)
                        showingZoom = false
                    }.disabled(appState.pdfViewStore.pdfView == nil)
                    ZoomOptionRow(title: "Fit Width") {
                        guard appState.activeTabID == tab.id,
                              let view = appState.pdfViewStore.pdfView else { return }
                        ZoomController.fitWidth(for: tab, in: view)
                        showingZoom = false
                    }.disabled(appState.pdfViewStore.pdfView == nil)
                }
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(6)
                .frame(width: 196)
                .onAppear { zoomFocused = true }
                .onExitCommand { showingZoom = false }
            }
        }
        .onChange(of: appState.activeTabID) { _, _ in
            showingPage = false
            showingZoom = false
        }
    }

    private func navigate() {
        guard let page = requestedPage, appState.activeTabID == tab.id else { return }
        tab.goToPage(page)
        showingPage = false
    }

    private func applyZoom() {
        guard appState.activeTabID == tab.id else { return }
        guard let zoom = requestedZoom else {
            zoomInputError = true
            return
        }
        tab.setZoom(zoom)
        showingZoom = false
    }
}

/// Menu-like rows retain native button semantics and keyboard focus.
private struct ZoomOptionRow: View {
    let title: String
    var selected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(hovered && isEnabled ? DesignTokens.Colors.inset : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#Preview {
    StatusBar()
        .environment(AppState())
}
