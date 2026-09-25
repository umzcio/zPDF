import Foundation

struct AccessibilityReport: Decodable {
    struct Summary: Decodable {
        let passed: Int
        let failed: Int
        let manual: Int
        let skipped: Int
    }
    struct PDFUA: Decodable { let claimed: Bool }
    let tagged: Bool
    let pdfua: PDFUA
    let summary: Summary
    let items: [AccessibilityCheckItem]

    var categories: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.category) { seen.append(item.category) }
        return seen
    }
    var fixable: [AccessibilityCheckItem] { items.filter { $0.status == .failed && $0.fix != nil } }
}

struct AccessibilityCheckItem: Decodable, Identifiable, Hashable {
    enum Status: String, Decodable {
        case passed, failed, manual, skipped
        var title: String {
            switch self {
            case .passed: "Passed"
            case .failed: "Failed"
            case .manual: "Needs manual check"
            case .skipped: "Skipped"
            }
        }
        var symbol: String {
            switch self {
            case .passed: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .manual: "person.crop.circle.badge.questionmark"
            case .skipped: "minus.circle"
            }
        }
    }
    let id: String
    let category: String
    let title: String
    let status: Status
    let detail: String
    let fix: String?
    let pages: [Int]
}

/// Fix actions the checker can suggest (engine fix ids).
enum AccessibilityFix: String, CaseIterable {
    case setTitle = "set_title", setLanguage = "set_language", setTabOrder = "set_page_tab_order", autotag,
         fieldTooltips = "field_tooltips", bookmarks, tagAnnotations = "tag_annotations"

    var title: String {
        switch self {
        case .setTitle: "Set Title…"
        case .setLanguage: "Set Language…"
        case .setTabOrder: "Set Tab Order"
        case .autotag: "Autotag Document"
        case .fieldTooltips: "Add Field Descriptions"
        case .bookmarks: "Add Bookmarks"
        case .tagAnnotations: "Tag Annotations"
        }
    }

    var needsInput: Bool { self == .setTitle || self == .setLanguage }
}

struct StructureNode: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let role: String?
    let alt: String?
    let actualText: String?
    let title: String?
    let lang: String?
    let page: Int?
    let text: String?
    let children: [StructureNode]?

    /// SwiftUI outline children (nil for leaves).
    var outlineChildren: [StructureNode]? { (children?.isEmpty ?? true) ? nil : children }

    var isFigure: Bool { (role ?? type) == "Figure" }

    func flattened() -> [StructureNode] { [self] + (children ?? []).flatMap { $0.flattened() } }

    /// Child-index path of `id` below this node.
    func path(to target: String) -> [Int]? {
        if id == target { return [] }
        for (index, child) in (children ?? []).enumerated() {
            if let rest = child.path(to: target) { return [index] + rest }
        }
        return nil
    }

    func node(at path: [Int]) -> StructureNode? {
        guard let first = path.first else { return self }
        guard let children, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }
}

struct StructureTreeResult: Decodable {
    let tagged: Bool
    let truncated: Bool
    let root: StructureNode?
}

struct ReadingOrderItem: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let order: Int
    let rect: [Double]
    let text: String?

    var cgRect: CGRect {
        guard rect.count == 4 else { return .zero }
        return CGRect(x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1])
    }
}

struct ReadingOrderResult: Decodable {
    let page: Int
    let items: [ReadingOrderItem]
}

struct AutotagResult: Decodable {
    let elements: Int
    let headings: Int
    let paragraphs: Int
    let lists: Int
    let tables: Int
    let figures: Int
    let notes: [String]
}

/// Standard structure types offered in the Tags editor.
enum StandardTag {
    static let groups: [(String, [String])] = [
        ("Grouping", ["Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct"]),
        ("Headings & paragraphs", ["H1", "H2", "H3", "H4", "H5", "H6", "H", "P"]),
        ("Lists", ["L", "LI", "Lbl", "LBody"]),
        ("Tables", ["Table", "THead", "TBody", "TFoot", "TR", "TH", "TD"]),
        ("Inline", ["Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot"]),
        ("Illustrations", ["Figure", "Formula", "Form"])
    ]
    static var all: [String] { groups.flatMap(\.1) }
}
