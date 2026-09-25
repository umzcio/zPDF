import AppKit
import PDFKit

/// Print options (also saved as named presets).
struct PrintOptions: Codable, Hashable {
    enum PageScope: String, Codable, CaseIterable { case all, current, range, area }
    enum Content: String, Codable, CaseIterable {
        case documentAndMarkups, document, documentWithoutFields
        var title: String {
            switch self {
            case .documentAndMarkups: "Document and Markups"
            case .document: "Document (form fields, no comments)"
            case .documentWithoutFields: "Document only (no fields or comments)"
            }
        }
    }
    enum Sizing: String, Codable, CaseIterable {
        case fit, actual, shrink, custom, poster, multiple, booklet
        var title: String {
            switch self {
            case .fit: "Fit"
            case .actual: "Actual Size"
            case .shrink: "Shrink Oversized Pages"
            case .custom: "Custom Scale"
            case .poster: "Poster"
            case .multiple: "Multiple"
            case .booklet: "Booklet"
            }
        }
    }

    var scope: PageScope = .all
    var range = ""
    var content: Content = .documentAndMarkups
    var sizing: Sizing = .fit
    var customScale: Double = 100
    var columns = 2
    var rows = 1
    var order = "horizontal"
    var borders = false
    var posterScale: Double = 100
    var posterOverlap: Double = 18
    var posterCutMarks = true
    var posterLabels = true
    var bookletBinding = "left"
    var autoRotate = true

    var scalingMode: PDFPrintScalingMode {
        switch sizing {
        case .fit, .multiple, .booklet: .pageScaleToFit
        case .actual, .custom, .poster: .pageScaleNone
        case .shrink: .pageScaleDownToFit
        }
    }
}

/// A prepared, print-ready temporary copy of the document with current edits.
final class PreparedPrint: @unchecked Sendable {
    let url: URL
    let document: PDFDocument
    let scalingMode: PDFPrintScalingMode
    let autoRotate: Bool
    private let work: AnyObject?

    init(url: URL, document: PDFDocument, scalingMode: PDFPrintScalingMode, autoRotate: Bool, work: AnyObject?) {
        self.url = url
        self.document = document
        self.scalingMode = scalingMode
        self.autoRotate = autoRotate
        self.work = work
    }
}

@MainActor
enum PrintService {
    /// Engine operations for `options` (paper size in points).
    static func operations(_ options: PrintOptions, pageCount: Int, currentPage: Int, paper: CGSize,
                           area: (page: Int, rect: CGRect)?) throws -> [[String: Any]] {
        var ops: [[String: Any]] = []
        switch options.content {
        case .documentAndMarkups: ops.append(["op": "print_prepare", "comments": true, "fields": true])
        case .document: ops.append(["op": "print_prepare", "comments": false, "fields": true])
        case .documentWithoutFields: ops.append(["op": "print_prepare", "comments": false, "fields": false])
        }
        switch options.scope {
        case .all: break
        case .current: ops.append(["op": "keep_pages", "pages": [currentPage]])
        case .range:
            let pages = try PageRangeSelection.parse(options.range, pageCount: pageCount)
            ops.append(["op": "keep_pages", "pages": Array(pages)])
        case .area:
            guard let area else { throw NativeSaveError(code: "NO_AREA", message: "Select an area on the page first.") }
            ops.append(["op": "crop_area", "page": area.page,
                        "rect": [area.rect.minX, area.rect.minY, area.rect.maxX, area.rect.maxY].map(Double.init)])
        }
        let sheet = [Double(paper.width), Double(paper.height)]
        switch options.sizing {
        case .fit, .actual, .shrink: break
        case .custom: ops.append(["op": "scale_pages", "percent": min(1000, max(1, options.customScale))])
        case .multiple:
            ops.append(["op": "impose_nup", "cols": max(1, options.columns), "rows": max(1, options.rows),
                        "order": options.order, "borders": options.borders, "sheet": sheet, "auto_rotate": options.autoRotate])
        case .booklet:
            ops.append(["op": "impose_booklet", "binding": options.bookletBinding,
                        "sheet": [max(sheet[0], sheet[1]), min(sheet[0], sheet[1])]])
        case .poster:
            ops.append(["op": "impose_poster", "tile": sheet, "scale": max(1, options.posterScale),
                        "overlap": max(0, options.posterOverlap), "cut_marks": options.posterCutMarks, "labels": options.posterLabels])
        }
        ops.append(["op": "finalize"])
        return ops
    }

    /// Materializes the document (pending edits included) through the print
    /// operations into a private temporary file. The user's file is untouched.
    static func prepare(_ tab: DocumentTab, options: PrintOptions, paper: CGSize,
                        area: (page: Int, rect: CGRect)?) async throws -> PreparedPrint {
        guard let document = tab.pdfDocument else { throw NativeSaveError(code: "NOT_READY", message: "Open the document first.") }
        let ops = try operations(options, pageCount: tab.pageCount, currentPage: tab.currentPage - 1, paper: paper, area: area)
        if let source = tab.editSource, let baseline = tab.saveBaseline {
            let changes = try baseline.changes(in: document)
            let output = try await NativeDocumentBridge.transform(source: source.url, hash: source.hash, changes: changes, ops: NativeOps(ops))
            guard let prepared = PDFDocument(url: output.url) else {
                throw NativeSaveError(code: "PRINT_UNAVAILABLE", message: "The print copy could not be opened.")
            }
            return PreparedPrint(url: output.url, document: prepared, scalingMode: options.scalingMode,
                                 autoRotate: options.autoRotate, work: output.work)
        }
        // Read-only (for example XFA) documents: transform the file itself.
        guard let url = tab.url, !document.isEncrypted else {
            throw NativeSaveError(code: "PRINT_LAYOUT_UNAVAILABLE", message: "Print layouts need an unencrypted document.")
        }
        let work = try NativeWorkDirectory()
        let destination = work.url.appendingPathComponent("print.pdf")
        _ = try await NativeDocumentBridge.transformFile(url, ops: NativeOps(ops), destination: destination)
        guard let prepared = PDFDocument(url: destination) else {
            throw NativeSaveError(code: "PRINT_UNAVAILABLE", message: "The print copy could not be opened.")
        }
        return PreparedPrint(url: destination, document: prepared, scalingMode: options.scalingMode,
                             autoRotate: options.autoRotate, work: work)
    }

    static func operation(for prepared: PreparedPrint, title: String, printInfo: NSPrintInfo = .shared) throws -> NSPrintOperation {
        guard let operation = prepared.document.printOperation(for: printInfo, scalingMode: prepared.scalingMode,
                                                               autoRotate: prepared.autoRotate) else {
            throw NativeSaveError(code: "PRINT_UNAVAILABLE", message: "The print operation could not be created.")
        }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsCopies, .showsPaperSize, .showsOrientation, .showsPreview, .showsPageRange])
        return operation
    }
}

/// Named print presets (Settings ▸ Print and the print sheet).
@MainActor @Observable
final class PrintPresetStore {
    static let shared = PrintPresetStore()
    static let key = "zpdf.printPresets.v1"
    private(set) var presets: [String: PrintOptions] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([String: PrintOptions].self, from: data) {
            presets = stored
        }
    }

    var names: [String] { presets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func save(_ options: PrintOptions, as name: String) {
        var stored = options
        if stored.scope == .area { stored.scope = .all }
        presets[name] = stored
        persist()
    }

    func remove(_ name: String) {
        presets[name] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.key) }
    }
}
