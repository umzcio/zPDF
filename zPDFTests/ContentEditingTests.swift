import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class ContentEditingTests: XCTestCase {
    private func paragraph() throws -> (url: URL, directory: URL) {
        try EditingFixtures.makePDF(named: "edit", lines: [
            .init(text: "The quick brown fox jumps over", origin: CGPoint(x: 72, y: 700)),
            .init(text: "the lazy dog near the river", origin: CGPoint(x: 72, y: 686)),
            .init(text: "bank on a sunny afternoon.", origin: CGPoint(x: 72, y: 672)),
            .init(text: "Footer text stays put", origin: CGPoint(x: 72, y: 100), size: 10),
        ], image: (CGRect(x: 350, y: 400, width: 120, height: 90), .blue))
    }

    func testEditParagraphInPlaceUndoSaveReopen() async throws {
        let (url, directory) = try paragraph()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        state.openTool(.editPDF)
        XCTAssertEqual(state.activePanel, .edit)
        let controller = state.contentEditing
        controller.activate(.edit)
        XCTAssertTrue(state.textEditingModeActive)
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let content = try await EditingFixtures.content(controller, page: page)
        let block = try XCTUnwrap(content.blocks.first { $0.text.hasPrefix("The quick") })
        XCTAssertEqual(block.text, "The quick brown fox jumps over the lazy dog near the river bank on a sunny afternoon.")
        XCTAssertEqual(block.lines.count, 3)

        controller.select(block: block, on: page, content: content)
        let key = try XCTUnwrap(block.runs.first?.fontKey)
        controller.commitBlock(block, on: page, runs: [["text": "A new sentence that is quite a bit longer than the original paragraph and therefore reflows onto more lines.",
                                                        "font": ["original": key], "size": block.size, "color": [0, 0, 0]]],
                               align: .left, lineSpacing: block.lineSpacing, width: nil, offset: nil, point: nil, digest: content.digest)
        try await EditingFixtures.idle(controller, tab)
        let edited = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.string)
        XCTAssertTrue(edited.contains("reflows onto"))
        XCTAssertFalse(edited.contains("quick brown"))
        XCTAssertTrue(edited.contains("Footer text stays put"))
        XCTAssertTrue(tab.hasUnsavedChanges)

        tab.undoHistory?.manager.undo()
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("quick brown") == true)
        tab.undoHistory?.manager.redo()
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("reflows onto") == true)

        try await TestSupport.save(state, tab)
        let saved = TestSupport.text(url)
        XCTAssertTrue(saved.contains("reflows onto"))
        XCTAssertFalse(saved.contains("quick brown"))
        let reopened = AppState()
        let tab2 = try await TestSupport.open(url, in: reopened)
        let page2 = try XCTUnwrap(tab2.pdfDocument?.page(at: 0))
        let content2 = try await EditingFixtures.content(reopened.contentEditing, page: page2)
        let newBlock = try XCTUnwrap(content2.blocks.first { $0.text.hasPrefix("A new sentence") })
        XCTAssertGreaterThan(newBlock.lines.count, 3, "Reflowed to the original width")
        XCTAssertLessThanOrEqual(newBlock.bbox.maxX, block.bbox.maxX + 1)
    }

    func testInlineEditorProducesStyledRuns() async throws {
        let (url, directory) = try paragraph()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let content = try await EditingFixtures.content(controller, page: page)
        let block = try XCTUnwrap(content.blocks.first { $0.text.hasPrefix("Footer") })
        let editor = InlineTextEditor(block: block, format: TextFormat(block: block), width: CGFloat(block.width), fixedWidth: false)
        XCTAssertEqual(editor.string, "Footer text stays put")
        XCTAssertTrue(editor.isContinuousSpellCheckingEnabled, "Spell checking while editing")
        var result = editor.result()
        XCTAssertFalse(result.changedText)
        XCTAssertFalse(result.changedStyle)
        XCTAssertEqual((result.runs.first?["font"] as? [String: Any])?["original"] as? String, block.runs.first?.fontKey)
        // Bold the word "Footer".
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        var format = editor.currentFormat()
        var bold = format
        bold.bold = true
        editor.apply(bold, previous: format)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" now", replacementRange: editor.selectedRange())
        result = editor.result()
        XCTAssertTrue(result.changedText)
        XCTAssertTrue(result.changedStyle)
        XCTAssertEqual(result.plainText, "Footer text stays put now")
        XCTAssertGreaterThanOrEqual(result.runs.count, 2)
        let first = try XCTUnwrap(result.runs.first?["font"] as? [String: Any])
        XCTAssertNil(first["original"], "A restyled run uses the new face")
        XCTAssertNotNil(first["path"])
        let last = try XCTUnwrap(result.runs.last?["font"] as? [String: Any])
        XCTAssertNotNil(last["original"], "Unchanged text keeps the document's font")
        format = editor.currentFormat()
        XCTAssertFalse(format.bold)

        // Commit through the controller and verify the page.
        controller.activate(.edit)
        controller.select(block: block, on: page, content: content)
        controller.commitBlock(block, on: page, runs: result.runs, align: result.alignment, lineSpacing: result.lineSpacing,
                               width: result.width, offset: result.offset, point: nil, digest: content.digest)
        try await EditingFixtures.idle(controller, tab)
        // The box keeps its width, so the longer text wraps onto a second line.
        func flat(_ text: String?) -> String { (text ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        XCTAssertTrue(flat(tab.pdfDocument?.page(at: 0)?.string).contains("Footer text stays put now"), tab.pdfDocument?.page(at: 0)?.string ?? "")
        try await TestSupport.save(state, tab)
        XCTAssertTrue(flat(TestSupport.text(url)).contains("Footer text stays put now"))
    }

    func testAddTextImageMoveDeleteAndArrange() async throws {
        let (url, directory) = try paragraph()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        controller.activate(.addText)
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        controller.commitBlock(nil, on: page, runs: [["text": "Added text box ✓", "font": ["family": "sans"], "size": 14, "color": [0.8, 0, 0]]],
                               align: .left, lineSpacing: 1.2, width: nil, offset: nil, point: CGPoint(x: 72, y: 500), digest: nil)
        try await EditingFixtures.idle(controller, tab)
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("Added text box ✓") == true)
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.annotations.filter { $0.type == "FreeText" }.count, 0, "Page content, not an annotation")

        // Add an image.
        let png = try EditingFixtures.pngFile(color: .green, size: CGSize(width: 40, height: 20), in: directory)
        controller.pendingImage = try controller.stageImage(png)
        controller.pendingImageSize = CGSize(width: 40, height: 20)
        controller.activate(.addImage)
        let livePage = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        controller.placeImage(on: livePage, rect: CGRect(x: 100, y: 200, width: 80, height: 40))
        try await EditingFixtures.idle(controller, tab)
        var current = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        var content = try await EditingFixtures.content(controller, page: current)
        XCTAssertEqual(content.objects.filter(\.kind.isImage).count, 2)
        let added = try XCTUnwrap(content.objects.first { $0.kind.isImage && abs($0.bbox.minX - 100) < 1 })

        // Move it by 50 pt and flip it.
        controller.tool = .edit
        controller.select(block: nil, objects: [added.id], on: current, content: content)
        controller.transformSelection(CGAffineTransform(translationX: 50, y: 10), name: "Move Object")
        try await EditingFixtures.idle(controller, tab)
        current = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        content = try await EditingFixtures.content(controller, page: current)
        let moved = try XCTUnwrap(content.objects.first { $0.kind.isImage && abs($0.bbox.minX - 150) < 1 })
        XCTAssertEqual(moved.bbox.minY, 210, accuracy: 1)
        XCTAssertEqual(controller.selection?.objects, [moved.id], "Selection follows the moved object")
        controller.flipSelection(horizontal: true)
        try await EditingFixtures.idle(controller, tab)

        // Send the original (blue) image to the back, then delete it.
        current = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        content = try await EditingFixtures.content(controller, page: current)
        let blue = try XCTUnwrap(content.objects.first { $0.kind.isImage && abs($0.bbox.minX - 350) < 1 })
        controller.select(block: nil, objects: [blue.id], on: current, content: content)
        controller.arrangeSelection(toFront: false)
        try await EditingFixtures.idle(controller, tab)
        current = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        content = try await EditingFixtures.content(controller, page: current)
        let blueAgain = try XCTUnwrap(content.objects.first { $0.kind.isImage && abs($0.bbox.minX - 350) < 1 })
        controller.select(block: nil, objects: [blueAgain.id], on: current, content: content)
        controller.deleteSelection()
        try await EditingFixtures.idle(controller, tab)
        current = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        content = try await EditingFixtures.content(controller, page: current)
        XCTAssertEqual(content.objects.filter(\.kind.isImage).count, 1)

        try await TestSupport.save(state, tab)
        let reopened = AppState()
        let tab2 = try await TestSupport.open(url, in: reopened)
        let content2 = try await EditingFixtures.content(reopened.contentEditing, page: try XCTUnwrap(tab2.pdfDocument?.page(at: 0)))
        XCTAssertEqual(content2.objects.filter(\.kind.isImage).count, 1)
        XCTAssertTrue(TestSupport.text(url).contains("Added text box ✓"))
    }

    func testLinksCropAndPageDesignSaveNatively() async throws {
        let (url, directory) = try paragraph()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        controller.activate(.link)
        controller.saveLink(LinkDraft(page: 0, rect: CGRect(x: 72, y: 690, width: 150, height: 20), target: .web("https://example.com/docs"), existing: nil))
        try await EditingFixtures.idle(controller, tab)
        controller.saveLink(LinkDraft(page: 0, rect: CGRect(x: 72, y: 90, width: 100, height: 20), target: .page(0), existing: nil))
        try await EditingFixtures.idle(controller, tab)
        let links = try await PageContentService.links(onSourcePage: 0, in: state, tab: tab)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first?.uri, "https://example.com/docs")
        // Edit, then remove the page link.
        controller.saveLink(LinkDraft(page: 0, rect: links[0].rect, target: .web("https://example.org"), existing: links[0]))
        try await EditingFixtures.idle(controller, tab)
        controller.removeLink(links[1], page: 0)
        try await EditingFixtures.idle(controller, tab)

        // Crop to a box.
        controller.activate(.crop)
        controller.cropRect = CGRect(x: 36, y: 36, width: 540, height: 720)
        controller.cropPage = 0
        controller.applyCrop(scope: .current)
        try await EditingFixtures.idle(controller, tab)
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 36, y: 36, width: 540, height: 720))

        // Header/footer, watermark, background and Bates with stored settings.
        try await state.applyDocumentTransform([
            ["op": "header_footer", "items": ["bottom-center": "Page <<page>> of <<pages>>"], "size": 9],
            ["op": "tag_overlay_settings", "kind": "HeaderFooter", "settings": ["fields": ["bottom-center": "Page <<page>> of <<pages>>"]]],
            ["op": "watermark", "text": "DRAFT", "opacity": 0.2],
            ["op": "background", "color": [255, 250, 230]],
            ["op": "bates", "prefix": "ZP", "start": 12, "digits": 5],
        ], to: tab, actionName: "Page Design")
        let design = try await state.queryDocument("page_design", in: tab)
        let header = try XCTUnwrap(design["HeaderFooter"] as? [String: Any])
        XCTAssertEqual(header["pages"] as? [Int], [0])
        XCTAssertNotNil(header["settings"] as? [String: Any])
        try await TestSupport.save(state, tab)

        let saved = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let text = saved.string ?? ""
        XCTAssertTrue(text.contains("Page 1 of 1"))
        XCTAssertTrue(text.contains("DRAFT"))
        XCTAssertTrue(text.contains("ZP00012"))
        XCTAssertEqual(saved.bounds(for: .cropBox), CGRect(x: 36, y: 36, width: 540, height: 720))
        let linkAnnotations = saved.annotations.filter { $0.type == "Link" }
        XCTAssertEqual(linkAnnotations.count, 1)
        XCTAssertEqual(linkAnnotations.first?.url?.absoluteString, "https://example.org")

        // Remove the watermark again.
        let state2 = AppState()
        let tab2 = try await TestSupport.open(url, in: state2)
        try await state2.applyDocumentTransform([["op": "remove_overlays", "kind": "Watermark"]], to: tab2, actionName: "Remove Watermark")
        try await TestSupport.save(state2, tab2)
        XCTAssertFalse(TestSupport.text(url).contains("DRAFT"))
        XCTAssertTrue(TestSupport.text(url).contains("ZP00012"))
    }

    func testFindAndReplaceInPageContent() async throws {
        let (url, directory) = try paragraph()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let controller = state.contentEditing
        controller.perform([["op": "replace_text", "find": "lazy dog", "replace": "sleepy cat", "match_case": false]], name: "Replace Text")
        try await EditingFixtures.idle(controller, tab)
        try await TestSupport.save(state, tab)
        let text = TestSupport.text(url)
        XCTAssertTrue(text.contains("the sleepy cat near the river"))
        XCTAssertFalse(text.contains("lazy"))
        let pdfium = try await EditingFixtures.pdfiumText(url)
        XCTAssertTrue(pdfium.contains("sleepy cat"))
    }

    func testCanvasToolsResetWithAppTools() async throws {
        let (url, directory) = try paragraph()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        _ = try await TestSupport.open(url, in: state)
        state.openTool(.editPDF)
        let controller = state.contentEditing
        controller.activate(.edit)
        XCTAssertTrue(controller.isActive || state.pdfViewStore.pdfView == nil)
        XCTAssertEqual(controller.tool, .edit)
        state.openTool(.comment)
        XCTAssertFalse(state.textEditingModeActive)
        XCTAssertNil(controller.tool, "Switching tools turns canvas editing off")
        state.openTool(.batesNumbering)
        XCTAssertEqual(state.activePanel, .edit)
        XCTAssertEqual(controller.designRequest, .bates)
    }

    func testPageScopeParsing() {
        XCTAssertEqual(EditPageScope.parse("1-3, 5", count: 10), [0, 1, 2, 4])
        XCTAssertEqual(EditPageScope.parse("8-", count: 10), [7, 8, 9])
        XCTAssertNil(EditPageScope.parse("0", count: 10))
        XCTAssertNil(EditPageScope.parse("4-2", count: 10))
        XCTAssertEqual(EditPageScope.all.pages(current: 0, count: 3), [0, 1, 2])
    }
}
