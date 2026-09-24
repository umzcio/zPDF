//
//  DocumentToolbar.swift
//  zPDF
//
//  Purpose: Persistent All tools entry, page/zoom controls centered over the
//  document viewport, and popover search. Canvas quick tools live separately
//  beside the page.
//  Phase: 2 — REAL for navigation/zoom/panel toggling, toolbar search
//  (PDFDocument.findString with match highlighting + next/previous), and
//  view-only canvas rotation (see CanvasRotationController).
//

import PDFKit
import SwiftUI

struct DocumentToolbar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appAccessibility) private var accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var canvasFrame: CGRect = .zero
    @State private var toolbarWidth: CGFloat = 960
    @FocusState private var allToolsFocused: Bool
    @State private var pageText = "1"
    @FocusState private var searchFocused: Bool
    @FocusState private var pageFocused: Bool
    @State private var showingSearch = false

    private var tab: DocumentTab? {
        appState.activeTab
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ViewThatFits(in: .horizontal) {
                navigationControls(compact: false).fixedSize()
                navigationControls(compact: true).fixedSize()
            }
            .frame(width: controlsWidth)
            .position(x: controlsCenter, y: DesignTokens.Layout.toolbarHeight / 2)
            HStack {
                Button(action: appState.toggleAllTools) {
                    Text("All tools")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 80, height: DesignTokens.Layout.toolbarHeight)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if appState.sidebarVisible {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(DesignTokens.Colors.accent)
                                    .frame(height: 2).padding(.horizontal, 10)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusable()
                .focusEffectDisabled()
                .focused($allToolsFocused)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .stroke(allToolsFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear,
                                lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .help(appState.sidebarVisible && appState.activePanel == nil
                      ? "Close all tools (⌃⌘S)" : "All tools (⌃⌘S)")
                .accessibilityLabel("All tools")
                .accessibilityValue(appState.sidebarVisible ? "Expanded" : "Collapsed")
                .disabled(tab == nil)
                Spacer(minLength: 0)
                Button {
                    showingSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .help("Search document (⌘F)")
                .accessibilityLabel("Search document")
                .disabled(tab == nil)
                .popover(isPresented: $showingSearch, arrowEdge: .bottom) {
                    searchField
                        .padding(8)
                        .onAppear { searchFocused = true }
                        .onDisappear { searchFocused = false }
                        .onExitCommand { closeSearch() }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: DesignTokens.Layout.toolbarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
        .onChange(of: appState.sidebarVisible) { _, visible in
            if visible { allToolsFocused = false }
        }
        .onChange(of: appState.toolsFocusRequest) { _, _ in
            // Restore focus after SwiftUI has removed the drawer's controls.
            DispatchQueue.main.async { allToolsFocused = true }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .background(.bar)
        .onChange(of: tab?.currentPage) { _, newValue in
            if let newValue {
                pageText = "\(newValue)"
            }
        }
        .onChange(of: tab?.searchText) { _, _ in
            tab?.updateSearchResults()
            applyCurrentMatch()
        }
        .onChange(of: tab?.currentMatchIndex) { _, _ in applyCurrentMatch() }
        .onChange(of: appState.pageFocusRequest) { _, _ in
            showingSearch = false
            pageFocused = true
        }
        .onChange(of: appState.searchFocusRequest) { _, _ in
            showingSearch = true
            searchFocused = true
        }
        .onChange(of: tab?.rotationDegrees) { _, _ in
            applyRotation()
        }
        .onChange(of: tab?.id) { _, _ in
            showingSearch = false
            pageText = "\(tab?.currentPage ?? 1)"
            // The PDFView is shared across tabs; restore this tab's search
            // highlight and canvas rotation. Deferred one runloop turn so
            // the representable has swapped in the tab's document first.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    applyCurrentMatch()
                    applyRotation()
                }
            }
        }
        .onChange(of: appState.activePanel) { _, _ in
            // Organize Pages swaps the canvas, recreating the PDFView.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    applyRotation()
                }
            }
        }
        .onAppear {
            pageText = "\(tab?.currentPage ?? 1)"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    applyCurrentMatch()
                    applyRotation()
                }
            }
        }
    }

    // Center over the actual page viewport as either drawer is resized, but
    // reserve room for the persistent All tools and Search targets at the edges.
    private var controlsCenter: CGFloat {
        let desired = canvasFrame.width > 0 ? canvasFrame.midX : toolbarWidth / 2
        return min(max(desired, 230), max(230, toolbarWidth - 170))
    }

    private var controlsWidth: CGFloat {
        max(250, 2 * min(controlsCenter - 100, toolbarWidth - 40 - controlsCenter))
    }

    private func navigationControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            pageNavigation
            separator
            if compact {
                Menu {
                    Button("Zoom in") { zoom(.in) }
                    Button("Zoom out") { zoom(.out) }
                    Button("Fit width") { fitWidth() }
                    Button("Fit page") { fitPage() }
                    Button("Actual size") { tab?.setZoom(1) }
                } label: { Text(ZoomController.percentString(tab?.zoomFactor ?? 1)) }
                .frame(width: 70)
                .help("Zoom and fit options").accessibilityLabel("Zoom and fit options")
            } else {
                zoomControls
            }
            Menu {
                ForEach(PDFViewMode.allCases) { mode in
                    Button(mode.title) { tab?.viewMode = mode }
                }
            } label: {
                Image(systemName: tab?.viewMode.symbolName ?? "rectangle.portrait")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("Page layout")
            .accessibilityLabel("Page layout: \(tab?.viewMode.title ?? "Single Page")")
        }
    }

    // MARK: - Page navigation

    private var pageNavigation: some View {
        HStack(spacing: 4) {
            Button {
                appState.navigatePage(.previous)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab == nil || (tab?.currentPage ?? 1) <= 1)
            .help("Previous page (⌘Page Up)")
            .accessibilityLabel("Previous page")

            TextField("", text: $pageText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 36)
                .focused($pageFocused)
                .accessibilityLabel("Page number")
                .help("Go to page (⇧⌘N)")
                .onSubmit {
                    guard let tab else { return }
                    tab.goToPage(Int(pageText) ?? tab.currentPage)
                    pageText = "\(tab.currentPage)"
                    pageFocused = false
                    // Let SwiftUI finish resigning the page field before
                    // handing reading keys back to the document canvas.
                    DispatchQueue.main.async {
                        guard appState.activeTabID == tab.id,
                              let view = appState.pdfViewStore.pdfView,
                              view.document === tab.pdfDocument else { return }
                        view.window?.makeFirstResponder(view)
                    }
                }

            Text("of \(max(tab?.pageCount ?? 0, 0))")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.mutedText)

            Button {
                appState.navigatePage(.next)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab == nil || (tab?.currentPage ?? 1) >= (tab?.pageCount ?? 1))
            .help("Next page (⌘Page Down)")
            .accessibilityLabel("Next page")
        }
    }

    // MARK: - Zoom

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                zoom(.out)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab == nil)
            .help("Zoom out (⌘−)")
            .accessibilityLabel("Zoom out")

            Text(ZoomController.percentString(tab?.zoomFactor ?? 1.0))
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.text)
                .frame(width: 44)

            Button {
                zoom(.in)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab == nil)
            .help("Zoom in (⌘=)")
            .accessibilityLabel("Zoom in")

            Button {
                fitWidth()
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab == nil)
            .help("Fit width")
            .accessibilityLabel("Fit width")

            Button {
                fitPage()
            } label: {
                Image(systemName: "rectangle.arrowtriangle.2.outward")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab == nil)
            .help("Fit page")
            .accessibilityLabel("Fit page")

            Button {
                rotate()
            } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(tab?.allowsSaveEdits != true)
            .help("Rotate page clockwise")
            .accessibilityLabel("Rotate page clockwise")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - View mode

    private var viewModePicker: some View {
        HStack(spacing: 1) {
            ForEach(PDFViewMode.allCases) { mode in
                Button {
                    tab?.viewMode = mode
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(tab?.viewMode == mode ? DesignTokens.Colors.accent : DesignTokens.Colors.text)
                        .background(tab?.viewMode == mode ? DesignTokens.Colors.accentTint : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .disabled(tab == nil)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(tab?.viewMode == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DesignTokens.Colors.inset)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Search

    /// Two-way bridge onto the active tab's search state (per-tab, so the
    /// query and matches survive tab switches).
    private var searchBinding: Binding<String> {
        Binding(
            get: { tab?.searchText ?? "" },
            set: { tab?.searchText = $0 }
        )
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignTokens.Colors.mutedText)
            TextField("Find in document", text: searchBinding)
                .focused($searchFocused)
                .onExitCommand { closeSearch() }
                .textFieldStyle(.plain)
                .accessibilityLabel("Search document")
                .help("Find text (Return for next match)")
                .disabled(tab == nil)
                .onSubmit {
                    tab?.goToNextMatch()
                    applyCurrentMatch()
                }
            if tab?.isSearching == true {
                Button { tab?.cancelSearch() } label: { Image(systemName: "xmark.circle") }
                    .help("Stop searching").accessibilityLabel("Stop searching")
            }
            if let countText = tab?.searchCountText {
                Text(countText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                Button {
                    tab?.goToPreviousMatch()
                    applyCurrentMatch()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .disabled(tab?.currentMatch == nil)
                .help("Previous match (⇧⌘G)")
                .accessibilityLabel("Previous match")
                Button {
                    tab?.goToNextMatch()
                    applyCurrentMatch()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing())
                .disabled(tab?.currentMatch == nil)
                .help("Next match (⌘G)")
                .accessibilityLabel("Next match")
            }
            Menu {
                Toggle("Whole words", isOn: Binding(
                    get: { tab?.searchWholeWords ?? false },
                    set: { tab?.searchWholeWords = $0 }
                ))
                Toggle("Case sensitive", isOn: Binding(
                    get: { tab?.searchCaseSensitive ?? false },
                    set: { tab?.searchCaseSensitive = $0 }
                ))
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Search options")
            .accessibilityLabel("Search options")
            Divider().frame(height: 20)
            Button { closeSearch() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .help("Close search (Esc)")
            .accessibilityLabel("Close search")
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(width: 380, height: 36)
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
    }

    private func closeSearch() {
        tab?.searchText = ""
        tab?.cancelSearch()
        searchFocused = false
        showingSearch = false
    }

    private var separator: some View {
        Rectangle()
            .fill(DesignTokens.Colors.hairline)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 6)
    }

    // MARK: - Actions

    private func zoom(_ direction: ZoomDirection) {
        guard let tab else { return }
        tab.setZoom(ZoomController.steppedZoom(from: tab.zoomFactor, direction: direction))
    }

    private func fitWidth() {
        guard let tab, let pdfView = appState.pdfViewStore.pdfView else { return }
        ZoomController.fitWidth(for: tab, in: pdfView)
    }

    private func fitPage() {
        guard let tab, let pdfView = appState.pdfViewStore.pdfView else { return }
        ZoomController.fitPage(for: tab, in: pdfView)
    }

    /// Rotate the actual page; Undo and native Save preserve this change.
    private func rotate() {
        guard let tab else { return }
        do { try appState.rotatePage(tab.currentPage - 1, in: tab) }
        catch { appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription) }
    }

    /// Highlight the tab's current search match in the PDFView and scroll
    /// it into view; clears the selection when there is nothing to show.
    private func applyCurrentMatch() {
        guard let tab,
              let pdfView = appState.pdfViewStore.pdfView,
              pdfView.document === tab.pdfDocument else { return }
        if let match = tab.currentMatch {
            pdfView.setCurrentSelection(match, animate: !(reduceMotion || accessibility.reduceMotion))
            pdfView.scrollSelectionToVisible(nil)
        } else {
            pdfView.setCurrentSelection(nil, animate: false)
        }
    }

    /// Apply the tab's view-only rotation to the shared PDFView.
    private func applyRotation() {
        guard let tab,
              let pdfView = appState.pdfViewStore.pdfView else { return }
        tab.viewRotation.apply(degrees: tab.rotationDegrees, to: pdfView)
    }
}
