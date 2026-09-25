import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import SwiftUI
import Vision

/// 2-D barcode module matrices for barcode fields (QR Code, PDF417), encoded
/// with Core Image's standard generators and drawn by the engine as vectors.
enum BarcodeEncoder {
    static func matrix(for text: String, symbology: String) -> [[Int]]? {
        let data = Data(text.utf8)
        let output: CIImage?
        if symbology == "pdf417" {
            let filter = CIFilter.pdf417BarcodeGenerator()
            filter.message = data
            output = filter.outputImage
        } else {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            filter.correctionLevel = "M"
            output = filter.outputImage
        }
        guard let image = output else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width * height < 250_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        // Core Image rows are bottom-up; the engine expects the top row first.
        return (0..<height).reversed().map { y in
            (0..<width).map { x in pixels[(y * width + x) * 4] < 128 ? 1 : 0 }
        }
    }
}

struct DraftFormField: Identifiable {
    let id = UUID()
    var name: String
    var type: String
    var bounds: CGRect
    var included = true
}

/// Field kinds Prepare Form can create (engine `add_form_field` types).
enum FormFieldKind: String, CaseIterable, Identifiable {
    case text, checkbox, radio, combo, list, signature, date, number, button, barcode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: "Text field"
        case .checkbox: "Check box"
        case .radio: "Radio button"
        case .combo: "Dropdown"
        case .list: "List box"
        case .signature: "Signature field"
        case .date: "Date field"
        case .number: "Number field"
        case .button: "Button"
        case .barcode: "Barcode"
        }
    }

    var shortName: String {
        switch self {
        case .text: "Text"
        case .checkbox: "Check box"
        case .radio: "Radio"
        case .combo: "Dropdown"
        case .list: "List box"
        case .signature: "Signature"
        case .date: "Date"
        case .number: "Number"
        case .button: "Button"
        case .barcode: "Barcode"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "character.textbox"
        case .checkbox: "checkmark.square"
        case .radio: "smallcircle.filled.circle"
        case .combo: "chevron.up.chevron.down.square"
        case .list: "list.bullet.rectangle"
        case .signature: "signature"
        case .date: "calendar"
        case .number: "number.square"
        case .button: "button.horizontal"
        case .barcode: "qrcode"
        }
    }

    /// Size used when the user clicks instead of dragging.
    var defaultSize: CGSize {
        switch self {
        case .text: CGSize(width: 150, height: 22)
        case .checkbox, .radio: CGSize(width: 14, height: 14)
        case .combo: CGSize(width: 150, height: 22)
        case .list: CGSize(width: 150, height: 66)
        case .signature: CGSize(width: 180, height: 44)
        case .date, .number: CGSize(width: 100, height: 22)
        case .button: CGSize(width: 90, height: 24)
        case .barcode: CGSize(width: 96, height: 96)
        }
    }

    /// Kinds offered in Prepare Form's field tool grid, in Acrobat's order.
    static let toolbar: [FormFieldKind] = [.text, .checkbox, .radio, .combo, .list, .signature, .date, .number, .button, .barcode]

    /// Acrobat-style shortcut letters (Prepare Form tool keys).
    var shortcut: KeyEquivalent? {
        switch self {
        case .text: "t"
        case .checkbox: "c"
        case .radio: "r"
        case .combo: "d"
        case .list: "l"
        case .signature: "s"
        case .date: "a"
        case .button: "b"
        default: nil
        }
    }
}

/// A form field as reported by the engine's `form_fields` query.
struct FormFieldInfo: Identifiable, Equatable {
    struct Widget: Equatable {
        var page: Int
        var rect: CGRect
        var export: String?
    }
    struct Option: Equatable, Hashable, Identifiable {
        var id = UUID()
        var label: String
        var export: String
        static func == (a: Option, b: Option) -> Bool { a.label == b.label && a.export == b.export }
        func hash(into hasher: inout Hasher) { hasher.combine(label); hasher.combine(export) }
    }
    struct Format: Equatable {
        var kind = "none"
        var decimals = 2
        var separator = 0
        var negative = 0
        var currency = ""
        var prepend = true
        var dateFormat = "mm/dd/yyyy"
        var timeStyle = 0
        var specialStyle = 0

        var json: [String: Any] {
            switch kind {
            case "number": ["kind": "number", "decimals": decimals, "separator": separator, "negative": negative,
                            "currency": currency, "prepend": prepend]
            case "percent": ["kind": "percent", "decimals": decimals, "separator": separator]
            case "date": ["kind": "date", "format": dateFormat]
            case "time": ["kind": "time", "style": timeStyle]
            case "special": ["kind": "special", "style": specialStyle]
            default: ["kind": "none"]
            }
        }
    }
    struct Calculation: Equatable {
        var kind = "none"          // none, sum, product, average, min, max, sfn, custom
        var fields: [String] = []
        var expression = ""

        var json: Any {
            switch kind {
            case "sum", "product", "average", "min", "max": ["kind": kind, "fields": fields] as [String: Any]
            case "sfn": ["kind": "sfn", "expression": expression] as [String: Any]
            default: NSNull()
            }
        }
    }

    var id: String { name }
    var name: String
    var kind: String
    var tooltip = ""
    var readonly = false
    var required = false
    var value = ""
    var values: [String] = []
    var defaultValue = ""
    var font = "helvetica"
    var fontSize: Double = 0
    var textColor: [Double]?
    var alignment = "left"
    var borderColor: [Double]?
    var fillColor: [Double]?
    var borderWidth: Double = 1
    var borderStyle = "solid"
    var hidden = false
    var printable = true
    var widgets: [Widget] = []
    var multiline = false
    var password = false
    var comb = false
    var scroll = true
    var spellcheck = true
    var maxLength: Int?
    var options: [Option] = []
    var editable = false
    var multiSelect = false
    var sort = false
    var commitOnSelect = false
    var checkStyle = "check"
    var exports: [String] = []
    var caption = ""
    var actionKind = "none"
    var actionURL = ""
    var actionFormat = "html"
    var barcodeSymbology = "qr"
    var barcodeFields: [String] = []
    var format = Format()
    var validateMin: Double?
    var validateMax: Double?
    var calculation = Calculation()
    var customScripts: [String] = []
    var signed = false

    init(name: String, kind: String) { self.name = name; self.kind = kind }

    init(_ json: [String: Any]) {
        name = json["name"] as? String ?? ""
        kind = json["kind"] as? String ?? "text"
        tooltip = json["tooltip"] as? String ?? ""
        readonly = json["readonly"] as? Bool ?? false
        required = json["required"] as? Bool ?? false
        if let list = json["value"] as? [String] { values = list; value = list.joined(separator: ", ") }
        else { value = json["value"] as? String ?? ""; values = value.isEmpty ? [] : [value] }
        defaultValue = json["default"] as? String ?? ""
        font = json["font"] as? String ?? "helvetica"
        fontSize = json["font_size"] as? Double ?? 0
        textColor = json["text_color"] as? [Double]
        alignment = json["alignment"] as? String ?? "left"
        borderColor = json["border_color"] as? [Double]
        fillColor = json["fill_color"] as? [Double]
        borderWidth = json["border_width"] as? Double ?? 1
        borderStyle = json["border_style"] as? String ?? "solid"
        hidden = json["hidden"] as? Bool ?? false
        printable = json["print"] as? Bool ?? true
        widgets = (json["widgets"] as? [[String: Any]] ?? []).map {
            let r = $0["rect"] as? [Double] ?? [0, 0, 0, 0]
            return Widget(page: $0["page"] as? Int ?? 0,
                          rect: CGRect(x: min(r[0], r[2]), y: min(r[1], r[3]), width: abs(r[2] - r[0]), height: abs(r[3] - r[1])),
                          export: $0["export"] as? String)
        }
        multiline = json["multiline"] as? Bool ?? false
        password = json["password"] as? Bool ?? false
        comb = json["comb"] as? Bool ?? false
        scroll = json["scroll"] as? Bool ?? true
        spellcheck = json["spellcheck"] as? Bool ?? true
        maxLength = json["max_length"] as? Int
        options = (json["options"] as? [[String: Any]] ?? []).map {
            Option(label: $0["label"] as? String ?? "", export: $0["export"] as? String ?? "")
        }
        editable = json["editable"] as? Bool ?? false
        multiSelect = json["multi_select"] as? Bool ?? false
        sort = json["sort"] as? Bool ?? false
        commitOnSelect = json["commit_on_select"] as? Bool ?? false
        checkStyle = json["check_style"] as? String ?? "check"
        exports = json["exports"] as? [String] ?? []
        caption = json["caption"] as? String ?? ""
        if let action = json["action"] as? [String: Any] {
            actionKind = action["kind"] as? String ?? "none"
            actionURL = action["url"] as? String ?? ""
            actionFormat = action["format"] as? String ?? "html"
        }
        if let barcode = json["barcode"] as? [String: Any] {
            barcodeSymbology = barcode["symbology"] as? String ?? "qr"
            barcodeFields = barcode["fields"] as? [String] ?? []
        }
        if let f = json["format"] as? [String: Any] {
            format.kind = f["kind"] as? String ?? "none"
            format.decimals = f["decimals"] as? Int ?? 2
            format.separator = f["separator"] as? Int ?? 0
            format.negative = f["negative"] as? Int ?? 0
            format.currency = f["currency"] as? String ?? ""
            format.prepend = f["prepend"] as? Bool ?? true
            format.dateFormat = f["format"] as? String ?? "mm/dd/yyyy"
            format.timeStyle = f["style"] as? Int ?? 0
            format.specialStyle = f["style"] as? Int ?? 0
            if format.kind == "custom" { customScripts.append("format") }
        }
        if let v = json["validate"] as? [String: Any] {
            validateMin = (v["min"] as? NSNumber)?.doubleValue
            validateMax = (v["max"] as? NSNumber)?.doubleValue
            if v["kind"] as? String == "custom" { customScripts.append("validation") }
        }
        if let c = json["calculate"] as? [String: Any] {
            calculation.kind = c["kind"] as? String ?? "none"
            calculation.fields = c["fields"] as? [String] ?? []
            calculation.expression = c["expression"] as? String ?? ""
            if calculation.kind == "custom" { customScripts.append("calculation") }
        }
        customScripts += json["unsupported_scripts"] as? [String] ?? []
        signed = json["signed"] as? Bool ?? false
    }

    var displayKind: String {
        switch kind {
        case "text": format.kind == "date" ? "Date" : format.kind == "number" ? "Number" : "Text"
        case "checkbox": "Check box"
        case "radio": "Radio group"
        case "combo": "Dropdown"
        case "list": "List box"
        case "signature": "Signature"
        case "button": "Button"
        case "barcode": "Barcode"
        default: kind.capitalized
        }
    }

    var symbolName: String {
        switch kind {
        case "text": format.kind == "date" ? "calendar" : format.kind == "number" ? "number.square" : "character.textbox"
        case "checkbox": "checkmark.square"
        case "radio": "smallcircle.filled.circle"
        case "combo": "chevron.up.chevron.down.square"
        case "list": "list.bullet.rectangle"
        case "signature": "signature"
        case "button": "button.horizontal"
        case "barcode": "qrcode"
        default: "questionmark.square.dashed"
        }
    }
}

@MainActor
enum FormFieldAuthoring {
    static func names(in document: PDFDocument) -> Set<String> {
        Set((0..<document.pageCount).flatMap { document.page(at: $0)?.annotations.compactMap(\.fieldName) ?? [] })
    }

    static func nextName(existing: Set<String>) -> String {
        var number = 1
        while existing.contains("Field \(number)") { number += 1 }
        return "Field \(number)"
    }

    static func widget(_ field: DraftFormField) -> PDFAnnotation {
        let widget = PDFAnnotation(bounds: field.bounds, forType: .widget, withProperties: nil)
        widget.setValue("1", forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFNewField"))
        widget.setValue(field.name, forAnnotationKey: PDFAnnotationKey(rawValue: "/TU"))
        widget.shouldPrint = true
        widget.isReadOnly = false
        widget.backgroundColor = .clear
        let border = PDFBorder(); border.lineWidth = 0; widget.border = border
        if field.type == "checkbox" {
            widget.widgetFieldType = .button
            widget.widgetControlType = .checkBoxControl
            widget.buttonWidgetState = .offState
            widget.buttonWidgetStateString = "Yes"
            widget.buttonWidgetState = .offState
        } else {
            widget.widgetFieldType = .text
            widget.font = NSFont(name: "Helvetica", size: 10)
            widget.fontColor = .black
            widget.widgetStringValue = ""
        }
        // PDFKit assigns a generated name when widgetFieldType changes.
        widget.fieldName = field.name
        return widget
    }

    static func apply(_ fields: [DraftFormField], page: PDFPage, tab: DocumentTab, state: AppState) throws {
        guard state.activeTab === tab, tab.allowsSaveEdits, let document = tab.pdfDocument,
              document.index(for: page) != NSNotFound else {
            throw NativeSaveError(code: "STALE_PAGE", message: "The document changed. Close this review and try again.")
        }
        var existing = names(in: document)
        let selected = fields.filter(\.included)
        guard !selected.isEmpty, selected.count <= 200 else {
            throw NativeSaveError(code: "INVALID_FIELDS", message: "Select between 1 and 200 fields.")
        }
        let crop = page.bounds(for: .cropBox)
        for field in selected {
            let r = field.bounds
            guard !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.name.count <= 200, !field.name.contains("."), !field.name.contains("\0"),
                  existing.insert(field.name).inserted else {
                throw NativeSaveError(code: "INVALID_FIELD_NAME", message: "Give each field a unique name without dots.")
            }
            guard [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite), r.width >= 4, r.height >= 4,
                  crop.contains(r), ["text", "checkbox"].contains(field.type) else {
                throw NativeSaveError(code: "INVALID_FIELD_BOUNDS", message: "Keep each field inside the page and at least 4 points wide and high.")
            }
        }
        guard state.commitFieldEditing() else {
            throw NativeSaveError(code: "EDIT_NOT_COMMITTED", message: "Finish editing the current field before adding fields.")
        }
        for field in selected { page.addAnnotation(widget(field)) }
        state.noteAnnotationsChanged()
    }

    static func uniqueName(_ base: String, in tab: DocumentTab) -> String {
        var existing = Set(tab.protection.formFields.map(\.name))
        if let document = tab.pdfDocument { existing.formUnion(names(in: document)) }
        let stem = base.replacingOccurrences(of: ".", with: " ")
        var number = 1
        while existing.contains("\(stem) \(number)") { number += 1 }
        return "\(stem) \(number)"
    }
}

// MARK: - Field detection on scanned pages

/// Suggests fields on raster (scanned) pages with Apple Vision: rectangles
/// become text fields or check boxes, and long horizontal rules become
/// answer lines. Printed text regions are excluded.
enum ScannedFieldDetector {
    @MainActor static func isRaster(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 20
    }

    @MainActor static func detect(on page: PDFPage) async -> [NativeFieldSuggestion] {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0 else { return [] }
        let scale: CGFloat = 2
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return await Task.detached(priority: .userInitiated) { analyze(cg, pageBox: box) }.value
    }

    nonisolated static func analyze(_ cg: CGImage, pageBox box: CGRect) -> [NativeFieldSuggestion] {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.03
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.012
        rectangles.maximumObservations = 80
        rectangles.minimumConfidence = 0.5
        rectangles.quadratureTolerance = 8
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        try? handler.perform([rectangles, text])
        func pageRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: box.minX + normalized.minX * box.width, y: box.minY + normalized.minY * box.height,
                   width: normalized.width * box.width, height: normalized.height * box.height)
        }
        let textBoxes = (text.results ?? []).map { pageRect($0.boundingBox) }
        var accepted: [CGRect] = []
        var kinds: [String] = []
        let candidates = (rectangles.results ?? []).map { pageRect($0.boundingBox) }
            .sorted { $0.width * $0.height < $1.width * $1.height }
        for rect in candidates {
            let inner = rect.insetBy(dx: 1.5, dy: 1.5)
            let textArea = textBoxes.reduce(CGFloat(0)) { sum, t in
                let i = t.intersection(inner); return sum + (i.isNull ? 0 : i.width * i.height)
            }
            guard textArea < inner.width * inner.height * 0.2 else { continue }
            guard !accepted.contains(where: { $0.intersects(inner) }) else { continue }
            let isCheck = (7...24).contains(rect.width) && (7...24).contains(rect.height) && abs(rect.width - rect.height) < 5
            guard isCheck || (rect.width >= 24 && (8...72).contains(rect.height)) else { continue }
            accepted.append(rect)
            kinds.append(isCheck ? "checkbox" : "text")
        }
        // Horizontal answer lines: long thin dark runs.
        for line in horizontalRules(cg) {
            let rect = CGRect(x: box.minX + line.minX / CGFloat(cg.width) * box.width,
                              y: box.minY + (1 - line.maxY / CGFloat(cg.height)) * box.height,
                              width: line.width / CGFloat(cg.width) * box.width, height: 14)
            guard rect.width >= 36, !accepted.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) }),
                  !textBoxes.contains(where: { $0.intersection(rect).width > rect.width * 0.4 }) else { continue }
            accepted.append(rect)
            kinds.append("text")
        }
        return zip(accepted, kinds).prefix(200).map { rect, kind in
            NativeFieldSuggestion(type: kind, rect: [rect.minX, rect.minY, rect.maxX, rect.maxY])
        }
    }

    /// Dark horizontal runs at least 70 px long and at most 4 px thick.
    nonisolated static func horizontalRules(_ cg: CGImage) -> [CGRect] {
        let width = cg.width, height = cg.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var runs: [CGRect] = []
        for y in 0..<height {
            var start: Int?
            for x in 0...width {
                let dark = x < width && pixels[(height - 1 - y) * width + x] < 110
                if dark { if start == nil { start = x } }
                else if let s = start {
                    if x - s >= 70 { runs.append(CGRect(x: s, y: y, width: x - s, height: 1)) }
                    start = nil
                }
            }
        }
        // Merge vertically adjacent runs into rules; drop thick bars (tables, boxes).
        var merged: [CGRect] = []
        for run in runs {
            if let index = merged.lastIndex(where: { abs($0.maxY - run.minY) <= 1 && abs($0.minX - run.minX) < 6 && abs($0.width - run.width) < 12 }) {
                merged[index] = merged[index].union(run)
            } else { merged.append(run) }
        }
        return merged.filter { $0.height <= 4 }
    }
}

// MARK: - Auto-fill from profile

struct ProfileSuggestion: Identifiable {
    let id = UUID()
    let annotation: PDFAnnotation
    let fieldName: String
    let label: String
    let value: String
    var include = true
}

enum FormProfileMatcher {
    nonisolated(unsafe) private static let rules: [(KeyPath<FormProfile, String>, String, [String])] = [
        (\.email, "Email", ["email", "e-mail", "e mail"]),
        (\.phone, "Phone", ["phone", "telephone", "tel", "mobile", "cell"]),
        (\.firstName, "First name", ["first name", "firstname", "given name", "fname", "first"]),
        (\.lastName, "Last name", ["last name", "lastname", "surname", "family name", "lname", "last"]),
        (\.street2, "Address line 2", ["address 2", "address line 2", "apt", "suite", "unit"]),
        (\.street, "Street address", ["street", "address 1", "address line 1", "address", "addr"]),
        (\.city, "City", ["city", "town"]),
        (\.state, "State", ["state", "province", "region"]),
        (\.postalCode, "ZIP code", ["zip", "postal", "postcode"]),
        (\.country, "Country", ["country"]),
        (\.company, "Company", ["company", "employer", "organization", "organisation", "business name"]),
        (\.jobTitle, "Job title", ["job title", "position", "occupation"]),
        (\.dateOfBirth, "Date of birth", ["date of birth", "birth date", "birthdate", "dob"]),
        (\.fullName, "Full name", ["full name", "your name", "print name", "printed name", "applicant name", "name"]),
    ]

    static func normalize(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased().replacingOccurrences(of: "[_\\-\\.\\[\\]0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Profile key label and value for a field label, if any rule matches.
    static func match(_ label: String, profile: FormProfile) -> (String, String)? {
        let text = " " + normalize(label) + " "
        for (path, title, keys) in rules {
            let value = profile[keyPath: path]
            guard !value.isEmpty else { continue }
            if keys.contains(where: { text.contains(" " + $0 + " ") }) { return (title, value) }
        }
        return nil
    }

    @MainActor
    static func suggestions(in document: PDFDocument, profile: FormProfile) -> [ProfileSuggestion] {
        guard !profile.isEmpty else { return [] }
        var out: [ProfileSuggestion] = []
        var seen = Set<String>()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" && annotation.widgetFieldType == .text
                && !annotation.isReadOnly && (annotation.widgetStringValue ?? "").isEmpty {
                let name = annotation.fieldName ?? ""
                guard !seen.contains(name) else { continue }
                let label = [annotation.toolTip ?? "", name].first { !$0.isEmpty } ?? ""
                if let (title, value) = match(label, profile: profile) ?? match(name, profile: profile) {
                    seen.insert(name)
                    out.append(ProfileSuggestion(annotation: annotation, fieldName: name, label: title, value: value))
                }
            }
        }
        return out
    }
}

// MARK: - Live form logic (calculations and formats while filling)

@MainActor
enum FormLogic {
    private static var observers: [ObjectIdentifier: [Any]] = [:]
    private static var pending: Task<Void, Never>?

    /// Recalculates after a field editor commits or a button/choice click,
    /// for documents whose fields carry format/validate/calculate actions.
    static func startObserving(_ state: AppState) {
        let key = ObjectIdentifier(state)
        guard observers[key] == nil else { return }
        let schedule: @MainActor () -> Void = { [weak state] in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let state, let tab = state.activeTab, tab.protection.hasFormLogic,
                      tab.allowsSaveEdits else { return }
                await recalculate(tab, state: state)
            }
        }
        let text = NotificationCenter.default.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule() }
        }
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            MainActor.assumeIsolated { schedule() }
            return event
        }
        observers[key] = [text, mouse as Any]
    }

    static func currentValues(_ document: PDFDocument) -> (values: [String: String], widgets: [String: [PDFAnnotation]]) {
        var values: [String: String] = [:]
        var widgets: [String: [PDFAnnotation]] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                guard let name = annotation.fieldName else { continue }
                widgets[name, default: []].append(annotation)
                if annotation.widgetFieldType == .button {
                    if annotation.buttonWidgetState == .onState { values[name] = annotation.buttonWidgetStateString }
                    else if values[name] == nil { values[name] = "" }
                } else {
                    values[name] = annotation.widgetStringValue ?? ""
                }
            }
        }
        return (values, widgets)
    }

    /// Recomputes calculated fields and formats after a field commits.
    static func recalculate(_ tab: DocumentTab, state: AppState, touched explicit: Set<String>? = nil) async {
        guard tab.protection.hasFormLogic, let document = tab.pdfDocument else { return }
        let before = currentValues(document).values
        let previous = tab.protection.lastFieldValues ?? Dictionary(uniqueKeysWithValues: tab.protection.formFields.map { ($0.name, $0.value) })
        let touched = explicit ?? Set(before.keys.filter { before[$0] != previous[$0] })
        guard explicit != nil || !touched.isEmpty else { return }
        let (values, widgets) = currentValues(document)
        let params: [String: Any] = ["values": values, "touched": Array(touched)]
        guard let result = try? await state.queryDocument("form_calculate", params: params, in: tab) else { return }
        if let errors = result["errors"] as? [String: String], let first = errors.first {
            let alert = NSAlert()
            alert.messageText = "Invalid value"
            alert.informativeText = first.value
            alert.alertStyle = .warning
            alert.runModal()
            for name in errors.keys {
                let restored = previous[name] ?? ""
                widgets[name]?.forEach { $0.widgetStringValue = restored }
            }
        }
        let display = result["display"] as? [String: String] ?? [:]
        let calculated = result["calculated"] as? [String: String] ?? [:]
        for (name, raw) in calculated {
            let shown = display[name] ?? raw
            widgets[name]?.forEach { if $0.widgetStringValue != shown { $0.widgetStringValue = shown } }
        }
        for (name, shown) in display where touched.contains(name) {
            widgets[name]?.forEach { if $0.widgetStringValue != shown { $0.widgetStringValue = shown } }
        }
        tab.protection.lastFieldValues = currentValues(document).values
        state.refreshUnsavedChanges(tab)
    }
}
