import PDFKit
import SwiftUI

/// Consistent action bar under a document panel's title: icon buttons on the
/// leading edge, an optional trailing menu. Every button carries a tooltip,
/// an accessibility label and, where Acrobat has one, its shortcut in the help.
struct SidebarActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 2) {
            leading()
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// 28×28 borderless icon button with hover feedback used across panels.
struct SidebarIconButton: View {
    let title: String
    let symbol: String
    var shortcutHint: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .foregroundStyle(isEnabled ? (role == .destructive && hovering ? Color.red : DesignTokens.Colors.text)
                                 : DesignTokens.Colors.mutedText.opacity(0.6))
                .background(hovering && isEnabled ? DesignTokens.Colors.inset : .clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .onHover { hovering = $0 }
        .help(shortcutHint.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}

/// Trailing "More" menu with the same footprint as SidebarIconButton.
struct SidebarMoreMenu<Content: View>: View {
    var title = "More options"
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Centered icon + message (+ optional action) for empty or unavailable panels.
struct SidebarEmptyState: View {
    let symbolName: String
    let message: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DesignTokens.Colors.mutedText)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.text)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.large)
    }
}

/// Inline progress while a panel loads engine data.
struct SidebarLoadingState: View {
    var message = "Loading…"
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Filter field shared by bookmark, destination and attachment lists.
struct SidebarFilterField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DesignTokens.Colors.mutedText)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(DesignTokens.Colors.inset)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A read-only notice row for panels (e.g. "Read-only document").
struct SidebarNotice: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
            Text(text).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DesignTokens.Colors.inset)
    }
}

/// Simple text-entry prompt used for new names (destinations, bookmarks).
struct NamePromptSheet: View {
    let title: String
    let message: String
    let fieldLabel: String
    @State var text: String
    let confirmTitle: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            TextField(fieldLabel, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel(fieldLabel)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func confirm() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onConfirm(value)
        dismiss()
    }
}


/// Small helpers for navigating the shared PDFView from panels.
enum PDFKitViewHelpers {
    /// Current view as a bookmark/destination target: page, top edge and zoom.
    @MainActor
    static func currentView(in appState: AppState, tab: DocumentTab) -> (page: Int, top: Double?, left: Double?, zoom: Double?) {
        let pageIndex = max(0, tab.currentPage - 1)
        guard let view = appState.pdfViewStore.pdfView, view.document === tab.pdfDocument,
              let page = view.currentPage ?? tab.pdfDocument?.page(at: pageIndex),
              let document = view.document else {
            return (pageIndex, nil, nil, nil)
        }
        let index = document.index(for: page)
        let visible = view.convert(view.bounds, to: page)
        let box = page.bounds(for: .cropBox)
        let top = min(Double(visible.maxY), Double(box.maxY))
        let left = max(Double(visible.minX), Double(box.minX))
        return (index, top, left, Double(view.scaleFactor))
    }

    /// Go to a page, optionally scrolling so `top` (page space) is at the top.
    @MainActor
    static func go(to page: Int, top: Double? = nil, left: Double? = nil, rect: CGRect? = nil,
                   in appState: AppState, tab: DocumentTab) {
        tab.goToPage(page + 1)
        guard let view = appState.pdfViewStore.pdfView, view.document === tab.pdfDocument,
              let target = tab.pdfDocument?.page(at: page) else { return }
        DispatchQueue.main.async {
            if let rect {
                view.go(to: rect, on: target)
            } else if let top {
                let box = target.bounds(for: .cropBox)
                let point = CGPoint(x: left ?? Double(box.minX), y: top)
                view.go(to: PDFDestination(page: target, at: point))
            } else {
                view.go(to: target)
            }
        }
    }
}

