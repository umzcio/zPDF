//
//  EditPanel.swift
//  zPDF
//
//  Purpose: Edit PDF inspector — Format section + Content rows, wired to
//  the phase-4 content-editing seam (PDFEngine.textRuns/replaceTextRun).
//  The "Edit text & images" row toggles AppState.textEditingModeActive;
//  while active, clicking a text run on the canvas selects it
//  (AppState.selectedTextRun — see PDFViewRepresentable) and the Format
//  section edits its text: committing calls replaceTextRun, clears the
//  selection, bumps noteAnnotationsChanged(), and forces the PDFView to
//  re-render (PDFKit does not observe in-place content-stream rewrites).
//  Font name/size display the selected run read-only; color and B/I/U
//  are disabled placeholders — replaceTextRun only rewrites text, so run
//  re-styling is TODO(phase-4+). Object rows and the remaining Content
//  rows (add text/image, crop, header & footer, watermark) stay
//  TODO(phase-4+).
//

import SwiftUI

struct EditPanel: View {
    @Environment(AppState.self) private var appState

    /// Draft of the selected run's text; synced from the selection.
    @State private var draftText = ""
    /// Last replaceTextRun failure, shown under the editor.
    @State private var editError: String?
    /// Placeholder for the disabled color well (runs carry no color yet).
    @State private var textColor = Color.black

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            formatSection
            objectSection
            contentSection
            PanelNote("Turn on “Edit text & images”, click a text run on the page, edit its text above, then Apply.")
        }
        .onChange(of: appState.selectedTextRun) { _, newRun in
            draftText = newRun?.text ?? ""
            editError = nil
        }
    }

    // MARK: - Format

    private var formatSection: some View {
        PanelSection(title: "Format") {
            if let run = appState.selectedTextRun {
                textEditor(for: run)
            } else if appState.textEditingModeActive {
                PanelNote("Editing is on — click a text run on the page to edit it.")
            } else {
                PanelNote("Turn on “Edit text & images” below, then click a text run on the page.")
            }
            // Selected-run attributes, read-only display. TODO(phase-4+):
            // re-styling runs (font/size/color/B/I/U) needs an engine
            // entry point beyond replaceTextRun — no fake mutation here.
            HStack(spacing: 6) {
                attributeField(value: appState.selectedTextRun?.fontName ?? "—")
                attributeField(value: fontSizeText)
                    .frame(maxWidth: 70)
            }
            HStack(spacing: 6) {
                ColorPicker("Text color", selection: $textColor)
                    .labelsHidden()
                    .frame(width: 26, height: 26)
                    .disabled(true)
                FormatToggle(title: "Bold", symbolName: "bold", isOn: .constant(false))
                FormatToggle(title: "Italic", symbolName: "italic", isOn: .constant(false))
                FormatToggle(title: "Underline", symbolName: "underline", isOn: .constant(false))
            }
            .disabled(true)
            .opacity(0.6)
        }
    }

    private var fontSizeText: String {
        guard let run = appState.selectedTextRun else { return "—" }
        return String(format: "%g pt", Double(run.fontSize))
    }

    /// Read-only attribute display styled like the panel's other fields.
    private func attributeField(value: String) -> some View {
        Text(value)
            .font(.system(size: 11.5))
            .foregroundStyle(appState.selectedTextRun == nil
                             ? DesignTokens.Colors.mutedText
                             : DesignTokens.Colors.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(DesignTokens.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
            )
    }

    /// Multi-line editor for the selected run's text, panel-styled after
    /// CommentPanel's inline editor.
    private func textEditor(for run: EditableTextRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $draftText)
                .font(.system(size: 11))
                .frame(minHeight: 56, maxHeight: 120)
                .padding(2)
                .background(DesignTokens.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
                )
            if let editError {
                Text(editError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: 8) {
                Button("Apply") { commit(run) }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .buttonStyle(.plain)
                    .disabled(draftText == run.text)
                Button("Cancel") { appState.selectedTextRun = nil }
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    .buttonStyle(.plain)
            }
        }
    }

    /// Replace the selected run's text via the engine, then force the
    /// canvas to re-render the rewritten content stream.
    private func commit(_ run: EditableTextRun) {
        guard let document = appState.activeTab?.pdfDocument else { return }
        do {
            try appState.engine.replaceTextRun(run, with: draftText, in: document)
            appState.selectedTextRun = nil
            editError = nil
            appState.noteAnnotationsChanged()
            refreshCanvas()
        } catch {
            editError = error.localizedDescription
        }
    }

    /// PDFKit caches page renderings and does not observe in-place
    /// content-stream rewrites, so bounce the document to force a full
    /// re-render (layoutDocumentView + setNeedsDisplay is not enough).
    private func refreshCanvas() {
        guard let pdfView = appState.pdfViewStore.pdfView else { return }
        let document = pdfView.document
        pdfView.document = nil
        pdfView.document = document
    }

    // MARK: - Object

    private var objectSection: some View {
        PanelSection(title: "Object") {
            PanelRow(title: "Move", symbolName: "arrow.up.and.down.and.arrow.left.and.right") {
                // TODO(phase-4+): begin object-drag mode on the canvas.
            }
            PanelRow(title: "Resize", symbolName: "arrow.up.left.and.arrow.down.right") {
                // TODO(phase-4+): resize selected object.
            }
            PanelRow(title: "Rotate", symbolName: "rotate.right") {
                // TODO(phase-4+): rotate selected object.
            }
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        PanelSection(title: "Content") {
            PanelRow(title: "Edit text & images", symbolName: "square.and.pencil") {
                appState.toggleTextEditingMode()
            }
            .background(appState.textEditingModeActive
                        ? DesignTokens.Colors.accentTint
                        : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            PanelRow(title: "Add text", symbolName: "character") {
                // TODO(phase-4+): place a new text object at the click point.
            }
            PanelRow(title: "Add image", symbolName: "photo") {
                // TODO(phase-4+): image picker → embed XObject.
            }
            PanelRow(title: "Crop pages", symbolName: "crop") {
                // TODO(phase-4+): crop-box editing UI.
            }
            PanelRow(title: "Header & footer", symbolName: "doc") {
                // TODO(phase-4+): header/footer template sheet.
            }
            PanelRow(title: "Watermark", symbolName: "tag") {
                // TODO(phase-4+): watermark composer.
            }
        }
    }
}

private struct FormatToggle: View {
    let title: String
    let symbolName: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 11.5, weight: .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(isOn ? DesignTokens.Colors.accent : DesignTokens.Colors.text)
                .background(isOn ? DesignTokens.Colors.accentTint : DesignTokens.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

#Preview {
    ScrollView { EditPanel().padding() }
        .frame(width: DesignTokens.Layout.inspectorWidth)
        .environment(AppState())
}
