//
//  CommentAnnotation.swift
//  zPDF
//
//  Purpose: App-drawn comment annotations. PDFKit serializes a subclass's
//  draw(with:in:) as the annotation's normal appearance stream, so shapes
//  PDFKit cannot draw (clouds, polygons, callouts, carets, stamps, media
//  icons) look identical on screen, in the saved file and in other viewers.
//  Standard keys (/Vertices, /L, /IC, /BS...) are written too; what PDFKit
//  cannot write (/CA, /BE, /IT, callout geometry, media) travels as
//  /ZPDFSpec JSON that the engine completes on Save (transforms/comments.py).
//  Also: loaded-annotation rehydration, save-time replacement identity,
//  presentation-only hiding, and undo snapshots of comment appearance.
//

import AppKit
import ObjectiveC
import PDFKit

// MARK: - Style model

/// sRGB colour with alpha, stable across light/dark interface appearance.
struct CommentColor: Codable, Equatable, Hashable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init?(_ color: NSColor?) {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
    var opaque: CommentColor { CommentColor(red: red, green: green, blue: blue) }
    var hex: String { String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }

    static let yellow = CommentColor(red: 1, green: 0.85, blue: 0.15)
    static let red = CommentColor(red: 0.90, green: 0.20, blue: 0.22)
    static let green = CommentColor(red: 0.15, green: 0.65, blue: 0.30)
    static let blue = CommentColor(red: 0.15, green: 0.45, blue: 0.95)
    static let purple = CommentColor(red: 0.60, green: 0.30, blue: 0.85)
    static let pink = CommentColor(red: 0.95, green: 0.35, blue: 0.65)
    static let orange = CommentColor(red: 0.96, green: 0.55, blue: 0.13)
    static let black = CommentColor(red: 0.08, green: 0.08, blue: 0.08)
    static let white = CommentColor(red: 1, green: 1, blue: 1)
    /// Palette offered by the properties inspector, in display order.
    static let palette: [CommentColor] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .black]

    var name: String {
        let named: [(CommentColor, String)] = [(.red, "Red"), (.orange, "Orange"), (.yellow, "Yellow"), (.green, "Green"),
                                               (.blue, "Blue"), (.purple, "Purple"), (.pink, "Pink"), (.black, "Black"), (.white, "White")]
        return named.first { $0.0.opaque == opaque }?.1 ?? hex
    }
}

enum CommentLineStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid, dashed, cloudy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CommentLineEnding: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "None", openArrow = "OpenArrow", closedArrow = "ClosedArrow", circle = "Circle", square = "Square", butt = "Butt"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"; case .openArrow: "Open arrow"; case .closedArrow: "Closed arrow"
        case .circle: "Circle"; case .square: "Square"; case .butt: "Bar"
        }
    }
    var pdfKitStyle: PDFLineStyle {
        switch self {
        case .none: .none; case .openArrow: .openArrow; case .closedArrow: .closedArrow
        case .circle: .circle; case .square: .square; case .butt: .none
        }
    }
}

/// Appearance shared by every comment kind; each tool keeps its own default.
struct CommentStyle: Codable, Equatable, Sendable {
    var color: CommentColor = .red
    var fill: CommentColor?
    var opacity: Double = 1
    var lineWidth: Double = 2
    var lineStyle: CommentLineStyle = .solid
    var fontName: String = "Helvetica"
    var fontSize: Double = 12
    var textColor: CommentColor = .black
    var startEnding: CommentLineEnding = .none
    var endEnding: CommentLineEnding = .none

    var dashPattern: [CGFloat] { [CGFloat(max(2, lineWidth * 2)), CGFloat(max(2, lineWidth * 1.5))] }
    var font: NSFont { NSFont(name: fontName, size: CGFloat(fontSize)) ?? .systemFont(ofSize: CGFloat(fontSize)) }
}

/// Stamp faces: Acrobat's standard business stamps, dynamic (name + time)
/// stamps, and the user's own images.
struct StampDesign: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case standard, dynamic, image }
    var kind: Kind
    /// PDF /Name for standard stamps ("Approved"); a label for dynamic ones.
    var name: String
    var label: String
    var detail: String?
    var colorHex: String
    var imagePNG: Data?

    static let standard: [StampDesign] = [
        .init(kind: .standard, name: "Approved", label: "APPROVED", colorHex: "#1E7B34"),
        .init(kind: .standard, name: "NotApproved", label: "NOT APPROVED", colorHex: "#C62828"),
        .init(kind: .standard, name: "Draft", label: "DRAFT", colorHex: "#1F4FA3"),
        .init(kind: .standard, name: "Final", label: "FINAL", colorHex: "#1E7B34"),
        .init(kind: .standard, name: "Confidential", label: "CONFIDENTIAL", colorHex: "#C62828"),
        .init(kind: .standard, name: "ForComment", label: "FOR COMMENT", colorHex: "#1F4FA3"),
        .init(kind: .standard, name: "ForPublicRelease", label: "FOR PUBLIC RELEASE", colorHex: "#1E7B34"),
        .init(kind: .standard, name: "NotForPublicRelease", label: "NOT FOR PUBLIC RELEASE", colorHex: "#C62828"),
        .init(kind: .standard, name: "AsIs", label: "AS IS", colorHex: "#1F4FA3"),
        .init(kind: .standard, name: "Departmental", label: "DEPARTMENTAL", colorHex: "#1F4FA3"),
        .init(kind: .standard, name: "Experimental", label: "EXPERIMENTAL", colorHex: "#1F4FA3"),
        .init(kind: .standard, name: "Expired", label: "EXPIRED", colorHex: "#C62828"),
        .init(kind: .standard, name: "Sold", label: "SOLD", colorHex: "#1F4FA3"),
        .init(kind: .standard, name: "TopSecret", label: "TOP SECRET", colorHex: "#C62828"),
    ]

    /// Dynamic stamp templates; the author and time are filled at placement.
    static let dynamicTemplates: [StampDesign] = [
        .init(kind: .dynamic, name: "Approved", label: "APPROVED", colorHex: "#1E7B34"),
        .init(kind: .dynamic, name: "Reviewed", label: "REVIEWED", colorHex: "#1F4FA3"),
        .init(kind: .dynamic, name: "Received", label: "RECEIVED", colorHex: "#1F4FA3"),
        .init(kind: .dynamic, name: "Revised", label: "REVISED", colorHex: "#B45309"),
        .init(kind: .dynamic, name: "Rejected", label: "REJECTED", colorHex: "#C62828"),
    ]

    func filled(author: String, date: Date) -> StampDesign {
        var copy = self
        guard kind == .dynamic else { return copy }
        let when = date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        copy.detail = author.isEmpty ? "at \(when)" : "By \(author) at \(when)"
        return copy
    }

    var displayTitle: String {
        switch kind {
        case .standard: label.capitalized
        case .dynamic: label.capitalized + " (name & date)"
        case .image: label
        }
    }

    /// Natural aspect ratio for placement.
    var aspectRatio: CGFloat {
        if kind == .image, let data = imagePNG, let image = NSImage(data: data), image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return kind == .dynamic ? 3.2 : max(2.4, CGFloat(label.count) * 0.36)
    }
}

// MARK: - Geometry model

/// Everything an app-drawn comment needs to render. Points are relative to
/// the annotation's bounds origin, so moving the annotation is a bounds change.
struct CommentDesign: Codable, Equatable, Sendable {
    enum Shape: String, Codable, Sendable {
        case rectangle, oval, line, polygon, polyline, caret, callout, stamp, attachment, sound
    }
    var shape: Shape
    var style: CommentStyle
    var points: [CGPoint] = []
    /// Callout text box, relative to the bounds origin.
    var textBox: CGRect?
    var stamp: StampDesign?
    /// Media icon name (FileAttachment: PushPin/Paperclip; Sound: Speaker/Mic).
    var icon: String?

    var subtype: String {
        switch shape {
        case .rectangle: "Square"
        case .oval: "Circle"
        case .line: "Line"
        case .polygon: "Polygon"
        case .polyline: "PolyLine"
        case .caret: "Caret"
        case .callout: "FreeText"
        case .stamp: "Stamp"
        case .attachment: "FileAttachment"
        case .sound: "Sound"
        }
    }

    /// Scale geometry for a resized bounds rectangle.
    func scaled(from old: CGSize, to new: CGSize) -> CommentDesign {
        guard old.width > 0, old.height > 0 else { return self }
        let sx = new.width / old.width, sy = new.height / old.height
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        if let box = textBox {
            copy.textBox = CGRect(x: box.minX * sx, y: box.minY * sy, width: box.width * sx, height: box.height * sy)
        }
        return copy
    }
}

// MARK: - Annotation subclass

final class CommentAnnotation: PDFAnnotation {
    var design: CommentDesign {
        didSet { if design != oldValue { syncStandardKeys() } }
    }

    init(bounds: CGRect, design: CommentDesign) {
        self.design = design
        super.init(bounds: bounds, forType: PDFAnnotationSubtype(rawValue: "/" + design.subtype), withProperties: nil)
        syncStandardKeys()
    }

    required init?(coder: NSCoder) {
        self.design = CommentDesign(shape: .rectangle, style: CommentStyle())
        super.init(coder: coder)
    }

    /// Save copies annotations into a scratch document; keep the subclass and
    /// its design so the copy draws (and therefore serializes) the same.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = CommentAnnotation(bounds: bounds, design: design)
        for (key, value) in annotationKeyValues {
            guard let key = key as? String,
                  !["/Rect", "/Subtype", "/Type", "/P", "/Popup", "/Parent", "/AP"].contains(key) else { continue }
            copy.setValue(value, forAnnotationKey: PDFAnnotationKey(rawValue: key))
        }
        copy.contents = contents
        copy.userName = userName
        copy.modificationDate = modificationDate
        copy.shouldDisplay = shouldDisplay
        copy.shouldPrint = shouldPrint
        CommentVisibility.copyPresentation(from: self, to: copy)
        return copy
    }

    /// Keys other viewers read, plus the engine's completion spec.
    func syncStandardKeys() {
        let style = design.style
        color = style.color.nsColor
        if let fill = style.fill { interiorColor = fill.nsColor } else { interiorColor = nil }
        let border = PDFBorder()
        border.lineWidth = CGFloat(style.lineWidth)
        border.style = style.lineStyle == .dashed ? .dashed : .solid
        if style.lineStyle == .dashed { border.dashPattern = style.dashPattern }
        if [.stamp, .attachment, .sound, .caret].contains(design.shape) { border.lineWidth = 0 }
        self.border = border
        let origin = bounds.origin
        let absolute = design.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        switch design.shape {
        case .polygon, .polyline:
            setValue(absolute.flatMap { [NSNumber(value: Double($0.x)), NSNumber(value: Double($0.y))] },
                     forAnnotationKey: PDFAnnotationKey(rawValue: "/Vertices"))
        case .line where design.points.count == 2:
            startPoint = design.points[0]
            endPoint = design.points[1]
            startLineStyle = style.startEnding.pdfKitStyle
            endLineStyle = style.endEnding.pdfKitStyle
        case .callout:
            font = style.font
            fontColor = style.textColor.nsColor
        case .stamp:
            if let stamp = design.stamp { stampName = stamp.kind == .image ? "ZPDFImage" : stamp.name }
        default:
            break
        }
        setValue(specJSON(absolute: absolute), forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFSpec"))
        setValue(UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFRevision"))
    }

    private func specJSON(absolute: [CGPoint]) -> String {
        let style = design.style
        var spec: [String: Any] = ["opacity": style.opacity]
        switch design.shape {
        case .rectangle, .oval, .polygon:
            spec["cloudy"] = style.lineStyle == .cloudy ? 1 : 0
            if design.shape == .polygon {
                spec["intent"] = style.lineStyle == .cloudy ? "PolygonCloud" : ""
                spec["vertices"] = absolute.flatMap { [Double($0.x), Double($0.y)] }
            }
            if design.shape != .polygon {
                let inset = style.lineStyle == .cloudy ? CommentDrawing.cloudRadius(style) : 0
                spec["rd"] = [inset, inset, inset, inset].map { Double($0) }
            }
        case .polyline:
            spec["vertices"] = absolute.flatMap { [Double($0.x), Double($0.y)] }
            spec["line_endings"] = [style.startEnding.rawValue, style.endEnding.rawValue]
        case .line:
            spec["line_endings"] = [style.startEnding.rawValue, style.endEnding.rawValue]
            if style.endEnding == .openArrow || style.endEnding == .closedArrow { spec["intent"] = "LineArrow" }
        case .callout:
            spec["intent"] = "FreeTextCallout"
            let callout = absolute.flatMap { [Double($0.x), Double($0.y)] }
            if callout.count == 4 || callout.count == 6 { spec["callout"] = callout }
            spec["callout_end"] = style.endEnding == .none ? "OpenArrow" : style.endEnding.rawValue
            if let box = design.textBox {
                spec["rd"] = [Double(box.minX), Double(box.minY), Double(bounds.width - box.maxX), Double(bounds.height - box.maxY)]
                    .map { max(0, $0) }
            }
        case .caret:
            spec["symbol"] = "None"
        case .stamp:
            if let stamp = design.stamp, stamp.kind != .image { spec["icon"] = stamp.name }
            spec["subject"] = design.stamp?.label.capitalized ?? "Stamp"
        case .attachment, .sound:
            break
        }
        if let media = CommentMediaLink.spec(for: self) {
            for (key, value) in media { spec[key] = value }
        }
        if let extra = extraSpec { for (key, value) in extra { spec[key] = value } }
        let data = (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Additional spec entries (e.g. reply flags) owned by the caller.
    var extraSpec: [String: Any]? {
        didSet { syncStandardKeys() }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !CommentVisibility.isHidden(self) else { return }
        CommentDrawing.draw(design, bounds: bounds, contents: contents ?? "", in: context)
    }
}

// MARK: - Drawing

enum CommentDrawing {
    static func cloudRadius(_ style: CommentStyle) -> CGFloat { CGFloat(4 + 2 * max(1, style.lineWidth / 2)) }

    static func draw(_ design: CommentDesign, bounds: CGRect, contents: String, in context: CGContext) {
        let style = design.style
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(max(0.05, min(1, style.opacity))))
        context.setLineWidth(CGFloat(style.lineWidth))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(style.color.cgColor)
        if let fill = style.fill { context.setFillColor(fill.cgColor) }
        if style.lineStyle == .dashed { context.setLineDash(phase: 0, lengths: style.dashPattern) }
        let origin = bounds.origin
        let points = design.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        let inset = CGFloat(style.lineWidth) / 2
        switch design.shape {
        case .rectangle:
            let rect = bounds.insetBy(dx: inset, dy: inset)
            if style.lineStyle == .cloudy {
                let r = cloudRadius(style)
                let inner = bounds.insetBy(dx: r, dy: r)
                let path = cloudPath([CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                                      CGPoint(x: inner.maxX, y: inner.maxY), CGPoint(x: inner.minX, y: inner.maxY)], radius: r)
                paint(path, fill: style.fill != nil, in: context)
            } else {
                paint(CGPath(rect: rect, transform: nil), fill: style.fill != nil, in: context)
            }
        case .oval:
            paint(CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil), fill: style.fill != nil, in: context)
        case .polygon:
            guard points.count >= 2 else { return }
            if style.lineStyle == .cloudy {
                paint(cloudPath(points, radius: cloudRadius(style)), fill: style.fill != nil, in: context)
            } else {
                let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
                paint(path, fill: style.fill != nil, in: context)
            }
        case .polyline, .line:
            guard points.count >= 2 else { return }
            let path = CGMutablePath(); path.addLines(between: points)
            context.addPath(path); context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            ending(style.startEnding, at: points[0], from: points[1], style: style, in: context)
            ending(style.endEnding, at: points[points.count - 1], from: points[points.count - 2], style: style, in: context)
        case .caret:
            context.setFillColor(style.color.cgColor)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.3))
            path.closeSubpath()
            context.addPath(path); context.fillPath()
        case .callout:
            drawCallout(design, bounds: bounds, points: points, contents: contents, in: context)
        case .stamp:
            if let stamp = design.stamp { drawStamp(stamp, in: bounds, context: context) }
        case .attachment, .sound:
            drawMediaIcon(design, in: bounds, context: context)
        }
    }

    private static func paint(_ path: CGPath, fill: Bool, in context: CGContext) {
        context.addPath(path)
        context.drawPath(using: fill ? .fillStroke : .stroke)
    }

    /// Same scallop construction the engine uses for imported clouds.
    static func cloudPath(_ input: [CGPoint], radius: CGFloat) -> CGPath {
        var pts = input
        let area = zip(pts, pts.dropFirst() + [pts[0]]).reduce(0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
        if area < 0 { pts.reverse() }
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        let k: CGFloat = 0.5523
        for i in 0..<pts.count {
            let p0 = pts[i], p1 = pts[(i + 1) % pts.count]
            let length = hypot(p1.x - p0.x, p1.y - p0.y)
            guard length > 0.001 else { continue }
            let count = max(1, Int((length / (2 * radius)).rounded()))
            let ux = (p1.x - p0.x) / length, uy = (p1.y - p0.y) / length
            let nx = uy, ny = -ux
            let step = length / CGFloat(count), r = step / 2
            for j in 0..<count {
                let s = CGPoint(x: p0.x + ux * step * CGFloat(j), y: p0.y + uy * step * CGFloat(j))
                let c = CGPoint(x: s.x + ux * r, y: s.y + uy * r)
                let e = CGPoint(x: s.x + ux * step, y: s.y + uy * step)
                let t = CGPoint(x: c.x + nx * r, y: c.y + ny * r)
                path.addCurve(to: t, control1: CGPoint(x: s.x + nx * r * k, y: s.y + ny * r * k),
                              control2: CGPoint(x: t.x - ux * r * k, y: t.y - uy * r * k))
                path.addCurve(to: e, control1: CGPoint(x: t.x + ux * r * k, y: t.y + uy * r * k),
                              control2: CGPoint(x: e.x + nx * r * k, y: e.y + ny * r * k))
            }
        }
        path.closeSubpath()
        return path
    }

    static func ending(_ ending: CommentLineEnding, at tip: CGPoint, from toward: CGPoint, style: CommentStyle, in context: CGContext) {
        guard ending != .none else { return }
        let length = max(0.001, hypot(tip.x - toward.x, tip.y - toward.y))
        let ux = (tip.x - toward.x) / length, uy = (tip.y - toward.y) / length
        let size = max(7, CGFloat(style.lineWidth) * 3.5)
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let px = -uy * size * 0.5, py = ux * size * 0.5
        let path = CGMutablePath()
        switch ending {
        case .openArrow, .closedArrow:
            path.move(to: CGPoint(x: base.x + px, y: base.y + py))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: base.x - px, y: base.y - py))
            if ending == .closedArrow {
                path.closeSubpath()
                context.setFillColor((style.fill ?? style.color).cgColor)
                context.addPath(path); context.drawPath(using: .fillStroke)
                return
            }
        case .circle:
            let r = size * 0.4
            path.addEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r))
            context.setFillColor((style.fill ?? style.color).cgColor)
            context.addPath(path); context.drawPath(using: .fillStroke)
            return
        case .square:
            let r = size * 0.4
            path.addRect(CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r))
            context.setFillColor((style.fill ?? style.color).cgColor)
            context.addPath(path); context.drawPath(using: .fillStroke)
            return
        case .butt:
            path.move(to: CGPoint(x: tip.x + px, y: tip.y + py))
            path.addLine(to: CGPoint(x: tip.x - px, y: tip.y - py))
        case .none:
            return
        }
        context.addPath(path); context.strokePath()
    }

    static func drawCallout(_ design: CommentDesign, bounds: CGRect, points: [CGPoint], contents: String, in context: CGContext) {
        let style = design.style
        let box = (design.textBox ?? CGRect(origin: .zero, size: bounds.size)).offsetBy(dx: bounds.minX, dy: bounds.minY)
        context.setStrokeColor(style.color.cgColor)
        if points.count >= 2 {
            let path = CGMutablePath(); path.addLines(between: points)
            context.addPath(path); context.strokePath()
            ending(style.endEnding == .none ? .openArrow : style.endEnding, at: points[0], from: points[1], style: style, in: context)
        }
        let frame = box.insetBy(dx: CGFloat(style.lineWidth) / 2, dy: CGFloat(style.lineWidth) / 2)
        context.setFillColor((style.fill ?? .white).cgColor)
        context.addPath(CGPath(rect: frame, transform: nil))
        context.drawPath(using: .fillStroke)
        drawText(contents, in: box.insetBy(dx: 4 + CGFloat(style.lineWidth), dy: 3 + CGFloat(style.lineWidth)),
                 font: style.font, color: style.textColor.nsColor, context: context)
    }

    static func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left,
                         context: CGContext) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Standard/dynamic stamps: double rounded frame, bold tracked label and
    /// an optional detail line; images draw aspect-fit.
    static func drawStamp(_ stamp: StampDesign, in rect: CGRect, context: CGContext) {
        if stamp.kind == .image {
            guard let data = stamp.imagePNG, let image = NSImage(data: data),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let size = image.size
            let scale = min(rect.width / max(1, size.width), rect.height / max(1, size.height))
            let fitted = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                                width: size.width * scale, height: size.height * scale)
            context.interpolationQuality = .high
            context.draw(cg, in: fitted)
            return
        }
        let color = CommentColor(hex: stamp.colorHex) ?? .red
        let frame = rect.insetBy(dx: 1.5, dy: 1.5)
        let radius = min(frame.height * 0.18, 8)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.opaque.nsColor.withAlphaComponent(0.06).cgColor)
        context.setLineWidth(max(1.5, rect.height * 0.045))
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.drawPath(using: .fillStroke)
        let innerInset = max(3, rect.height * 0.08)
        let inner = frame.insetBy(dx: innerInset, dy: innerInset)
        context.setLineWidth(max(0.6, rect.height * 0.018))
        context.addPath(CGPath(roundedRect: inner, cornerWidth: max(1, radius - innerInset / 2),
                               cornerHeight: max(1, radius - innerInset / 2), transform: nil))
        context.strokePath()
        let hasDetail = !(stamp.detail ?? "").isEmpty
        let labelArea = hasDetail ? CGRect(x: inner.minX, y: inner.midY - inner.height * 0.05, width: inner.width, height: inner.height * 0.55)
                                  : inner
        var size = labelArea.height * 0.62
        let bold = NSFont.systemFont(ofSize: size, weight: .heavy)
        let tracking = size * 0.08
        func width(of font: NSFont) -> CGFloat {
            NSAttributedString(string: stamp.label, attributes: [.font: font, .kern: tracking]).size().width
        }
        var font = bold
        while width(of: font) > labelArea.width * 0.92 && size > 4 {
            size *= 0.92
            font = NSFont.systemFont(ofSize: size, weight: .heavy)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let label = NSAttributedString(string: stamp.label, attributes: [.font: font, .foregroundColor: color.nsColor, .kern: size * 0.08])
        let labelSize = label.size()
        label.draw(at: CGPoint(x: labelArea.midX - labelSize.width / 2, y: labelArea.midY - labelSize.height / 2))
        if let detail = stamp.detail, !detail.isEmpty {
            var detailSize = inner.height * 0.2
            var detailFont = NSFont.systemFont(ofSize: detailSize, weight: .semibold)
            while NSAttributedString(string: detail, attributes: [.font: detailFont]).size().width > inner.width * 0.92 && detailSize > 3 {
                detailSize *= 0.92
                detailFont = NSFont.systemFont(ofSize: detailSize, weight: .semibold)
            }
            let line = NSAttributedString(string: detail, attributes: [.font: detailFont, .foregroundColor: color.nsColor])
            let lineSize = line.size()
            line.draw(at: CGPoint(x: inner.midX - lineSize.width / 2, y: inner.minY + inner.height * 0.12))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Media comments: a filled badge with a paperclip or speaker glyph.
    static func drawMediaIcon(_ design: CommentDesign, in rect: CGRect, context: CGContext) {
        let color = design.style.color
        let badge = rect.insetBy(dx: 0.75, dy: 0.75)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: badge.width * 0.22, cornerHeight: badge.width * 0.22, transform: nil))
        context.fillPath()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setFillColor(NSColor.white.cgColor)
        let w = badge.width, h = badge.height, x = badge.minX, y = badge.minY
        context.setLineWidth(max(1, w * 0.085))
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [])
        if design.shape == .sound {
            let body = CGMutablePath()
            body.move(to: CGPoint(x: x + w * 0.2, y: y + h * 0.4))
            body.addLine(to: CGPoint(x: x + w * 0.34, y: y + h * 0.4))
            body.addLine(to: CGPoint(x: x + w * 0.52, y: y + h * 0.24))
            body.addLine(to: CGPoint(x: x + w * 0.52, y: y + h * 0.76))
            body.addLine(to: CGPoint(x: x + w * 0.34, y: y + h * 0.6))
            body.addLine(to: CGPoint(x: x + w * 0.2, y: y + h * 0.6))
            body.closeSubpath()
            context.addPath(body); context.fillPath()
            for (radius, _) in [(0.16, 0), (0.28, 1)] {
                let arc = CGMutablePath()
                arc.addArc(center: CGPoint(x: x + w * 0.52, y: y + h * 0.5), radius: w * radius,
                           startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
                context.addPath(arc); context.strokePath()
            }
        } else {
            // Paperclip: two nested rounded loops.
            let clip = CGMutablePath()
            clip.move(to: CGPoint(x: x + w * 0.62, y: y + h * 0.64))
            clip.addLine(to: CGPoint(x: x + w * 0.62, y: y + h * 0.3))
            clip.addArc(center: CGPoint(x: x + w * 0.5, y: y + h * 0.3), radius: w * 0.12, startAngle: 0, endAngle: .pi, clockwise: true)
            clip.addLine(to: CGPoint(x: x + w * 0.38, y: y + h * 0.72))
            clip.addArc(center: CGPoint(x: x + w * 0.46, y: y + h * 0.72), radius: w * 0.08, startAngle: .pi, endAngle: 0, clockwise: true)
            clip.addLine(to: CGPoint(x: x + w * 0.54, y: y + h * 0.38))
            context.addPath(clip); context.strokePath()
        }
    }
}

// MARK: - Loaded annotation rehydration

enum CommentRehydration {
    /// Loaded annotations whose appearance PDFKit would lose on edit.
    static func needsAppDrawing(_ annotation: PDFAnnotation) -> Bool {
        if annotation is CommentAnnotation { return false }
        switch annotation.type {
        case "Polygon", "PolyLine", "Caret", "FileAttachment", "Sound": return true
        case "Square", "Circle": return cloudIntensity(annotation) > 0
        case "FreeText": return (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CL")) as? [NSNumber])?.isEmpty == false
            || intent(annotation) == "FreeTextCallout"
        default: return false
        }
    }

    static func intent(_ annotation: PDFAnnotation) -> String? {
        (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/IT")) as? String)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func cloudIntensity(_ annotation: PDFAnnotation) -> Double {
        guard let be = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/BE")) as? [AnyHashable: Any] else { return 0 }
        let style = (be["/S"] as? String) ?? (be["S"] as? String)
        guard style?.hasSuffix("C") == true else { return 0 }
        return ((be["/I"] ?? be["I"]) as? NSNumber)?.doubleValue ?? 1
    }

    static func numbers(_ annotation: PDFAnnotation, _ key: String) -> [CGFloat] {
        ((annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) as? [Any]) ?? [])
            .compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
    }

    static func opacity(_ annotation: PDFAnnotation) -> Double {
        if let ca = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")) as? NSNumber { return ca.doubleValue }
        return Double(annotation.color.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
    }

    /// Style of any comment annotation, for the properties inspector.
    static func style(of annotation: PDFAnnotation) -> CommentStyle {
        if let drawn = annotation as? CommentAnnotation { return drawn.design.style }
        var style = CommentStyle()
        style.color = CommentColor(annotation.color)?.opaque ?? .red
        style.fill = CommentColor(annotation.interiorColor).flatMap { $0.alpha > 0.01 ? $0.opaque : nil }
        style.opacity = opacity(annotation)
        style.lineWidth = Double(annotation.border?.lineWidth ?? 1)
        if annotation.border?.style == .dashed { style.lineStyle = .dashed }
        if cloudIntensity(annotation) > 0 { style.lineStyle = .cloudy }
        if let font = annotation.font { style.fontName = font.fontName; style.fontSize = Double(font.pointSize) }
        style.textColor = CommentColor(annotation.fontColor)?.opaque ?? .black
        if annotation.type == "Line" {
            style.startEnding = ending(annotation.startLineStyle)
            style.endEnding = ending(annotation.endLineStyle)
        }
        return style
    }

    static func ending(_ style: PDFLineStyle) -> CommentLineEnding {
        switch style {
        case .openArrow: .openArrow; case .closedArrow: .closedArrow; case .circle: .circle; case .square: .square
        default: .none
        }
    }

    /// An app-drawn equivalent for a loaded annotation, preserving its
    /// dictionary metadata (author, dates, NM, contents...).
    static func rehydrate(_ annotation: PDFAnnotation) -> CommentAnnotation? {
        let bounds = annotation.bounds
        var style = style(of: annotation)
        let origin = bounds.origin
        func relative(_ values: [CGFloat]) -> [CGPoint] {
            stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0] - origin.x, y: values[$0 + 1] - origin.y) }
        }
        var design: CommentDesign
        switch annotation.type {
        case "Polygon":
            design = CommentDesign(shape: .polygon, style: style, points: relative(numbers(annotation, "/Vertices")))
        case "PolyLine":
            design = CommentDesign(shape: .polyline, style: style, points: relative(numbers(annotation, "/Vertices")))
        case "Caret":
            style.color = CommentColor(annotation.color)?.opaque ?? .blue
            design = CommentDesign(shape: .caret, style: style)
        case "FileAttachment":
            design = CommentDesign(shape: .attachment, style: style)
        case "Sound":
            design = CommentDesign(shape: .sound, style: style)
        case "Square":
            design = CommentDesign(shape: .rectangle, style: style)
        case "Circle":
            design = CommentDesign(shape: .oval, style: style)
        case "FreeText":
            let rd = numbers(annotation, "/RD")
            let box = rd.count == 4 ? CGRect(x: rd[0], y: rd[1], width: bounds.width - rd[0] - rd[2], height: bounds.height - rd[1] - rd[3])
                                    : CGRect(origin: .zero, size: bounds.size)
            if let da = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DA")) as? String {
                let parts = da.split(separator: " ")
                if let index = parts.firstIndex(of: "Tf"), index > 0, let size = Double(parts[index - 1]) { style.fontSize = size }
                if let index = parts.firstIndex(of: "rg"), index >= 3,
                   let r = Double(parts[index - 3]), let g = Double(parts[index - 2]), let b = Double(parts[index - 1]) {
                    style.textColor = CommentColor(red: r, green: g, blue: b)
                }
            }
            style.fill = CommentColor(annotation.color).flatMap { $0.alpha > 0.01 ? $0.opaque : nil }
            style.color = style.textColor
            design = CommentDesign(shape: .callout, style: style, points: relative(numbers(annotation, "/CL")), textBox: box)
        default:
            return nil
        }
        let replacement = CommentAnnotation(bounds: bounds, design: design)
        for (key, value) in annotation.annotationKeyValues {
            guard let key = key as? String,
                  !["/Rect", "/Subtype", "/Type", "/P", "/Popup", "/Parent", "/AP", "/IRT", "/FS", "/Sound"].contains(key) else { continue }
            replacement.setValue(value, forAnnotationKey: PDFAnnotationKey(rawValue: key))
        }
        replacement.contents = annotation.contents
        replacement.userName = annotation.userName
        replacement.modificationDate = annotation.modificationDate
        replacement.syncStandardKeys()
        AnnotationReplacement.mark(replacement, replacing: annotation)
        return replacement
    }
}

// MARK: - Save identity

/// A replacement stands in for a baseline annotation at the same source
/// position, so Save updates the original dictionary (keeping its replies,
/// popup and structure) instead of deleting and re-adding it.
enum AnnotationReplacement {
    private nonisolated(unsafe) static var key: UInt8 = 0

    static func mark(_ replacement: PDFAnnotation, replacing original: PDFAnnotation) {
        let root = Self.original(of: original) ?? original
        objc_setAssociatedObject(replacement, &key, root, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func original(of annotation: PDFAnnotation) -> PDFAnnotation? {
        objc_getAssociatedObject(annotation, &key) as? PDFAnnotation
    }
}

// MARK: - Presentation-only visibility

/// Hiding comments on the canvas (Hide All, on-page filters) must never
/// reach the saved file: the original display state is remembered and used
/// by Save's change detection and scratch copies.
enum CommentVisibility {
    private nonisolated(unsafe) static var key: UInt8 = 0

    static func hide(_ annotation: PDFAnnotation) {
        guard objc_getAssociatedObject(annotation, &key) == nil else { return }
        objc_setAssociatedObject(annotation, &key, NSNumber(value: annotation.shouldDisplay), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        annotation.shouldDisplay = false
    }

    static func reveal(_ annotation: PDFAnnotation) {
        guard let saved = objc_getAssociatedObject(annotation, &key) as? NSNumber else { return }
        objc_setAssociatedObject(annotation, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        annotation.shouldDisplay = saved.boolValue
    }

    static func isHidden(_ annotation: PDFAnnotation) -> Bool { objc_getAssociatedObject(annotation, &key) != nil }

    /// The display state Save should see.
    static func savedDisplay(_ annotation: PDFAnnotation) -> Bool {
        (objc_getAssociatedObject(annotation, &key) as? NSNumber)?.boolValue ?? annotation.shouldDisplay
    }

    /// A scratch copy carries the saved display state, never the filter's.
    static func copyPresentation(from source: PDFAnnotation, to copy: PDFAnnotation) {
        if isHidden(source) { copy.shouldDisplay = savedDisplay(source) }
    }
}

// MARK: - Undo snapshots

/// Appearance properties undo restores for a comment (move, resize, colour,
/// line, font, geometry). Widgets are form state and excluded.
struct CommentAppearance: Equatable {
    private let bounds: CGRect
    private let color: CommentColor?
    private let interior: CommentColor?
    private let fontColor: CommentColor?
    private let border: [Double]
    private let fontName: String?
    private let fontSize: CGFloat
    private let lineEnds: [CGPoint]
    private let lineStyles: [Int]
    private let paths: [NSBezierPath]
    private let pathSignature: String
    private let design: CommentDesign?
    private let spec: String?

    init?(_ annotation: PDFAnnotation) {
        guard annotation.type != "Widget", annotation.type != "Popup", annotation.type != "Link" else { return nil }
        bounds = annotation.bounds
        color = CommentColor(annotation.color)
        interior = CommentColor(annotation.interiorColor)
        fontColor = CommentColor(annotation.fontColor)
        border = annotation.border.map { [Double($0.lineWidth), Double($0.style.rawValue)] + ($0.dashPattern ?? []).compactMap { ($0 as? NSNumber)?.doubleValue } } ?? []
        fontName = annotation.font?.fontName
        fontSize = annotation.font?.pointSize ?? 0
        if annotation.type == "Line" {
            lineEnds = [annotation.startPoint, annotation.endPoint]
            lineStyles = [annotation.startLineStyle.rawValue, annotation.endLineStyle.rawValue]
        } else { lineEnds = []; lineStyles = [] }
        paths = (annotation.paths ?? []).map { $0.copy() as! NSBezierPath }
        pathSignature = paths.map { "\($0.elementCount):\($0.bounds)" }.joined(separator: ";")
        design = (annotation as? CommentAnnotation)?.design
        spec = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFSpec")) as? String
    }

    static func == (lhs: CommentAppearance, rhs: CommentAppearance) -> Bool {
        lhs.bounds == rhs.bounds && lhs.color == rhs.color && lhs.interior == rhs.interior && lhs.fontColor == rhs.fontColor
            && lhs.border == rhs.border && lhs.fontName == rhs.fontName && lhs.fontSize == rhs.fontSize
            && lhs.lineEnds == rhs.lineEnds && lhs.lineStyles == rhs.lineStyles && lhs.pathSignature == rhs.pathSignature
            && lhs.design == rhs.design && lhs.spec == rhs.spec
    }

    func apply(to annotation: PDFAnnotation) {
        if let drawn = annotation as? CommentAnnotation, let design, drawn.design != design { drawn.design = design }
        if annotation.bounds != bounds { annotation.bounds = bounds }
        if let color, CommentColor(annotation.color) != color { annotation.color = color.nsColor }
        if CommentColor(annotation.interiorColor) != interior { annotation.interiorColor = interior?.nsColor }
        if let fontColor, CommentColor(annotation.fontColor) != fontColor { annotation.fontColor = fontColor.nsColor }
        if border.count >= 2 {
            let restored = PDFBorder()
            restored.lineWidth = CGFloat(border[0])
            restored.style = PDFBorderStyle(rawValue: Int(border[1])) ?? .solid
            if border.count > 2 { restored.dashPattern = border.dropFirst(2).map { CGFloat($0) } }
            annotation.border = restored
        }
        if let fontName, fontSize > 0, annotation.font?.fontName != fontName || annotation.font?.pointSize != fontSize {
            annotation.font = NSFont(name: fontName, size: fontSize)
        }
        if lineEnds.count == 2 {
            annotation.startPoint = lineEnds[0]; annotation.endPoint = lineEnds[1]
            annotation.startLineStyle = PDFLineStyle(rawValue: lineStyles[0]) ?? .none
            annotation.endLineStyle = PDFLineStyle(rawValue: lineStyles[1]) ?? .none
        }
        if annotation.type == "Ink" {
            let current = (annotation.paths ?? []).map { "\($0.elementCount):\($0.bounds)" }.joined(separator: ";")
            if current != pathSignature {
                for path in annotation.paths ?? [] { annotation.remove(path) }
                for path in paths { annotation.add(path.copy() as! NSBezierPath) }
            }
        }
        if let spec, annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFSpec")) as? String != spec {
            annotation.setValue(spec, forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFSpec"))
        }
        annotation.setValue(UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFRevision"))
    }
}
