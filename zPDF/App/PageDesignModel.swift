import AppKit

/// Form state of a page design sheet and the engine operations it produces.
/// Kept separate from the view so settings round-trip and operations are testable.
struct PageDesignModel {
    let kind: PageDesignKind
    var scope: ScopeChoice = .all
    var range = ""
    // Text styling
    var family: FontFamilyChoice = .sans
    var bold = false
    var fontSize: Double = 10
    var color: NSColor = .black
    // Header & footer
    var fields: [String: String] = [:]
    var margins = EdgeMargins(left: 36, bottom: 30, right: 36, top: 30)
    var startNumber = 1
    // Watermark / background
    var useImage = false
    var text = "CONFIDENTIAL"
    var imageURL: URL?
    var opacity: Double = 0.3
    var angle: Double = 45
    var anchor: AnchorChoice = .center
    var under = false
    var fit = false
    var scale: Double = 100
    // Bates
    var prefix = ""
    var suffix = ""
    var batesStart = 1
    var digits = 6
    var batesAnchor: AnchorChoice = .bottomRight

    static let headerKeys = ["top-left", "top-center", "top-right"]
    static let footerKeys = ["bottom-left", "bottom-center", "bottom-right"]

    init(kind: PageDesignKind) {
        self.kind = kind
        switch kind {
        case .headerFooter:
            fontSize = 10
            fields = ["bottom-center": "Page <<page>> of <<pages>>"]
        case .watermark:
            fontSize = 60
            color = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
            bold = true
        case .background:
            color = NSColor(srgbRed: 1, green: 0.98, blue: 0.9, alpha: 1)
            opacity = 1
        case .bates:
            fontSize = 10
        }
    }

    func batesNumber(_ n: Int) -> String {
        prefix + String(format: "%0\(min(max(digits, 1), 15))d", n) + suffix
    }

    /// nil when the range is invalid; empty = all pages.
    func pages(current: Int, count: Int) -> [Int]? {
        if scope == .all { return [] }
        let list = scope.scope(range: range).pages(current: current, count: count)
        return list.isEmpty ? nil : list
    }

    func canApply(current: Int, count: Int) -> Bool {
        guard pages(current: current, count: count) != nil else { return false }
        switch kind {
        case .headerFooter: return fields.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .watermark: return useImage ? imageURL != nil : !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .background: return useImage ? imageURL != nil : true
        case .bates: return true
        }
    }

    private var fontSpec: [String: Any] { ["family": family.rawValue, "bold": bold] }

    var settings: [String: Any] {
        var s: [String: Any] = ["family": family.rawValue, "bold": bold, "size": fontSize, "color": color.engineRGB,
                                "scope": scope.rawValue, "range": range]
        switch kind {
        case .headerFooter:
            s["fields"] = fields
            s["margins"] = [margins.left, margins.bottom, margins.right, margins.top]
            s["start"] = startNumber
        case .watermark:
            s["text"] = text; s["image"] = useImage; s["opacity"] = opacity; s["angle"] = angle
            s["anchor"] = anchor.rawValue; s["under"] = under; s["fit"] = fit; s["scale"] = scale
        case .background:
            s["image"] = useImage; s["opacity"] = opacity; s["fit"] = fit
        case .bates:
            s["prefix"] = prefix; s["suffix"] = suffix; s["start"] = batesStart; s["digits"] = digits
            s["anchor"] = batesAnchor.rawValue
        }
        return s
    }

    /// The overlay operation followed by the settings tag used to update it later.
    func operations(current: Int, count: Int) -> [[String: Any]] {
        var op: [String: Any]
        let rgb = color.engineRGB
        switch kind {
        case .headerFooter:
            let items = fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            op = ["op": "header_footer", "items": items, "font": fontSpec, "size": fontSize, "color": rgb,
                  "margins": [margins.left, margins.bottom, margins.right, margins.top], "start": startNumber]
        case .watermark:
            op = ["op": "watermark", "opacity": opacity, "angle": angle, "anchor": anchor.rawValue, "under": under]
            if useImage, let imageURL {
                op["image"] = imageURL.path
                op["fit"] = fit
                op["scale"] = scale / 100
            } else {
                op["text"] = text
                op["font"] = fontSpec
                op["size"] = fontSize
                op["color"] = rgb
            }
        case .background:
            op = ["op": "background", "opacity": opacity]
            if useImage, let imageURL { op["image"] = imageURL.path; op["scale_to_fit"] = fit } else { op["color"] = rgb }
        case .bates:
            op = ["op": "bates", "prefix": prefix, "suffix": suffix, "start": batesStart, "digits": digits,
                  "anchor": batesAnchor.rawValue, "font": fontSpec, "size": fontSize, "color": rgb,
                  "margins": [36, 24, 36, 24]]
        }
        if let pages = pages(current: current, count: count), !pages.isEmpty { op["pages"] = pages }
        return [op, ["op": "tag_overlay_settings", "kind": kind.rawValue, "settings": settings]]
    }

    mutating func restore(_ s: [String: Any]) {
        if let v = s["family"] as? String, let f = FontFamilyChoice(rawValue: v) { family = f }
        if let v = s["bold"] as? Bool { bold = v }
        if let v = s["size"] as? Double { fontSize = v }
        if let v = NSColor(components: s["color"]) { color = v }
        if let v = s["scope"] as? String, let c = ScopeChoice(rawValue: v) { scope = c }
        if let v = s["range"] as? String { range = v }
        switch kind {
        case .headerFooter:
            if let v = s["fields"] as? [String: String] { fields = v }
            if let m = s["margins"] as? [Double], m.count == 4 { margins = EdgeMargins(left: m[0], bottom: m[1], right: m[2], top: m[3]) }
            if let v = s["start"] as? Int { startNumber = v }
        case .watermark:
            if let v = s["text"] as? String { text = v }
            // The image file is not kept; an image watermark must be chosen again to change it.
            if let v = s["image"] as? Bool { useImage = v && imageURL != nil }
            if let v = s["opacity"] as? Double { opacity = v }
            if let v = s["angle"] as? Double { angle = v }
            if let v = s["anchor"] as? String, let a = AnchorChoice(rawValue: v) { anchor = a }
            if let v = s["under"] as? Bool { under = v }
            if let v = s["fit"] as? Bool { fit = v }
            if let v = s["scale"] as? Double { scale = v }
        case .background:
            if let v = s["opacity"] as? Double { opacity = v }
            if let v = s["fit"] as? Bool { fit = v }
        case .bates:
            if let v = s["prefix"] as? String { prefix = v }
            if let v = s["suffix"] as? String { suffix = v }
            if let v = s["start"] as? Int { batesStart = v }
            if let v = s["digits"] as? Int { digits = v }
            if let v = s["anchor"] as? String, let a = AnchorChoice(rawValue: v) { batesAnchor = a }
        }
    }

    /// Text substituted for a header/footer template in the preview.
    func expanded(_ template: String, pageCount: Int) -> String {
        template.replacingOccurrences(of: "<<page>>", with: "\(startNumber)")
            .replacingOccurrences(of: "<<pages>>", with: "\(max(1, pageCount))")
            .replacingOccurrences(of: "<<date>>", with: Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))
            .replacingOccurrences(of: "<<isodate>>", with: Date().formatted(.iso8601.year().month().day()))
            .replacingOccurrences(of: "<<bates>>", with: batesNumber(batesStart))
    }
}
