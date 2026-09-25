import AppKit
import PDFKit
import SwiftUI

/// Bookmarks panel: native outline with add (⌘B), rename (double-click or
/// context menu), delete (⌫), drag to reorder or nest, style and destination
/// edits, and bookmarks built from headings. Every edit is one Undo step that
/// rewrites /Outlines natively; Save keeps it.
struct BookmarksSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var model = BookmarksModel()
    @State private var filter = ""
    @State private var confirmHeadings = false

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }

    var body: some View {
        VStack(spacing: 0) {
            SidebarActionBar {
                SidebarIconButton(title: "New bookmark at current view", symbol: "bookmark.fill", shortcutHint: "⌘B") {
                    addBookmark()
                }.disabled(!canEdit)
                SidebarIconButton(title: "Delete bookmark", symbol: "trash", shortcutHint: "⌫", role: .destructive) {
                    deleteSelection()
                }.disabled(!canEdit || model.selection.isEmpty)
                SidebarIconButton(title: "Expand all", symbol: "arrow.down.right.and.arrow.up.left.circle") {
                    model.expandAllRequest += 1
                }.disabled(model.items.isEmpty)
                SidebarIconButton(title: "Collapse all", symbol: "arrow.up.left.and.arrow.down.right.circle") {
                    model.collapseAllRequest += 1
                }.disabled(model.items.isEmpty)
            } trailing: {
                SidebarMoreMenu {
                    Button("New Bookmark") { addBookmark() }.disabled(!canEdit)
                    Button("New Child Bookmark") { addBookmark(asChild: true) }
                        .disabled(!canEdit || model.selection.count != 1)
                    Button("Rename Bookmark") { model.renameRequest = model.selection.first }
                        .disabled(!canEdit || model.selection.count != 1)
                    Button("Set Destination to Current View") { setDestinationToCurrentView() }
                        .disabled(!canEdit || model.selection.count != 1)
                    Divider()
                    Button("New Bookmarks from Headings…") { confirmHeadings = true }.disabled(!canEdit)
                    Divider()
                    Button("Delete All Bookmarks…", role: .destructive) { model.confirmDeleteAll = true }
                        .disabled(!canEdit || model.items.isEmpty)
                }
            }
            if !model.items.isEmpty || !filter.isEmpty {
                SidebarFilterField(prompt: "Find in bookmarks", text: $filter)
            }
            content
        }
        .task(id: tab.editSource?.hash ?? tab.url?.path) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .zpdfAddBookmark)) { _ in
            if appState.activeTabID == tab.id, canEdit { addBookmark() }
        }
        .alert("Replace bookmarks with headings?", isPresented: $confirmHeadings) {
            Button("Cancel", role: .cancel) {}
            Button("Add to Existing") { buildFromHeadings(replace: false) }
            Button("Replace") { buildFromHeadings(replace: true) }
        } message: {
            Text("zPDF finds headings from text that is larger than the body text and creates nested bookmarks for them. You can undo this.")
        }
        .alert("Delete all bookmarks?", isPresented: $model.confirmDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { commit([], action: "Delete All Bookmarks") }
        } message: { Text("You can undo this with ⌘Z.") }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.items.isEmpty {
            SidebarLoadingState(message: "Loading bookmarks…")
        } else if let error = model.error {
            SidebarEmptyState(symbolName: "exclamationmark.triangle", message: "Bookmarks couldn't be read.",
                              detail: error, actionTitle: "Try Again") { Task { await reload() } }
        } else if !filter.isEmpty {
            filteredList
        } else if model.items.isEmpty {
            SidebarEmptyState(symbolName: "bookmark", message: "No bookmarks",
                              detail: canEdit ? "Add one for the current view with ⌘B, or build them from the document's headings." : nil,
                              actionTitle: canEdit ? "New Bookmarks from Headings…" : nil) { confirmHeadings = true }
        } else {
            BookmarkOutlineView(model: model, canEdit: canEdit,
                                onActivate: navigate, onRename: rename, onMove: move,
                                onDelete: { deleteSelection() }, menu: contextMenu)
            if !canEdit {
                SidebarNotice(symbol: "lock", text: "This document is read-only. Bookmarks can be viewed but not changed.")
            }
        }
    }

    private var filteredList: some View {
        let results = OutlineTree.matches(filter, in: model.items)
        return Group {
            if results.isEmpty {
                SidebarEmptyState(symbolName: "magnifyingglass", message: "No bookmarks match “\(filter)”.")
            } else {
                List(results, id: \.item.id) { result in
                    Button { navigate(result.item) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.item.title).font(.system(size: 12)).lineLimit(2)
                            if !result.path.isEmpty {
                                Text(result.path.joined(separator: " › "))
                                    .font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(result.item.destinationSummary)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Loading & committing

    private func reload() async {
        guard appState.canQuery(tab) else { return }
        model.loading = true
        defer { model.loading = false }
        do {
            let result = try await appState.documentQuery("outline", in: tab, as: OutlineResult.self)
            model.replace(with: result.items)
            model.error = nil
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func commit(_ items: [OutlineItemModel], action: String) {
        let previous = model.items
        model.replace(with: items, keepIDs: true)
        Task {
            let ok = await appState.performDocumentEdit([["op": "set_outline", "items": items.map(\.engineItem)]],
                                                        actionName: action, in: tab)
            if !ok { model.replace(with: previous, keepIDs: true) }
        }
    }

    // MARK: - Actions

    private func navigate(_ item: OutlineItemModel) {
        if let uri = item.uri, let url = URL(string: uri), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        if let page = item.page {
            PDFKitViewHelpers.go(to: page, top: item.fit == "XYZ" || item.fit == "FitH" ? item.top : nil,
                                 left: item.fit == "XYZ" ? item.left : nil, in: appState, tab: tab)
            if let zoom = item.zoom, zoom > 0, item.fit == "XYZ" { tab.setZoom(zoom) }
            if item.fit == "Fit", let view = appState.pdfViewStore.pdfView { ZoomController.fitPage(for: tab, in: view) }
            if item.fit == "FitH", let view = appState.pdfViewStore.pdfView { ZoomController.fitWidth(for: tab, in: view) }
        }
    }

    private func addBookmark(asChild: Bool = false) {
        let view = PDFKitViewHelpers.currentView(in: appState, tab: tab)
        let selectedText = appState.pdfViewStore.pdfView?.currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bookmark = OutlineItemModel(title: (selectedText?.isEmpty == false ? String(selectedText!.prefix(120)) : "Untitled"),
                                        page: view.page, top: view.top, left: view.left, zoom: nil)
        bookmark.fit = view.top == nil ? "Fit" : "XYZ"
        var items = model.items
        if asChild, let parent = model.selection.first {
            OutlineTree.insert([bookmark], under: parent, at: nil, into: &items)
        } else if let selected = model.selection.first, let location = OutlineTree.location(of: selected, in: items) {
            OutlineTree.insert([bookmark], under: location.parent, at: location.index + 1, into: &items)
        } else {
            items.append(bookmark)
        }
        // Acrobat-style: the new bookmark starts in rename mode; the edit is
        // committed once, with its final title, when renaming ends.
        model.pendingNew = bookmark.id
        model.replace(with: items, keepIDs: true)
        model.selection = [bookmark.id]
        model.renameRequest = bookmark.id
    }

    private func rename(_ id: UUID, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = model.items
        let isNew = model.pendingNew == id
        model.pendingNew = nil
        guard let current = OutlineTree.find(id, in: items) else { return }
        if trimmed.isEmpty || trimmed == current.title {
            if isNew { commit(items, action: "Add Bookmark") }
            return
        }
        OutlineTree.update(id, in: &items) { $0.title = trimmed }
        commit(items, action: isNew ? "Add Bookmark" : "Rename Bookmark")
    }

    private func move(_ ids: [UUID], _ parent: UUID?, _ index: Int?) {
        var items = model.items
        guard OutlineTree.move(ids, under: parent, at: index, in: &items) else { NSSound.beep(); return }
        commit(items, action: "Move Bookmark")
    }

    private func deleteSelection() {
        guard canEdit, !model.selection.isEmpty else { return }
        var items = model.items
        let removed = OutlineTree.remove(model.selection, from: &items)
        model.selection = []
        commit(items, action: removed.count > 1 ? "Delete Bookmarks" : "Delete Bookmark")
    }

    private func setDestinationToCurrentView() {
        guard let id = model.selection.first else { return }
        let view = PDFKitViewHelpers.currentView(in: appState, tab: tab)
        var items = model.items
        OutlineTree.update(id, in: &items) { item in
            item.page = view.page; item.top = view.top; item.left = view.left; item.zoom = nil
            item.fit = view.top == nil ? "Fit" : "XYZ"; item.uri = nil; item.destName = nil
        }
        commit(items, action: "Set Bookmark Destination")
    }

    private func toggleStyle(_ id: UUID, bold: Bool) {
        var items = model.items
        OutlineTree.update(id, in: &items) { item in
            if bold { item.bold.toggle() } else { item.italic.toggle() }
        }
        commit(items, action: "Change Bookmark Style")
    }

    private func setColor(_ id: UUID, _ color: [Int]?) {
        var items = model.items
        OutlineTree.update(id, in: &items) { $0.color = color }
        commit(items, action: "Change Bookmark Color")
    }

    private func buildFromHeadings(replace: Bool) {
        Task {
            await appState.performDocumentEdit([["op": "outline_from_headings", "replace": replace]],
                                               actionName: "New Bookmarks from Headings", in: tab)
        }
    }

    private func contextMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu()
        let item = OutlineTree.find(id, in: model.items)
        menu.addItem(ClosureMenuItem("Go to Bookmark") { if let item { navigate(item) } })
        guard canEdit else { return menu }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename") { model.renameRequest = id })
        menu.addItem(ClosureMenuItem("New Bookmark Below") { model.selection = [id]; addBookmark() })
        menu.addItem(ClosureMenuItem("New Child Bookmark") { model.selection = [id]; addBookmark(asChild: true) })
        menu.addItem(ClosureMenuItem("Set Destination to Current View") { model.selection = [id]; setDestinationToCurrentView() })
        menu.addItem(.separator())
        let bold = ClosureMenuItem("Bold") { toggleStyle(id, bold: true) }
        bold.state = item?.bold == true ? .on : .off
        menu.addItem(bold)
        let italic = ClosureMenuItem("Italic") { toggleStyle(id, bold: false) }
        italic.state = item?.italic == true ? .on : .off
        menu.addItem(italic)
        let colors = NSMenu()
        for (name, value) in [("Default", nil), ("Red", [204, 30, 30]), ("Orange", [214, 110, 0]), ("Green", [20, 130, 60]),
                              ("Blue", [20, 90, 200]), ("Purple", [120, 50, 170])] as [(String, [Int]?)] {
            let entry = ClosureMenuItem(name) { setColor(id, value) }
            entry.state = item?.color == value ? .on : .off
            colors.addItem(entry)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete") {
            if !model.selection.contains(id) { model.selection = [id] }
            deleteSelection()
        })
        return menu
    }
}

extension Notification.Name {
    /// View ▸ Add Bookmark (⌘B) → the bookmarks panel of the active tab.
    static let zpdfAddBookmark = Notification.Name("zpdf.addBookmark")
}

/// NSMenuItem that runs a Swift closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

/// Observable panel state shared with the AppKit outline.
@MainActor @Observable
final class BookmarksModel {
    var items: [OutlineItemModel] = []
    var loading = false
    var error: String?
    var selection: Set<UUID> = []
    var renameRequest: UUID?
    var pendingNew: UUID?
    var expandAllRequest = 0
    var collapseAllRequest = 0
    var confirmDeleteAll = false
    /// Expanded rows survive reloads, keyed by title path.
    var expandedPaths: Set<String> = []
    var revision = 0

    func replace(with newItems: [OutlineItemModel], keepIDs: Bool = false) {
        items = newItems
        if !keepIDs {
            if expandedPaths.isEmpty { expandedPaths = Set(Self.openPaths(newItems)) }
            selection = []
        }
        revision += 1
    }

    static func openPaths(_ items: [OutlineItemModel], prefix: String = "") -> [String] {
        items.flatMap { item -> [String] in
            let path = prefix + "/" + item.title
            return (item.open ? [path] : []) + openPaths(item.children, prefix: path)
        }
    }
}

// MARK: - AppKit outline

private final class BookmarkNode: NSObject {
    let item: OutlineItemModel
    let path: String
    var children: [BookmarkNode] = []
    weak var parent: BookmarkNode?
    init(item: OutlineItemModel, path: String) { self.item = item; self.path = path }
}

private let bookmarkDragType = NSPasteboard.PasteboardType("app.zpdf.bookmark")

private struct BookmarkOutlineView: NSViewRepresentable {
    let model: BookmarksModel
    let canEdit: Bool
    let onActivate: (OutlineItemModel) -> Void
    let onRename: (UUID, String) -> Void
    let onMove: ([UUID], UUID?, Int?) -> Void
    let onDelete: () -> Void
    let menu: (UUID) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 24
        outline.usesAutomaticRowHeights = true
        outline.allowsMultipleSelection = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = true
        let column = NSTableColumn(identifier: .init("title"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.registerForDraggedTypes([bookmarkDragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Bookmarks")
        outline.coordinator = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        context.coordinator.rebuild()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.revision != model.revision { coordinator.rebuild() }
        if coordinator.expandAll != model.expandAllRequest {
            coordinator.expandAll = model.expandAllRequest
            coordinator.outline?.expandItem(nil, expandChildren: true)
        }
        if coordinator.collapseAll != model.collapseAllRequest {
            coordinator.collapseAll = model.collapseAllRequest
            coordinator.outline?.collapseItem(nil, collapseChildren: true)
        }
        if let rename = model.renameRequest {
            DispatchQueue.main.async { coordinator.beginRename(rename) }
            model.renameRequest = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        var parent: BookmarkOutlineView
        weak var outline: NSOutlineView?
        var roots: [BookmarkNode] = []
        var revision = -1
        var expandAll = 0
        var collapseAll = 0
        private var restoring = false
        private var editingID: UUID?

        init(_ parent: BookmarkOutlineView) {
            self.parent = parent
            expandAll = parent.model.expandAllRequest
            collapseAll = parent.model.collapseAllRequest
        }

        func rebuild() {
            revision = parent.model.revision
            func build(_ items: [OutlineItemModel], prefix: String, parent: BookmarkNode?) -> [BookmarkNode] {
                items.map { item in
                    let node = BookmarkNode(item: item, path: prefix + "/" + item.title)
                    node.parent = parent
                    node.children = build(item.children, prefix: node.path, parent: node)
                    return node
                }
            }
            roots = build(parent.model.items, prefix: "", parent: nil)
            guard let outline else { return }
            restoring = true
            outline.reloadData()
            func expand(_ nodes: [BookmarkNode]) {
                for node in nodes where !node.children.isEmpty {
                    if parent.model.expandedPaths.contains(node.path) { outline.expandItem(node) }
                    expand(node.children)
                }
            }
            expand(roots)
            let rows = IndexSet(parent.model.selection.compactMap { id in
                allNodes().first { $0.item.id == id }.map { outline.row(forItem: $0) }
            }.filter { $0 >= 0 })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            restoring = false
        }

        func allNodes() -> [BookmarkNode] {
            func walk(_ nodes: [BookmarkNode]) -> [BookmarkNode] { nodes.flatMap { [$0] + walk($0.children) } }
            return walk(roots)
        }

        // Data source
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? BookmarkNode)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? BookmarkNode)?.children[index] ?? roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? BookmarkNode)?.children.isEmpty ?? true)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? BookmarkNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("BookmarkCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 2
                field.cell?.wraps = true
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(image)
                cell.addSubview(field)
                cell.imageView = image
                cell.textField = field
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 14),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                    field.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)
                ])
                return cell
            }()
            let item = node.item
            let symbol = item.uri != nil ? "link" : item.action != nil && item.page == nil ? "bolt" : "bookmark"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            var traits: NSFontDescriptor.SymbolicTraits = []
            if item.bold { traits.insert(.bold) }
            if item.italic { traits.insert(.italic) }
            let base = NSFont.systemFont(ofSize: 12)
            let font = traits.isEmpty ? base : NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 12) ?? base
            let color = item.color.map { NSColor(srgbRed: CGFloat($0[0]) / 255, green: CGFloat($0[1]) / 255,
                                                 blue: CGFloat($0[2]) / 255, alpha: 1) } ?? NSColor.labelColor
            cell.textField?.attributedStringValue = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: color])
            cell.textField?.isEditable = false
            cell.textField?.delegate = self
            cell.toolTip = "\(item.title)\n\(item.destinationSummary)"
            cell.setAccessibilityLabel(item.title)
            cell.setAccessibilityHelp(item.destinationSummary)
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? BookmarkNode else { return }
            parent.model.expandedPaths.insert(node.path)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? BookmarkNode else { return }
            parent.model.expandedPaths.remove(node.path)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !restoring, let outline else { return }
            parent.model.selection = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? BookmarkNode)?.item.id })
        }

        @objc func clicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? BookmarkNode,
                  NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true else { return }
            parent.onActivate(node.item)
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard parent.canEdit, sender.clickedRow >= 0,
                  let node = sender.item(atRow: sender.clickedRow) as? BookmarkNode else { return }
            beginRename(node.item.id)
        }

        func activateSelection() {
            guard let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? BookmarkNode else { return }
            parent.onActivate(node.item)
        }

        func beginRename(_ id: UUID) {
            guard parent.canEdit, let outline, let node = allNodes().first(where: { $0.item.id == id }) else { return }
            var ancestor = node.parent
            while let current = ancestor { outline.expandItem(current); ancestor = current.parent }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            editingID = id
            field.isEditable = true
            field.stringValue = node.item.title
            outline.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let id = editingID else { return }
            editingID = nil
            field.isEditable = false
            let cancelled = (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
            let title = cancelled ? (OutlineTree.find(id, in: parent.model.items)?.title ?? field.stringValue) : field.stringValue
            parent.onRename(id, title)
            outline?.window?.makeFirstResponder(outline)
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let outline, row >= 0, let node = outline.item(atRow: row) as? BookmarkNode else { return nil }
            return parent.menu(node.item.id)
        }

        func deleteSelection() { if parent.canEdit { parent.onDelete() } }

        // Drag and drop
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard parent.canEdit, let node = item as? BookmarkNode else { return nil }
            let entry = NSPasteboardItem()
            entry.setString(node.item.id.uuidString, forType: bookmarkDragType)
            return entry
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard parent.canEdit, info.draggingSource as? NSOutlineView === outlineView else { return [] }
            let ids = draggedIDs(info)
            if let target = item as? BookmarkNode,
               ids.contains(where: { $0 == target.item.id || OutlineTree.isDescendant(target.item.id, of: $0, in: parent.model.items) }) {
                return []
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let ids = draggedIDs(info)
            guard !ids.isEmpty else { return false }
            let target = (item as? BookmarkNode)?.item.id
            parent.onMove(ids, target, index == NSOutlineViewDropOnItemIndex ? nil : index)
            return true
        }

        private func draggedIDs(_ info: NSDraggingInfo) -> [UUID] {
            (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.string(forType: bookmarkDragType).flatMap(UUID.init(uuidString:))
            }
        }
    }
}

/// Outline with Return (go), Delete (remove) and a per-row context menu.
private final class KeyOutlineView: NSOutlineView {
    weak var coordinator: BookmarkOutlineView.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: coordinator?.activateSelection()
        case 51, 117: coordinator?.deleteSelection()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return coordinator?.contextMenu(forRow: row)
    }
}
