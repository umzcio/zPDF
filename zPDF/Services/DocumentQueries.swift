import Foundation
import PDFKit

/// Typed access to the native engine's read-only queries and a small
/// transform helper for panels. Engine replies are JSON dictionaries with
/// snake_case keys; they are decoded into the Codable models below.
extension NativeJSON {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

extension Encodable {
    /// JSON object for an engine operation parameter.
    func engineJSON() throws -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONSerialization.jsonObject(with: try encoder.encode(self), options: [.fragmentsAllowed])
    }
}

@MainActor
extension AppState {
    /// Queries the current editing revision; read-only documents (no editing
    /// revision) are inspected directly from their file.
    func documentQuery<T: Decodable>(_ name: String, params: [String: Any] = [:], in tab: DocumentTab,
                                     as type: T.Type) async throws -> T {
        try await documentQueryJSON(name, params: params, in: tab).decode(T.self)
    }

    func documentQueryJSON(_ name: String, params: [String: Any] = [:], in tab: DocumentTab) async throws -> NativeJSON {
        if tab.editSource != nil {
            return try await queryDocument(name, params: params, in: tab)
        }
        guard let url = tab.url else {
            throw NativeSaveError(code: "NOT_READY", message: "This document isn't ready yet.")
        }
        return try await NativeDocumentBridge.query(source: url, hash: nil, name: name, params: NativeJSON(value: params))
    }

    /// True once the document can be inspected by the engine.
    func canQuery(_ tab: DocumentTab) -> Bool {
        !tab.saveChecking && (tab.editSource != nil || (tab.url != nil && tab.pdfDocument?.isEncrypted != true))
    }

    /// Engine operations available in this build (guards optional features).
    func availableOperations(in tab: DocumentTab) async -> Set<String> {
        if let cached = EngineCapabilities.shared.operations { return cached }
        guard let result = try? await documentQuery("list_operations", in: tab, as: OperationList.self) else { return [] }
        EngineCapabilities.shared.operations = Set(result.ops)
        return Set(result.ops)
    }

    /// Runs an immediate, undoable document edit and reports failures in the
    /// standard alert. Returns false when the edit did not apply.
    @discardableResult
    func performDocumentEdit(_ ops: [[String: Any]], actionName: String, in tab: DocumentTab) async -> Bool {
        do {
            try await applyDocumentTransform(ops, to: tab, actionName: actionName)
            return true
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return false
        }
    }

    /// Unified error reporting for panel actions.
    func reportPanelError(_ error: Error, in tab: DocumentTab?) {
        saveError = OpenError(fileName: tab?.displayName ?? Constants.appName, message: error.localizedDescription)
    }
}

@MainActor
final class EngineCapabilities {
    static let shared = EngineCapabilities()
    var operations: Set<String>?
}

struct OperationList: Decodable {
    let ops: [String]
    let queries: [String]
}

// MARK: - Navigation models

struct OutlineItemModel: Codable, Identifiable, Hashable {
    var id = UUID()
    var ref: String?
    var title: String
    var page: Int?
    var fit: String?
    var left: Double?
    var top: Double?
    var zoom: Double?
    var destName: String?
    var uri: String?
    var action: String?
    var open: Bool = false
    var italic: Bool = false
    var bold: Bool = false
    var color: [Int]?
    var children: [OutlineItemModel] = []

    enum CodingKeys: String, CodingKey {
        case ref, title, page, fit, left, top, zoom, destName, uri, action, open, italic, bold, color, children
    }

    init(title: String, page: Int?, top: Double? = nil, left: Double? = nil, zoom: Double? = nil) {
        self.title = title
        self.page = page
        self.top = top
        self.left = left
        self.zoom = zoom
        self.fit = top == nil ? nil : "XYZ"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        fit = try c.decodeIfPresent(String.self, forKey: .fit)
        left = try c.decodeIfPresent(Double.self, forKey: .left)
        top = try c.decodeIfPresent(Double.self, forKey: .top)
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
        destName = try c.decodeIfPresent(String.self, forKey: .destName)
        uri = try c.decodeIfPresent(String.self, forKey: .uri)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        color = try c.decodeIfPresent([Int].self, forKey: .color)
        children = try c.decodeIfPresent([OutlineItemModel].self, forKey: .children) ?? []
    }

    /// Engine `set_outline` item. A page destination wins over the original
    /// target; unmodelled actions travel by `ref`.
    var engineItem: [String: Any] {
        var item: [String: Any] = ["title": title, "open": open, "bold": bold, "italic": italic,
                                   "children": children.map(\.engineItem)]
        if let ref { item["ref"] = ref }
        if let uri { item["uri"] = uri }
        else if let page {
            item["page"] = page
            if let fit { item["fit"] = fit }
            if let left { item["left"] = left }
            if let top { item["top"] = top }
            if let zoom { item["zoom"] = zoom }
        } else if let destName { item["dest_name"] = destName }
        if let color { item["color"] = color }
        return item
    }

    var destinationSummary: String {
        if let uri { return uri }
        if let page { return "Page \(page + 1)" }
        if let destName { return "Destination “\(destName)”" }
        if let action { return "\(action) action" }
        return "No destination"
    }
}

struct OutlineResult: Decodable {
    let items: [OutlineItemModel]
    let count: Int?
    let truncated: Bool?
}

struct DestinationModel: Decodable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let page: Int?
    let fit: String?
    let left: Double?
    let top: Double?
    let zoom: Double?
}

struct DestinationsResult: Decodable { let items: [DestinationModel] }

struct AttachmentModel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let filename: String?
    let description: String?
    let size: Int?
    let mime: String?
    let created: String?
    let modified: String?
    let page: Int?

    var displayName: String { filename ?? name }
    var isPDF: Bool { displayName.lowercased().hasSuffix(".pdf") || mime == "application/pdf" }
}

struct AttachmentsResult: Decodable { let items: [AttachmentModel] }

struct AttachmentData: Decodable {
    let filename: String
    let size: Int
    let data: String
}

struct LayerModel: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
    let visible: Bool?
    let locked: Bool
    let depth: Int
    let group: String?
    let prints: Bool?
    let kind: String

    var rowID: String { id ?? "label:\(depth):\(name)" }
}

struct LayersResult: Decodable {
    let items: [LayerModel]
    let hasLayers: Bool
}

struct ArticleBead: Decodable, Hashable {
    let page: Int?
    let rect: [Double]?
}

struct ArticleThread: Decodable, Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let title: String
    let author: String?
    let subject: String?
    let beads: [ArticleBead]
}

struct ArticlesResult: Decodable { let threads: [ArticleThread] }

struct Model3DItem: Decodable, Identifiable, Hashable {
    var id: String { "\(page)-\(name)-\(rect?.description ?? "")" }
    let page: Int
    let subtype: String
    let name: String
    let format: String?
    let views: [String]
    let rect: [Double]?
}

struct Models3DResult: Decodable { let items: [Model3DItem] }

struct ContentObjectModel: Decodable, Hashable {
    let type: String
    let rect: [Double]
    let text: String?
}

struct ContentObjectsResult: Decodable {
    let page: Int
    let objects: [ContentObjectModel]
    let total: Int
}

// MARK: - Properties models

struct FontModel: Decodable, Hashable, Identifiable {
    var id: String { name + type + encoding + "\(pages)" }
    let name: String
    let type: String
    let embedded: Bool
    let subset: Bool
    let embeddedType: String?
    let encoding: String
    let toUnicode: Bool
    let pages: [Int]
}

struct FontsResult: Decodable { let items: [FontModel] }

struct DocumentPropertiesModel: Decodable {
    struct Info: Decodable {
        var title: String?
        var author: String?
        var subject: String?
        var keywords: String?
        var creator: String?
        var producer: String?
        var creationdate: String?
        var moddate: String?
        var trapped: String?
    }
    struct OpenAction: Decodable {
        let page: Int?
        let zoom: ZoomValue?
        let fit: String?
        let javascript: Bool?
    }
    struct InitialView: Decodable {
        let pageLayout: String?
        let pageMode: String?
        let open: OpenAction
        let viewerPreferences: [String: FlexibleValue]
    }
    struct Encryption: Decodable {
        let R: Int?
        let V: Int?
        let bits: Int?
        let method: String?
        enum CodingKeys: String, CodingKey { case R, V, bits, method }
    }
    var info: Info
    var custom: [String: String]
    var xmp: String?
    var version: String
    var pageCount: Int
    var pageSize: [Double]
    var tagged: Bool
    var linearized: Bool
    var encrypted: Bool
    var encryption: Encryption?
    var permissions: [String: Bool]
    var lang: String?
    var hasXfa: Bool
    var xfaOnly: Bool
    var needsRendering: Bool
    var formFields: Int
    var pageLabels: Bool
    var attachments: Int
    var pdfa: String?
    var pdfua: Bool
    var initialView: InitialView

    /// JSONDecoder's snake-case strategy also rewrites dictionary keys, so
    /// custom metadata names are restored from the raw reply.
    static func load(_ json: NativeJSON) throws -> DocumentPropertiesModel {
        var model = try json.decode(DocumentPropertiesModel.self)
        if let custom = json["custom"] as? [String: Any] {
            model.custom = custom.compactMapValues { $0 as? String }
        }
        return model
    }
}

/// Engine zoom values are "default", "fit_page"... or a percentage.
enum ZoomValue: Decodable, Hashable {
    case named(String)
    case percent(Double)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Double.self) { self = .percent(value) }
        else { self = .named(try c.decode(String.self)) }
    }
}

enum FlexibleValue: Decodable, Hashable {
    case bool(Bool), string(String), int(Int), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int.self) { self = .int(value) }
        else { self = .string(try c.decode(String.self)) }
    }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int: Int? { if case .int(let v) = self { return v }; return nil }
}

struct JavaScriptItem: Decodable, Identifiable, Hashable {
    let id: String
    let location: String
    let name: String
    let event: String?
    let page: Int?
    let length: Int
    let script: String

    var locationTitle: String {
        switch location {
        case "document": "Document script"
        case "open_action": "Open action"
        case "document_action": "Document action"
        case "page": "Page action"
        case "field": "Form field"
        case "link": "Link"
        default: "Annotation"
        }
    }
}

struct JavaScriptResult: Decodable { let items: [JavaScriptItem] }

// MARK: - Dates

enum PDFDateText {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = iso.date(from: value) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: value)
    }

    static func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        guard let date = date(value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
