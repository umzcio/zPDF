import AppKit
import PDFKit
import SwiftUI

/// Share: materializes the document with current edits into a temporary copy
/// (never the unsaved original) and hands it to the macOS share sheet, Mail,
/// AirDrop or the pasteboard.
@MainActor
enum ShareService {
    /// Keeps shared copies alive while a share service may still read them.
    private static var retained: [NativeWorkDirectory] = []

    static func sharedCopy(of tab: DocumentTab) async throws -> URL {
        let work = try NativeWorkDirectory()
        let name = SafeFileName.make(tab.displayName.lowercased().hasSuffix(".pdf") ? tab.displayName : tab.displayName + ".pdf")
        let target = work.url.appendingPathComponent(name)
        if let source = tab.editSource, let baseline = tab.saveBaseline, let document = tab.pdfDocument {
            let changes = try baseline.changes(in: document)
            if changes.isEmpty {
                try FileManager.default.copyItem(at: source.url, to: target)
            } else {
                let output = try await NativeDocumentBridge.transform(source: source.url, hash: source.hash, changes: changes,
                                                                      ops: NativeOps([["op": "finalize"]]))
                try FileManager.default.copyItem(at: output.url, to: target)
            }
        } else if let url = tab.url {
            try FileManager.default.copyItem(at: url, to: target)
        } else {
            throw NativeSaveError(code: "NOT_READY", message: "Open the document first.")
        }
        retained.append(work)
        if retained.count > 8 { retained.removeFirst() }
        return target
    }

    static func share(_ tab: DocumentTab, appState: AppState, anchor: NSView? = nil, service: NSSharingService.Name? = nil) {
        Task {
            do {
                let url = try await sharedCopy(of: tab)
                if let service, let sharing = NSSharingService(named: service) {
                    sharing.subject = (tab.displayName as NSString).deletingPathExtension
                    guard sharing.canPerform(withItems: [url]) else {
                        throw NativeSaveError(code: "SHARE_UNAVAILABLE", message: "\(sharing.title) isn't available on this Mac.")
                    }
                    sharing.perform(withItems: [url])
                    return
                }
                let picker = NSSharingServicePicker(items: [url])
                let view = anchor ?? appState.pdfViewStore.pdfView ?? NSApp.keyWindow?.contentView
                guard let view else { return }
                let rect = anchor == nil ? NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1) : view.bounds
                picker.show(relativeTo: rect, of: view, preferredEdge: anchor == nil ? .maxY : .minY)
            } catch {
                appState.reportPanelError(error, in: tab)
            }
        }
    }

    static func copyToPasteboard(_ tab: DocumentTab, appState: AppState) {
        Task {
            do {
                let url = try await sharedCopy(of: tab)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            } catch { appState.reportPanelError(error, in: tab) }
        }
    }
}

/// Toolbar share button anchored for the native picker.
struct ShareToolbarButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ShareAnchor { anchor in
            if let tab = appState.activeTab { ShareService.share(tab, appState: appState, anchor: anchor) }
        }
        .frame(width: 28, height: 28)
        .help("Share a copy with your current edits")
        .accessibilityLabel("Share")
        .disabled(appState.activeTab == nil || appState.activeTab?.saveChecking == true)
    }
}

/// An NSButton so NSSharingServicePicker can anchor to a real view.
private struct ShareAnchor: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = "Share a copy with your current edits"
        button.setAccessibilityLabel("Share")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { action(sender) }
    }
}
