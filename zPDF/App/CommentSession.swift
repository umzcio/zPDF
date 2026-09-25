//
//  CommentSession.swift
//  zPDF
//
//  Purpose: Comment-tool state shared by the canvas, the Comment panel and
//  the menus: the selected comment annotation, per-tool styles, the stamp
//  in use, canvas visibility (Hide All / on-page filters), recording state,
//  comparison results and transient status messages. One session per
//  AppState, looked up without adding stored properties to AppState.
//

import AppKit
import Foundation
import PDFKit

/// Per-tool appearance defaults, persisted under the app's own defaults keys.
@MainActor
@Observable
final class CommentToolStyles {
    static let shared = CommentToolStyles()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "zpdf.comments.v1.toolStyles"
    private var custom: [String: CommentStyle] = [:]

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([String: CommentStyle].self, from: data) {
            custom = decoded
        }
    }

    func style(for tool: AnnotationTool) -> CommentStyle { custom[tool.rawValue] ?? tool.defaultStyle }
    func hasCustomColor(for tool: AnnotationTool) -> Bool { custom[tool.rawValue] != nil }

    func set(_ style: CommentStyle, for tool: AnnotationTool) {
        custom[tool.rawValue] = style
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: key) }
    }

    func reset(_ tool: AnnotationTool) {
        custom[tool.rawValue] = nil
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: key) }
    }
}

/// A comment annotation selected on the canvas.
struct CommentSelection {
    let annotation: PDFAnnotation
    let page: PDFPage
}

/// Result of Compare Comments, shown in a sheet.
struct CommentComparison: Identifiable {
    struct Item: Identifiable {
        let id = UUID()
        let page: Int
        let subtype: String
        let author: String
        let contents: String
        let changes: [String]
        let before: String?
        var kind: CommentKind { CommentKind(pdfSubtype: subtype) }
    }
    let id = UUID()
    let otherName: String
    let added: [Item]
    let removed: [Item]
    let changed: [Item]
    let unchanged: Int
}

@MainActor
@Observable
final class CommentSession {
    private static let sessions = NSMapTable<AppState, CommentSession>.weakToStrongObjects()

    static func of(_ appState: AppState) -> CommentSession {
        if let existing = sessions.object(forKey: appState) { return existing }
        let session = CommentSession()
        session.appState = appState
        sessions.setObject(session, forKey: appState)
        return session
    }

    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored private var canvasController: CommentCanvasController?

    /// Canvas interaction for comment tools (attached to the live PDFView).
    var canvas: CommentCanvasController {
        if let canvasController { return canvasController }
        let controller = CommentCanvasController(appState: appState!)
        canvasController = controller
        return controller
    }

    /// Selected comment annotation on the canvas (validated on read).
    var selection: CommentSelection? {
        didSet { selectionRevision += 1 }
    }
    private(set) var selectionRevision = 0
    /// Comment row to reveal in the list (canvas selection, new comment).
    var focusedCommentID: UUID?
    /// Show or hide every comment on the canvas (never changes the file).
    var showsComments = true
    /// Hide canvas comments the list's type/reviewer/status filters exclude.
    var filtersCanvas = false
    var stampDesign: StampDesign = StampDesign.standard[0] {
        didSet { (appState?.annotationService as? PDFKitAnnotationService)?.stampDesign = stampDesign }
    }
    let stamps = CustomStampLibrary()
    var isRecording = false
    var recordingStart: Date?
    var comparison: CommentComparison?
    var isWorking = false
    var statusMessage: String?
    /// Replaces the recorder/audio chooser prompt for tests.
    @ObservationIgnored var soundSource: (@MainActor () async -> URL?)?
    @ObservationIgnored var fileSource: (@MainActor () async -> URL?)?

    var styles: CommentToolStyles {
        (appState?.annotationService as? PDFKitAnnotationService)?.styles ?? .shared
    }

    /// The selection if it still belongs to the active document.
    func validSelection(in tab: DocumentTab?) -> CommentSelection? {
        guard let selection, let tab, let document = tab.pdfDocument,
              selection.annotation.page === selection.page, selection.page.document === document,
              selection.page.annotations.contains(where: { $0 === selection.annotation }) else { return nil }
        return selection
    }

    func flash(_ message: String) {
        statusMessage = message
        let current = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.statusMessage == current { self?.statusMessage = nil }
        }
    }
}

extension AppState {
    /// Comment tools state for this app state.
    var comments: CommentSession { CommentSession.of(self) }
}
