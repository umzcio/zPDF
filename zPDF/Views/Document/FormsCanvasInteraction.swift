import AppKit
import PDFKit
import SwiftUI

/// Canvas interaction for Fill & Sign marks, signature placement, Prepare
/// Form field placement and certificate-signature boxes. PDFViewRepresentable
/// forwards mouse events here first (three one-line hooks); everything else
/// lives in this file so other canvas tools stay independent.
@MainActor
final class FormsCanvasInteraction: NSObject, NSTextFieldDelegate {
    private var dragStart: CGPoint?
    private weak var dragPage: PDFPage?
    private var preview: PDFAnnotation?
    private var editor: NSTextField?
    private weak var editorView: PDFView?
    private weak var editorPage: PDFPage?
    private var editorOrigin: CGPoint = .zero
    private var editorReplacing: PDFAnnotation?
    private weak var editorState: AppState?

    nonisolated override init() { super.init() }

    static let typewriterIntent = "/FreeTextTypeWriter"

    func cancel() {
        if let preview, let page = dragPage { page.removeAnnotation(preview) }
        preview = nil
        dragStart = nil
        dragPage = nil
        endEditing(commit: false)
    }

    // MARK: Hooks

    func begin(_ event: NSEvent, in view: PDFView, state: AppState) -> Bool {
        let service = state.signatureService
        let viewPoint = view.convert(event.locationInWindow, from: nil)
        guard let page = view.page(for: viewPoint, nearest: true), let document = view.document else { return false }
        let point = view.convert(viewPoint, to: page)
        if editor != nil { endEditing(commit: true) }
        guard let tool = service.armedTool else {
            // Double-click a Fill & Sign text box to edit it again.
            if event.clickCount == 2, let annotation = page.annotation(at: point), Self.isFillText(annotation) {
                beginEditing(at: annotation.bounds.origin, on: page, in: view, state: state, replacing: annotation)
                return true
            }
            return false
        }
        switch tool {
        case .addText:
            beginEditing(at: CGPoint(x: point.x, y: point.y - service.fillTextSize * 0.6), on: page, in: view, state: state)
        case .check, .cross, .dot:
            placeSymbol(tool, at: point, on: page, state: state)
        case .date:
            let text = Date().formatted(date: .numeric, time: .omitted)
            addFillText(text, at: CGPoint(x: point.x, y: point.y - service.fillTextSize * 0.6), on: page, state: state)
            finish(state)
        case .line, .signature, .field, .certificateSignature:
            dragStart = point
            dragPage = page
        case .signField:
            if let widget = page.annotation(at: point), widget.type == "Widget", widget.widgetFieldType == .signature,
               let name = widget.fieldName {
                service.onSignatureBox?(document.index(for: page), nil, name)
                service.armedTool = nil
            } else {
                NSSound.beep()
            }
        }
        return true
    }

    func drag(_ event: NSEvent, in view: PDFView, state: AppState) -> Bool {
        guard let start = dragStart, let page = dragPage, let tool = state.signatureService.armedTool else { return false }
        let point = view.convert(view.convert(event.locationInWindow, from: nil), to: page)
        if let preview { page.removeAnnotation(preview) }
        let annotation: PDFAnnotation
        if tool == .line {
            let bounds = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                width: abs(point.x - start.x), height: abs(point.y - start.y)).insetBy(dx: -4, dy: -4)
            annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            annotation.endPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
            annotation.color = state.signatureService.fillColor
        } else {
            let rect = Self.rect(from: start, to: point, within: page.bounds(for: .cropBox))
            annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            annotation.color = NSColor.controlAccentColor
            annotation.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.1)
            let border = PDFBorder()
            border.lineWidth = 1
            border.style = .dashed
            border.dashPattern = [4, 3]
            annotation.border = border
        }
        page.addAnnotation(annotation)
        preview = annotation
        return true
    }

    func end(_ event: NSEvent, in view: PDFView, state: AppState) -> Bool {
        guard let start = dragStart, let page = dragPage, let tool = state.signatureService.armedTool else { return false }
        if let preview { page.removeAnnotation(preview) }
        preview = nil
        dragStart = nil
        dragPage = nil
        let point = view.convert(view.convert(event.locationInWindow, from: nil), to: page)
        let dragged = hypot(point.x - start.x, point.y - start.y) > 4
        let crop = page.bounds(for: .cropBox)
        guard let document = view.document else { return true }
        let pageIndex = document.index(for: page)
        switch tool {
        case .line:
            let end = dragged ? point : CGPoint(x: start.x + 72, y: start.y)
            addLine(from: start, to: end, on: page, state: state)
            finish(state)
        case .signature(let signature):
            let rect: CGRect
            if dragged {
                rect = Self.rect(from: start, to: point, within: crop)
            } else {
                let width = signature.kind == .initials ? SignatureService.placedInitialsWidth : SignatureService.placedWidth
                let aspect = (signature.image?.size).map { $0.height / max($0.width, 1) } ?? 0.35
                let size = CGSize(width: width, height: width * aspect)
                rect = Self.clamp(CGRect(x: start.x - size.width / 2, y: start.y - size.height / 2,
                                         width: size.width, height: size.height), to: crop)
            }
            state.signatureService.armedTool = nil
            state.placeSignature(signature, page: pageIndex, rect: rect)
        case .field(let kind):
            let rect = dragged ? Self.rect(from: start, to: point, within: crop)
                : Self.clamp(CGRect(origin: CGPoint(x: start.x - kind.defaultSize.width / 2,
                                                    y: start.y - kind.defaultSize.height / 2),
                                    size: kind.defaultSize), to: crop)
            guard rect.width >= 6, rect.height >= 6 else { NSSound.beep(); return true }
            let group = kind == .radio ? state.signatureService.radioGroupTarget : nil
            state.signatureService.armedTool = nil
            state.placeFormField(kind, page: pageIndex, rect: rect, joining: group)
        case .certificateSignature:
            let rect = Self.rect(from: start, to: point, within: crop)
            guard rect.width >= 30, rect.height >= 14 else {
                state.signatureService.onSignatureBox?(pageIndex, CGRect(x: start.x - 90, y: start.y - 25, width: 180, height: 50)
                    .intersection(crop), nil)
                state.signatureService.armedTool = nil
                return true
            }
            state.signatureService.armedTool = nil
            state.signatureService.onSignatureBox?(pageIndex, rect, nil)
        default:
            break
        }
        return true
    }

    // MARK: Fill & Sign marks

    static func isFillText(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.type == "FreeText" else { return false }
        let intent = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/IT")) as? String
        return intent == typewriterIntent || intent == "FreeTextTypeWriter"
    }

    private func finish(_ state: AppState) {
        if !state.preferences.keepAnnotationToolSelected { state.signatureService.armedTool = nil }
        state.noteAnnotationsChanged()
    }

    private func placeSymbol(_ tool: FormsCanvasTool, at point: CGPoint, on page: PDFPage, state: AppState) {
        let size = max(8, state.signatureService.fillTextSize)
        let bounds = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let color = state.signatureService.fillColor
        let annotation: PDFAnnotation
        if tool == .dot {
            let inset = size * 0.3
            annotation = PDFAnnotation(bounds: bounds.insetBy(dx: inset, dy: inset), forType: .circle, withProperties: nil)
            annotation.color = color
            annotation.interiorColor = color
            let border = PDFBorder(); border.lineWidth = 0.5; annotation.border = border
        } else {
            annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            if tool == .check {
                path.move(to: CGPoint(x: size * 0.12, y: size * 0.52))
                path.line(to: CGPoint(x: size * 0.4, y: size * 0.18))
                path.line(to: CGPoint(x: size * 0.9, y: size * 0.88))
            } else {
                path.move(to: CGPoint(x: size * 0.15, y: size * 0.15))
                path.line(to: CGPoint(x: size * 0.85, y: size * 0.85))
                path.move(to: CGPoint(x: size * 0.15, y: size * 0.85))
                path.line(to: CGPoint(x: size * 0.85, y: size * 0.15))
            }
            path.lineWidth = max(1.2, size * 0.12)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            annotation.add(path)
            annotation.color = color
            let border = PDFBorder(); border.lineWidth = path.lineWidth; annotation.border = border
        }
        annotation.contents = tool == .check ? "Check mark" : tool == .cross ? "Cross mark" : "Dot"
        annotation.shouldPrint = true
        page.addAnnotation(annotation)
        finish(state)
    }

    private func addLine(from start: CGPoint, to end: CGPoint, on page: PDFPage, state: AppState) {
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                            height: abs(end.y - start.y)).insetBy(dx: -3, dy: -3)
        let line = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        line.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        line.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        line.color = state.signatureService.fillColor
        let border = PDFBorder(); border.lineWidth = 1; line.border = border
        line.shouldPrint = true
        page.addAnnotation(line)
    }

    @discardableResult
    func addFillText(_ text: String, at origin: CGPoint, on page: PDFPage, state: AppState) -> PDFAnnotation? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let size = state.signatureService.fillTextSize
        let font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        let lines = trimmed.components(separatedBy: "\n")
        let width = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 20
        let height = CGFloat(lines.count) * (font.ascender - font.descender + font.leading) + 4
        let bounds = Self.clamp(CGRect(x: origin.x, y: origin.y, width: ceil(width) + 8, height: ceil(height)),
                                to: page.bounds(for: .cropBox))
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = trimmed
        annotation.font = font
        annotation.fontColor = state.signatureService.fillColor
        annotation.color = .clear
        annotation.alignment = .left
        let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
        annotation.setValue(Self.typewriterIntent, forAnnotationKey: PDFAnnotationKey(rawValue: "/IT"))
        annotation.shouldPrint = true
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: Inline text editor

    private func beginEditing(at origin: CGPoint, on page: PDFPage, in view: PDFView, state: AppState,
                              replacing annotation: PDFAnnotation? = nil) {
        endEditing(commit: true)
        guard let documentView = view.documentView else { return }
        let size = state.signatureService.fillTextSize
        let scale = view.scaleFactor
        let pageRect = CGRect(x: origin.x, y: origin.y, width: max(160, annotation?.bounds.width ?? 0),
                              height: max(size * 1.5, annotation?.bounds.height ?? 0))
        let inView = view.convert(pageRect, from: page)
        let frame = documentView.convert(inView, from: view)
        let field = NSTextField(frame: frame.insetBy(dx: -2, dy: -2))
        field.font = NSFont(name: "Helvetica", size: size * scale)
        field.textColor = state.signatureService.fillColor
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        field.focusRingType = .exterior
        field.placeholderString = "Type here"
        field.stringValue = annotation?.contents ?? ""
        field.delegate = self
        field.setAccessibilityLabel("Fill & Sign text")
        field.toolTip = "Press Return to place the text, Escape to cancel."
        documentView.addSubview(field)
        view.window?.makeFirstResponder(field)
        editor = field
        editorView = view
        editorPage = page
        editorOrigin = origin
        editorReplacing = annotation
        editorState = state
        if !state.preferences.keepAnnotationToolSelected { state.signatureService.armedTool = nil }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        endEditing(commit: movement != NSTextMovement.cancel.rawValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endEditing(commit: true)
            return true
        }
        return false
    }

    private func endEditing(commit: Bool) {
        guard let field = editor else { return }
        editor = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        guard let page = editorPage, let state = editorState else { return }
        let replaced = editorReplacing
        editorReplacing = nil
        if commit {
            if let replaced {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { page.removeAnnotation(replaced) }
                else if text != replaced.contents {
                    page.removeAnnotation(replaced)
                    addFillText(text, at: replaced.bounds.origin, on: page, state: state)
                }
            } else {
                addFillText(text, at: editorOrigin, on: page, state: state)
            }
            state.noteAnnotationsChanged()
        }
        if let view = editorView { view.window?.makeFirstResponder(view) }
    }

    // MARK: Geometry

    static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}

// MARK: - Canvas actions that run native transforms

@MainActor
extension AppState {
    /// Places a saved signature or initials as a stamp that saves natively.
    func placeSignature(_ signature: SavedSignature, page: Int, rect: CGRect) {
        guard let tab = activeTab, let png = signature.pngData else { return }
        runDocumentTransform([["op": "place_image_stamp", "page": page,
                               "rect": [rect.minX, rect.minY, rect.maxX, rect.maxY],
                               "image": png.base64EncodedString(), "kind": signature.kind.rawValue,
                               "name": signature.kind == .initials ? "Initials" : "Signature",
                               "author": preferences.commentAuthor]],
                             actionName: signature.kind == .initials ? "Place Initials" : "Place Signature", in: tab)
    }

    /// Adds a Prepare Form field with sensible defaults and selects it.
    func placeFormField(_ kind: FormFieldKind, page: Int, rect: CGRect, joining group: String? = nil) {
        guard let tab = activeTab else { return }
        if kind == .radio, let group, let existing = tab.protection.formFields.first(where: { $0.name == group && $0.kind == "radio" }) {
            var number = existing.exports.count + 1
            while existing.exports.contains("Choice\(number)") { number += 1 }
            runDocumentTransform([["op": "add_form_field", "type": "radio", "name": group, "page": page,
                                   "rect": [rect.minX, rect.minY, rect.maxX, rect.maxY], "export_value": "Choice\(number)"]],
                                 actionName: "Add Radio Button", in: tab) { [weak self] _ in
                self?.refreshFormModel(tab)
                self?.signatureService.onFieldPlaced?(group)
            }
            return
        }
        let base: String
        switch kind {
        case .radio: base = "Group"
        case .combo: base = "Dropdown"
        case .list: base = "List Box"
        case .checkbox: base = "Check Box"
        default: base = kind.shortName
        }
        let name = FormFieldAuthoring.uniqueName(base, in: tab)
        var op: [String: Any] = ["op": "add_form_field", "type": kind.rawValue, "name": name, "page": page,
                                 "rect": [rect.minX, rect.minY, rect.maxX, rect.maxY]]
        if kind == .radio { op["export_value"] = "Choice1" }
        runDocumentTransform([op], actionName: "Add \(kind.displayName)", in: tab) { [weak self] _ in
            guard let self else { return }
            tab.protection.profiledHash = nil
            self.profileDocument(tab)
            self.signatureService.onFieldPlaced?(name)
        }
    }
}
