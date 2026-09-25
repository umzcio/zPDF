import AppKit
import PDFKit

/// A standard PDF /Redact annotation (a mark that has not been applied yet).
/// PDFKit would paint its interior color as an opaque box, hiding what is
/// marked; marks instead draw like Acrobat: an outline with a light tint.
/// Applying (`apply_redactions`) removes the content and draws the fill.
final class RedactionMarkAnnotation: PDFAnnotation {
    static let subtype = PDFAnnotationSubtype(rawValue: "Redact")
    static let overlayTextKey = PDFAnnotationKey(rawValue: "/OverlayText")
    static let repeatKey = PDFAnnotationKey(rawValue: "/Repeat")
    static let defaultAppearanceKey = PDFAnnotationKey(rawValue: "/DA")

    /// Mark outline shown on screen (not the applied fill).
    static let markColor = NSColor(srgbRed: 0.86, green: 0.12, blue: 0.1, alpha: 1)

    convenience init(page: PDFPage, rects: [CGRect], appearance: RedactionAppearance) {
        let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        self.init(bounds: union, forType: Self.subtype, withProperties: nil)
        if rects.count > 1 || rects.first != union {
            var points: [NSValue] = []
            for rect in rects {
                let r = rect.offsetBy(dx: -union.minX, dy: -union.minY)
                points += [NSValue(point: CGPoint(x: r.minX, y: r.maxY)), NSValue(point: CGPoint(x: r.maxX, y: r.maxY)),
                           NSValue(point: CGPoint(x: r.minX, y: r.minY)), NSValue(point: CGPoint(x: r.maxX, y: r.minY))]
            }
            quadrilateralPoints = points
        }
        color = Self.markColor
        apply(appearance)
    }

    func apply(_ appearance: RedactionAppearance) {
        interiorColor = appearance.fill
        let text = appearance.overlayText
        if text.isEmpty {
            setValue(nil as String?, forAnnotationKey: Self.overlayTextKey)
        } else {
            setValue(text, forAnnotationKey: Self.overlayTextKey)
        }
        if !text.isEmpty {
            let rgb = (appearance.textColor.usingColorSpace(.deviceRGB) ?? .white)
            let size = appearance.fontSize > 0 ? String(format: "%g", appearance.fontSize) : "0"
            setValue(String(format: "/Helv %@ Tf %.3f %.3f %.3f rg", size, rgb.redComponent, rgb.greenComponent, rgb.blueComponent),
                     forAnnotationKey: Self.defaultAppearanceKey)
            if appearance.repeatText { setValue(NSNumber(value: true), forAnnotationKey: Self.repeatKey) }
        }
        userName = NSFullUserName()
    }

    /// Rectangles of this mark in page space.
    var markRects: [CGRect] { Self.rects(of: self) }

    var overlayText: String? { value(forAnnotationKey: Self.overlayTextKey) as? String }

    static func isMark(_ annotation: PDFAnnotation) -> Bool { annotation.type == "Redact" }

    static func rects(of annotation: PDFAnnotation) -> [CGRect] {
        guard let points = annotation.quadrilateralPoints?.map(\.pointValue), points.count >= 4 else {
            return [annotation.bounds]
        }
        let origin = annotation.bounds.origin
        return stride(from: 0, to: points.count - 3, by: 4).map { i in
            let quad = points[i..<i + 4]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: xs.min()! + origin.x, y: ys.min()! + origin.y,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard shouldDisplay else { return }
        context.saveGState()
        let fill = (interiorColor ?? .black).usingColorSpace(.deviceRGB) ?? .black
        let outline = (color.usingColorSpace(.deviceRGB) ?? Self.markColor)
        for rect in markRects {
            context.setFillColor(fill.withAlphaComponent(0.16).cgColor)
            context.fill(rect)
            context.setStrokeColor(outline.cgColor)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
        context.restoreGState()
    }
}

/// How marks look once applied.
struct RedactionAppearance: Equatable {
    var fill: NSColor = .black
    var overlayText: String = ""
    var textColor: NSColor = .white
    var fontSize: Double = 0
    var repeatText = false
}

/// Loaded /Redact annotations use the mark class (PDFDocument delegate).
final class RedactionMarkAppearance: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    static let shared = RedactionMarkAppearance()

    func `class`(forAnnotationType annotationType: String) -> AnyClass {
        annotationType == "Redact" ? RedactionMarkAnnotation.self : PDFAnnotation.self
    }
}

/// Redaction codes (U.S. FOIA / Privacy Act exemptions), as offered by Acrobat.
enum RedactionCodeSet: String, CaseIterable, Identifiable {
    case foia
    case privacyAct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foia: "U.S. FOIA"
        case .privacyAct: "U.S. Privacy Act"
        }
    }

    var codes: [(code: String, meaning: String)] {
        switch self {
        case .foia:
            [("(b)(1)", "Classified national security information"),
             ("(b)(2)", "Internal personnel rules and practices"),
             ("(b)(3)", "Information exempted by another statute"),
             ("(b)(4)", "Trade secrets or confidential commercial information"),
             ("(b)(5)", "Privileged interagency or intra-agency communications"),
             ("(b)(6)", "Personal privacy"),
             ("(b)(7)(A)", "Law enforcement: interference with proceedings"),
             ("(b)(7)(C)", "Law enforcement: personal privacy"),
             ("(b)(7)(E)", "Law enforcement: techniques and procedures"),
             ("(b)(8)", "Financial institution reports"),
             ("(b)(9)", "Geological information on wells")]
        case .privacyAct:
            [("(d)(5)", "Information compiled for civil actions"),
             ("(j)(2)", "Criminal law enforcement records"),
             ("(k)(1)", "Classified information"),
             ("(k)(2)", "Investigatory material for law enforcement"),
             ("(k)(3)", "Protective services records"),
             ("(k)(4)", "Statistical records"),
             ("(k)(5)", "Investigatory material for employment or clearance"),
             ("(k)(6)", "Testing or examination material"),
             ("(k)(7)", "Evaluation material for promotion in the armed services")]
        }
    }
}

/// Search & Redact pattern presets.
enum RedactionPattern: String, CaseIterable, Identifiable {
    case ssn, phone, email, creditCard, date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssn: "Social Security numbers"
        case .phone: "Phone numbers"
        case .email: "Email addresses"
        case .creditCard: "Credit card numbers"
        case .date: "Dates"
        }
    }

    var symbolName: String {
        switch self {
        case .ssn: "person.text.rectangle"
        case .phone: "phone"
        case .email: "envelope"
        case .creditCard: "creditcard"
        case .date: "calendar"
        }
    }

    var regex: String {
        switch self {
        case .ssn: #"\b\d{3}[- ]\d{2}[- ]\d{4}\b"#
        case .phone: #"(?<![\d-])(?:\+?1[-. ]?)?(?:\(\d{3}\)\s?|\d{3}[-. ])\d{3}[-. ]\d{4}(?![\d-])"#
        case .email: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        case .creditCard: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#
        case .date: #"\b(?:\d{1,2}[/.-]\d{1,2}[/.-](?:\d{4}|\d{2})|\d{4}-\d{2}-\d{2}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.? \d{1,2},? \d{4}|\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]* \d{4})\b"#
        }
    }

    /// Extra validation beyond the pattern (Luhn for card numbers).
    func accepts(_ match: String) -> Bool {
        guard self == .creditCard else { return true }
        let digits = match.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
