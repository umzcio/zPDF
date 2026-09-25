//
//  ToolID.swift
//  zPDF
//
//  Purpose: Catalog of every tool shown on the Tools screen, mirroring the
//  prototype's TOOLGROUPS table: 25 tools in 5 groups. Each tool has a name,
//  SF Symbol, description, its group, and its inspector-panel mapping
//  (tool→panel mapping mirrors the prototype's TOOL_PANEL).
//  Phase: 1 — REAL (pure data). ToolCount note: the approved prototype lists
//  25 tools (the original plan said 24); the prototype is authoritative.
//

import Foundation

/// The five tool groups, in prototype order.
enum ToolGroup: String, CaseIterable, Identifiable {
    case createEdit
    case shareReview
    case protectOptimize
    case formsSignatures
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .createEdit: "Create & Edit"
        case .shareReview: "Share & Review"
        case .protectOptimize: "Protect & Optimize"
        case .formsSignatures: "Forms & Signatures"
        case .advanced: "Advanced"
        }
    }
}

enum ToolID: String, CaseIterable, Identifiable {
    // Create & Edit
    case createPDF
    case combineFiles
    case editPDF
    case exportPDF
    case organizePages
    case compressPDF
    // Share & Review
    case comment
    case sendForComments
    case share
    case sendForSignature
    // Protect & Optimize
    case protect
    case redact
    case optimizePDF
    case certificates
    // Forms & Signatures
    case fillAndSign
    case prepareForm
    case signWithCertificate
    // Advanced
    case compareFiles
    case scanAndOCR
    case measureObjects
    case printProduction
    case actionWizard
    case accessibilityCheck
    case archivePDFA
    case batesNumbering

    /// Only workflows supported by the app’s native Save path, in the order
    /// the quick toolbar lists them.
    static let available: [ToolID] = [.comment, .fillAndSign, .organizePages, .combineFiles, .compressPDF, .exportPDF]
        + allCases.filter { $0.isImplemented && ![.comment, .fillAndSign, .organizePages, .combineFiles, .compressPDF, .exportPDF].contains($0) }

    /// Flip a tool to `true` only when its whole workflow saves natively.
    /// One case per line so independent features never edit the same line.
    var isImplemented: Bool {
        switch self {
        case .comment: true
        case .fillAndSign: true
        case .organizePages: true
        case .combineFiles: true
        case .compressPDF: true
        case .exportPDF: true

        case .createPDF: true

        case .editPDF: true

        case .sendForComments: false

        case .share: true

        case .sendForSignature: false

        case .protect: false

        case .redact: true

        case .optimizePDF: true

        case .certificates: false

        case .prepareForm: false

        case .signWithCertificate: false

        case .compareFiles: true

        case .scanAndOCR: true

        case .measureObjects: true

        case .printProduction: true

        case .actionWizard: true

        case .accessibilityCheck: true

        case .archivePDFA: true

        case .batesNumbering: true
        }
    }

    var id: String { rawValue }

    var group: ToolGroup {
        switch self {
        case .createPDF, .combineFiles, .editPDF, .exportPDF, .organizePages, .compressPDF:
            .createEdit
        case .comment, .sendForComments, .share, .sendForSignature:
            .shareReview
        case .protect, .redact, .optimizePDF, .certificates:
            .protectOptimize
        case .fillAndSign, .prepareForm, .signWithCertificate:
            .formsSignatures
        case .compareFiles, .scanAndOCR, .measureObjects, .printProduction,
             .actionWizard, .accessibilityCheck, .archivePDFA, .batesNumbering:
            .advanced
        }
    }

    var name: String {
        switch self {
        case .createPDF: "Create PDF"
        case .combineFiles: "Combine Files"
        case .editPDF: "Edit PDF"
        case .exportPDF: "Export PDF"
        case .organizePages: "Organize Pages"
        case .compressPDF: "Reduce File Size"
        case .comment: "Comment"
        case .sendForComments: "Send for Comments"
        case .share: "Share"
        case .sendForSignature: "Send for Signature"
        case .protect: "Protect"
        case .redact: "Redact"
        case .optimizePDF: "Optimize PDF"
        case .certificates: "Certificates"
        case .fillAndSign: "Fill forms"
        case .prepareForm: "Prepare Form"
        case .signWithCertificate: "Sign with Certificate"
        case .compareFiles: "Compare Files"
        case .scanAndOCR: "Scan & OCR"
        case .measureObjects: "Measure Objects"
        case .printProduction: "Print Production"
        case .actionWizard: "Action Wizard"
        case .accessibilityCheck: "Accessibility Check"
        case .archivePDFA: "Archive (PDF/A)"
        case .batesNumbering: "Bates Numbering"
        }
    }

    /// Short subtitle shown under the tool name on the Tools screen.
    var toolDescription: String {
        switch self {
        case .createPDF: "Convert files or scans to PDF"
        case .combineFiles: "Merge multiple files into one PDF"
        case .editPDF: "Change text, images, and pages"
        case .exportPDF: "Save pages as images or plain text"
        case .organizePages: "Reorder, rotate, delete, or extract pages"
        case .compressPDF: "Reduce file size for sharing"
        case .comment: "Annotate with highlights and notes"
        case .sendForComments: "Collect feedback in one place"
        case .share: "Send a link or a copy of the file"
        case .sendForSignature: "Request e-signatures from others"
        case .protect: "Encrypt and restrict editing"
        case .redact: "Permanently remove sensitive content"
        case .optimizePDF: "Tune size, fonts, and images"
        case .certificates: "Encrypt and validate with certificates"
        case .fillAndSign: "Complete existing form fields"
        case .prepareForm: "Add fillable fields to any document"
        case .signWithCertificate: "Apply a digital ID signature"
        case .compareFiles: "Spot differences between versions"
        case .scanAndOCR: "Recognize text in scanned documents"
        case .measureObjects: "Distance, area, and perimeter tools"
        case .printProduction: "Preflight and output previews"
        case .actionWizard: "Automate repeatable tasks"
        case .accessibilityCheck: "Verify reading order and tags"
        case .archivePDFA: "Convert for long-term preservation"
        case .batesNumbering: "Add legal index numbers to pages"
        }
    }

    var symbolName: String {
        switch self {
        case .createPDF: "doc.badge.plus"
        case .combineFiles: "doc.on.doc"
        case .editPDF: "square.and.pencil"
        case .exportPDF: "square.and.arrow.up"
        case .organizePages: "rectangle.on.rectangle"
        case .compressPDF: "rectangle.compress.vertical"
        case .comment: "text.bubble"
        case .sendForComments: "paperplane"
        case .share: "person.2"
        case .sendForSignature: "signature"
        case .protect: "lock.shield"
        case .redact: "eye.slash"
        case .optimizePDF: "speedometer"
        case .certificates: "checkmark.seal"
        case .fillAndSign: "list.bullet.rectangle"
        case .prepareForm: "list.bullet.rectangle"
        case .signWithCertificate: "checkmark.seal.fill"
        case .compareFiles: "rectangle.split.2x1"
        case .scanAndOCR: "doc.viewfinder"
        case .measureObjects: "ruler"
        case .printProduction: "printer"
        case .actionWizard: "wand.and.stars"
        case .accessibilityCheck: "accessibility"
        case .archivePDFA: "archivebox"
        case .batesNumbering: "list.number"
        }
    }

    /// Inspector panel opened when this tool is invoked, mirroring the
    /// prototype's TOOL_PANEL mapping. nil = navigate to the document view
    /// without opening a panel (the tool's UI arrives in a later phase).
    var inspectorPanel: InspectorPanel? {
        switch self {
        case .editPDF: .edit
        case .comment: .comment
        case .organizePages: .organize
        case .exportPDF: .export
        case .fillAndSign: .fillSign
        case .protect: .protect
        case .prepareForm: .prepareForm
        case .redact: .redact
        case .certificates, .signWithCertificate: .sign
        case .createPDF: .createPDF
        case .scanAndOCR: .scanOCR
        case .optimizePDF: .optimize
        case .compareFiles: .compare
        case .measureObjects: .measure
        case .accessibilityCheck: .accessibility
        case .archivePDFA, .printProduction: .standards
        case .actionWizard: .automation
        case .batesNumbering: .edit
        default: nil
        }
    }

    /// Tools belonging to a group, in prototype order.
    static func tools(in group: ToolGroup) -> [ToolID] {
        allCases.filter { $0.group == group }
    }
}
