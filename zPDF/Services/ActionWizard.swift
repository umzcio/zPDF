import AppKit
import Foundation
import PDFKit

// MARK: - Step catalog

/// A value for a step parameter.
enum StepValue: Codable, Hashable {
    case text(String), number(Double), flag(Bool)

    var text: String { if case .text(let v) = self { return v }; if case .number(let v) = self { return MeasureSession.format(v) }; return "" }
    var number: Double { if case .number(let v) = self { return v }; if case .text(let v) = self { return Double(v) ?? 0 }; return 0 }
    var flag: Bool { if case .flag(let v) = self { return v }; return false }
}

struct StepParameter: Identifiable, @unchecked Sendable {
    enum Kind {
        case text(prompt: String)
        case number(range: ClosedRange<Double>, step: Double, suffix: String)
        case toggle
        case choice([(value: String, label: String)])
    }
    let key: String
    let label: String
    let kind: Kind
    let defaultValue: StepValue
    var help: String = ""
    var id: String { key }
}

/// A step type the Action Wizard can run: one engine operation (or a short
/// fixed sequence) with user parameters.
struct StepDefinition: Identifiable, @unchecked Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let parameters: [StepParameter]
    /// Engine operations this step needs (it is hidden when missing).
    let requires: [String]
    /// Only meaningful for files written by a batch run.
    var batchOnly = false
    let build: ([String: StepValue], StepContext) -> [[String: Any]]
}

/// Values available to token substitution when a step runs.
struct StepContext {
    var fileName: String
    var author: String
    var identityTitle: String
    var organization: String
    var email: String
    var language: String

    func expand(_ text: String) -> String {
        let values = ["filename": fileName, "author": author, "title": identityTitle, "organization": organization, "email": email]
        var output = text
        for (key, value) in values { output = output.replacingOccurrences(of: "<<\(key)>>", with: value, options: .caseInsensitive) }
        return output
    }

    @MainActor
    static func make(fileName: String, preferences: AppPreferences) -> StepContext {
        StepContext(fileName: (fileName as NSString).deletingPathExtension, author: preferences.commentAuthor,
                    identityTitle: preferences.identityTitle, organization: preferences.identityOrganization,
                    email: preferences.identityEmail, language: TitleLanguageSheet.defaultLanguage ?? "en-US")
    }
}

enum StepCatalog {
    static let positions: [(value: String, label: String)] = [
        ("top-left", "Top left"), ("top-center", "Top center"), ("top-right", "Top right"),
        ("bottom-left", "Bottom left"), ("bottom-center", "Bottom center"), ("bottom-right", "Bottom right")
    ]

    static func optional(_ step: [String: Any]) -> [String: Any] { ["op": "optional", "step": step] }

    static func rgb(_ name: String) -> [Int] {
        switch name {
        case "gray": [128, 128, 128]
        case "blue": [30, 80, 200]
        case "black": [0, 0, 0]
        case "green": [20, 130, 60]
        default: [220, 30, 30]
        }
    }

    static let colors: [(value: String, label: String)] = [("red", "Red"), ("gray", "Gray"), ("blue", "Blue"), ("green", "Green"), ("black", "Black")]

    static let all: [StepDefinition] = [
        StepDefinition(id: "watermark", title: "Add Watermark", symbol: "drop", summary: "Text across each page",
                       parameters: [
                        .init(key: "text", label: "Text", kind: .text(prompt: "CONFIDENTIAL"), defaultValue: .text("CONFIDENTIAL"),
                              help: "Tokens: <<filename>>, <<author>>, <<organization>>, <<date>>"),
                        .init(key: "size", label: "Size", kind: .number(range: 8...200, step: 4, suffix: "pt"), defaultValue: .number(60)),
                        .init(key: "opacity", label: "Opacity", kind: .number(range: 5...100, step: 5, suffix: "%"), defaultValue: .number(25)),
                        .init(key: "angle", label: "Angle", kind: .number(range: -90...90, step: 15, suffix: "°"), defaultValue: .number(45)),
                        .init(key: "color", label: "Color", kind: .choice(colors), defaultValue: .text("red"))
                       ], requires: ["watermark"]) { p, c in
            [["op": "watermark", "text": c.expand(p["text"]?.text ?? "CONFIDENTIAL"), "size": p["size"]?.number ?? 60,
              "opacity": (p["opacity"]?.number ?? 25) / 100, "angle": p["angle"]?.number ?? 45, "color": rgb(p["color"]?.text ?? "red")]]
        },
        StepDefinition(id: "header_footer", title: "Add Header & Footer", symbol: "rectangle.topthird.inset.filled",
                       summary: "Text in the page margins",
                       parameters: [
                        .init(key: "header", label: "Header", kind: .text(prompt: "<<filename>>"), defaultValue: .text("")),
                        .init(key: "header_position", label: "Header position", kind: .choice(Array(positions.prefix(3))), defaultValue: .text("top-center")),
                        .init(key: "footer", label: "Footer", kind: .text(prompt: "Page <<page>> of <<pages>>"), defaultValue: .text("Page <<page>> of <<pages>>"),
                              help: "Tokens: <<page>>, <<pages>>, <<date>>, <<filename>>, <<author>>"),
                        .init(key: "footer_position", label: "Footer position", kind: .choice(Array(positions.suffix(3))), defaultValue: .text("bottom-center")),
                        .init(key: "size", label: "Size", kind: .number(range: 6...36, step: 1, suffix: "pt"), defaultValue: .number(10))
                       ], requires: ["header_footer"]) { p, c in
            var items: [String: String] = [:]
            let header = c.expand(p["header"]?.text ?? ""), footer = c.expand(p["footer"]?.text ?? "")
            if !header.isEmpty { items[p["header_position"]?.text ?? "top-center"] = header }
            if !footer.isEmpty { items[p["footer_position"]?.text ?? "bottom-center"] = footer }
            guard !items.isEmpty else { return [] }
            return [["op": "header_footer", "items": items, "size": p["size"]?.number ?? 10]]
        },
        StepDefinition(id: "bates", title: "Bates Numbering", symbol: "number", summary: "Sequential legal page numbers",
                       parameters: [
                        .init(key: "prefix", label: "Prefix", kind: .text(prompt: "ABC"), defaultValue: .text("")),
                        .init(key: "start", label: "Start at", kind: .number(range: 0...9_999_999, step: 1, suffix: ""), defaultValue: .number(1)),
                        .init(key: "digits", label: "Digits", kind: .number(range: 3...15, step: 1, suffix: ""), defaultValue: .number(6)),
                        .init(key: "suffix", label: "Suffix", kind: .text(prompt: ""), defaultValue: .text("")),
                        .init(key: "anchor", label: "Position", kind: .choice(positions), defaultValue: .text("bottom-right"))
                       ], requires: ["bates"]) { p, c in
            [["op": "bates", "prefix": c.expand(p["prefix"]?.text ?? ""), "suffix": c.expand(p["suffix"]?.text ?? ""),
              "start": Int(p["start"]?.number ?? 1), "digits": Int(p["digits"]?.number ?? 6), "anchor": p["anchor"]?.text ?? "bottom-right"]]
        },
        StepDefinition(id: "remove_overlays", title: "Remove Watermarks & Headers", symbol: "eraser",
                       summary: "Remove overlays added by zPDF",
                       parameters: [.init(key: "kind", label: "Remove", kind: .choice([("Watermark", "Watermarks"), ("HeaderFooter", "Headers & footers"),
                                                                                          ("Bates", "Bates numbers"), ("Background", "Backgrounds")]),
                                          defaultValue: .text("Watermark"))],
                       requires: ["remove_overlays"]) { p, _ in
            [["op": "remove_overlays", "kind": p["kind"]?.text ?? "Watermark"]]
        },
        StepDefinition(id: "flatten_comments", title: "Flatten Comments", symbol: "square.stack.3d.down.right",
                       summary: "Merge comment appearances into the page", parameters: [], requires: ["flatten_annotations"]) { _, _ in
            [["op": "flatten_annotations"]]
        },
        StepDefinition(id: "flatten_all", title: "Flatten Comments and Form Fields", symbol: "square.stack.3d.down.forward",
                       summary: "Make every printable comment and field part of the page", parameters: [], requires: ["print_prepare"]) { _, _ in
            [["op": "print_prepare", "comments": true, "fields": true]]
        },
        StepDefinition(id: "flatten_layers", title: "Flatten Layers", symbol: "square.3.layers.3d.down.right",
                       summary: "Merge visible layers, discard hidden ones", parameters: [], requires: ["flatten_layers", "optional"]) { _, _ in
            [optional(["op": "flatten_layers"])]
        },
        StepDefinition(id: "remove_javascript", title: "Remove JavaScript", symbol: "curlybraces.square",
                       summary: "Delete every document, page, field and link script", parameters: [], requires: ["remove_javascript"]) { _, _ in
            [["op": "remove_javascript"]]
        },
        StepDefinition(id: "set_metadata", title: "Set Document Properties", symbol: "info.circle",
                       summary: "Title, author, subject, keywords",
                       parameters: [
                        .init(key: "title", label: "Title", kind: .text(prompt: "<<filename>>"), defaultValue: .text("")),
                        .init(key: "author", label: "Author", kind: .text(prompt: "<<author>>"), defaultValue: .text("")),
                        .init(key: "subject", label: "Subject", kind: .text(prompt: ""), defaultValue: .text("")),
                        .init(key: "keywords", label: "Keywords", kind: .text(prompt: ""), defaultValue: .text(""))
                       ], requires: ["set_metadata"]) { p, c in
            var info: [String: Any] = [:]
            for key in ["title", "author", "subject", "keywords"] {
                let value = c.expand(p[key]?.text ?? "")
                if !value.isEmpty { info[key] = value }
            }
            return info.isEmpty ? [] : [["op": "set_metadata", "info": info]]
        },
        StepDefinition(id: "initial_view", title: "Set Initial View", symbol: "rectangle.portrait.on.rectangle.portrait",
                       summary: "How the document opens",
                       parameters: [
                        .init(key: "page_mode", label: "Show", kind: .choice([("keep", "Unchanged"), ("default", "Page only"), ("UseOutlines", "Bookmarks panel"),
                                                                               ("UseThumbs", "Pages panel")]), defaultValue: .text("UseOutlines")),
                        .init(key: "page_layout", label: "Layout", kind: .choice([("keep", "Unchanged"), ("default", "Default"), ("SinglePage", "Single page"),
                                                                                  ("OneColumn", "Continuous"), ("TwoPageRight", "Two-up (cover)")]),
                              defaultValue: .text("keep")),
                        .init(key: "zoom", label: "Magnification", kind: .choice([("keep", "Unchanged"), ("default", "Default"), ("fit_page", "Fit page"),
                                                                                  ("fit_width", "Fit width"), ("100", "100%")]), defaultValue: .text("keep")),
                        .init(key: "title", label: "Show document title in title bar", kind: .toggle, defaultValue: .flag(true))
                       ], requires: ["set_initial_view"]) { p, _ in
            var op: [String: Any] = ["op": "set_initial_view"]
            func value(_ key: String) -> Any { let v = p[key]?.text ?? "keep"; return v == "default" ? NSNull() : v }
            op["page_mode"] = value("page_mode")
            op["page_layout"] = value("page_layout")
            let zoom = p["zoom"]?.text ?? "keep"
            if zoom != "keep" { op["open_page"] = 0; op["open_zoom"] = Double(zoom).map { $0 as Any } ?? zoom }
            if p["title"]?.flag == true { op["viewer_preferences"] = ["DisplayDocTitle": true] }
            return [op]
        },
        StepDefinition(id: "make_accessible", title: "Make Accessible", symbol: "accessibility",
                       summary: "Autotag, title, language, field descriptions and tab order",
                       parameters: [
                        .init(key: "language", label: "Language", kind: .text(prompt: "en-US"), defaultValue: .text("")),
                        .init(key: "title", label: "Title", kind: .text(prompt: "<<filename>>"), defaultValue: .text("<<filename>>"))
                       ], requires: ["autotag", "set_language", "set_title", "set_field_tooltips", "set_page_tab_order", "optional"]) { p, c in
            let language = (p["language"]?.text).flatMap { $0.isEmpty ? nil : $0 } ?? c.language
            var ops: [[String: Any]] = [optional(["op": "autotag", "language": language])]
            let title = c.expand(p["title"]?.text ?? "")
            if !title.isEmpty { ops.append(["op": "set_title", "title": title, "display_doc_title": true]) }
            ops.append(["op": "set_language", "lang": language])
            ops.append(["op": "set_field_tooltips"])
            ops.append(["op": "set_page_tab_order", "order": "S"])
            ops.append(optional(["op": "tag_annotations"]))
            return ops
        },
        StepDefinition(id: "bookmarks_headings", title: "Bookmarks from Headings", symbol: "bookmark",
                       summary: "Build bookmarks from large text", parameters: [
                        .init(key: "replace", label: "Replace existing bookmarks", kind: .toggle, defaultValue: .flag(true))
                       ], requires: ["outline_from_headings", "optional"]) { p, _ in
            [optional(["op": "outline_from_headings", "replace": p["replace"]?.flag ?? true])]
        },
        StepDefinition(id: "fast_web_view", title: "Save for Fast Web View", symbol: "bolt.horizontal",
                       summary: "Linearize output files", parameters: [], requires: ["linearize"], batchOnly: true) { _, _ in
            [["op": "linearize"]]
        }
    ]

    static func definition(_ id: String) -> StepDefinition? { all.first { $0.id == id } }

    static func defaults(for definition: StepDefinition) -> [String: StepValue] {
        Dictionary(uniqueKeysWithValues: definition.parameters.map { ($0.key, $0.defaultValue) })
    }
}

// MARK: - Actions

struct ActionStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: String
    var values: [String: StepValue]

    var definition: StepDefinition? { StepCatalog.definition(kind) }

    var summary: String {
        guard let definition else { return "Unavailable step" }
        let details = definition.parameters.compactMap { parameter -> String? in
            guard let value = values[parameter.key] else { return nil }
            switch parameter.kind {
            case .text: return value.text.isEmpty ? nil : "“\(value.text)”"
            case .choice(let options): return options.first { $0.value == value.text }?.label
            case .toggle: return value.flag ? parameter.label : nil
            case .number(_, _, let suffix): return "\(MeasureSession.format(value.number))\(suffix)"
            }
        }
        return details.isEmpty ? definition.summary : details.prefix(3).joined(separator: ", ")
    }
}

struct SavedAction: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var details: String
    var steps: [ActionStep]
    var builtIn = false

    /// Engine operations for all steps (empty steps are dropped).
    func operations(context: StepContext, forBatch: Bool) -> [[String: Any]] {
        steps.flatMap { step -> [[String: Any]] in
            guard let definition = step.definition, forBatch || !definition.batchOnly else { return [] }
            return definition.build(step.values, context)
        }
    }

    static func step(_ kind: String, _ overrides: [String: StepValue] = [:]) -> ActionStep {
        var values = StepCatalog.definition(kind).map(StepCatalog.defaults(for:)) ?? [:]
        for (key, value) in overrides { values[key] = value }
        return ActionStep(kind: kind, values: values)
    }

    static let builtIns: [SavedAction] = [
        SavedAction(id: UUID(uuidString: "6B1F7F3C-9E1D-4C43-9B6E-0000000000A1")!, name: "Prepare for Distribution",
                    details: "Remove scripts, flatten comments and fields, open with bookmarks, optimize for the web.",
                    steps: [step("remove_javascript"), step("flatten_all"), step("initial_view"), step("fast_web_view")], builtIn: true),
        SavedAction(id: UUID(uuidString: "6B1F7F3C-9E1D-4C43-9B6E-0000000000A2")!, name: "Make Accessible",
                    details: "Autotag, set title and language, describe fields, set tab order and add bookmarks.",
                    steps: [step("make_accessible"), step("bookmarks_headings", ["replace": .flag(false)]), step("initial_view")], builtIn: true),
        SavedAction(id: UUID(uuidString: "6B1F7F3C-9E1D-4C43-9B6E-0000000000A3")!, name: "Mark Confidential",
                    details: "Add a CONFIDENTIAL watermark and page numbers.",
                    steps: [step("watermark"), step("header_footer")], builtIn: true),
        SavedAction(id: UUID(uuidString: "6B1F7F3C-9E1D-4C43-9B6E-0000000000A4")!, name: "Bates Stamp for Production",
                    details: "Flatten comments and add Bates numbers.",
                    steps: [step("flatten_comments"), step("bates", ["prefix": .text("PROD")])], builtIn: true)
    ]
}

@MainActor @Observable
final class ActionStore {
    static let shared = ActionStore()
    static let key = "zpdf.actions.v1"
    private(set) var custom: [SavedAction] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([SavedAction].self, from: data) {
            custom = stored
        }
    }

    var all: [SavedAction] { SavedAction.builtIns + custom }

    func save(_ action: SavedAction) {
        var copy = action
        copy.builtIn = false
        if let index = custom.firstIndex(where: { $0.id == copy.id }) { custom[index] = copy } else { custom.append(copy) }
        persist()
    }

    func remove(_ id: UUID) {
        custom.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Custom commands

struct CustomCommand: Codable, Identifiable, Hashable {
    enum Kind: Codable, Hashable { case step(ActionStep), printPreset(String) }
    var id = UUID()
    var name: String
    var kind: Kind

    var symbol: String {
        switch kind {
        case .step(let step): step.definition?.symbol ?? "wand.and.stars"
        case .printPreset: "printer"
        }
    }

    var summary: String {
        switch kind {
        case .step(let step): "\(step.definition?.title ?? "Step"): \(step.summary)"
        case .printPreset(let name): "Print with “\(name)”"
        }
    }
}

@MainActor @Observable
final class CustomCommandStore {
    static let shared = CustomCommandStore()
    static let key = "zpdf.customCommands.v1"
    private(set) var commands: [CustomCommand] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([CustomCommand].self, from: data) {
            commands = stored
        }
    }

    func save(_ command: CustomCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) { commands[index] = command } else { commands.append(command) }
        persist()
    }

    func remove(_ id: UUID) {
        commands.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(commands) { defaults.set(data, forKey: Self.key) }
    }
}

@MainActor
extension AppState {
    /// Runs an action on the active document as one Undo step.
    @discardableResult
    func runAction(_ action: SavedAction, on tab: DocumentTab) async -> Bool {
        let context = StepContext.make(fileName: tab.displayName, preferences: preferences)
        let ops = action.operations(context: context, forBatch: false)
        guard !ops.isEmpty else {
            saveError = OpenError(fileName: tab.displayName, message: "“\(action.name)” has no steps that apply to an open document.")
            return false
        }
        return await performDocumentEdit(ops, actionName: action.name, in: tab)
    }

    func runCustomCommand(_ command: CustomCommand) {
        guard let tab = activeTab else { return }
        switch command.kind {
        case .step(let step):
            let action = SavedAction(name: command.name, details: "", steps: [step])
            Task { await runAction(action, on: tab) }
        case .printPreset(let name):
            if let options = PrintPresetStore.shared.presets[name] { features.printInitialOptions = options }
            showPrintDialog()
        }
    }
}

// MARK: - Batch

/// Runs an action on many files into an output folder. Sources are never
/// written; existing output files are never replaced.
@MainActor @Observable
final class BatchRun {
    struct FileResult: Identifiable {
        let id = UUID()
        let source: URL
        let output: URL?
        let message: String?
        var note: String? = nil
        var succeeded: Bool { message == nil }
    }

    private(set) var total = 0
    private(set) var completed = 0
    private(set) var current: String?
    private(set) var results: [FileResult] = []
    private(set) var running = false
    private(set) var cancelled = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    /// PDFs in the chosen files and (recursively) folders.
    static func collectPDFs(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = enumerator?.nextObject() as? URL {
                    if item.pathExtension.lowercased() == "pdf" { found.append(item) }
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                found.append(url)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }.sorted { $0.path < $1.path }
    }

    static func outputURL(for source: URL, in folder: URL, suffix: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent(base + ".pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).pdf")
            counter += 1
        }
        return candidate
    }

    func start(action: SavedAction, files: [URL], output folder: URL, suffix: String, preferences: AppPreferences,
               openTabs: [DocumentTab]) {
        guard !running else { return }
        total = files.count
        completed = 0
        results = []
        cancelled = false
        running = true
        let access = folder.startAccessingSecurityScopedResource()
        task = Task {
            defer {
                if access { folder.stopAccessingSecurityScopedResource() }
                running = false
                current = nil
            }
            for file in files {
                if Task.isCancelled || cancelled { break }
                current = file.lastPathComponent
                let context = StepContext.make(fileName: file.lastPathComponent, preferences: preferences)
                let ops = action.operations(context: context, forBatch: true)
                let unsaved = openTabs.contains { $0.url.map { SaveDestination.sameFile($0, file) } == true && $0.hasUnsavedChanges }
                let destination = Self.outputURL(for: file, in: folder, suffix: suffix)
                do {
                    guard !ops.isEmpty else { throw NativeSaveError(code: "NO_STEPS", message: "The action has no steps.") }
                    let fileAccess = file.startAccessingSecurityScopedResource()
                    defer { if fileAccess { file.stopAccessingSecurityScopedResource() } }
                    _ = try await NativeDocumentBridge.transformFile(file, ops: NativeOps(ops), destination: destination)
                    results.append(FileResult(source: file, output: destination, message: nil,
                                              note: unsaved ? "Open in zPDF with unsaved changes; the saved file was processed." : nil))
                } catch {
                    results.append(FileResult(source: file, output: nil, message: error.localizedDescription))
                }
                completed += 1
            }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
    }
}
