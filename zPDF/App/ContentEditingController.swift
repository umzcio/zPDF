import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Canvas tools that edit page content (Edit PDF) or mark redactions.
/// Only one canvas interaction is live at a time: a tool is active while
/// `AppState.textEditingModeActive` is on, which every tool switch, tab
/// switch and panel close already resets.
enum CanvasTool: String, CaseIterable, Identifiable {
    case edit, addText, addImage, link, crop, redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Edit Text & Images"
        case .addText: "Add Text"
        case .addImage: "Add Image"
        case .link: "Link"
        case .crop: "Crop Pages"
        case .redact: "Mark for Redaction"
        }
    }

    var shortTitle: String {
        switch self {
        case .edit: "Edit"
        case .addText: "Add Text"
        case .addImage: "Add Image"
        case .link: "Link"
        case .crop: "Crop"
        case .redact: "Mark"
        }
    }

    var symbolName: String {
        switch self {
        case .edit: "cursorarrow.rays"
        case .addText: "character.textbox"
        case .addImage: "photo.badge.plus"
        case .link: "link"
        case .crop: "crop"
        case .redact: "rectangle.dashed.badge.record"
        }
    }

    var hint: String {
        switch self {
        case .edit: "Click text to edit it in place. Click an image or artwork to select it; drag to move, drag a handle to resize. Shift-click to select several."
        case .addText: "Click where the text should start, or drag to set the box width. Click outside the box when you're done."
        case .addImage: "Click to place the image at its natural size, or drag to set its size."
        case .link: "Drag to draw a new link. Click an existing link to edit or remove it."
        case .crop: "Drag on the page to set the crop area, adjust it with the handles, then choose Apply."
        case .redact: "Drag across text to mark it. Drag in an empty area — or hold Option — to mark a rectangle. Click a mark to select it."
        }
    }
}

/// What is selected on the canvas.
struct CanvasSelection: Equatable {
    /// Live document page index (current page order).
    let page: Int
    let digest: String
    var block: Int?
    var objects: [String] = []

    var isEmpty: Bool { block == nil && objects.isEmpty }
}

@MainActor
@Observable
final class ContentEditingController {
    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored let overlay = ContentEditOverlay()

    var tool: CanvasTool?
    var selection: CanvasSelection?
    var isBusy = false
    /// Short feedback shown in the panel (substitutions, counts).
    var notice: String?
    /// Page content per live page (keyed by page identity + revision).
    @ObservationIgnored private var cache: [ObjectIdentifier: (hash: String, content: PageContent)] = [:]
    @ObservationIgnored private var loading: Set<ObjectIdentifier> = []
    var contentRevision = 0

    // Add Image
    var pendingImage: URL?
    var pendingImageSize: CGSize?

    // Crop
    var cropRect: CGRect?
    var cropPage: Int?

    // Links
    var links: [Int: [PageLink]] = [:]
    var selectedLink: PageLink?
    var linkDraft: LinkDraft?

    // Inline text editing
    var isEditingText: Bool { overlay.editor != nil }
    var editorRevision = 0

    // Formatting shown in the panel (selection or inline editor).
    var format = TextFormat()

    // Redaction
    var redactionAppearance = RedactionAppearance()
    var selectedMark: RedactionMarkAnnotation?
    var markRevision = 0
    var lastReport: RedactionReport?
    var findRequest = 0
    /// Page design sheet to open (menu commands, Bates Numbering tool).
    var designRequest: PageDesignKind?
    /// Opens the Remove Hidden Information sheet (menu command).
    var sanitizeRequest = 0
    var sanitizeSummary: String?

    init(appState: AppState) {
        self.appState = appState
        overlay.controller = self
    }

    var tab: DocumentTab? { appState?.activeTab }
    var pdfView: PDFView? { appState?.pdfViewStore.pdfView }
    var isActive: Bool {
        guard let appState, appState.textEditingModeActive, tool != nil, let tab = appState.activeTab else { return false }
        return tab.allowsSaveEdits && pdfView?.document === tab.pdfDocument
    }

    // MARK: - Tool lifecycle

    func activate(_ newTool: CanvasTool) {
        guard let appState, let tab = appState.activeTab, tab.allowsSaveEdits else { return }
        if tool == newTool && appState.textEditingModeActive { return }
        finishEditing(commit: true)
        if !appState.textEditingModeActive {
            appState.toggleTextEditingMode()
        }
        tool = newTool
        selection = nil
        selectedLink = nil
        selectedMark = nil
        linkDraft = nil
        notice = nil
        if newTool != .crop { cropRect = nil; cropPage = nil }
        attachOverlay()
        prefetchVisiblePages()
        if newTool == .link { loadLinks(forCurrentPage: true) }
        if let pdfView { pdfView.window?.makeFirstResponder(overlay) }
        overlay.needsDisplay = true
    }

    /// Toggle a tool: activating the active tool turns canvas editing off.
    func toggle(_ newTool: CanvasTool) {
        if tool == newTool && isActive { deactivate() } else { activate(newTool) }
    }

    func deactivate() {
        finishEditing(commit: true)
        tool = nil
        selection = nil
        selectedLink = nil
        selectedMark = nil
        linkDraft = nil
        cropRect = nil
        pendingImage = nil
        if appState?.textEditingModeActive == true { appState?.toggleTextEditingMode() }
        overlay.needsDisplay = true
        if let pdfView { pdfView.window?.makeFirstResponder(pdfView) }
    }

    /// Called when AppState turned editing off behind our back (tool switch,
    /// tab switch, panel closed).
    func syncWithAppState() {
        guard let appState else { return }
        if !appState.textEditingModeActive, tool != nil {
            finishEditing(commit: true)
            tool = nil
            selection = nil
            selectedMark = nil
            linkDraft = nil
            overlay.needsDisplay = true
        }
    }

    func attachOverlay() {
        guard let pdfView else { return }
        overlay.attach(to: pdfView)
    }

    // MARK: - Page content cache

    func content(for page: PDFPage) -> PageContent? {
        guard let tab, let hash = tab.editSource?.hash, let entry = cache[ObjectIdentifier(page)], entry.hash == hash else {
            return nil
        }
        return entry.content
    }

    func invalidateContent() {
        cache.removeAll()
        links.removeAll()
        contentRevision += 1
    }

    func prefetchVisiblePages() {
        guard let pdfView, let document = pdfView.document else { return }
        var pages = pdfView.visiblePages
        if let current = pdfView.currentPage, !pages.contains(current) { pages.append(current) }
        for page in pages where document.index(for: page) != NSNotFound { load(page) }
    }

    func load(_ page: PDFPage, completion: (() -> Void)? = nil) {
        guard let appState, let tab, let hash = tab.editSource?.hash,
              let source = PageContentService.sourceIndex(of: page, in: tab) else { return }
        let key = ObjectIdentifier(page)
        if let entry = cache[key], entry.hash == hash { completion?(); return }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            defer { self?.loading.remove(key) }
            do {
                let result = try await PageContentService.content(of: [source], in: appState, tab: tab)
                guard let self, tab.editSource?.hash == hash, let content = result.first else { return }
                self.cache[key] = (hash, content)
                self.contentRevision += 1
                self.overlay.needsDisplay = true
                completion?()
            } catch {
                self?.notice = error.localizedDescription
            }
        }
    }

    // MARK: - Selection helpers

    func selectedBlock(on page: PDFPage) -> TextBlock? {
        guard let selection, let block = selection.block, let content = content(for: page),
              selection.digest == content.digest else { return nil }
        return content.blocks.first { $0.id == block }
    }

    func selectedObjects(on page: PDFPage) -> [ContentObject] {
        guard let selection, let content = content(for: page), selection.digest == content.digest else { return [] }
        return content.objects.filter { selection.objects.contains($0.id) }
    }

    var selectionPage: PDFPage? {
        guard let selection, let document = tab?.pdfDocument else { return nil }
        return document.page(at: selection.page)
    }

    var selectedBlock: TextBlock? { selectionPage.flatMap { selectedBlock(on: $0) } }
    var selectedObjectsList: [ContentObject] { selectionPage.map { selectedObjects(on: $0) } ?? [] }

    func select(block: TextBlock?, objects: [String] = [], on page: PDFPage, content: PageContent) {
        guard let document = tab?.pdfDocument else { return }
        let index = document.index(for: page)
        if block == nil && objects.isEmpty {
            selection = nil
        } else {
            selection = CanvasSelection(page: index, digest: content.digest, block: block?.id, objects: objects)
        }
        if let block { format = TextFormat(block: block) }
        overlay.needsDisplay = true
    }

    func clearSelection() {
        selection = nil
        selectedLink = nil
        selectedMark = nil
        overlay.needsDisplay = true
    }

    // MARK: - Running operations

    /// Runs engine ops as one Undo step; refreshes content and reselects.
    func perform(_ ops: [[String: Any]], name: String, reselect: ((PDFPage, PageContent) -> Void)? = nil,
                 completion: (([NativeJSON]) -> Void)? = nil) {
        guard let appState, let tab, !isBusy else { return }
        isBusy = true
        let pageIndex = selection?.page ?? cropPage ?? (tab.currentPage - 1)
        Task { [weak self] in
            defer { self?.isBusy = false }
            do {
                let results = try await appState.applyDocumentTransform(ops, to: tab, actionName: name)
                guard let self else { return }
                self.invalidateContent()
                self.selection = nil
                self.selectedLink = nil
                completion?(results)
                if let page = tab.pdfDocument?.page(at: min(pageIndex, max(0, (tab.pdfDocument?.pageCount ?? 1) - 1))) {
                    self.load(page) { [weak self] in
                        guard let self, let content = self.content(for: page) else { return }
                        reselect?(page, content)
                        self.overlay.needsDisplay = true
                    }
                }
                self.prefetchVisiblePages()
                self.overlay.needsDisplay = true
                if self.tool == .link { self.loadLinks(forCurrentPage: true) }
            } catch {
                self?.notice = nil
                appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
                self?.invalidateContent()
                self?.prefetchVisiblePages()
            }
        }
    }

    func livePageIndex(_ page: PDFPage) -> Int? {
        guard let document = tab?.pdfDocument else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    // MARK: - Objects

    func transformSelection(_ transform: CGAffineTransform, name: String) {
        guard let page = selectionPage, let selection, let index = livePageIndex(page) else { return }
        if let block = selectedBlock(on: page) {
            editBlock(block, on: page, transform: transform, name: name)
            return
        }
        let objects = selectedObjects(on: page)
        guard !objects.isEmpty else { return }
        guard objects.allSatisfy(\.movable) else {
            notice = "This artwork also clips other content, so it can't be moved on its own."
            return
        }
        let predicted = objects.map { ($0.kind, $0.bbox.applying(transform)) }
        perform([["op": "object_transform", "page": index, "digest": selection.digest, "ids": selection.objects,
                  "matrix": transform.pdfMatrix]], name: name) { [weak self] page, content in
            self?.reselectObjects(predicted, on: page, content: content)
        }
    }

    func reselectObjects(_ predicted: [(ContentObject.Kind, CGRect)], on page: PDFPage, content: PageContent) {
        var ids: [String] = []
        for (kind, rect) in predicted {
            let match = content.objects
                .filter { $0.kind == kind }
                .min { $0.bbox.distance(to: rect) < $1.bbox.distance(to: rect) }
            if let match, match.bbox.distance(to: rect) < 2, !ids.contains(match.id) { ids.append(match.id) }
        }
        if !ids.isEmpty { select(block: nil, objects: ids, on: page, content: content) }
    }

    func deleteSelection() {
        guard let page = selectionPage, let selection, let index = livePageIndex(page) else { return }
        if let block = selectedBlock(on: page) {
            perform([["op": "edit_text_block", "page": index, "block": block.id, "digest": selection.digest, "delete": true]],
                    name: "Delete Text")
            return
        }
        guard !selection.objects.isEmpty else { return }
        let count = selection.objects.count
        perform([["op": "object_delete", "page": index, "digest": selection.digest, "ids": selection.objects]],
                name: count == 1 ? "Delete Object" : "Delete Objects")
    }

    func arrangeSelection(toFront: Bool) {
        guard let page = selectionPage, let selection, let index = livePageIndex(page), !selection.objects.isEmpty else { return }
        let predicted = selectedObjects(on: page).map { ($0.kind, $0.bbox) }
        perform([["op": "object_arrange", "page": index, "digest": selection.digest, "ids": selection.objects,
                  "to": toFront ? "front" : "back"]], name: toFront ? "Bring to Front" : "Send to Back") { [weak self] page, content in
            self?.reselectObjects(predicted, on: page, content: content)
        }
    }

    enum Alignment: String, CaseIterable, Identifiable {
        case left, center, right, top, middle, bottom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .left: "Align Left"
            case .center: "Align Centers Horizontally"
            case .right: "Align Right"
            case .top: "Align Top"
            case .middle: "Align Centers Vertically"
            case .bottom: "Align Bottom"
            }
        }
        var symbolName: String {
            switch self {
            case .left: "align.horizontal.left"
            case .center: "align.horizontal.center"
            case .right: "align.horizontal.right"
            case .top: "align.vertical.top"
            case .middle: "align.vertical.center"
            case .bottom: "align.vertical.bottom"
            }
        }
    }

    /// Aligns several selected objects to their common bounds (visual orientation).
    func alignSelection(_ alignment: Alignment) {
        guard let page = selectionPage, let selection, let index = livePageIndex(page) else { return }
        let objects = selectedObjects(on: page)
        guard objects.count > 1 else { return }
        let toVisual = page.visualTransform
        let visual = objects.map { $0.bbox.applying(toVisual) }
        let union = visual.dropFirst().reduce(visual[0]) { $0.union($1) }
        var items: [[String: Any]] = []
        var predicted: [(ContentObject.Kind, CGRect)] = []
        for (object, rect) in zip(objects, visual) {
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch alignment {
            case .left: dx = union.minX - rect.minX
            case .center: dx = union.midX - rect.midX
            case .right: dx = union.maxX - rect.maxX
            case .top: dy = union.maxY - rect.maxY
            case .middle: dy = union.midY - rect.midY
            case .bottom: dy = union.minY - rect.minY
            }
            let user = CGAffineTransform(translationX: dx, y: dy).conjugated(by: toVisual)
            predicted.append((object.kind, object.bbox.applying(user)))
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                items.append(["id": object.id, "matrix": user.pdfMatrix])
            }
        }
        guard !items.isEmpty else { return }
        perform([["op": "object_transform", "page": index, "digest": selection.digest, "items": items]],
                name: alignment.title) { [weak self] page, content in
            self?.reselectObjects(predicted, on: page, content: content)
        }
    }

    /// Free rotation (degrees, clockwise on screen) about the selection's center.
    func rotateSelection(freeDegrees degrees: CGFloat) {
        guard abs(degrees) > 0.01 else { return }
        rotateSelection(degrees: degrees)
    }

    func rotateSelection(degrees: CGFloat) {
        guard let page = selectionPage else { return }
        let box = selectionBounds(on: page)
        guard !box.isNull else { return }
        // Rotation is visual: clockwise on screen regardless of page rotation.
        let t = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: box.midX, y: box.midY))
        transformSelection(t, name: degrees > 0 ? "Rotate Clockwise" : "Rotate Counterclockwise")
    }

    func flipSelection(horizontal: Bool) {
        guard let page = selectionPage else { return }
        let box = selectionBounds(on: page)
        guard !box.isNull else { return }
        let toVisual = page.visualTransform
        let visualBox = box.applying(toVisual)
        let flip = CGAffineTransform(translationX: -visualBox.midX, y: -visualBox.midY)
            .concatenating(CGAffineTransform(scaleX: horizontal ? -1 : 1, y: horizontal ? 1 : -1))
            .concatenating(CGAffineTransform(translationX: visualBox.midX, y: visualBox.midY))
        transformSelection(flip.conjugated(by: toVisual), name: horizontal ? "Flip Horizontal" : "Flip Vertical")
    }

    func selectionBounds(on page: PDFPage) -> CGRect {
        if let block = selectedBlock(on: page) { return block.bbox }
        return selectedObjects(on: page).reduce(CGRect.null) { $0.union($1.bbox) }
    }

    /// Move/resize to an exact rectangle (Position fields).
    func setSelectionFrame(_ rect: CGRect) {
        guard let page = selectionPage else { return }
        let current = selectionBounds(on: page)
        guard !current.isNull, current.width > 0.01, current.height > 0.01 else { return }
        let t = CGAffineTransform(translationX: -current.minX, y: -current.minY)
            .concatenating(CGAffineTransform(scaleX: rect.width / current.width, y: rect.height / current.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        transformSelection(t, name: "Move Object")
    }

    // MARK: - Images

    static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .webP]

    func chooseImage(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.imageTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to place on the page."
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        }
    }

    /// Copies the chosen image to a private file the engine can read.
    func stageImage(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            throw NativeSaveError(code: "INVALID_IMAGE", message: "That file couldn't be read as an image.")
        }
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-image-\(UUID().uuidString).\(isJPEG ? "jpg" : "png")")
        let data: Data?
        if isJPEG { data = try Data(contentsOf: url) } else { data = rep.representation(using: .png, properties: [:]) }
        guard let data else { throw NativeSaveError(code: "INVALID_IMAGE", message: "That image couldn't be prepared.") }
        try data.write(to: staged, options: .atomic)
        return staged
    }

    func beginAddImage() {
        chooseImage { [weak self] url in
            guard let self else { return }
            do {
                let staged = try self.stageImage(url)
                self.pendingImage = staged
                self.pendingImageSize = NSImage(contentsOf: staged).map { image in
                    let rep = image.representations.first
                    let px = CGSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
                    // 72 dpi natural size, like Acrobat.
                    return px.width > 0 ? px : image.size
                }
                self.activate(.addImage)
            } catch {
                self.appState?.saveError = OpenError(fileName: url.lastPathComponent, message: error.localizedDescription)
            }
        }
    }

    func placeImage(on page: PDFPage, rect: CGRect?) {
        guard let image = pendingImage, let index = livePageIndex(page) else { return }
        var target = rect ?? .zero
        if rect == nil || target.width < 4 || target.height < 4 {
            let size = pendingImageSize ?? CGSize(width: 200, height: 150)
            let visual = page.visualBounds
            let scale = min(1, visual.width * 0.5 / max(size.width, 1), visual.height * 0.5 / max(size.height, 1))
            let point = rect?.origin ?? CGPoint(x: page.bounds(for: .cropBox).midX, y: page.bounds(for: .cropBox).midY)
            let vp = point.applying(page.visualTransform)
            let visualRect = CGRect(x: vp.x - size.width * scale / 2, y: vp.y - size.height * scale / 2,
                                    width: size.width * scale, height: size.height * scale)
            target = visualRect.applying(page.visualTransform.inverted())
        }
        perform([["op": "image_add", "page": index, "image": image.path, "rect": target.pdfBox]], name: "Add Image") { [weak self] page, content in
            guard let self else { return }
            if let placed = content.objects.last(where: { $0.kind.isImage && $0.bbox.distance(to: target) < 2 }) {
                self.tool = .edit
                self.select(block: nil, objects: [placed.id], on: page, content: content)
            }
        } completion: { [weak self] _ in
            try? FileManager.default.removeItem(at: image)
            self?.pendingImage = nil
            self?.tool = .edit
        }
    }

    func replaceSelectedImage() {
        guard let page = selectionPage, let selection, let index = livePageIndex(page),
              let object = selectedObjects(on: page).first(where: { $0.kind.isImage }) else { return }
        chooseImage { [weak self] url in
            guard let self else { return }
            do {
                let staged = try self.stageImage(url)
                let bbox = object.bbox
                self.perform([["op": "image_replace", "page": index, "digest": selection.digest, "id": object.id,
                               "image": staged.path]], name: "Replace Image") { [weak self] page, content in
                    if let match = content.objects.first(where: { $0.kind.isImage && bbox.intersects($0.bbox) }) {
                        self?.select(block: nil, objects: [match.id], on: page, content: content)
                    }
                } completion: { _ in try? FileManager.default.removeItem(at: staged) }
            } catch {
                self.appState?.saveError = OpenError(fileName: url.lastPathComponent, message: error.localizedDescription)
            }
        }
    }

    /// Image crop mode: handles set a clip rectangle instead of resizing.
    var isCroppingImage = false
    var imageCropRect: CGRect?

    func beginImageCrop() {
        guard let page = selectionPage, let object = selectedObjects(on: page).first(where: { $0.kind.isImage }) else { return }
        isCroppingImage = true
        imageCropRect = object.bbox
        overlay.needsDisplay = true
    }

    func commitImageCrop() {
        defer { isCroppingImage = false; imageCropRect = nil; overlay.needsDisplay = true }
        guard let page = selectionPage, let selection, let index = livePageIndex(page), let rect = imageCropRect,
              let object = selectedObjects(on: page).first(where: { $0.kind.isImage }) else { return }
        guard rect.insetBy(dx: -0.5, dy: -0.5).contains(object.bbox) == false else { return }
        perform([["op": "image_crop", "page": index, "digest": selection.digest, "id": object.id, "rect": rect.pdfBox]],
                name: "Crop Image") { [weak self] page, content in
            if let match = content.objects.first(where: { $0.kind.isImage && $0.bbox.intersects(rect) }) {
                self?.select(block: nil, objects: [match.id], on: page, content: content)
            }
        }
    }

    func cancelImageCrop() {
        isCroppingImage = false
        imageCropRect = nil
        overlay.needsDisplay = true
    }

    // MARK: - Text blocks

    /// Applies a geometric change (move/resize/rotate) to a text block.
    func editBlock(_ block: TextBlock, on page: PDFPage, transform: CGAffineTransform? = nil, width: Double? = nil, name: String) {
        guard let selection, let index = livePageIndex(page) else { return }
        var op: [String: Any] = ["op": "edit_text_block", "page": index, "block": block.id, "digest": selection.digest]
        if let transform { op["matrix"] = transform.pdfMatrix }
        if let width { op["width"] = width }
        let target = (transform.map { block.bbox.applying($0) } ?? block.bbox)
        perform([op], name: name) { [weak self] page, content in
            if let match = content.blocks.min(by: { $0.bbox.distance(to: target) < $1.bbox.distance(to: target) }),
               match.bbox.distance(to: target) < 6 {
                self?.select(block: match, on: page, content: content)
            }
        }
    }

    /// Commits runs (from the inline editor or a format change) for a block.
    func commitBlock(_ block: TextBlock?, on page: PDFPage, runs: [[String: Any]], align: TextAlignmentChoice,
                     lineSpacing: Double, width: Double?, offset: CGPoint?, point: CGPoint?, digest: String?) {
        guard let index = livePageIndex(page) else { return }
        let ops: [[String: Any]]
        if let block, let digest {
            var op: [String: Any] = ["op": "edit_text_block", "page": index, "block": block.id, "digest": digest,
                                     "runs": runs, "align": align.rawValue, "line_spacing": lineSpacing]
            if let width { op["width"] = width }
            if let offset, abs(offset.x) > 0.01 || abs(offset.y) > 0.01 { op["offset"] = [offset.x, offset.y] }
            ops = [op]
        } else if let point {
            var op: [String: Any] = ["op": "add_text", "page": index, "point": [point.x, point.y], "runs": runs,
                                     "align": align.rawValue, "line_spacing": lineSpacing, "baseline": true]
            if let width { op["width"] = width }
            ops = [op]
        } else { return }
        let anchor = block?.bbox.origin ?? point ?? .zero
        perform(ops, name: block == nil ? "Add Text" : "Edit Text") { [weak self] page, content in
            guard let self else { return }
            let text = runs.compactMap { $0["text"] as? String }.joined()
            let match = content.blocks
                .filter { !text.isEmpty && $0.text.hasPrefix(String(text.prefix(12)).trimmingCharacters(in: .whitespaces)) }
                .min { $0.bbox.origin.distance(to: anchor) < $1.bbox.origin.distance(to: anchor) }
            if let match, self.tool == .edit { self.select(block: match, on: page, content: content) }
        } completion: { [weak self] results in
            let substituted = (results.first?["substituted"] as? [String]) ?? []
            if !substituted.isEmpty {
                self?.notice = "Some characters aren't in the embedded font “\(substituted.joined(separator: "”, “"))”, so zPDF used a matching font from this Mac."
            } else {
                self?.notice = nil
            }
        }
    }

    /// Re-styles the whole selected block (no inline editor).
    func restyleSelectedBlock(_ change: (inout TextFormat) -> Void) {
        guard let page = selectionPage, let block = selectedBlock(on: page), let selection else { return }
        var next = format
        change(&next)
        format = next
        let runs = block.runs.map { run -> [String: Any] in
            let font = next.fontOverride(for: run)
            let size = next.sizeOverride ?? run.size
            return ["text": run.text, "font": font, "size": size,
                    "color": (next.colorOverride ?? run.color).engineRGB]
        }
        commitBlock(block, on: page, runs: runs, align: next.alignment, lineSpacing: next.lineSpacing,
                    width: nil, offset: nil, point: nil, digest: selection.digest)
    }

    // MARK: - Inline editor

    func beginEditing(_ block: TextBlock, on page: PDFPage, content: PageContent, at point: CGPoint?) {
        guard block.editable else {
            notice = "This text uses a font without character information, so it can be moved but not retyped."
            select(block: block, on: page, content: content)
            return
        }
        select(block: block, on: page, content: content)
        overlay.beginEditing(block: block, page: page, digest: content.digest, at: point)
        editorRevision += 1
    }

    func beginNewText(on page: PDFPage, at point: CGPoint, width: Double?) {
        selection = nil
        overlay.beginNewText(page: page, at: point, width: width, format: format)
        editorRevision += 1
    }

    func finishEditing(commit: Bool) {
        guard let editor = overlay.editor else { return }
        overlay.editor = nil
        editor.removeFromSuperview()
        editorRevision += 1
        overlay.needsDisplay = true
        if isActive { overlay.window?.makeFirstResponder(overlay) }
        guard commit, let page = editor.page else { return }
        let result = editor.result()
        if editor.block == nil {
            guard !result.runs.isEmpty, result.plainText.trimmingCharacters(in: .whitespacesAndNewlines) != "" else { return }
            // The engine places the first baseline where the editor shows it.
            var baseline = editor.newTextPoint
            if let point = editor.newTextPoint {
                let visual = point.applying(page.visualTransform)
                baseline = CGPoint(x: visual.x, y: visual.y - editor.firstBaselineOffset).applying(page.visualTransform.inverted())
            }
            commitBlock(nil, on: page, runs: result.runs, align: result.alignment, lineSpacing: result.lineSpacing,
                        width: editor.fixedWidth ? result.width : nil, offset: nil, point: baseline, digest: nil)
            return
        }
        guard let block = editor.block else { return }
        if !result.changedText && !result.changedStyle {
            if result.changedGeometry {
                editBlockGeometry(block, page: page, digest: editor.digest, offset: result.offset, width: result.width)
            }
            return
        }
        if result.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let index = livePageIndex(page) else { return }
            perform([["op": "edit_text_block", "page": index, "block": block.id, "digest": editor.digest, "delete": true]],
                    name: "Delete Text")
            return
        }
        commitBlock(block, on: page, runs: result.runs, align: result.alignment, lineSpacing: result.lineSpacing,
                    width: result.width, offset: result.offset, point: nil, digest: editor.digest)
    }

    private func editBlockGeometry(_ block: TextBlock, page: PDFPage, digest: String, offset: CGPoint, width: Double?) {
        guard let index = livePageIndex(page) else { return }
        var op: [String: Any] = ["op": "edit_text_block", "page": index, "block": block.id, "digest": digest]
        if abs(offset.x) > 0.01 || abs(offset.y) > 0.01 { op["offset"] = [offset.x, offset.y] }
        if let width { op["width"] = width }
        perform([op], name: "Move Text")
    }

    /// Formatting from the panel while editing inline or with a block selected.
    func applyFormat(_ change: (inout TextFormat) -> Void) {
        if let editor = overlay.editor {
            var next = format
            change(&next)
            editor.apply(next, previous: format)
            format = next
            return
        }
        if selectedBlock != nil {
            restyleSelectedBlock(change)
        } else {
            change(&format)
        }
    }

    // MARK: - Links

    func loadLinks(forCurrentPage: Bool) {
        guard let appState, let tab, let pdfView else { return }
        let pages = pdfView.visiblePages
        for page in pages {
            guard let source = PageContentService.sourceIndex(of: page, in: tab), let live = livePageIndex(page) else { continue }
            Task { [weak self] in
                if let found = try? await PageContentService.links(onSourcePage: source, in: appState, tab: tab) {
                    self?.links[live] = found
                    self?.overlay.needsDisplay = true
                }
            }
        }
    }

    func saveLink(_ draft: LinkDraft) {
        var op: [String: Any]
        switch draft.target {
        case .web(let url):
            op = ["uri": url]
        case .page(let page):
            op = ["dest_page": page]
        }
        if let existing = draft.existing {
            op["op"] = "link_update"
            op["index"] = existing.index
            op["rect"] = draft.rect.pdfBox
        } else {
            op["op"] = "link_add"
            op["rect"] = draft.rect.pdfBox
        }
        op["page"] = draft.page
        linkDraft = nil
        perform([op], name: draft.existing == nil ? "Add Link" : "Edit Link")
    }

    func removeLink(_ link: PageLink, page: Int) {
        linkDraft = nil
        selectedLink = nil
        perform([["op": "link_remove", "page": page, "indexes": [link.index]]], name: "Remove Link")
    }

    // MARK: - Crop

    func applyCrop(scope: EditPageScope, margins: EdgeMargins? = nil, removeWhiteMargins: Bool = false) {
        guard let tab, let document = tab.pdfDocument else { return }
        let pages = scope.pages(current: tab.currentPage - 1, count: document.pageCount)
        guard !pages.isEmpty else { return }
        var op: [String: Any] = ["op": "crop_pages", "pages": pages]
        if removeWhiteMargins {
            op["remove_white_margins"] = true
        } else if let margins {
            op["margins"] = [margins.left, margins.bottom, margins.right, margins.top]
        } else if let rect = cropRect {
            if scope == .current || pages.count == 1 {
                op["box"] = rect.pdfBox
            } else if let page = document.page(at: cropPage ?? tab.currentPage - 1) {
                // Same margins on every page, measured on the page the box was drawn on.
                let crop = page.bounds(for: .cropBox)
                let visual = page.visualTransform
                let v = rect.applying(visual), c = crop.applying(visual)
                op["margins"] = [max(0, v.minX - c.minX), max(0, v.minY - c.minY), max(0, c.maxX - v.maxX), max(0, c.maxY - v.maxY)]
            }
        } else { return }
        cropRect = nil
        perform([op], name: "Crop Pages")
    }

    func resetCrop(scope: EditPageScope) {
        guard let tab, let document = tab.pdfDocument else { return }
        let pages = scope.pages(current: tab.currentPage - 1, count: document.pageCount)
        cropRect = nil
        perform([["op": "crop_pages", "pages": pages, "reset": true]], name: "Reset Crop")
    }
}

/// Text formatting controls (panel) state.
struct TextFormat: Equatable {
    var family: String = "Helvetica"
    var size: Double = 12
    var bold = false
    var italic = false
    var color: NSColor = .black
    var alignment: TextAlignmentChoice = .left
    var lineSpacing: Double = 1.2
    // Overrides when restyling a selected block (nil = keep each run's value).
    var familyOverride: String?
    var sizeOverride: Double?
    var boldOverride: Bool?
    var italicOverride: Bool?
    var colorOverride: NSColor?

    init() {}

    init(block: TextBlock) {
        let font = block.style.font(size: CGFloat(block.size))
        family = font.familyName ?? block.style.family
        size = (block.size * 10).rounded() / 10
        bold = block.style.bold
        italic = block.style.italic
        color = block.color
        alignment = block.align
        lineSpacing = (block.lineSpacing * 100).rounded() / 100
    }

    func nsFont(scale: CGFloat = 1) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: CGFloat(size) * scale)
            ?? NSFont(name: "Helvetica", size: CGFloat(size) * scale)!
    }

    /// Font spec for a run when restyling a whole block.
    func fontOverride(for run: TextRun) -> [String: Any] {
        guard familyOverride != nil || boldOverride != nil || italicOverride != nil else {
            return ["original": run.fontKey, "fallback": run.style.font(size: 12).engineSpec]
        }
        let manager = NSFontManager.shared
        var font = run.style.font(size: 12)
        if let familyOverride {
            font = manager.convert(font, toFamily: familyOverride)
        }
        if let boldOverride {
            font = boldOverride ? manager.convert(font, toHaveTrait: .boldFontMask) : manager.convert(font, toNotHaveTrait: .boldFontMask)
        }
        if let italicOverride {
            font = italicOverride ? manager.convert(font, toHaveTrait: .italicFontMask) : manager.convert(font, toNotHaveTrait: .italicFontMask)
        }
        return font.engineSpec
    }

    static func == (a: TextFormat, b: TextFormat) -> Bool {
        a.family == b.family && a.size == b.size && a.bold == b.bold && a.italic == b.italic && a.color == b.color
            && a.alignment == b.alignment && a.lineSpacing == b.lineSpacing
    }
}

/// A link being created or edited.
struct LinkDraft: Equatable {
    enum Target: Equatable {
        case web(String)
        case page(Int)
    }
    var page: Int
    var rect: CGRect
    var target: Target
    var existing: PageLink?
}

struct EdgeMargins: Equatable {
    var left: Double = 0, bottom: Double = 0, right: Double = 0, top: Double = 0
}

/// Page ranges offered by page-level tools.
enum EditPageScope: Equatable, Hashable {
    case current
    case all
    case range(String)

    func pages(current: Int, count: Int) -> [Int] {
        switch self {
        case .current: return [current]
        case .all: return Array(0..<count)
        case .range(let text): return EditPageScope.parse(text, count: count) ?? []
        }
    }

    /// "1-3, 5, 8-" → 0-based indexes; nil when invalid.
    static func parse(_ text: String, count: Int) -> [Int]? {
        var result: [Int] = []
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        for part in parts {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 1, let n = Int(bounds[0]), (1...count).contains(n) {
                result.append(n - 1)
            } else if bounds.count == 2 {
                let lo = bounds[0].isEmpty ? 1 : Int(bounds[0])
                let hi = bounds[1].isEmpty ? count : Int(bounds[1])
                guard let lo, let hi, lo >= 1, hi <= count, lo <= hi else { return nil }
                result += (lo - 1)...(hi - 1)
            } else {
                return nil
            }
        }
        return Array(Set(result)).sorted()
    }
}

extension CGAffineTransform {
    var pdfMatrix: [Double] { [a, b, c, d, tx, ty].map { Double($0) } }

    /// `self` expressed in the space `other` maps into (other⁻¹ · self · other).
    func conjugated(by other: CGAffineTransform) -> CGAffineTransform {
        other.concatenating(self).concatenating(other.inverted())
    }
}

extension CGRect {
    func distance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) + abs(minY - other.minY) + abs(maxX - other.maxX) + abs(maxY - other.maxY)
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

extension PDFPage {
    /// Maps page (user) space to the upright visual space shown on screen
    /// (origin bottom-left of the crop box, after /Rotate).
    var visualTransform: CGAffineTransform {
        let box = bounds(for: .cropBox)
        let r = ((rotation % 360) + 360) % 360
        switch r {
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.maxX, ty: box.maxY)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
        default: return CGAffineTransform(translationX: -box.minX, y: -box.minY)
        }
    }

    var visualBounds: CGRect { bounds(for: .cropBox).applying(visualTransform) }
}
