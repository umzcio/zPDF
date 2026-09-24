//
//  RootView.swift
//  zPDF
//
//  Purpose: Window title-bar Home and document tabs, then the active view
//  (Home / Document). Owns the window title (active tab name) and
//  the app-level file-open error alert.
//  Phase: 1 — REAL. No TODOs.
//

import SwiftUI

struct RootView: View {
    var lifecycle: AppLifecycle?
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState
    @State private var windowWidth: CGFloat = 960

    var body: some View {
        @Bindable var appState = appState

        activeView
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ReadingPresentationHost(appState: appState).frame(width: 0, height: 0))
        .modifier(FeatureHost())
        .task { await appState.startRecovery() }
        .onAppear {
            lifecycle?.showMainWindow = { openWindow(id: "main") }
            lifecycle?.appState = appState
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // Identify the document by its hosting window as well as its
            // identifier; child popovers also own document commands.
            var window = notification.object as? NSWindow
            var belongsToDocument = false
            while let candidate = window {
                if candidate.identifier?.rawValue == "zpdf.main"
                    || candidate === appState.pdfViewStore.pdfView?.window {
                    belongsToDocument = true
                    break
                }
                window = candidate.parent ?? candidate.sheetParent
            }
            appState.documentWindowIsKey = belongsToDocument
        }
        .onChange(of: appState.preferences.recentFileLimit) { _, count in
            appState.recentFiles.maximumCount = count
        }
        .onChange(of: appState.preferences.restoreOpenDocuments) { _, _ in appState.persistOpenSession() }
        .onChange(of: appState.preferences.rememberReadingPosition) { _, enabled in
            if !enabled { appState.readingHistory.clearPositions() }
        }
        .onChange(of: appState.preferences.rememberSidebar) { _, enabled in
            if enabled { appState.preferences.sidebarVisible = appState.sidebarVisible }
        }
        .onChange(of: appState.preferences.sidebarVisible) { _, visible in
            if appState.preferences.rememberSidebar { appState.sidebarVisible = visible }
        }
        .navigationTitle(appState.activeTab?.displayName ?? Constants.appName)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(id: "zpdf.home", placement: .navigation) {
                HomeToolbarButton(appState: appState)
                    .frame(width: 32, height: 32)
            }
            documentTabs
        }

        .sheet(isPresented: $appState.showingCombine) { CombinePDFsView().environment(appState) }
        .sheet(item: $appState.conversionExport) { request in
            ConversionExportView(request: request).environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.recovery?.showingRecovery == true },
            set: { appState.recovery?.showingRecovery = $0 }
        )) {
            if let recovery = appState.recovery {
                RecoveryView(recovery: recovery, restore: appState.restoreRecovery)
            }
        }
        .alert("PDF Output Ready", isPresented: Binding(
            get: { appState.exportMessage != nil && !appState.showingCombine },
            set: { if !$0 { appState.exportMessage = nil } }
        )) {
            if let url = appState.exportedURL {
                if url.pathExtension.lowercased() == "pdf" {
                    Button("Open PDF") { appState.showAllTools(); appState.openDocument(at: url) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Done", role: .cancel) {}
        } message: { Text(appState.exportMessage ?? "") }
        .alert("Cannot Open File", item: $appState.openError) { error in
            if let stale = error.staleRecentFile {
                Button("Remove from Recents", role: .destructive) {
                    appState.recentFiles.remove(stale)
                }
            }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text("\(error.fileName): \(error.message)")
        }
        .alert("Cannot Complete PDF Action", item: $appState.saveError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text("\(error.fileName): \(error.message)")
        }
    }

    @ToolbarContentBuilder
    private var documentTabs: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) {
                DocumentTabStrip(availableWidth: max(200, windowWidth - 200))
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                DocumentTabStrip(availableWidth: max(200, windowWidth - 200))
            }
        }
    }

    @ViewBuilder
    private var activeView: some View {
        switch appState.railSelection {
        case .home:
            HomeView()
        case .document:
            DocumentView()
        }
    }
}

/// SwiftUI's synthesized NSToolbar button drops `.help`. Use an actual
/// NSButton so its native hover tooltip and accessibility help agree.
private struct HomeToolbarButton: NSViewRepresentable {
    let appState: AppState

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState) }

    func makeNSView(context: Context) -> NSView {
        // A container prevents NSToolbar from synthesizing a replacement
        // button and dropping the original control’s help metadata.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let button = NSButton(frame: container.bounds)
        button.autoresizingMask = [.width, .height]
        container.addSubview(button)
        button.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showHome)
        button.setAccessibilityLabel("Home")
        button.setAccessibilityTitle("Home")
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let button = container.subviews.first as? NSButton else { return }
        let help = "Home"
        container.toolTip = help
        button.toolTip = help
        button.setAccessibilityHelp(help)
        button.setAccessibilityValue(appState.railSelection == .home ? "Selected" : "")
        button.image = NSImage(systemSymbolName: appState.railSelection == .home ? "house.fill" : "house",
                               accessibilityDescription: nil)
        // NSToolbar exposes its item's label/help instead of the child view's.
        DispatchQueue.main.async { [weak container] in
            guard let container, let toolbar = container.window?.toolbar else { return }
            for item in toolbar.items where item.itemIdentifier.rawValue.contains("zpdf.home")
                || item.view.map({ container.isDescendant(of: $0) }) == true {
                item.label = "Home"
                item.toolTip = help
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let appState: AppState
        init(appState: AppState) { self.appState = appState }
        @objc func showHome() { appState.showHome() }
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .frame(width: 1100, height: 700)
}
