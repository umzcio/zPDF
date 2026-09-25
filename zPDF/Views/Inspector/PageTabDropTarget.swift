import SwiftUI

/// Lets a page thumbnail dragged from Organize Pages be dropped on another
/// document's tab: the page (with that document's unsaved edits) is added
/// at the end of the target document as one Undo step.
struct PageTabDropTarget: ViewModifier {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .stroke(DesignTokens.Colors.accent, lineWidth: 2)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .dropDestination(for: String.self) { items, _ in
                targeted = false
                guard let token = items.first, appState.acceptsForeignPageDrag(into: tab) else { return false }
                Task {
                    if await appState.dropForeignPage(token, at: tab.pageCount, in: tab) {
                        appState.exportMessage = nil
                    }
                }
                return true
            } isTargeted: { value in
                targeted = value && appState.acceptsForeignPageDrag(into: tab)
            }
    }
}

extension ToolID {
    /// Tools that read a document or create new files, so they stay
    /// available for read-only documents.
    var worksOnReadOnlyDocuments: Bool {
        switch self {
        case .createPDF, .compareFiles: true
        default: false
        }
    }
}
