import AppKit
import CoreText
import PDFKit

/// Page content as reported by the engine's `page_content` query (user space).
struct PageContent: Sendable {
    let page: Int
    let digest: String
    let rotation: Int
    let crop: CGRect
    let blocks: [TextBlock]
    let objects: [ContentObject]

    init?(_ value: [String: Any]) {
        guard let page = value["page"] as? Int, let digest = value["digest"] as? String else { return nil }
        self.page = page
        self.digest = digest
        rotation = value["rotation"] as? Int ?? 0
        crop = CGRect(box: value["crop"]) ?? .zero
        blocks = (value["blocks"] as? [[String: Any]] ?? []).compactMap(TextBlock.init)
        objects = (value["objects"] as? [[String: Any]] ?? []).compactMap(ContentObject.init)
    }
}

struct TextRunStyle: Sendable, Equatable {
    let base: String
    let family: String
    let bold: Bool
    let italic: Bool
    let mono: Bool
    let serif: Bool

    init(_ value: [String: Any]?) {
        base = value?["base"] as? String ?? "Helvetica"
        family = value?["family"] as? String ?? "Helvetica"
        bold = value?["bold"] as? Bool ?? false
        italic = value?["italic"] as? Bool ?? false
        mono = value?["mono"] as? Bool ?? false
        serif = value?["serif"] as? Bool ?? false
    }

    /// The closest installed face for on-screen editing.
    func font(size: CGFloat) -> NSFont {
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let exact = NSFont(name: base, size: size) { return exact }
        let compact = family.replacingOccurrences(of: " ", with: "")
        for candidate in [family, compact] {
            if let font = manager.font(withFamily: candidate, traits: traits, weight: bold ? 9 : 5, size: size) {
                return font
            }
        }
        let fallbackFamily = mono ? "Courier" : (serif ? "Times" : "Helvetica")
        return manager.font(withFamily: fallbackFamily, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

struct TextRun: Sendable {
    let text: String
    let fontKey: String
    let style: TextRunStyle
    let size: Double
    let color: NSColor

    init?(_ value: [String: Any]) {
        guard let text = value["text"] as? String else { return nil }
        self.text = text
        fontKey = value["font"] as? String ?? ""
        style = TextRunStyle(value["style"] as? [String: Any])
        size = value["size"] as? Double ?? 12
        color = NSColor(components: value["color"]) ?? .black
    }
}

enum TextAlignmentChoice: String, CaseIterable, Identifiable, Sendable {
    case left, center, right, justify
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbolName: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justify: "text.justify"
        }
    }
    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justify: .justified
        }
    }
    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center: self = .center
        case .right: self = .right
        case .justified: self = .justify
        default: self = .left
        }
    }
}

struct TextBlock: Identifiable, Sendable {
    let id: Int
    let text: String
    let lines: [String]
    let runs: [TextRun]
    /// Maps block-local coordinates (x along the baseline, y up; origin at the
    /// first baseline's left edge) to user space.
    let frame: CGAffineTransform
    let width: Double
    let ascent: Double
    let bottom: Double
    let quad: [CGPoint]
    let bbox: CGRect
    let size: Double
    let align: TextAlignmentChoice
    let lineSpacing: Double
    let editable: Bool
    let style: TextRunStyle
    let color: NSColor

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? Int, let frame = value["frame"] as? [Double], frame.count == 6,
              let bbox = CGRect(box: value["bbox"]) else { return nil }
        self.id = id
        text = value["text"] as? String ?? ""
        lines = value["lines"] as? [String] ?? []
        runs = (value["runs"] as? [[String: Any]] ?? []).compactMap(TextRun.init)
        self.frame = CGAffineTransform(a: frame[0], b: frame[1], c: frame[2], d: frame[3], tx: frame[4], ty: frame[5])
        width = value["width"] as? Double ?? bbox.width
        ascent = value["ascent"] as? Double ?? 10
        bottom = value["bottom"] as? Double ?? -3
        quad = (value["quad"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        self.bbox = bbox
        size = value["size"] as? Double ?? 12
        align = TextAlignmentChoice(rawValue: value["align"] as? String ?? "left") ?? .left
        lineSpacing = value["line_spacing"] as? Double ?? 1.2
        editable = value["editable"] as? Bool ?? true
        style = TextRunStyle(value["font"] as? [String: Any])
        color = NSColor(components: value["color"]) ?? .black
    }

    /// The block box in block-local coordinates.
    var localBox: CGRect { CGRect(x: 0, y: bottom, width: width, height: ascent - bottom) }

    func contains(_ point: CGPoint, tolerance: CGFloat = 2) -> Bool {
        let local = point.applying(frame.inverted())
        return localBox.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
    }

    var area: CGFloat { CGFloat(width * (ascent - bottom)) }
}

struct ContentObject: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case image, inlineImage = "inline_image", path, shading, form
        var title: String {
            switch self {
            case .image, .inlineImage: "Image"
            case .path: "Vector artwork"
            case .shading: "Shading"
            case .form: "Group"
            }
        }
        var isImage: Bool { self == .image || self == .inlineImage }
    }

    let id: String
    let kind: Kind
    let bbox: CGRect
    let quad: [CGPoint]
    let pixels: CGSize?
    let movable: Bool

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let kind = Kind(rawValue: value["kind"] as? String ?? ""),
              let bbox = CGRect(box: value["bbox"]) else { return nil }
        self.id = id
        self.kind = kind
        self.bbox = bbox
        quad = (value["quad"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        if let px = value["pixels"] as? [Int], px.count == 2 { pixels = CGSize(width: px[0], height: px[1]) } else { pixels = nil }
        movable = value["movable"] as? Bool ?? true
    }

    var area: CGFloat { max(bbox.width, 1) * max(bbox.height, 1) }
}

struct PageLink: Identifiable, Sendable, Equatable {
    let index: Int
    let rect: CGRect
    let uri: String?
    let destinationPage: Int?
    var id: Int { index }

    init?(_ value: [String: Any]) {
        guard let index = value["index"] as? Int, let rect = CGRect(box: value["rect"]) else { return nil }
        self.index = index
        self.rect = rect
        uri = value["uri"] as? String
        destinationPage = value["dest_page"] as? Int
    }

    var summary: String {
        if let uri { return uri }
        if let destinationPage { return "Page \(destinationPage + 1)" }
        return "Other action"
    }
}

extension CGRect {
    init?(box: Any?) {
        guard let values = box as? [Double], values.count == 4 else { return nil }
        self.init(x: min(values[0], values[2]), y: min(values[1], values[3]),
                  width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    var pdfBox: [Double] { [Double(minX), Double(minY), Double(maxX), Double(maxY)] }
}

extension NSColor {
    convenience init?(components: Any?) {
        guard let values = components as? [Double], values.count >= 3 else { return nil }
        let scale = values.contains { $0 > 1 } ? 255.0 : 1.0
        self.init(srgbRed: values[0] / scale, green: values[1] / scale, blue: values[2] / scale, alpha: 1)
    }

    /// 0–1 sRGB components for engine operations.
    var engineRGB: [Double] {
        let rgb = usingColorSpace(.sRGB) ?? .black
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Double(($0 * 1000).rounded() / 1000) }
    }
}

extension NSFont {
    /// Engine font spec: the installed file backing this face.
    var engineSpec: [String: Any] {
        if let url = CTFontCopyAttribute(self as CTFont, kCTFontURLAttribute) as? URL {
            return ["path": url.path, "postscript": fontName]
        }
        let traits = fontDescriptor.symbolicTraits
        return ["family": traits.contains(.monoSpace) ? "mono" : "sans",
                "bold": traits.contains(.bold), "italic": traits.contains(.italic)]
    }
}

/// Engine calls used by the editing tools.
@MainActor
enum PageContentService {
    /// Source (editing revision) page index for a live PDFKit page.
    static func sourceIndex(of page: PDFPage, in tab: DocumentTab) -> Int? {
        tab.saveBaseline?.sourceIndex(for: page)
    }

    static func content(of pages: [Int], in appState: AppState, tab: DocumentTab) async throws -> [PageContent] {
        let result = try await appState.queryDocument("page_content", params: ["pages": pages], in: tab)
        return (result["pages"] as? [[String: Any]] ?? []).compactMap(PageContent.init)
    }

    static func links(onSourcePage page: Int, in appState: AppState, tab: DocumentTab) async throws -> [PageLink] {
        let result = try await appState.queryDocument("links", params: ["page": page], in: tab)
        return (result["links"] as? [[String: Any]] ?? []).compactMap(PageLink.init)
    }
}
