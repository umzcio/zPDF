import PDFKit
import SwiftUI

/// Popover for creating or editing a link rectangle on the page.
struct LinkEditorView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case web, page
        var id: String { rawValue }
        var title: String { self == .web ? "Open a web page" : "Go to a page" }
    }

    let pageCount: Int
    let isNew: Bool
    let onSave: (LinkDraft.Target) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var kind: Kind
    @State private var url: String
    @State private var page: Int
    @FocusState private var urlFocused: Bool

    init(draft: LinkDraft, pageCount: Int, onSave: @escaping (LinkDraft.Target) -> Void,
         onRemove: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.pageCount = pageCount
        self.isNew = draft.existing == nil
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        switch draft.target {
        case .web(let value):
            _kind = State(initialValue: .web)
            _url = State(initialValue: value)
            _page = State(initialValue: 1)
        case .page(let value):
            _kind = State(initialValue: .page)
            _url = State(initialValue: "https://")
            _page = State(initialValue: value + 1)
        }
    }

    private var normalizedURL: String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("@"), !text.contains(":") { text = "mailto:" + text }
        if !text.contains("://"), !text.hasPrefix("mailto:"), text.contains(".") { text = "https://" + text }
        guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme != "mailto", (parsed.host ?? "").isEmpty { return nil }
        return text
    }

    private var isValid: Bool {
        kind == .web ? normalizedURL != nil : (1...max(1, pageCount)).contains(page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text(isNew ? "New Link" : "Edit Link")
                .font(.headline)
            Picker("Action", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if kind == .web {
                TextField("Web address or email", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onSubmit { save() }
                    .accessibilityLabel("Link address")
                if !url.isEmpty, normalizedURL == nil, url != "https://" {
                    Text("Enter a web address (https://…) or an email address.")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
            } else {
                HStack {
                    Text("Page")
                    TextField("Page", value: $page, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .onSubmit { save() }
                        .accessibilityLabel("Destination page number")
                    Stepper("Destination page", value: $page, in: 1...max(1, pageCount))
                        .labelsHidden()
                    Text("of \(pageCount)")
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
            HStack {
                if !isNew {
                    Button("Remove Link", role: .destructive) { onRemove() }
                        .help("Delete this link from the page")
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Link" : "Update") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(width: 300)
        .onAppear { urlFocused = kind == .web }
    }

    private func save() {
        guard isValid else { return }
        onSave(kind == .web ? .web(normalizedURL ?? url) : .page(page - 1))
    }
}

extension ContentEditOverlay {
    func showLinkEditor(on page: PDFPage) {
        guard let controller, let draft = controller.linkDraft else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let pageCount = controller.tab?.pdfDocument?.pageCount ?? 1
        let view = LinkEditorView(draft: draft, pageCount: pageCount, onSave: { [weak controller, weak popover] target in
            guard let controller, var draft = controller.linkDraft else { return }
            draft.target = target
            popover?.performClose(nil)
            controller.saveLink(draft)
        }, onRemove: { [weak controller, weak popover] in
            popover?.performClose(nil)
            guard let controller, let draft = controller.linkDraft, let existing = draft.existing else { return }
            controller.removeLink(existing, page: draft.page)
        }, onCancel: { [weak controller, weak popover] in
            popover?.performClose(nil)
            controller?.linkDraft = nil
            controller?.selectedLink = nil
            controller?.overlay.needsDisplay = true
        })
        popover.contentViewController = NSHostingController(rootView: view)
        let anchor = viewRect(draft.rect, on: page)
        popover.show(relativeTo: anchor.insetBy(dx: -2, dy: -2), of: self, preferredEdge: .maxY)
    }
}
