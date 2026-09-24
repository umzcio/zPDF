//
//  PDFEngine.swift
//  zPDF
//
//  Purpose: THE PDF engine abstraction. All PDF access in the app goes
//  through this protocol so the engine can be swapped later (PDFium,
//  PSPDFKit) without touching views. Document/page types are type-aliased
//  so a non-PDFKit engine can re-point the aliases at adapter types.
//  Phase: 1 — contract is final; page operations are real in PDFKitEngine.
//  Phase: 2 — additive contract addition: embedded-file enumeration
//  (EmbeddedFile + embeddedFiles(for:)) for the sidebar Attachments tab.
//  Phase: 3 — additive contract addition: AcroForm enumeration/filling
//  (PDFFormField + formFields(in:) + setFormFieldValue(_:forFieldNamed:in:))
//  for the Fill & Sign panel's quick-fill surface.
//  TODO(phase-5): redaction burn-in and optimize/compress entry points.
//

import AppKit
import Foundation
import PDFKit

/// Concrete document type of the current engine (PDFKit-backed).
/// A swapped engine must still be able to vend a `PDFDocument` facade,
/// because `PDFView` requires one — see SPEC.md §2.2.
typealias EngineDocument = PDFDocument
/// Concrete page type of the current engine.
typealias EnginePage = PDFPage

enum PDFEngineError: Error, LocalizedError {
    case cannotOpenDocument(URL)
    case cannotSaveDocument(URL)
    case pageIndexOutOfRange(Int)
    case formFieldNotFound(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenDocument(let url):
            "Could not open PDF at \(url.path)."
        case .cannotSaveDocument(let url):
            "Could not save PDF to \(url.path)."
        case .pageIndexOutOfRange(let index):
            "Page index \(index) is out of range."
        case .formFieldNotFound(let name):
            "No fillable form field named \"\(name)\" exists."
        case .unsupportedOperation(let name):
            "\(name) is not supported by the current PDF engine."
        }
    }
}

/// One embedded file (attachment) declared in a document's /Names
/// /EmbeddedFiles name tree. PDFKit exposes no API for these, so engines
/// parse the name tree directly (PDFKitEngine uses CGPDFDocument).
struct EmbeddedFile: Identifiable, Hashable {
    let id = UUID()
    /// Display name: the file spec's /UF or /F filename when present,
    /// otherwise the name-tree key.
    let name: String
    /// Uncompressed size from the embedded stream's /Params /Size,
    /// nil when the stream carries no params.
    let byteCount: Int64?
}

/// One fillable AcroForm field, derived from a widget PDFAnnotation
/// (phase 3, additive — see `PDFEngine.formFields(in:)`). Values are
/// strings across all kinds: text content for text fields, the selected
/// option for choice fields, and `PDFFormField.checkboxOn`/`checkboxOff`
/// for checkboxes.
struct PDFFormField: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case text
        case checkbox
        case choice

        var title: String {
            switch self {
            case .text: "Text field"
            case .checkbox: "Checkbox"
            case .choice: "Dropdown"
            }
        }

        var symbolName: String {
            switch self {
            case .text: "character.textbox"
            case .checkbox: "checkmark.square"
            case .choice: "chevron.up.chevron.down"
            }
        }
    }

    /// Value reported for a checked checkbox, and the value
    /// `setFormFieldValue` expects to check one.
    static let checkboxOn = "on"
    /// Value reported for an unchecked checkbox.
    static let checkboxOff = "off"

    /// Field name (the widget's /T entry).
    let name: String
    let kind: Kind
    /// Current value: text content, selected option, or checkbox on/off.
    let value: String
    /// Selectable options for choice fields; empty for other kinds.
    let options: [String]
    /// 0-based page index the field's widget lives on.
    let pageIndex: Int

    var id: String { "\(pageIndex):\(name)" }

    var isChecked: Bool { value == PDFFormField.checkboxOn }
}

/// One editable text run extracted from a page content stream (phase 4,
/// additive — see `PDFEngine.textRuns(onPageAt:in:)`). PDFKit cannot edit
/// page content, so engines parse/rewrite content streams directly.
struct EditableTextRun: Identifiable, Equatable, Sendable {
    /// Index into the `textRuns(onPageAt:in:)` result array. Stable only
    /// until the next successful `replaceTextRun` — re-fetch after edits.
    let id: Int
    /// 0-based page index the run lives on.
    let pageIndex: Int
    /// The run's current text (decoded from the font's encoding).
    var text: String
    /// Bounding box in page space (points, bottom-left origin).
    let bounds: CGRect
    /// PostScript name of the run's font (e.g. "Helvetica").
    let fontName: String
    /// Font size in points.
    let fontSize: CGFloat
}

protocol PDFEngine {
    /// Open a PDF from disk. Throws `PDFEngineError.cannotOpenDocument`.
    func openDocument(at url: URL) throws -> EngineDocument

    /// Create a new, empty document (Create PDF tool — phase 4).
    func createEmptyDocument() -> EngineDocument

    func pageCount(of document: EngineDocument) -> Int
    func page(at index: Int, in document: EngineDocument) -> EnginePage?

    /// Raster thumbnail for sidebar / organize grid cells.
    func thumbnail(for page: EnginePage, size: CGSize) -> NSImage?

    /// Raster render of a full page fitted into `size` (export, OCR input).
    func renderPage(_ page: EnginePage, toFit size: CGSize) -> NSImage?

    // MARK: Annotations

    func addAnnotation(_ annotation: PDFAnnotation, toPageAt index: Int, in document: EngineDocument) throws
    func removeAnnotation(_ annotation: PDFAnnotation, fromPageAt index: Int, in document: EngineDocument) throws

    // MARK: Attachments (phase 2, additive)

    /// Enumerate embedded files (attachments) from the document catalog's
    /// /Names /EmbeddedFiles name tree. Returns an empty array when the
    /// document has none or the file cannot be read. Takes the on-disk URL
    /// rather than the live document because PDFKit has no embedded-file
    /// API — engines re-parse the file (PDFKitEngine via CGPDFDocument).
    func embeddedFiles(for url: URL) -> [EmbeddedFile]

    // MARK: Forms (phase 3, additive)

    /// Enumerate the document's fillable AcroForm fields (widget
    /// annotations) in page order. Text, checkbox, and choice (dropdown)
    /// widgets are included; read-only, push-button, radio-button, and
    /// signature widgets are skipped. Returns an empty array when the
    /// document has no fillable form.
    func formFields(in document: EngineDocument) -> [PDFFormField]

    /// Set the value of the field named `name`: free text for text
    /// fields, one of the field's `options` for choice fields, and
    /// `PDFFormField.checkboxOn` / `checkboxOff` for checkboxes. Throws
    /// `PDFEngineError.formFieldNotFound` when no fillable field with
    /// that name exists.
    func setFormFieldValue(_ value: String, forFieldNamed name: String, in document: EngineDocument) throws

    // MARK: Content editing (phase 4, additive)

    /// Extract the editable text runs of a page by parsing its content
    /// stream (BT/ET text objects: Tf/Tm/Td positioning, Tj/TJ show ops).
    /// Runs are in stream order; `EditableTextRun.id` is the index into the
    /// returned array and is stable only until the next edit invalidates it.
    func textRuns(onPageAt index: Int, in document: EngineDocument) -> [EditableTextRun]

    /// Replace the text of a run previously returned by `textRuns` and
    /// rewrite the page content stream in place. Only single-font,
    /// single-size runs are supported; glyphs outside the run font's
    /// encoding are not representable (the implementation may throw
    /// `.unsupportedOperation` in that case). The caller must treat all
    /// previously returned runs as stale after a successful replace.
    func replaceTextRun(_ run: EditableTextRun, with newText: String, in document: EngineDocument) throws

    // MARK: Page operations (REAL in PDFKitEngine)

    func insertPage(_ page: EnginePage, at index: Int, in document: EngineDocument) throws
    func removePage(at index: Int, in document: EngineDocument) throws
    /// Rotate by a positive multiple of 90 degrees.
    func rotatePage(at index: Int, in document: EngineDocument, byDegrees degrees: Int) throws
    func movePage(from sourceIndex: Int, to destinationIndex: Int, in document: EngineDocument) throws
    /// Build a new document containing copies of the given pages, in order.
    func extractPages(_ indexes: IndexSet, from document: EngineDocument) throws -> EngineDocument

    // MARK: Persistence

    func save(_ document: EngineDocument, to url: URL) throws

    /// Write an encrypted copy (PDFKit write options). UI lives in
    /// ProtectPanel — TODO(phase-5) for permission bits and certificates.
    func encrypt(_ document: EngineDocument, to url: URL, userPassword: String?, ownerPassword: String?) throws

    /// TODO(phase-5): burn redaction annotations into the content stream.
    /// PDFKit cannot do this; requires content-stream rewriting or an engine
    /// swap. PDFKitEngine throws `.unsupportedOperation`.
    func applyRedactions(in document: EngineDocument) throws
}
