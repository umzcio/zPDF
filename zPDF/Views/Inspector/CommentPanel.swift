// Notes, highlights and underlines use the native Save path, including
// contents edits and deletion after reopening a saved document.

import SwiftUI

struct CommentPanel: View {
    var showsTools = true
    var showsComments = true
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            if showsTools { annotationGrid.disabled(appState.activeTab?.allowsSaveEdits != true) }
            if showsComments { commentsSection }
            if showsTools { PanelNote("Select text to highlight or underline it. Choose Sticky Note, then click the page. Edit or delete notes, highlights and underlines, then Save to keep your changes.") }
        }
    }

    private var annotationGrid: some View {
        PanelSection(title: "Add annotation") {
            PanelToolGrid {
                ForEach([AnnotationTool.highlight, .underline, .stickyNote]) { tool in
                    PanelToolButton(title: tool.name,
                                    symbolName: tool.symbolName,
                                    isActive: appState.armedAnnotationTool == tool) {
                        appState.toggleArmedAnnotationTool(tool)
                    }
                }
            }
        }
    }

    private var commentsSection: some View {
        Group {
            if let tab = appState.activeTab {
                // Subscribe to annotation mutations; the PDFDocument itself
                // is not observable, so AppState bumps this revision.
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

    var body: some View {
        @Bindable var tab = tab
        let visible = tab.commentReviewQuery.apply(to: comments, keepingVisible: drafts.editingIDs)
        PanelSection(title: "Comments (\(comments.count))") {
            if comments.isEmpty {
                Text("No comments yet")
                    .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
            } else {
                TextField("Search comments", text: $tab.commentReviewQuery.text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search comment text or author")
                    .help("Search comment text and author names")
                Picker("Type", selection: $tab.commentReviewQuery.kind) {
                    Text("All comments").tag(nil as CommentKind?)
                    ForEach(CommentKind.allCases) { kind in Text(kind.title).tag(Optional(kind)) }
                }
                .accessibilityLabel("Filter comments by type")
                Picker("Sort", selection: $tab.commentReviewQuery.sort) {
                    ForEach(CommentSortOrder.allCases) { order in Text(order.title).tag(order) }
                }
                .accessibilityLabel("Sort comments")
                if !drafts.editingIDs.isEmpty {
                    Text("Comments being edited stay visible until Apply or Cancel.")
                        .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                if visible.isEmpty {
                    Text("No matching comments")
                        .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                    Button("Clear Filters") { tab.commentReviewQuery.text = ""; tab.commentReviewQuery.kind = nil }
                } else {
                    if visible.count != comments.count {
                        Text("Showing \(visible.count) of \(comments.count)")
                            .font(.caption).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                    ForEach(visible) { comment in
                        let canEdit = tab.allowsSaveEdits && (tab.saveBaseline.map { $0.supportsComment(id: comment.id) } ?? false)
                        CommentRowView(comment: comment,
                                       onEdit: canEdit ? { target, text in
                                           appState.annotationService.updateComment(target, newText: text, in: tab)
                                           appState.noteAnnotationsChanged()
                                       } : nil,
                                       onDelete: canEdit ? { target in
                                           appState.annotationService.remove(comment: target, from: tab)
                                           appState.noteAnnotationsChanged()
                                       } : nil,
                                       editDraft: drafts.existingDraft(for: comment.id),
                                       onNavigate: { tab.goToPage(comment.pageIndex + 1) })
                    }
                }
            }
        }
        .onChange(of: comments.map(\.id), initial: true) { _, ids in drafts.retain(ids: Set(ids)) }
    }
}

/// One comment (plus nested replies), mirroring the prototype's .cmt rows.
/// The reply/edit/delete closures are nil in previews (no AppState there).
struct CommentRowView: View {
    let comment: Comment
    var depth: Int = 0
    var onReply: ((Comment, String) -> Void)? = nil
    var onEdit: ((Comment, String) -> Void)? = nil
    var onDelete: ((Comment) -> Void)? = nil

    @State private var isReplying = false
    @State private var replyText = ""
    var editDraft: CommentEditDraft? = nil
    var onNavigate: (() -> Void)? = nil
    @State private var fallbackDraft = CommentEditDraft()

    var body: some View {
        @Bindable var draft = editDraft ?? fallbackDraft
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(avatarColor)
                .frame(width: 24, height: 24)
                .overlay(
                    Text(comment.authorInitials)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(comment.author)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(comment.date == .distantPast ? "Date unavailable" : comment.date.formatted(.dateTime.month().day().hour().minute()))
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                }

                if let quotedText = comment.quotedText {
                    Text("“\(quotedText)”")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Colors.text)
                        .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
                        .background(DesignTokens.Colors.accentTint)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if draft.isEditing {
                    inlineEditor(text: $draft.text, submitTitle: "Apply") {
                        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        onEdit?(comment, text)
                        draft.isEditing = false
                    } cancel: {
                        onEdit?(comment, draft.originalText)
                        draft.isEditing = false
                    }
                } else if comment.text.isEmpty {
                    Text(onEdit != nil ? "No text yet" : "No comment text")
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                } else {
                    Text(comment.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignTokens.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let onNavigate {
                    Button("Page \(comment.pageIndex + 1)", action: onNavigate)
                        .font(.system(size: 11))
                        .help("Go to page \(comment.pageIndex + 1)")
                        .accessibilityLabel("Go to comment on page \(comment.pageIndex + 1)")
                }
                if onEdit != nil && !draft.isEditing {
                    Button("Edit comment") {
                        draft.begin(comment.text)
                    }
                    .font(.system(size: 11))
                    .help("Edit comment")
                    .accessibilityLabel("Edit comment by \(comment.author) on page \(comment.pageIndex + 1)")
                }
                if let onDelete {
                    Button("Delete comment", role: .destructive) { onDelete(comment) }
                        .font(.system(size: 11))
                        .help("Delete comment")
                        .accessibilityLabel("Delete comment by \(comment.author) on page \(comment.pageIndex + 1)")
                }
                if onReply != nil {
                Button("Reply") {
                    replyText = ""
                    isReplying.toggle()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(DesignTokens.Colors.accent)
                .buttonStyle(.plain)

                }

                if isReplying {
                    inlineEditor(text: $replyText, submitTitle: "Post") {
                        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            onReply?(comment, text)
                        }
                        isReplying = false
                    } cancel: {
                        isReplying = false
                    }
                }
            }
        }
        .onChange(of: draft.text) { _, text in
            if draft.isEditing { onEdit?(comment, text) }
        }
        .onChange(of: comment.text) { _, text in
            if draft.isEditing && draft.text != text { draft.text = text }
        }
        .padding(.leading, depth > 0 ? 18 : 0)
        .padding(.vertical, 4)
        .contextMenu {
            if onEdit != nil && !draft.isEditing {
                Button("Edit Comment…") {
                    draft.begin(comment.text)
                }
            }
            if let onDelete {
                Button("Delete Comment", role: .destructive) {
                    onDelete(comment)
                }
            }
        }

        ForEach(comment.replies) { reply in
            CommentRowView(comment: reply,
                           depth: depth + 1,
                           onReply: onReply,
                           onEdit: onEdit,
                           onDelete: onDelete)
        }
    }

    /// Small inline editor used for replies and text edits.
    private func inlineEditor(text: Binding<String>,
                              submitTitle: String,
                              submit: @escaping () -> Void,
                              cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Comment", text: text, axis: .vertical)
                .disabled(onEdit == nil && onReply == nil)
                .accessibilityLabel("Comment text")
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(submit)
            HStack(spacing: 8) {
                Button(submitTitle, action: submit)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .buttonStyle(.bordered)
                Button("Cancel", action: cancel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Deterministic avatar tint from the author's name.
    private var avatarColor: Color {
        let palette: [Color] = [
            Color(hex: 0x7C3AED), Color(hex: 0x0E7490),
            Color(hex: 0xB45309), Color(hex: 0x285DBC)
        ]
        let index = comment.author.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[index]
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
