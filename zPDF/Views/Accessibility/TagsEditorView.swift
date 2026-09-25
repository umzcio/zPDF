import PDFKit
import SwiftUI

/// Tags panel editor: the structure tree with type, alternate text, actual
/// text, title and language, plus reorder (up/down), indent/outdent and
/// delete. Each change is one Undo step on the working revision.
struct TagsEditorView: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var root: StructureNode?
    @State private var tagged = true
    @State private var truncated = false
    @State private var selection: String?
    @State private var selectionPath: [Int]?
    @State private var loading = false
    @State private var error: String?
    @State private var draft = NodeDraft()
    @State private var working = false
    @State private var filter = ""

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }
    private var selectedNode: StructureNode? {
        guard let root, let selection else { return nil }
        return root.flattened().first { $0.id == selection }
    }

    struct NodeDraft: Equatable {
        var type = ""
        var alt = ""
        var actualText = ""
        var title = ""
        var lang = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags").font(.headline)
                if truncated {
                    Text("Showing the first 5,000 tags").font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
                TextField("Filter tags", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                    .accessibilityLabel("Filter tags")
            }
            .padding(12)
            Divider()
            HSplitView {
                tree.frame(minWidth: 320, idealWidth: 380)
                inspector.frame(minWidth: 260, idealWidth: 280)
            }
            Divider()
            HStack {
                if working { ProgressView().controlSize(.small) }
                Text("Changes apply immediately and can be undone with ⌘Z.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 560)
        .task(id: tab.editSource?.hash) { await load() }
        .onChange(of: selection) { _, _ in
            if let node = selectedNode {
                draft = NodeDraft(type: node.type, alt: node.alt ?? "", actualText: node.actualText ?? "",
                                  title: node.title ?? "", lang: node.lang ?? "")
                selectionPath = root?.path(to: node.id)
                if let page = node.page { tab.goToPage(page + 1) }
            }
        }
    }

    @ViewBuilder
    private var tree: some View {
        if loading && root == nil {
            ProgressView("Reading tags…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Tags unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !tagged || root == nil {
            ContentUnavailableView {
                Label("No tags", systemImage: "tag.slash")
            } description: {
                Text("This document isn't tagged. Autotag it from the Accessibility tool to create a tag tree.")
            }
        } else if let root {
            let nodes = filter.isEmpty ? (root.children ?? []) : root.flattened().filter {
                $0.type.localizedCaseInsensitiveContains(filter) || ($0.text ?? "").localizedCaseInsensitiveContains(filter)
            }
            List(selection: $selection) {
                if filter.isEmpty {
                    OutlineGroup(nodes, children: \.outlineChildren) { node in row(node).tag(node.id) }
                } else {
                    ForEach(nodes) { node in row(node).tag(node.id) }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Tag tree")
        }
    }

    private func row(_ node: StructureNode) -> some View {
        HStack(spacing: 6) {
            Text("<\(node.type)>")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignTokens.Colors.accent)
            if let text = node.text, !text.isEmpty {
                Text(text).font(.system(size: 11)).lineLimit(1).foregroundStyle(DesignTokens.Colors.text)
            }
            Spacer(minLength: 0)
            if node.isFigure {
                Image(systemName: node.alt?.isEmpty == false ? "text.below.photo" : "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(node.alt?.isEmpty == false ? DesignTokens.Colors.mutedText : .orange)
                    .help(node.alt?.isEmpty == false ? "Alternate text: \(node.alt!)" : "Missing alternate text")
            }
            if let page = node.page {
                Text("p\(page + 1)").font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
        .help(node.text ?? node.type)
    }

    @ViewBuilder
    private var inspector: some View {
        if let node = selectedNode, node.id != "root" {
            Form {
                Section("Tag") {
                    Picker("Type", selection: $draft.type) {
                        ForEach(StandardTag.groups, id: \.0) { group in
                            Section(group.0) { ForEach(group.1, id: \.self) { Text($0).tag($0) } }
                        }
                        if !StandardTag.all.contains(draft.type) { Text(draft.type).tag(draft.type) }
                    }
                    if let role = node.role, role != node.type {
                        LabeledContent("Maps to", value: role)
                    }
                    TextField("Title", text: $draft.title)
                    TextField("Language", text: $draft.lang, prompt: Text("Inherited"))
                }
                Section("Alternate Text") {
                    TextField("Alternate text", text: $draft.alt, axis: .vertical).lineLimit(3...6)
                        .help("A description read instead of the content (required for figures)")
                    TextField("Actual text", text: $draft.actualText, axis: .vertical).lineLimit(2...4)
                        .help("Exact replacement text, for example for text drawn as an image")
                }
                Section {
                    HStack {
                        Button("Apply") { applyDraft(node) }
                            .disabled(!canEdit || !draftChanged(node) || working)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Apply the tag changes (⌘↩)")
                        Spacer()
                    }
                }
                Section("Arrange") {
                    HStack(spacing: 6) {
                        arrangeButton("Move Up", "arrow.up") { move(node, by: -1) }
                        arrangeButton("Move Down", "arrow.down") { move(node, by: 1) }
                        arrangeButton("Outdent", "arrow.left.to.line") { outdent(node) }
                        arrangeButton("Indent", "arrow.right.to.line") { indent(node) }
                        Spacer()
                        Button(role: .destructive) { delete(node) } label: { Image(systemName: "trash") }
                            .help("Delete this tag; its content moves to the parent tag")
                            .accessibilityLabel("Delete tag")
                            .disabled(!canEdit || working)
                    }
                    if let page = node.page {
                        Button("Show on Page \(page + 1)") { tab.goToPage(page + 1) }.buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!canEdit)
        } else {
            ContentUnavailableView("Select a tag", systemImage: "tag", description: Text("Choose a tag to edit its type, alternate text and position."))
        }
    }

    private func arrangeButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22) }
            .help(title)
            .accessibilityLabel(title)
            .disabled(!canEdit || working)
    }

    private func draftChanged(_ node: StructureNode) -> Bool {
        draft != NodeDraft(type: node.type, alt: node.alt ?? "", actualText: node.actualText ?? "",
                           title: node.title ?? "", lang: node.lang ?? "")
    }

    // MARK: - Engine

    private func load() async {
        guard appState.canQuery(tab) else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await appState.documentQuery("structure_tree", in: tab, as: StructureTreeResult.self)
            root = result.root
            tagged = result.tagged
            truncated = result.truncated
            error = nil
            // Ids change after edits; reselect by position.
            if let path = selectionPath, let node = result.root?.node(at: path) {
                selection = node.id
            } else if let selection, result.root?.path(to: selection) == nil {
                self.selection = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func edit(_ edits: [[String: Any]], _ action: String, reselect path: [Int]? = nil) {
        working = true
        if let path { selectionPath = path }
        Task {
            await appState.performDocumentEdit([["op": "edit_structure", "edits": edits]], actionName: action, in: tab)
            working = false
        }
    }

    private func applyDraft(_ node: StructureNode) {
        var set: [String: Any] = [:]
        if draft.type != node.type { set["type"] = draft.type }
        if draft.alt != (node.alt ?? "") { set["alt"] = draft.alt }
        if draft.actualText != (node.actualText ?? "") { set["actual_text"] = draft.actualText }
        if draft.title != (node.title ?? "") { set["title"] = draft.title }
        if draft.lang != (node.lang ?? "") { set["lang"] = draft.lang }
        guard !set.isEmpty else { return }
        edit([["id": node.id, "set": set]], "Edit Tag")
    }

    private func parentInfo(_ node: StructureNode) -> (parent: StructureNode, index: Int, path: [Int])? {
        guard let root, let path = root.path(to: node.id), let last = path.last,
              let parent = root.node(at: Array(path.dropLast())) else { return nil }
        return (parent, last, path)
    }

    private func move(_ node: StructureNode, by delta: Int) {
        guard let info = parentInfo(node) else { return }
        let count = info.parent.children?.count ?? 0
        let target = info.index + delta
        guard target >= 0, target < count else { NSSound.beep(); return }
        // Engine index is the position after removal.
        edit([["id": node.id, "move": ["parent": info.parent.id, "index": target]]], "Move Tag",
             reselect: Array(info.path.dropLast()) + [target])
    }

    private func indent(_ node: StructureNode) {
        guard let info = parentInfo(node), info.index > 0, let sibling = info.parent.children?[info.index - 1] else { NSSound.beep(); return }
        edit([["id": node.id, "move": ["parent": sibling.id, "index": sibling.children?.count ?? 0]]], "Indent Tag",
             reselect: Array(info.path.dropLast()) + [info.index - 1, sibling.children?.count ?? 0])
    }

    private func outdent(_ node: StructureNode) {
        guard let info = parentInfo(node), info.path.count >= 2, let grand = parentInfo(info.parent) else { NSSound.beep(); return }
        edit([["id": node.id, "move": ["parent": grand.parent.id, "index": grand.index + 1]]], "Outdent Tag",
             reselect: Array(grand.path.dropLast()) + [grand.index + 1])
    }

    private func delete(_ node: StructureNode) {
        selection = nil
        selectionPath = nil
        edit([["id": node.id, "delete": true]], "Delete Tag")
    }
}

/// Alternate text for every figure, with a preview cropped from the page.
struct AltTextEditorView: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var figures: [Figure] = []
    @State private var loading = true
    @State private var saving = false
    @State private var decorative: Set<String> = []

    struct Figure: Identifiable {
        let id: String
        let page: Int?
        var alt: String
        let original: String
        var rect: CGRect?
    }

    private var changed: [Figure] { figures.filter { $0.alt != $0.original } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Alternate Text").font(.headline)
                Text("Describe what each figure conveys. Screen readers read this text instead of the image.")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            .padding(16)
            Divider()
            if loading {
                ProgressView("Finding figures…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if figures.isEmpty {
                ContentUnavailableView("No figures", systemImage: "photo",
                                       description: Text("The tag tree has no Figure tags. Autotag the document first if it has images."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach($figures) { $figure in
                            HStack(alignment: .top, spacing: 12) {
                                FigurePreview(document: tab.pdfDocument, page: figure.page, rect: figure.rect)
                                    .frame(width: 120, height: 90)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(figure.page.map { "Figure on page \($0 + 1)" } ?? "Figure").font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        if let page = figure.page {
                                            Button("Show") { tab.goToPage(page + 1) }.buttonStyle(.link).font(.system(size: 11))
                                        }
                                    }
                                    TextField("Describe this figure", text: $figure.alt, axis: .vertical)
                                        .lineLimit(2...4)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Alternate text for figure \(figure.page.map { "on page \($0 + 1)" } ?? "")")
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text(changed.isEmpty ? "" : "\(changed.count) changed").font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changed.isEmpty || saving || !tab.allowsSaveEdits)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let tree = try? await appState.documentQuery("structure_tree", in: tab, as: StructureTreeResult.self),
              let root = tree.root else { return }
        var found = root.flattened().filter(\.isFigure).map {
            Figure(id: $0.id, page: $0.page, alt: $0.alt ?? "", original: $0.alt ?? "", rect: nil)
        }
        for page in Set(found.compactMap(\.page)) {
            guard let order = try? await appState.documentQuery("reading_order", params: ["page": page], in: tab,
                                                                  as: ReadingOrderResult.self) else { continue }
            for item in order.items {
                if let index = found.firstIndex(where: { $0.id == item.id }) { found[index].rect = item.cgRect }
            }
        }
        figures = found
    }

    private func save() {
        saving = true
        let items = changed.map { ["id": $0.id, "alt": $0.alt] }
        Task {
            let ok = await appState.performDocumentEdit([["op": "set_alt_text", "items": items]], actionName: "Set Alternate Text", in: tab)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// Crops a page region into a small preview image.
struct FigurePreview: View {
    let document: PDFDocument?
    let page: Int?
    let rect: CGRect?

    var body: some View {
        Group {
            if let image = render() {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.inset)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        .accessibilityHidden(true)
    }

    private func render() -> NSImage? {
        guard let page, let rect, rect.width > 1, rect.height > 1, let pdfPage = document?.page(at: page) else { return nil }
        let scale = min(240 / rect.width, 180 / rect.height, 3)
        let size = NSSize(width: rect.width * scale, height: rect.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        pdfPage.draw(with: .mediaBox, to: context)
        return image
    }
}
