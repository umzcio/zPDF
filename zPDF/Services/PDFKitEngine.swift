//
//  PDFKitEngine.swift
//  zPDF
//
//  Purpose: Concrete PDFEngine implementation backed by Apple PDFKit.
//  Page operations (insert/remove/rotate/move/extract), rendering, saving,
//  password encryption, and embedded-file enumeration are REAL.
//  Phase: 1 — real for page ops.
//  Phase: 2 — embeddedFiles(for:) walks the catalog's /Names /EmbeddedFiles
//  name tree via CGPDFDocument (PDFKit exposes no embedded-file API).
//  Phase: 3 — AcroForm enumeration/filling over widget PDFAnnotations
//  (fieldName/widgetStringValue/buttonWidgetState/choices).
//  Page content editing runs as native transforms (see DocumentTransforms).
//  TODO(phase-5): applyRedactions, optimize/compress.
//

import AppKit
import CoreGraphics
import Foundation
import PDFKit

final class PDFKitEngine: PDFEngine {
    private final class Thumbnail {
        weak var page: PDFPage? // Do not retain a closed document through its thumbnail.
        let image: NSImage
        init(page: PDFPage, image: NSImage) { self.page = page; self.image = image }
    }
    private let thumbnails: NSCache<NSString, Thumbnail> = {
        let cache = NSCache<NSString, Thumbnail>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()


    // MARK: - Open / create

    func openDocument(at url: URL) throws -> EngineDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFEngineError.cannotOpenDocument(url)
        }
        // Redaction marks draw as outlines until they are applied.
        document.delegate = RedactionMarkAppearance.shared
        return document
    }

    func createEmptyDocument() -> EngineDocument {
        PDFDocument()
    }

    // MARK: - Queries

    func pageCount(of document: EngineDocument) -> Int {
        document.pageCount
    }

    func page(at index: Int, in document: EngineDocument) -> EnginePage? {
        document.page(at: index)
    }

    // MARK: - Rendering

    func thumbnail(for page: EnginePage, size: CGSize) -> NSImage? {
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(page)); hasher.combine(page.rotation)
        hasher.combine(size.width); hasher.combine(size.height)
        for annotation in page.annotations {
            hasher.combine(ObjectIdentifier(annotation)); hasher.combine(annotation.contents)
            hasher.combine(annotation.widgetStringValue); hasher.combine(annotation.buttonWidgetState.rawValue)
        }
        let key = String(hasher.finalize()) as NSString
        if let cached = thumbnails.object(forKey: key), cached.page === page { return cached.image }
        guard let image = renderPage(page, toFit: size) else { return nil }
        thumbnails.setObject(Thumbnail(page: page, image: image), forKey: key,
                             cost: Int(size.width * size.height * 16))
        return image
    }

    /// Rasterize a page, scaled to fit `size` while preserving aspect ratio.
    func renderPage(_ page: EnginePage, toFit size: CGSize) -> NSImage? {
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0, size.width > 0, size.height > 0 else {
            return nil
        }
        let scale = min(size.width / mediaBox.width, size.height / mediaBox.height)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.saveGState()
        // Center the scaled page inside the target rect.
        let scaledSize = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
        let origin = CGPoint(x: (size.width - scaledSize.width) / 2,
                             y: (size.height - scaledSize.height) / 2)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return image
    }

    // MARK: - Annotations

    func addAnnotation(_ annotation: PDFAnnotation, toPageAt index: Int, in document: EngineDocument) throws {
        guard let page = document.page(at: index) else {
            throw PDFEngineError.pageIndexOutOfRange(index)
        }
        page.addAnnotation(annotation)
    }

    func removeAnnotation(_ annotation: PDFAnnotation, fromPageAt index: Int, in document: EngineDocument) throws {
        guard let page = document.page(at: index) else {
            throw PDFEngineError.pageIndexOutOfRange(index)
        }
        page.removeAnnotation(annotation)
    }

    // MARK: - Attachments (embedded files)

    /// PDFKit has no embedded-file API, so re-parse the file with
    /// CGPDFDocument and walk the catalog's /Names /EmbeddedFiles name tree.
    func embeddedFiles(for url: URL) -> [EmbeddedFile] {
        guard let document = CGPDFDocument(url as CFURL),
              let catalog = document.catalog,
              let names = pdfDictionary("Names", in: catalog),
              let tree = pdfDictionary("EmbeddedFiles", in: names) else {
            return []
        }
        var files: [EmbeddedFile] = []
        collectEmbeddedFiles(from: tree, into: &files)
        return files
    }

    /// Recursively walk a name tree node: leaf /Names arrays alternate
    /// key-string / file-spec pairs; intermediate nodes carry /Kids.
    private func collectEmbeddedFiles(from node: CGPDFDictionaryRef, into files: inout [EmbeddedFile]) {
        if let pairs = pdfArray("Names", in: node) {
            var index = 0
            while index + 1 < CGPDFArrayGetCount(pairs) {
                var keyObject: CGPDFObjectRef?
                var valueObject: CGPDFObjectRef?
                if CGPDFArrayGetObject(pairs, index, &keyObject),
                   CGPDFArrayGetObject(pairs, index + 1, &valueObject),
                   let file = embeddedFile(name: pdfText(from: keyObject), from: valueObject) {
                    files.append(file)
                }
                index += 2
            }
        }
        if let kids = pdfArray("Kids", in: node) {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kidObject: CGPDFObjectRef?
                if CGPDFArrayGetObject(kids, index, &kidObject),
                   let kid = pdfDictionary(from: kidObject) {
                    collectEmbeddedFiles(from: kid, into: &files)
                }
            }
        }
    }

    /// Build an EmbeddedFile from a file-spec dictionary, preferring the
    /// /UF (Unicode) filename and reading the uncompressed size from the
    /// embedded stream's /Params /Size.
    private func embeddedFile(name: String?, from fileSpecObject: CGPDFObjectRef?) -> EmbeddedFile? {
        guard let fileSpec = pdfDictionary(from: fileSpecObject) else { return nil }
        let displayName = pdfText(pdfString("UF", in: fileSpec))
            ?? pdfText(pdfString("F", in: fileSpec))
            ?? name
            ?? "Unnamed attachment"
        var byteCount: Int64?
        if let ef = pdfDictionary("EF", in: fileSpec),
           let stream = pdfStream("UF", in: ef) ?? pdfStream("F", in: ef),
           let streamDictionary = CGPDFStreamGetDictionary(stream),
           let params = pdfDictionary("Params", in: streamDictionary) {
            var size: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(params, "Size", &size) {
                byteCount = Int64(size)
            }
        }
        return EmbeddedFile(name: displayName, byteCount: byteCount)
    }

    // MARK: CGPDF object helpers

    /// Raw (possibly indirect) object for `key`; the typed helpers below
    /// dereference it via CGPDFObjectGetValue.
    private func pdfObject(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGPDFObjectRef? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &object) else { return nil }
        return object
    }

    private func pdfDictionary(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        pdfDictionary(from: pdfObject(key, in: dictionary))
    }

    private func pdfDictionary(from object: CGPDFObjectRef?) -> CGPDFDictionaryRef? {
        guard let object else { return nil }
        var value: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &value) else { return nil }
        return value
    }

    private func pdfArray(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGPDFArrayRef? {
        guard let object = pdfObject(key, in: dictionary) else { return nil }
        var value: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &value) else { return nil }
        return value
    }

    private func pdfString(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGPDFStringRef? {
        guard let object = pdfObject(key, in: dictionary) else { return nil }
        var value: CGPDFStringRef?
        guard CGPDFObjectGetValue(object, .string, &value) else { return nil }
        return value
    }

    private func pdfStream(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGPDFStreamRef? {
        guard let object = pdfObject(key, in: dictionary) else { return nil }
        var value: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &value) else { return nil }
        return value
    }

    private func pdfText(_ string: CGPDFStringRef?) -> String? {
        guard let string, let text = CGPDFStringCopyTextString(string) else { return nil }
        return text as String
    }

    private func pdfText(from object: CGPDFObjectRef?) -> String? {
        guard let object else { return nil }
        var string: CGPDFStringRef?
        guard CGPDFObjectGetValue(object, .string, &string) else { return nil }
        return pdfText(string)
    }

    // MARK: - Forms (phase 3)

    func formFields(in document: EngineDocument) -> [PDFFormField] {
        var fields: [PDFFormField] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                if let field = formField(from: annotation, pageIndex: pageIndex) {
                    fields.append(field)
                }
            }
        }
        return fields
    }

    func setFormFieldValue(_ value: String, forFieldNamed name: String, in document: EngineDocument) throws {
        guard let annotation = widgetAnnotation(fieldNamed: name, in: document) else {
            throw PDFEngineError.formFieldNotFound(name)
        }
        switch annotation.widgetFieldType {
        case PDFAnnotationWidgetSubtype.text, PDFAnnotationWidgetSubtype.choice:
            annotation.widgetStringValue = value
        case PDFAnnotationWidgetSubtype.button:
            // Setting buttonWidgetState writes both /V and /AS.
            annotation.buttonWidgetState = value == PDFFormField.checkboxOn ? .onState : .offState
        default:
            throw PDFEngineError.unsupportedOperation("Setting the value of form field \"\(name)\"")
        }
    }

    /// First fillable widget annotation carrying the given field name.
    private func widgetAnnotation(fieldNamed name: String, in document: EngineDocument) -> PDFAnnotation? {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.fieldName == name {
                if formField(from: annotation, pageIndex: pageIndex) != nil {
                    return annotation
                }
            }
        }
        return nil
    }

    /// Map a widget annotation to a PDFFormField, or nil when it is not a
    /// fillable text/checkbox/choice field (e.g. read-only, radio,
    /// push-button, or signature widgets).
    private func formField(from annotation: PDFAnnotation, pageIndex: Int) -> PDFFormField? {
        guard isWidget(annotation),
              !annotation.isReadOnly,
              let name = annotation.fieldName, !name.isEmpty else { return nil }
        switch annotation.widgetFieldType {
        case PDFAnnotationWidgetSubtype.text:
            return PDFFormField(name: name, kind: .text,
                             value: annotation.widgetStringValue ?? "",
                             options: [], pageIndex: pageIndex)
        case PDFAnnotationWidgetSubtype.choice:
            return PDFFormField(name: name, kind: .choice,
                             value: annotation.widgetStringValue ?? "",
                             options: annotation.choices ?? [], pageIndex: pageIndex)
        case PDFAnnotationWidgetSubtype.button:
            // Radio buttons and push buttons carry group/action semantics
            // the quick-fill surface does not model.
            guard annotation.widgetControlType == .checkBoxControl else { return nil }
            return PDFFormField(name: name, kind: .checkbox,
                             value: annotation.buttonWidgetState == .onState
                                ? PDFFormField.checkboxOn : PDFFormField.checkboxOff,
                             options: [], pageIndex: pageIndex)
        default:
            return nil
        }
    }

    /// `annotation.type` returns the /Subtype entry without the leading
    /// slash ("Widget"), while the PDFAnnotationSubtype constant keeps it
    /// ("/Widget") — accept both forms.
    private func isWidget(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }
        let subtype = PDFAnnotationSubtype.widget.rawValue
        return type == subtype || type == String(subtype.dropFirst())
    }

    // MARK: - Page operations (REAL)

    func insertPage(_ page: EnginePage, at index: Int, in document: EngineDocument) throws {
        guard index >= 0, index <= document.pageCount else {
            throw PDFEngineError.pageIndexOutOfRange(index)
        }
        document.insert(page, at: index)
    }

    func removePage(at index: Int, in document: EngineDocument) throws {
        guard index >= 0, index < document.pageCount else {
            throw PDFEngineError.pageIndexOutOfRange(index)
        }
        document.removePage(at: index)
    }

    func rotatePage(at index: Int, in document: EngineDocument, byDegrees degrees: Int) throws {
        guard let page = document.page(at: index) else {
            throw PDFEngineError.pageIndexOutOfRange(index)
        }
        page.rotation = (page.rotation + degrees) % 360
    }

    func movePage(from sourceIndex: Int, to destinationIndex: Int, in document: EngineDocument) throws {
        guard let page = document.page(at: sourceIndex) else {
            throw PDFEngineError.pageIndexOutOfRange(sourceIndex)
        }
        document.removePage(at: sourceIndex)
        var destination = destinationIndex
        if sourceIndex < destinationIndex {
            destination -= 1
        }
        document.insert(page, at: min(max(0, destination), document.pageCount))
    }

    func extractPages(_ indexes: IndexSet, from document: EngineDocument) throws -> EngineDocument {
        let extracted = PDFDocument()
        var insertAt = 0
        for index in indexes.sorted() {
            guard let page = document.page(at: index) else {
                throw PDFEngineError.pageIndexOutOfRange(index)
            }
            // PDFKit copies pages when inserting across documents.
            extracted.insert(page, at: insertAt)
            insertAt += 1
        }
        return extracted
    }

    // MARK: - Persistence

    func save(_ document: EngineDocument, to url: URL) throws {
        guard document.write(to: url) else {
            throw PDFEngineError.cannotSaveDocument(url)
        }
    }

    // MARK: - Protection (partially real)

    func encrypt(_ document: EngineDocument, to url: URL, userPassword: String?, ownerPassword: String?) throws {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let userPassword, !userPassword.isEmpty {
            options[.userPasswordOption] = userPassword
        }
        if let ownerPassword, !ownerPassword.isEmpty {
            options[.ownerPasswordOption] = ownerPassword
        }
        guard document.write(to: url, withOptions: options) else {
            throw PDFEngineError.cannotSaveDocument(url)
        }
    }

    func applyRedactions(in document: EngineDocument) throws {
        // TODO(phase-5): draw opaque rectangles into the content stream and
        // strip the underlying text objects. Not possible with PDFKit alone.
        throw PDFEngineError.unsupportedOperation("Redaction burn-in")
    }
}
