//
//  AppState+Comments.swift
//  zPDF
//
//  Purpose: Comment actions shared by the canvas, the Comment panel and the
//  menus. Every edit happens on the PDFKit display copy and becomes one
//  named Undo step; Save carries it natively. Whole-document operations
//  (import, flatten) are engine transforms; export/compare read a private
//  materialized revision, never the user's file.
//

import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
extension AppState {
    private var service: PDFKitAnnotationService? { annotationService as? PDFKitAnnotationService }

    var canEditComments: Bool { activeTab?.allowsSaveEdits == true }

    /// Records one named Undo step and refreshes dirty state and lists.
    func commitCommentEdit(_ name: String, in tab: DocumentTab? = nil) {
        guard let tab = tab ?? activeTab else { return }
        tab.undoHistory?.record(name: name)
        if activeTab === tab { noteAnnotationsChanged() } else { refreshUnsavedChanges(tab) }
        refreshCommentVisibility()
        pdfViewStore.pdfView.map { view in
            for index in 0..<(tab.pdfDocument?.pageCount ?? 0) {
                if let page = tab.pdfDocument?.page(at: index) { view.annotationsChanged(on: page) }
            }
        }
    }

    func redraw(_ page: PDFPage) {
        pdfViewStore.pdfView?.annotationsChanged(on: page)
    }

    // MARK: Tools

    func armCommentTool(_ tool: AnnotationTool) {
        guard canEditComments, commitFieldEditing() else { return }
        signatureService.disarmPlacement()
        toggleArmedAnnotationTool(tool)
        if armedAnnotationTool != nil { comments.selection = nil; comments.showsComments = true; refreshCommentVisibility() }
        if let view = pdfViewStore.pdfView { view.window?.makeFirstResponder(view) }
    }

    // MARK: Selection

    func selectComment(_ comment: Comment, reveal: Bool = true) {
        guard let tab = activeTab, let found = annotationService.annotation(for: comment, in: tab) else { return }
        comments.selection = CommentSelection(annotation: found.annotation, page: found.page)
        comments.focusedCommentID = comment.id
        guard reveal, let view = pdfViewStore.pdfView, let document = tab.pdfDocument else { return }
        let index = document.index(for: found.page)
        if index != NSNotFound { tab.goToPage(index + 1) }
        view.go(to: found.annotation.bounds.insetBy(dx: -40, dy: -40), on: found.page)
    }

    func selectedCommentForPanel() -> Comment? {
        guard let tab = activeTab, let selection = comments.validSelection(in: tab) else { return nil }
        return annotationService.comment(for: selection.annotation, in: tab)
    }

    func deleteSelectedComment() {
        guard canEditComments, let tab = activeTab, let selection = comments.validSelection(in: tab),
              let comment = annotationService.comment(for: selection.annotation, in: tab) else { return }
        comments.selection = nil
        annotationService.remove(comment: comment, from: tab)
        commitCommentEdit("Delete Comment", in: tab)
    }

    func deleteComment(_ comment: Comment) {
        guard canEditComments, let tab = activeTab else { return }
        if let selection = comments.selection, annotationService.comment(for: selection.annotation, in: tab)?.id == comment.id {
            comments.selection = nil
        }
        annotationService.remove(comment: comment, from: tab)
        commitCommentEdit(comment.replies.isEmpty ? "Delete Comment" : "Delete Comment Thread", in: tab)
    }

    func setCommentStatus(_ status: CommentStatus, for comment: Comment) {
        guard canEditComments, let tab = activeTab else { return }
        annotationService.setStatus(status, for: comment, in: tab)
        commitCommentEdit("Set Status", in: tab)
    }

    func setCommentMarked(_ marked: Bool, for comment: Comment) {
        guard canEditComments, let tab = activeTab else { return }
        annotationService.setMarked(marked, for: comment, in: tab)
        commitCommentEdit(marked ? "Mark Comment" : "Unmark Comment", in: tab)
    }

    func replyToComment(_ comment: Comment, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditComments, !text.isEmpty, let tab = activeTab else { return }
        annotationService.addReply(text, to: comment, in: tab)
        commitCommentEdit("Reply", in: tab)
    }

    func editCommentText(_ comment: Comment, text: String, live: Bool = false) {
        guard canEditComments, let tab = activeTab else { return }
        annotationService.updateComment(comment, newText: text, in: tab)
        if let found = annotationService.annotation(for: comment, in: tab) { redraw(found.page) }
        if live { refreshUnsavedChanges(tab); return }
        commitCommentEdit("Edit Comment", in: tab)
    }

    // MARK: Appearance

    /// Replaces a loaded annotation by an app-drawn equivalent when an edit
    /// would make PDFKit discard its appearance (clouds, callouts, polygons...).
    @discardableResult
    func prepareForEditing(_ selection: CommentSelection, cloudy: Bool = false) -> CommentSelection {
        let annotation = selection.annotation
        let wantsDrawing = CommentRehydration.needsAppDrawing(annotation)
            || (cloudy && ["Square", "Polygon"].contains(annotation.type ?? "") && !(annotation is CommentAnnotation))
        guard wantsDrawing, let replacement = CommentRehydration.rehydrate(annotation) else { return selection }
        // Same comment identity (list row, replies) for the stand-in.
        if let service {
            replacement.setValue(service.commentID(for: annotation).uuidString, forAnnotationKey: PDFKitAnnotationService.commentIDKey)
        }
        let page = selection.page
        page.removeAnnotation(annotation)
        page.addAnnotation(replacement)
        let updated = CommentSelection(annotation: replacement, page: page)
        if comments.selection?.annotation === annotation { comments.selection = updated }
        return updated
    }

    /// Applies a style to one comment annotation (one Undo step).
    func applyCommentStyle(_ style: CommentStyle, to original: CommentSelection, commit: Bool = true) {
        guard canEditComments else { return }
        let selection = prepareForEditing(original, cloudy: style.lineStyle == .cloudy)
        let annotation = selection.annotation
        if let drawn = annotation as? CommentAnnotation {
            var design = drawn.design
            design.style = style
            drawn.design = design
        } else {
            CommentStyleApplier.apply(style, to: annotation)
        }
        annotation.modificationDate = Date()
        redraw(selection.page)
        if commit { commitCommentEdit("Change Appearance") }
    }

    /// After text markup is applied: reveal it; Replace Text types its new text.
    func didCreateMarkup(_ created: [PDFAnnotation], tool: AnnotationTool, in tab: DocumentTab) {
        guard let first = created.first else { return }
        comments.focusedCommentID = annotationService.commentID(for: first)
        if tool == .replaceText, first.type == "Caret" { comments.canvas.beginEditing(first, isNew: true) }
    }

    // MARK: Media

    /// File Attachment tool: choose a file, embed it as a comment at `point`.
    func attachFileComment(at point: CGPoint, onPage pageIndex: Int) async {
        guard canEditComments, let tab = activeTab else { return }
        let chosen: URL?
        if let source = comments.fileSource { chosen = await source() }
        else {
            let panel = NSOpenPanel()
            panel.title = "Attach File"
            panel.prompt = "Attach"
            panel.message = "The file is embedded in the PDF as a comment."
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            chosen = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        guard let chosen else { return }
        do {
            let copy = try CommentMedia.shared.importFile(chosen)
            guard let annotation = annotationService.addAnnotation(.attachFile, at: point, onPage: pageIndex, in: tab) as? CommentAnnotation else { return }
            CommentMedia.shared.attach(file: copy, name: chosen.lastPathComponent, to: annotation)
            annotation.contents = chosen.lastPathComponent
            finishPlacement(annotation, in: tab, name: "Attach File")
        } catch {
            saveError = OpenError(fileName: chosen.lastPathComponent, message: "The file could not be attached. \(error.localizedDescription)")
        }
    }

    /// Sound tool: record (or choose) audio, embed it as a comment at `point`.
    func addSoundComment(from wav: URL, at point: CGPoint, onPage pageIndex: Int) {
        guard canEditComments, let tab = activeTab,
              let annotation = annotationService.addAnnotation(.sound, at: point, onPage: pageIndex, in: tab) as? CommentAnnotation else { return }
        CommentMedia.shared.attach(sound: wav, to: annotation)
        if let duration = try? AVAudioDuration.seconds(of: wav) {
            annotation.contents = "Recording (\(AVAudioDuration.format(duration)))"
        }
        finishPlacement(annotation, in: tab, name: "Add Sound")
    }

    func chooseSoundFile() async -> URL? {
        if let source = comments.soundSource { return await source() }
        let panel = NSOpenPanel()
        panel.title = "Choose Audio"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        guard await withCheckedContinuation({ continuation in panel.begin { continuation.resume(returning: $0 == .OK) } }),
              let url = panel.url else { return nil }
        do { return try CommentMedia.shared.normalizedWAV(from: url) }
        catch {
            saveError = OpenError(fileName: url.lastPathComponent, message: "That audio can't be used for a sound comment. \(error.localizedDescription)")
            return nil
        }
    }

    func finishPlacement(_ annotation: PDFAnnotation, in tab: DocumentTab, name: String) {
        if !preferences.keepAnnotationToolSelected { armedAnnotationTool = nil }
        if let page = annotation.page {
            comments.selection = CommentSelection(annotation: annotation, page: page)
        }
        comments.focusedCommentID = annotationService.commentID(for: annotation)
        commitCommentEdit(name, in: tab)
    }

    /// Bytes and name of a file-attachment comment (pending or saved).
    func attachmentData(for annotation: PDFAnnotation, in tab: DocumentTab) -> (name: String, data: Data)? {
        if let pending = CommentMediaLink.pendingFile(of: annotation), let data = try? Data(contentsOf: pending.url) {
            return (pending.name, data)
        }
        let original = AnnotationReplacement.original(of: annotation) ?? annotation
        guard let baseline = tab.saveBaseline else { return nil }
        return CommentFileInfo.attachment(of: original, baseline: baseline)
    }

    func openAttachment(_ comment: Comment) {
        guard let tab = activeTab, let found = annotationService.annotation(for: comment, in: tab),
              let file = attachmentData(for: found.annotation, in: tab) else {
            comments.flash("This attachment's data isn't available.")
            return
        }
        let folder = CommentMedia.shared.directory.appendingPathComponent("open-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(Self.safeFileName(file.name))
            try file.data.write(to: url, options: .atomic)
            // Open a read-only temporary copy; the PDF keeps the original.
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            saveError = OpenError(fileName: file.name, message: error.localizedDescription)
        }
    }

    func saveAttachment(_ comment: Comment) {
        guard let tab = activeTab, let found = annotationService.annotation(for: comment, in: tab),
              let file = attachmentData(for: found.annotation, in: tab) else {
            comments.flash("This attachment's data isn't available.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = Self.safeFileName(file.name)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do { try file.data.write(to: url, options: .atomic) }
                catch { self?.saveError = OpenError(fileName: file.name, message: error.localizedDescription) }
            }
        }
    }

    func toggleSoundPlayback(_ comment: Comment) {
        guard let tab = activeTab, let found = annotationService.annotation(for: comment, in: tab) else { return }
        let id = ObjectIdentifier(found.annotation)
        if CommentMedia.shared.isPlaying(id) { CommentMedia.shared.stopPlayback(); comments.flash("Stopped."); return }
        let wav: Data?
        if let pending = CommentMediaLink.pendingFile(of: found.annotation) { wav = try? Data(contentsOf: pending.url) }
        else if let baseline = tab.saveBaseline {
            wav = CommentFileInfo.soundWAV(of: AnnotationReplacement.original(of: found.annotation) ?? found.annotation, baseline: baseline)
        } else { wav = nil }
        guard let wav else { comments.flash("This recording uses an encoding zPDF can't play."); return }
        do { try CommentMedia.shared.play(wav, id: id); comments.flash("Playing…") }
        catch { comments.flash("This recording couldn't be played.") }
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Attachment" + cleaned : cleaned
    }

    // MARK: Visibility

    /// Applies Hide All and the on-page filters. Presentation only.
    func refreshCommentVisibility() {
        guard let tab = activeTab, let document = tab.pdfDocument else { return }
        let session = comments
        var allowed: Set<UUID>?
        if session.showsComments && session.filtersCanvas && tab.commentReviewQuery.isFiltering {
            let roots = annotationService.comments(for: tab).filter { tab.commentReviewQuery.passesFilters($0) }
            allowed = Set(roots.flatMap(\.threadIDs))
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var changed = false
            for annotation in page.annotations where PDFKitAnnotationService.isListed(annotation) {
                let visible: Bool
                if !session.showsComments { visible = false }
                else if let allowed { visible = allowed.contains(annotationService.commentID(for: annotation)) }
                else { visible = true }
                if !visible && !CommentVisibility.isHidden(annotation) { CommentVisibility.hide(annotation); changed = true }
                if visible && CommentVisibility.isHidden(annotation) { CommentVisibility.reveal(annotation); changed = true }
            }
            if changed { redraw(page) }
        }
    }

    func setCommentsVisible(_ visible: Bool) {
        comments.showsComments = visible
        if !visible { comments.selection = nil }
        refreshCommentVisibility()
        comments.flash(visible ? "Comments are shown on the page." : "Comments are hidden on the page. They are still in the document.")
    }

    // MARK: Whole-document operations

    /// The current revision with pending edits applied, for export/compare.
    private func materializedRevision(of tab: DocumentTab) async throws -> NativeTransformOutput {
        guard let source = tab.editSource, let baseline = tab.saveBaseline, let document = tab.pdfDocument else {
            throw NativeSaveError(code: "NOT_EDITABLE", message: "This document isn't ready yet.")
        }
        guard commitFieldEditing() else { throw NativeSaveError(code: "BUSY", message: "Finish editing the current field first.") }
        let changes = try baseline.changes(in: document)
        return try await NativeDocumentBridge.transform(source: source.url, hash: source.hash, changes: changes,
                                                        ops: NativeOps([["op": "finalize"]]))
    }

    func exportComments(format: String, to destination: URL? = nil) async -> Bool {
        guard let tab = activeTab else { return false }
        let ext = format == "fdf" ? "fdf" : "xfdf"
        let target: URL
        if let destination { target = destination }
        else {
            let panel = NSSavePanel()
            panel.title = "Export Comments"
            panel.message = format == "fdf" ? "FDF keeps every comment's exact appearance." : "XFDF is an XML format most PDF apps can import."
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
            panel.nameFieldStringValue = (tab.displayName as NSString).deletingPathExtension + " comments.\(ext)"
            panel.directoryURL = tab.url?.deletingLastPathComponent()
            guard await withCheckedContinuation({ continuation in panel.begin { continuation.resume(returning: $0 == .OK) } }),
                  let url = panel.url else { return false }
            target = url
        }
        comments.isWorking = true
        defer { comments.isWorking = false }
        do {
            let revision = try await materializedRevision(of: tab)
            let result = try await NativeDocumentBridge.query(source: revision.url, hash: revision.hash, name: "export_comments",
                                                              params: NativeJSON(value: ["format": format, "file_name": tab.displayName]))
            let value = result.value
            let data: Data
            if format == "fdf", let encoded = value["data"] as? String, let decoded = Data(base64Encoded: encoded) { data = decoded }
            else if let text = value["text"] as? String { data = Data(text.utf8) }
            else { throw NativeSaveError(code: "EXPORT_FAILED", message: "The comments could not be exported.") }
            let access = target.startAccessingSecurityScopedResource()
            defer { if access { target.stopAccessingSecurityScopedResource() } }
            try data.write(to: target, options: .atomic)
            let count = value["count"] as? Int ?? 0
            comments.flash("Exported \(count) comment\(count == 1 ? "" : "s") to \(target.lastPathComponent).")
            return true
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return false
        }
    }

    /// Import comments from FDF, XFDF or another PDF (one Undo step).
    func importComments(from source: URL? = nil) async -> Bool {
        guard canEditComments, let tab = activeTab else { return false }
        let chosen: URL
        if let source { chosen = source }
        else {
            let panel = NSOpenPanel()
            panel.title = "Import Comments"
            panel.message = "Choose an FDF or XFDF comments file, or a PDF whose comments you want to copy."
            panel.allowedContentTypes = [.pdf] + ["fdf", "xfdf"].compactMap { UTType(filenameExtension: $0) }
            panel.canChooseDirectories = false
            guard await withCheckedContinuation({ continuation in panel.begin { continuation.resume(returning: $0 == .OK) } }),
                  let url = panel.url else { return false }
            chosen = url
        }
        comments.isWorking = true
        defer { comments.isWorking = false }
        do {
            let copy = try CommentMedia.shared.importFile(chosen)
            let results = try await applyDocumentTransform([["op": "import_comments", "path": copy.path]], to: tab, actionName: "Import Comments")
            let value = results.first?.value ?? [:]
            let added = value["added"] as? Int ?? 0, skipped = value["skipped"] as? Int ?? 0
            comments.flash(added == 0 ? "No new comments were found in \(chosen.lastPathComponent)."
                           : "Imported \(added) comment\(added == 1 ? "" : "s")" + (skipped > 0 ? " (\(skipped) already present)." : "."))
            return true
        } catch {
            saveError = OpenError(fileName: chosen.lastPathComponent, message: error.localizedDescription)
            return false
        }
    }

    /// Compare this document's comments with another version of the PDF.
    func compareComments(with other: URL? = nil) async {
        guard let tab = activeTab else { return }
        let chosen: URL
        if let other { chosen = other }
        else {
            let panel = NSOpenPanel()
            panel.title = "Compare Comments"
            panel.message = "Choose an earlier or later version of this PDF."
            panel.allowedContentTypes = [.pdf]
            guard await withCheckedContinuation({ continuation in panel.begin { continuation.resume(returning: $0 == .OK) } }),
                  let url = panel.url else { return }
            chosen = url
        }
        comments.isWorking = true
        defer { comments.isWorking = false }
        do {
            let copy = try CommentMedia.shared.importFile(chosen)
            let revision = try await materializedRevision(of: tab)
            let result = try await NativeDocumentBridge.query(source: revision.url, hash: revision.hash, name: "compare_comments",
                                                              params: NativeJSON(value: ["other": copy.path]))
            let value = result.value
            func items(_ key: String) -> [CommentComparison.Item] {
                (value[key] as? [[String: Any]] ?? []).map { entry in
                    let before = (entry["before"] as? [String: Any])?.compactMap { key, value -> String? in
                        guard let text = value as? String, !text.isEmpty else { return nil }
                        return "\(key): \(text)"
                    }.sorted().joined(separator: "; ")
                    return .init(page: entry["page"] as? Int ?? 0, subtype: entry["subtype"] as? String ?? "",
                                 author: entry["author"] as? String ?? "", contents: entry["contents"] as? String ?? "",
                                 changes: entry["changes"] as? [String] ?? [], before: before?.isEmpty == false ? before : nil)
                }
            }
            comments.comparison = CommentComparison(otherName: chosen.lastPathComponent, added: items("added"), removed: items("removed"),
                                                    changed: items("changed"), unchanged: value["unchanged"] as? Int ?? 0)
        } catch {
            saveError = OpenError(fileName: chosen.lastPathComponent, message: error.localizedDescription)
        }
    }

    /// Draw comments into the page content (Undo-able; Save makes it permanent).
    func flattenComments(confirm: Bool = true) async -> Bool {
        guard canEditComments, let tab = activeTab else { return false }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Flatten comments in “\(tab.displayName)”?"
            alert.informativeText = "Comments become part of the page and can no longer be edited, replied to or listed. Replies and hidden comments are removed. You can undo this until you close the document."
            alert.addButton(withTitle: "Flatten")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        comments.selection = nil
        do {
            let results = try await applyDocumentTransform([["op": "flatten_annotations"]], to: tab, actionName: "Flatten Comments")
            let count = results.first?["flattened"] as? Int ?? 0
            comments.flash("Flattened \(count) comment\(count == 1 ? "" : "s").")
            return true
        } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return false
        }
    }

    /// Summary of comments as a new PDF (saved or printed).
    func summarizeComments(print: Bool) {
        guard let tab = activeTab, let document = tab.pdfDocument else { return }
        let list = annotationService.comments(for: tab)
        guard !list.isEmpty else { comments.flash("There are no comments to summarize."); return }
        let data = CommentSummary.render(title: tab.displayName, document: document, comments: list)
        if print {
            guard let summary = PDFDocument(data: data),
                  let operation = summary.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
            operation.jobTitle = "Comments on \(tab.displayName)"
            operation.showsPrintPanel = true
            operation.run()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Summarize Comments"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (tab.displayName as NSString).deletingPathExtension + " comment summary.pdf"
        panel.directoryURL = tab.url?.deletingLastPathComponent()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self?.comments.flash("Saved the comment summary as \(url.lastPathComponent).")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { self?.saveError = OpenError(fileName: url.lastPathComponent, message: error.localizedDescription) }
            }
        }
    }
}

/// Style edits on annotations PDFKit draws itself.
enum CommentStyleApplier {
    static func apply(_ style: CommentStyle, to annotation: PDFAnnotation) {
        let alpha = CGFloat(max(0.05, min(1, style.opacity)))
        switch annotation.type {
        case "FreeText":
            annotation.font = style.font
            annotation.fontColor = style.textColor.nsColor.withAlphaComponent(alpha)
            annotation.color = (style.fill?.nsColor ?? .clear).withAlphaComponent(style.fill == nil ? 0 : alpha)
        case "Highlight":
            annotation.color = style.color.nsColor
        default:
            annotation.color = style.color.nsColor.withAlphaComponent(alpha)
        }
        if ["Square", "Circle", "Line", "Polygon", "PolyLine"].contains(annotation.type ?? "") {
            annotation.interiorColor = style.fill?.nsColor.withAlphaComponent(alpha)
        }
        if ["Square", "Circle", "Line", "Ink", "FreeText", "Polygon", "PolyLine"].contains(annotation.type ?? "") {
            let border = PDFBorder()
            border.lineWidth = CGFloat(style.lineWidth)
            if style.lineStyle == .dashed { border.style = .dashed; border.dashPattern = style.dashPattern }
            annotation.border = border
            if annotation.type == "Ink", let paths = annotation.paths {
                for path in paths {
                    let copy = path.copy() as! NSBezierPath
                    copy.lineWidth = CGFloat(style.lineWidth)
                    annotation.remove(path)
                    annotation.add(copy)
                }
            }
        }
        if annotation.type == "Line" {
            annotation.startLineStyle = style.startEnding.pdfKitStyle
            annotation.endLineStyle = style.endEnding.pdfKitStyle
        }
        CommentSpec.set(["opacity": style.opacity], on: annotation)
    }
}

enum AVAudioDuration {
    static func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / max(1, file.processingFormat.sampleRate)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
