import SwiftUI
import PDFKit

/// Existing AcroForms are edited in PDFKit's native widgets and saved by
/// the native session. Signature placement and name-based quick-fill are
/// not exposed until their complete save workflows are supported.
struct FillSignPanel: View {
    @Environment(AppState.self) private var appState

    @State private var review: Review?
    private struct Review: Identifiable { let id = UUID(); let tab: DocumentTab; let page: PDFPage; let detect: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            Text(hasFields ? "Fill fields on the page" : "No fillable fields found")
                .font(.system(size: 13, weight: .semibold))
            PanelNote(hasFields
                      ? "Click an editable field in the document to enter text or choose an option. Use Tab to move between fields, then Save to keep your changes."
                      : "This document has no existing form fields to fill.")
            Button("Detect fields on this page") { openReview(detect: true) }
                .tint(DesignTokens.Colors.accent)
                .help("Suggest fields from empty boxes and lines on the current page. Review before adding.")
            Button("Add a field manually") { openReview(detect: false) }
                .tint(DesignTokens.Colors.accent)
                .help("Draw a text field or checkbox, or place one using its coordinates.")
        }
        .disabled(appState.activeTab?.allowsSaveEdits != true)
        .sheet(item: $review) { review in
            FormFieldReviewView(tab: review.tab, page: review.page, detect: review.detect).environment(appState)
        }
    }

    private func openReview(detect: Bool) {
        guard let tab = appState.activeTab, tab.allowsSaveEdits,
              let page = tab.pdfDocument?.page(at: tab.currentPage - 1) else { return }
        review = Review(tab: tab, page: page, detect: detect)
    }

    private var hasFields: Bool {
        let _ = appState.annotationRevision
        guard let document = appState.activeTab?.pdfDocument else { return false }
        // PDFKit temporarily marks widgets read-only while Save is running.
        // Presence must not depend on those transient presentation flags.
        return (0..<document.pageCount).contains { index in
            document.page(at: index)?.annotations.contains {
                $0.type == "Widget" && [.text, .button, .choice].contains($0.widgetFieldType)
            } == true
        }
    }
}
