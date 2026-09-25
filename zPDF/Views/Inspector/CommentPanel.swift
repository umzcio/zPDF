//
//  CommentPanel.swift
//  zPDF
//
//  Purpose: The Comment tool panel (tools, appearance, stamps, review
//  tools) and the Comments list (threads with replies, status, checkmarks,
//  media, search/filter/sort). Every comment type saves natively.
//

import SwiftUI

struct CommentPanel: View {
    var showsTools = true
    var showsComments = true
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            if showsTools { tools }
            if showsComments { commentsSection }
        }
    }

    @ViewBuilder
    private var tools: some View {
        let editable = appState.canEditComments
        if let message = appState.comments.statusMessage {
            Label(message, systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(DesignTokens.Colors.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
                .accessibilityAddTraits(.updatesFrequently)
        }
        ForEach(CommentPanelGroup.allCases) { group in
            PanelSection(title: group.title) {
                CommentToolGrid(tools: group.tools)
            }
            .disabled(!editable)
        }
        contextual.disabled(!editable)
        CommentReviewTools()
        PanelNote(guidance)
    }

    @ViewBuilder
    private var contextual: some View {
        let tool = appState.armedAnnotationTool
        if tool == .stamp {
            StampPicker()
        }
        if let selection = appState.comments.validSelection(in: appState.activeTab) {
            let kind = CommentKind(pdfSubtype: selection.annotation.type).singular
            CommentPropertiesView(target: .selection(ObjectIdentifier(selection.annotation)), title: "Selected \(kind.lowercased())")
                .id(ObjectIdentifier(selection.annotation))
            HStack(spacing: 8) {
                Button {
                    appState.deleteSelectedComment()
                } label: {
                    Label("Delete", systemImage: "trash").font(.system(size: 11))
                }
                .help("Delete the selected comment and its replies (Delete)")
                Button {
                    appState.comments.selection = nil
                } label: {
                    Label("Deselect", systemImage: "xmark.circle").font(.system(size: 11))
                }
                .help("Deselect (Esc)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if let tool, tool.hasStyle {
            CommentPropertiesView(target: .tool(tool), title: "\(tool.name) appearance")
                .id(tool)
        }
    }

    private var guidance: String {
        switch appState.armedAnnotationTool {
        case .some(let tool) where tool == .polygon || tool == .polyline:
            return "\(tool.usage) Press Esc to cancel."
        case .some(let tool):
            return tool.usage + (appState.preferences.keepAnnotationToolSelected ? "" : " The tool turns off after one use; keep it on in Settings.")
        case nil:
            return "Choose a tool, then use it on the page. Click a comment to select it: drag to move, drag a handle to resize, press Delete to remove it, double-click to edit text. Save keeps every comment, reply and status in the PDF."
        }
    }

    private var commentsSection: some View {
        Group {
            if let tab = appState.activeTab {
                // PDFDocument is not observable; AppState bumps this revision.
                let _ = appState.annotationRevision
                let comments = appState.annotationService.comments(for: tab)
                CommentReviewList(tab: tab, comments: comments)
                    .id(tab.id)
            } else {
                PanelSection(title: "Comments") {
                    Text("Open a document to add comments.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
            }
        }
    }
}

private struct CommentReviewList: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    let comments: [Comment]
    private var drafts: CommentDraftStore { tab.commentDrafts }

    private var authors: [String] {
        Array(Set(comments.flatMap { thread in [thread.author] + thread.replies.map(\.author) }))
            .filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        @Bindable var tab = tab
        let visible = tab.commentReviewQuery.apply(to: comments, keepingVisible: drafts.editingIDs)
        let focused = appState.comments.focusedCommentID
        ScrollViewReader { proxy in
            PanelSection(title: "Comments (\(comments.count))") {
                if comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No comments yet")
                            .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                        Text("Open the Comment tool to highlight, draw, stamp or attach files.")
                            .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                        Button("Open Comment Tools") { appState.openTool(.comment) }
                            .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        TextField("Search comments", text: $tab.commentReviewQuery.text)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search comment text or author")
                            .help("Search comment text, replies and author names")
                        filterMenu(tab)
                        sortMenu(tab)
                    }
                    if tab.commentReviewQuery.isFiltering {
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .foregroundStyle(DesignTokens.Colors.accent)
                                .accessibilityHidden(true)
                            Text(filterSummary(tab.commentReviewQuery))
                                .font(.system(size: 11))
                                .lineLimit(2)
                            Spacer()
                            Button("Clear") { clearFilters(tab) }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                                .help("Show all comments")
                        }
                    }
                    if !drafts.editingIDs.isEmpty {
                        Text("Comments being edited stay visible until Apply or Cancel.")
                            .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    if visible.isEmpty {
                        Text("No matching comments")
                            .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                        Button("Clear Filters") { tab.commentReviewQuery.text = ""; clearFilters(tab) }
                    } else {
                        if visible.count != comments.count {
                            Text("Showing \(visible.count) of \(comments.count)")
                                .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(visible) { comment in
                                CommentRowView(comment: comment,
                                               onReply: tab.allowsSaveEdits ? { target, text in appState.replyToComment(target, text: text) } : nil,
                                               onEdit: tab.allowsSaveEdits ? { target, text, live in appState.editCommentText(target, text: text, live: live) } : nil,
                                               onDelete: tab.allowsSaveEdits ? { target in appState.deleteComment(target) } : nil,
                                               editDraft: drafts.existingDraft(for: comment.id),
                                               onNavigate: { appState.selectComment(comment) },
                                               focusedID: focused)
                                    .id(comment.id)
                                Divider().opacity(0.6)
                            }
                        }
                    }
                }
            }
            .onChange(of: focused) { _, id in
                guard let id, let root = comments.first(where: { $0.threadIDs.contains(id) }) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(root.id, anchor: .center) }
            }
        }
        .onChange(of: comments.map(\.id), initial: true) { _, ids in drafts.retain(ids: Set(ids)) }
        .onChange(of: tab.commentReviewQuery) { _, _ in
            if appState.comments.filtersCanvas { appState.refreshCommentVisibility() }
        }
    }

    private func clearFilters(_ tab: DocumentTab) {
        tab.commentReviewQuery.kind = nil
        tab.commentReviewQuery.author = nil
        tab.commentReviewQuery.status = nil
        tab.commentReviewQuery.marked = nil
    }

    private func filterSummary(_ query: CommentReviewQuery) -> String {
        var parts: [String] = []
        if let kind = query.kind { parts.append(kind.title) }
        if let author = query.author { parts.append("by \(author)") }
        if let status = query.status { parts.append(status == .none ? "no status" : status.title.lowercased()) }
        if let marked = query.marked { parts.append(marked ? "checked" : "unchecked") }
        return parts.joined(separator: ", ")
    }

    private func filterMenu(_ tab: DocumentTab) -> some View {
        @Bindable var tab = tab
        let kinds = CommentKind.allCases.filter { kind in comments.contains { $0.kind == kind } }
        return Menu {
            Picker("Type", selection: $tab.commentReviewQuery.kind) {
                Text("All types").tag(nil as CommentKind?)
                ForEach(kinds) { kind in Label(kind.title, systemImage: kind.symbolName).tag(Optional(kind)) }
            }
            Picker("Reviewer", selection: $tab.commentReviewQuery.author) {
                Text("All reviewers").tag(nil as String?)
                ForEach(authors, id: \.self) { author in Text(author).tag(Optional(author)) }
            }
            Picker("Status", selection: $tab.commentReviewQuery.status) {
                Text("Any status").tag(nil as CommentStatus?)
                ForEach(CommentStatus.allCases) { status in Label(status.title, systemImage: status.symbolName).tag(Optional(status)) }
            }
            Picker("Checkmark", selection: $tab.commentReviewQuery.marked) {
                Text("Checked or not").tag(nil as Bool?)
                Text("Checked").tag(Optional(true))
                Text("Unchecked").tag(Optional(false))
            }
            Divider()
            Button("Clear Filters") { clearFilters(tab) }.disabled(!tab.commentReviewQuery.isFiltering)
        } label: {
            Image(systemName: tab.commentReviewQuery.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type, reviewer, status or checkmark")
        .accessibilityLabel("Filter comments")
    }

    private func sortMenu(_ tab: DocumentTab) -> some View {
        @Bindable var tab = tab
        return Menu {
            Picker("Sort", selection: $tab.commentReviewQuery.sort) {
                ForEach(CommentSortOrder.allCases) { order in Text(order.title).tag(order) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort comments")
        .accessibilityLabel("Sort comments")
    }
}

/// One comment thread row (plus nested replies). Closures are nil in
/// previews and read-only documents.
struct CommentRowView: View {
    @Environment(AppState.self) private var appState: AppState?
    let comment: Comment
    var depth: Int = 0
    var onReply: ((Comment, String) -> Void)? = nil
    /// (comment, text, live) — live edits update the page as you type.
    var onEdit: ((Comment, String, Bool) -> Void)? = nil
    var onDelete: ((Comment) -> Void)? = nil
    var editDraft: CommentEditDraft? = nil
    var onNavigate: (() -> Void)? = nil
    var focusedID: UUID? = nil

    @State private var isReplying = false
    @State private var replyText = ""
    @State private var fallbackDraft = CommentEditDraft()
    @State private var hovering = false

    private var isFocused: Bool { focusedID == comment.id }

    var body: some View {
        @Bindable var draft = editDraft ?? fallbackDraft
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                typeBadge
                VStack(alignment: .leading, spacing: 3) {
                    header
                    if comment.status != .none {
                        Label(comment.status.title, systemImage: comment.status.symbolName)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(statusColor.opacity(0.12)))
                            .help(comment.statusAuthor.map { "\(comment.status.title) — set by \($0)" } ?? comment.status.title)
                    }
                    if let quotedText = comment.quotedText, !quotedText.isEmpty {
                        Text("“\(quotedText)”")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DesignTokens.Colors.text)
                            .lineLimit(4)
                            .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignTokens.Colors.accentTint)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .accessibilityLabel("Quoted text: \(quotedText)")
                    }
                    if draft.isEditing {
                        inlineEditor(text: $draft.text, submitTitle: "Apply") {
                            onEdit?(comment, draft.text.trimmingCharacters(in: .whitespacesAndNewlines), false)
                            draft.isEditing = false
                        } cancel: {
                            onEdit?(comment, draft.originalText, true)
                            draft.isEditing = false
                        }
                    } else if comment.text.isEmpty {
                        Text(onEdit != nil && depth == 0 ? placeholder : "No comment text")
                            .font(.system(size: 11.5)).italic()
                            .foregroundStyle(DesignTokens.Colors.mutedText)
                    } else {
                        Text(comment.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DesignTokens.Colors.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    media
                    actions(draft: draft)
                    if isReplying {
                        inlineEditor(text: $replyText, submitTitle: "Reply") {
                            let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { onReply?(comment, text) }
                            replyText = ""
                            isReplying = false
                        } cancel: {
                            replyText = ""
                            isReplying = false
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(isFocused ? DesignTokens.Colors.accentTint : (hovering ? DesignTokens.Colors.inset : Color.clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !draft.isEditing { onNavigate?() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(comment.kind.singular) by \(comment.author), page \(comment.pageIndex + 1)")
            .contextMenu { contextItems(draft: draft) }
            .onChange(of: draft.text) { _, text in
                if draft.isEditing { onEdit?(comment, text, true) }
            }
            .onChange(of: comment.text) { _, text in
                if draft.isEditing && draft.text != text { draft.text = text }
            }

            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comment.replies) { reply in
                        CommentRowView(comment: reply, depth: depth + 1, onReply: onReply, onEdit: onEdit, onDelete: onDelete,
                                       onNavigate: onNavigate, focusedID: focusedID)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DesignTokens.Colors.hairline).frame(width: 1).padding(.leading, 17).padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var placeholder: String {
        switch comment.kind {
        case .replaceText: "Type the replacement text"
        case .insertText: "Type the text to insert"
        default: "No text yet — double-click to add some"
        }
    }

    private var typeBadge: some View {
        let tint = CommentColor(hex: comment.colorHex).map { Color(nsColor: $0.nsColor) } ?? DesignTokens.Colors.accent
        return ZStack {
            Circle().fill(tint.opacity(0.18))
            Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1)
            Image(systemName: depth > 0 ? "arrowshape.turn.up.left.fill" : comment.kind.symbolName)
                .font(.system(size: depth > 0 ? 9 : 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.text)
        }
        .frame(width: depth > 0 ? 20 : 24, height: depth > 0 ? 20 : 24)
        .help(depth > 0 ? "Reply" : comment.kind.singular)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(comment.author.isEmpty ? "Unknown author" : comment.author)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Text(comment.date == .distantPast ? "" : comment.date.formatted(.dateTime.month().day().hour().minute()))
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if depth == 0 {
                Button {
                    appState?.setCommentMarked(!comment.isMarked, for: comment)
                } label: {
                    Image(systemName: comment.isMarked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(comment.isMarked ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onEdit == nil)
                .help(comment.isMarked ? "Remove checkmark" : "Add checkmark (marks the comment for your own tracking)")
                .accessibilityLabel(comment.isMarked ? "Checked" : "Not checked")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private var statusColor: Color {
        switch comment.status {
        case .accepted, .completed: DesignTokens.Colors.readyGreen
        case .rejected: .red
        case .cancelled: DesignTokens.Colors.mutedText
        case .none: DesignTokens.Colors.mutedText
        }
    }

    @ViewBuilder
    private var media: some View {
        if comment.kind == .attachment {
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(DesignTokens.Colors.mutedText).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(comment.attachmentName ?? "Attached file").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if let size = comment.attachmentSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                }
                Spacer(minLength: 4)
                iconButton("arrow.up.forward.app", help: "Open attachment", label: "Open attachment") { appState?.openAttachment(comment) }
                iconButton("square.and.arrow.down", help: "Save attachment…", label: "Save attachment") { appState?.saveAttachment(comment) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).fill(DesignTokens.Colors.inset))
        } else if comment.kind == .sound {
            HStack(spacing: 6) {
                iconButton("play.fill", help: "Play or stop the recording", label: "Play recording") { appState?.toggleSoundPlayback(comment) }
                Image(systemName: "waveform").foregroundStyle(DesignTokens.Colors.mutedText).accessibilityHidden(true)
                if let duration = comment.soundDuration {
                    Text(AVAudioDuration.format(duration)).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).fill(DesignTokens.Colors.inset))
        }
    }

    private func actions(draft: CommentEditDraft) -> some View {
        HStack(spacing: 2) {
            if onReply != nil {
                iconButton("arrowshape.turn.up.left", help: "Reply", label: "Reply to \(comment.author)") {
                    replyText = ""
                    isReplying.toggle()
                }
            }
            if depth == 0, onEdit != nil {
                Menu {
                    ForEach(CommentStatus.allCases) { status in
                        Button {
                            appState?.setCommentStatus(status, for: comment)
                        } label: {
                            if comment.status == status { Label(status.title, systemImage: "checkmark") } else { Text(status.title) }
                        }
                    }
                } label: {
                    Image(systemName: comment.status == .none ? "flag" : "flag.fill")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 24, height: 22)
                .help("Set status (Accepted, Rejected, Cancelled, Completed)")
                .accessibilityLabel("Set status")
            }
            if onEdit != nil && !draft.isEditing {
                iconButton("pencil", help: "Edit text", label: "Edit comment by \(comment.author)") { draft.begin(comment.text) }
            }
            if let onDelete {
                iconButton("trash", help: comment.replies.isEmpty ? "Delete comment" : "Delete comment and \(comment.totalReplyCount) repl\(comment.totalReplyCount == 1 ? "y" : "ies")",
                           label: "Delete comment by \(comment.author)") { onDelete(comment) }
            }
            Spacer(minLength: 4)
            if depth == 0, let onNavigate {
                Button("Page \(comment.pageIndex + 1)", action: onNavigate)
                    .buttonStyle(.link)
                    .font(.system(size: 10.5))
                    .help("Show on page \(comment.pageIndex + 1)")
                    .accessibilityLabel("Go to comment on page \(comment.pageIndex + 1)")
            }
        }
        .opacity(hovering || isFocused || isReplying ? 1 : 0.75)
    }

    @ViewBuilder
    private func contextItems(draft: CommentEditDraft) -> some View {
        if onEdit != nil && !draft.isEditing {
            Button("Edit Text…") { draft.begin(comment.text) }
        }
        if onReply != nil { Button("Reply") { isReplying = true } }
        if depth == 0, onEdit != nil {
            Menu("Set Status") {
                ForEach(CommentStatus.allCases) { status in
                    Button(status.title) { appState?.setCommentStatus(status, for: comment) }
                }
            }
            Button(comment.isMarked ? "Remove Checkmark" : "Add Checkmark") { appState?.setCommentMarked(!comment.isMarked, for: comment) }
        }
        if comment.kind == .attachment {
            Button("Open Attachment") { appState?.openAttachment(comment) }
            Button("Save Attachment…") { appState?.saveAttachment(comment) }
        }
        if comment.kind == .sound { Button("Play Sound") { appState?.toggleSoundPlayback(comment) } }
        if let onDelete {
            Divider()
            Button(comment.replies.isEmpty ? "Delete Comment" : "Delete Comment and Replies", role: .destructive) { onDelete(comment) }
        }
    }

    private func iconButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(DesignTokens.Colors.mutedText)
        .help(help)
        .accessibilityLabel(label)
    }

    /// Small inline editor used for replies and text edits.
    private func inlineEditor(text: Binding<String>, submitTitle: String,
                              submit: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(submitTitle == "Reply" ? "Write a reply" : "Comment", text: text, axis: .vertical)
                .lineLimit(1...8)
                .disabled(onEdit == nil && onReply == nil)
                .accessibilityLabel(submitTitle == "Reply" ? "Reply text" : "Comment text")
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .onSubmit(submit)
                .onExitCommand(perform: cancel)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: cancel)
                    .controlSize(.small)
                Button(submitTitle, action: submit)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.controlAccent)
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Comment.sampleData) { comment in
                CommentRowView(comment: comment)
            }
        }
        .padding()
    }
    .frame(width: DesignTokens.Layout.inspectorWidth)
}
