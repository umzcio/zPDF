// Native page composition: insertion, replacement, duplication, range
// rotation, labels, boxes, size and transitions.
//
// None of this happens on the PDFKit display copy — SaveBaseline treats
// PDFKit-inserted pages as unknown. Each operation runs natively on the
// editing revision (pending edits included), reloads, and is one Undo step.
// The user's file changes only on Save.

import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PageInsertionPosition: String, CaseIterable, Identifiable {
    case beforeCurrent, afterCurrent, first, last
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beforeCurrent: "Before current page"
        case .afterCurrent: "After current page"
        case .first: "At the beginning"
        case .last: "At the end"
        }
    }
    @MainActor func index(in tab: DocumentTab) -> Int {
        switch self {
        case .beforeCurrent: max(0, tab.currentPage - 1)
        case .afterCurrent: min(tab.pageCount, tab.currentPage)
        case .first: 0
        case .last: tab.pageCount
        }
    }
}

/// Paper presets offered by Insert Blank Page, Change Page Size and Blank PDF.
enum PaperSize: String, CaseIterable, Identifiable {
    case matchCurrent, letter, legal, tabloid, a3, a4, a5, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matchCurrent: "Same as current page"
        case .letter: "US Letter (8.5 × 11 in)"
        case .legal: "US Legal (8.5 × 14 in)"
        case .tabloid: "Tabloid (11 × 17 in)"
        case .a3: "A3 (297 × 420 mm)"
        case .a4: "A4 (210 × 297 mm)"
        case .a5: "A5 (148 × 210 mm)"
        case .custom: "Custom"
        }
    }
    var points: CGSize? {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .tabloid: CGSize(width: 792, height: 1224)
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .matchCurrent, .custom: nil
        }
    }
    /// Presets without "match current", for documents that have no pages yet.
    static let fixed: [PaperSize] = [.letter, .legal, .tabloid, .a3, .a4, .a5, .custom]
}

enum PageFileKind {
    static let imageTypes: [UTType] = [.jpeg, .png, .tiff, .heic, .heif, .gif, .bmp, .webP]
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }
    static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true
    }
}

@MainActor
extension AppState {
    /// Runs a page transform with the standard busy state and error alert.
    /// `lease` keeps staged inputs alive until the transform finishes.
    @discardableResult
    func performPageTransform(_ ops: [[String: Any]], in tab: DocumentTab, actionName: String,
                              lease: NativeWorkDirectory? = nil) async -> [NativeJSON]? {
        do {
            let results = try await applyDocumentTransform(ops, to: tab, actionName: actionName)
            withExtendedLifetime(lease) {}
            return results
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func insertBlankPages(count: Int, size: CGSize?, landscape: Bool?, at index: Int, in tab: DocumentTab) async -> Bool {
        var op: [String: Any] = ["op": "insert_blank_pages", "at": index, "count": count]
        if let size { op["size"] = [Double(size.width), Double(size.height)] }
        else { op["like"] = max(0, min(tab.pageCount - 1, index == 0 ? 0 : index - 1)) }
        if let landscape { op["orientation"] = landscape ? "landscape" : "portrait" }
        let ok = await performPageTransform([op], in: tab, actionName: count == 1 ? "Insert Blank Page" : "Insert Blank Pages") != nil
        if ok { tab.goToPage(index + 1) }
        return ok
    }

    /// Inserts PDFs (optionally a subset of one PDF's zero-based pages) and
    /// images (one page each) at `index`, in the given order.
    @discardableResult
    func insertFiles(_ urls: [URL], pages: [Int]? = nil, at index: Int, in tab: DocumentTab,
                     imageOptions: [String: Any] = [:]) async -> Bool {
        guard !urls.isEmpty else { return false }
        do {
            let (lease, staged) = try NativeWorkflowBridge.stage(urls)
            var ops = try Self.insertionOps(staged, pages: urls.count == 1 ? pages : nil, at: index,
                                            imageOptions: imageOptions, work: lease.url)
            let name = urls.count == 1 ? "Insert \(urls[0].lastPathComponent)" : "Insert Pages"
            do {
                _ = try await applyDocumentTransform(ops, to: tab, actionName: name)
            } catch let error as NativeSaveError where error.code == "PASSWORD_REQUIRED" {
                guard let password = promptForInsertPassword(urls.count == 1 ? urls[0].lastPathComponent : "the PDF") else { return false }
                ops = ops.map { var op = $0; if op["op"] as? String == "insert_pages" { op["password"] = password }; return op }
                _ = try await applyDocumentTransform(ops, to: tab, actionName: name)
            }
            withExtendedLifetime(lease) {}
            tab.goToPage(index + 1)
            return true
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return false
        }
    }

    /// Engine ops that insert staged files in order: consecutive images share one op.
    nonisolated static func insertionOps(_ staged: [URL], pages: [Int]?, at index: Int,
                                         imageOptions: [String: Any], work: URL) throws -> [[String: Any]] {
        var ops: [[String: Any]] = []
        var position = index
        var images: [String] = []
        func flush() {
            guard !images.isEmpty else { return }
            var op: [String: Any] = ["op": "insert_images", "images": images, "at": position]
            op.merge(imageOptions) { $1 }
            ops.append(op)
            position += images.count
            images = []
        }
        for url in staged {
            if PageFileKind.isImage(url) {
                images.append(contentsOf: try ImageNormalizer.frames(of: url, into: work).map(\.path))
            } else {
                flush()
                var op: [String: Any] = ["op": "insert_pages", "path": url.path, "at": position]
                if let pages { op["pages"] = pages }
                ops.append(op)
                position += pages?.count ?? (CGPDFDocument(url as CFURL)?.numberOfPages ?? 1)
            }
        }
        flush()
        return ops
    }

    func promptForInsertPassword(_ name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Unlock “\(name)”"
        alert.informativeText = "Enter the password of the PDF you are inserting. It is used once and not stored."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Password"
        field.setAccessibilityLabel("PDF password")
        alert.accessoryView = field
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Replaces the content of `targets` (zero-based) with pages of a PDF,
    /// one to one. Annotations, fields and links of the replaced pages stay.
    @discardableResult
    func replacePages(_ targets: [Int], with url: URL, sourcePages: [Int], in tab: DocumentTab) async -> Bool {
        do {
            let (lease, staged) = try NativeWorkflowBridge.stage([url])
            let ops: [[String: Any]] = [["op": "replace_pages", "path": staged[0].path, "targets": targets,
                                         "source_pages": sourcePages]]
            return await performPageTransform(ops, in: tab, actionName: "Replace Pages", lease: lease) != nil
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func duplicatePages(_ pages: [Int], in tab: DocumentTab) async -> Bool {
        guard !pages.isEmpty else { return false }
        let ok = await performPageTransform([["op": "duplicate_pages", "pages": pages]], in: tab,
                                            actionName: pages.count == 1 ? "Duplicate Page" : "Duplicate Pages") != nil
        if ok { tab.goToPage((pages.max() ?? 0) + 2) }
        return ok
    }

    /// Rotates a range (nil = every page) in one Undo step.
    @discardableResult
    func rotatePages(_ pages: [Int]?, by angle: Int, in tab: DocumentTab) async -> Bool {
        var op: [String: Any] = ["op": "rotate_pages", "angle": angle]
        if let pages { op["pages"] = pages }
        return await performPageTransform([op], in: tab, actionName: "Rotate Pages") != nil
    }

    @discardableResult
    func deletePages(_ pages: [Int], in tab: DocumentTab) async -> Bool {
        await performPageTransform([["op": "delete_pages", "pages": pages]], in: tab,
                                   actionName: pages.count == 1 ? "Delete Page" : "Delete Pages") != nil
    }

    // MARK: Dragging pages between documents

    /// True while a page drag from a different document could land in `tab`.
    func acceptsForeignPageDrag(into tab: DocumentTab) -> Bool {
        guard let drag = pageDrag else { return false }
        return drag.tab !== tab && tab.allowsSaveEdits && drag.tab.editSource != nil
    }

    /// Inserts a page dragged from another open document at `index`, together
    /// with that document's unsaved edits (annotations, fields…).
    @discardableResult
    func dropForeignPage(_ token: String, at index: Int, in target: DocumentTab) async -> Bool {
        guard let drag = pageDrag, drag.token == token, drag.tab !== target,
              tabs.contains(where: { $0 === drag.tab }), drag.tab.pdfDocument === drag.document else { return false }
        pageDrag = nil
        let source = drag.tab
        let sourceIndex = drag.document.index(for: drag.page)
        guard sourceIndex != NSNotFound, let revision = source.editSource, let baseline = source.saveBaseline,
              let document = source.pdfDocument else {
            saveError = OpenError(fileName: source.displayName, message: "That document isn't ready to share pages yet.")
            return false
        }
        do {
            let changes = try baseline.changes(in: document)
            // A private snapshot of the source including its unsaved edits.
            let snapshot = try await NativeDocumentBridge.transform(source: revision.url, hash: revision.hash,
                                                                    changes: changes, ops: NativeOps([["op": "finalize"]]))
            let ok = await performPageTransform([["op": "insert_pages", "path": snapshot.url.path,
                                                  "pages": [sourceIndex], "at": index]],
                                                in: target, actionName: "Insert Page from \(source.displayName)",
                                                lease: snapshot.work) != nil
            if ok { target.goToPage(index + 1) }
            return ok
        } catch {
            saveError = OpenError(fileName: target.displayName, message: error.localizedDescription)
            return false
        }
    }

    // MARK: Labels, boxes, size, transitions

    @discardableResult
    func setPageLabels(_ ranges: [PageLabelRange], in tab: DocumentTab) async -> Bool {
        await performPageTransform([["op": "set_page_labels", "ranges": ranges.map(\.json)]], in: tab,
                                   actionName: ranges.isEmpty ? "Remove Page Labels" : "Number Pages") != nil
    }

    @discardableResult
    func setPageBoxes(_ boxes: [String: Any], remove: [String] = [], pages: [Int]?, in tab: DocumentTab) async -> Bool {
        var op: [String: Any] = ["op": "set_page_boxes", "boxes": boxes, "remove": remove]
        if let pages { op["pages"] = pages }
        return await performPageTransform([op], in: tab, actionName: "Set Page Boxes") != nil
    }

    @discardableResult
    func resizePages(to size: CGSize, mode: String, pages: [Int]?, in tab: DocumentTab) async -> Bool {
        var op: [String: Any] = ["op": "resize_pages", "size": [Double(size.width), Double(size.height)], "mode": mode]
        if let pages { op["pages"] = pages }
        return await performPageTransform([op], in: tab, actionName: "Change Page Size") != nil
    }

    @discardableResult
    func setTransitions(style: String?, duration: Double, direction: Int?, advance: Double?, pages: [Int]?,
                        in tab: DocumentTab) async -> Bool {
        var op: [String: Any] = ["op": "set_transitions", "duration": duration]
        if let style { op["style"] = style }
        if let direction { op["direction"] = direction }
        if let advance { op["advance"] = advance }
        if let pages { op["pages"] = pages }
        return await performPageTransform([op], in: tab,
                                          actionName: style == nil ? "Remove Page Transitions" : "Set Page Transitions") != nil
    }
}

/// One /PageLabels range (zero-based start page).
struct PageLabelRange: Identifiable, Equatable {
    enum Style: String, CaseIterable, Identifiable {
        case decimal = "D", upperRoman = "R", lowerRoman = "r", upperLetters = "A", lowerLetters = "a", none = ""
        var id: String { rawValue }
        var title: String {
            switch self {
            case .decimal: "1, 2, 3"
            case .upperRoman: "I, II, III"
            case .lowerRoman: "i, ii, iii"
            case .upperLetters: "A, B, C"
            case .lowerLetters: "a, b, c"
            case .none: "None (prefix only)"
            }
        }
    }
    let id = UUID()
    var start: Int
    var style: Style = .decimal
    var prefix = ""
    var first = 1

    var json: [String: Any] {
        var value: [String: Any] = ["start": start, "prefix": prefix, "first": first]
        if style != .none { value["style"] = style.rawValue }
        return value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.start == rhs.start && lhs.style == rhs.style && lhs.prefix == rhs.prefix && lhs.first == rhs.first
    }

    /// Label text for a page `offset` pages after this range's start.
    func label(offset: Int) -> String {
        let n = first + offset
        func roman(_ value: Int) -> String {
            let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                          (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
            var rest = value, out = ""
            for (v, s) in table { while rest >= v { out += s; rest -= v } }
            return out
        }
        func letters(_ value: Int) -> String {
            let scalar = UnicodeScalar(UInt8(97 + (value - 1) % 26))
            return String(repeating: String(Character(scalar)), count: (value - 1) / 26 + 1)
        }
        let body: String
        switch style {
        case .decimal: body = "\(n)"
        case .upperRoman: body = roman(n).uppercased()
        case .lowerRoman: body = roman(n)
        case .upperLetters: body = letters(n).uppercased()
        case .lowerLetters: body = letters(n)
        case .none: body = ""
        }
        return prefix + body
    }
}

extension DocumentTab {
    /// The page's label (from /PageLabels) when it differs from its number.
    func pageLabel(at index: Int) -> String? {
        let _ = pageRevision
        guard let label = pdfDocument?.page(at: index)?.label, !label.isEmpty, label != "\(index + 1)" else { return nil }
        return label
    }

    /// Resolves a typed page number or page label to a 1-based page number.
    /// Labels win over numbers only when they match exactly (Acrobat behaviour).
    func pageNumber(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = pdfDocument, !trimmed.isEmpty else { return nil }
        for index in 0..<document.pageCount where document.page(at: index)?.label == trimmed {
            return index + 1
        }
        if let number = Int(trimmed), (1...max(1, pageCount)).contains(number) { return number }
        return nil
    }
}
