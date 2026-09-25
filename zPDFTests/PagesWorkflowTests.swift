import PDFKit
import XCTest
@testable import zPDF

/// Programmatic test inputs (no fixtures needed).
/// XCTAssertTrue for async results (XCTest's autoclosures can't await).
func check(_ value: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, message(), file: file, line: line)
}

func unwrap<T>(_ value: T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, message(), file: file, line: line)
}

@MainActor
enum WorkflowFactory {
    /// A PDF whose pages carry real text: one string per page.
    static func textPDF(_ pages: [String], at url: URL, size: CGSize = CGSize(width: 612, height: 792),
                        font: CGFloat = 28, outline: [String]? = nil) throws -> URL {
        var box = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: font), .foregroundColor: NSColor.black])
                .draw(with: CGRect(x: 60, y: 120, width: size.width - 120, height: size.height - 200),
                      options: [.usesLineFragmentOrigin])
            NSGraphicsContext.current = previous
            context.endPDFPage()
        }
        context.closePDF()
        if let outline {
            let document = try XCTUnwrap(PDFDocument(url: url))
            let root = PDFOutline()
            for (index, title) in outline.enumerated() {
                let item = PDFOutline()
                item.label = title
                item.destination = PDFDestination(page: try XCTUnwrap(document.page(at: index * 2)), at: CGPoint(x: 0, y: size.height))
                root.insertChild(item, at: index)
            }
            document.outlineRoot = root
            XCTAssertTrue(document.write(to: url))
        }
        return url
    }

    /// An image of rendered text, like a scan (PNG).
    static func textImage(_ text: String, at url: URL, size: CGSize = CGSize(width: 1700, height: 2200),
                          angle: CGFloat = 0) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: angle * .pi / 180)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            .draw(with: CGRect(x: 150, y: 300, width: size.width - 300, height: size.height - 600), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current = previous
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(ImageNormalizer.write(image, to: url, jpeg: url.pathExtension == "jpg", dpi: 200))
        return url
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zPDF workflow \(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
final class PagesWorkflowTests: XCTestCase {
    func testInsertBlankPdfAndImagePagesSaveReopenAndUndo() async throws {
        let (url, directory) = try TestSupport.fixture("uscis-i9", in: Self.self)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let before = tab.pageCount
        let fieldCount = PDFDocument(url: url)!.page(at: 0)!.annotations.filter { $0.type == "Widget" }.count

        check(await state.insertBlankPages(count: 2, size: PaperSize.a4.points, landscape: nil, at: 1, in: tab))
        XCTAssertEqual(tab.pageCount, before + 2)
        XCTAssertEqual(tab.pdfDocument?.page(at: 1)?.bounds(for: .mediaBox).width ?? 0, 595.28, accuracy: 0.5)
        XCTAssertEqual(try Data(contentsOf: url), original, "insertion never writes the user's file")

        // Same form inserted again: fields come along, namespaced, still fillable.
        let copy = directory.appendingPathComponent("second form.pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        check(await state.insertFiles([copy], pages: [0], at: 0, in: tab), state.saveError?.message ?? "")
        let image = try WorkflowFactory.textImage("Inserted image page", at: directory.appendingPathComponent("photo.png"))
        check(await state.insertFiles([image], at: tab.pageCount, in: tab), state.saveError?.message ?? "")
        XCTAssertEqual(tab.pageCount, before + 4)
        // Each insertion is one Undo step.
        let manager = try XCTUnwrap(tab.undoHistory?.manager)
        manager.undo()
        XCTAssertEqual(tab.pageCount, before + 3)
        manager.redo()
        XCTAssertEqual(tab.pageCount, before + 4)

        let inserted = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let widgets = inserted.annotations.filter { $0.type == "Widget" }
        XCTAssertEqual(widgets.count, fieldCount)
        XCTAssertTrue(widgets.contains { $0.fieldName?.hasPrefix("zpdf1_") == true })
        // Fill an imported field, then save and reopen.
        let text = try XCTUnwrap(widgets.first { $0.widgetFieldType == .text })
        text.widgetStringValue = "IMPORTED VALUE"
        state.refreshUnsavedChanges(tab)
        try await TestSupport.save(state, tab)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.pageCount, before + 4)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.fieldName == text.fieldName }?.widgetStringValue, "IMPORTED VALUE")
        XCTAssertEqual(reopened.page(at: reopened.pageCount - 1)?.bounds(for: .mediaBox).width ?? 0, 1700 * 72 / 200, accuracy: 1)
    }

    func testDuplicateReplaceRotateLabelsBoxesResizeTransitions() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try WorkflowFactory.textPDF(["ALPHA page", "BRAVO page", "CHARLIE page"], at: directory.appendingPathComponent("doc.pdf"))
        let replacement = try WorkflowFactory.textPDF(["REPLACEMENT page"], at: directory.appendingPathComponent("other.pdf"),
                                                      size: CGSize(width: 500, height: 500))
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)

        check(await state.duplicatePages([0], in: tab))
        XCTAssertEqual(tab.pageCount, 4)
        XCTAssertTrue(tab.pdfDocument?.page(at: 1)?.string?.contains("ALPHA") == true)
        check(await state.replacePages([3], with: replacement, sourcePages: [0], in: tab))
        XCTAssertTrue(tab.pdfDocument?.page(at: 3)?.string?.contains("REPLACEMENT") == true)
        check(await state.rotatePages(nil, by: 90, in: tab))
        XCTAssertEqual(tab.pdfDocument?.page(at: 2)?.rotation, 90)
        check(await state.setPageLabels([PageLabelRange(start: 0, style: .lowerRoman),
                                                 PageLabelRange(start: 2, style: .decimal, prefix: "A-")], in: tab))
        XCTAssertEqual(tab.pdfDocument?.page(at: 1)?.label, "ii")
        XCTAssertEqual(tab.pageLabel(at: 3), "A-2")
        XCTAssertEqual(tab.pageNumber(for: "A-1"), 3)
        check(await state.setPageBoxes(["CropBox": ["margins": [36, 36, 36, 36]]], pages: [0], in: tab))
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.bounds(for: .cropBox).width ?? 0, 540, accuracy: 0.5)
        check(await state.resizePages(to: PaperSize.a4.points!, mode: "scale", pages: [1], in: tab))
        XCTAssertEqual(tab.pdfDocument?.page(at: 1)?.bounds(for: .mediaBox).height ?? 0, 595.28, accuracy: 0.5,
                       "rotated page: A4 portrait visually means a landscape media box")
        check(await state.setTransitions(style: "Dissolve", duration: 1, direction: nil, advance: 4, pages: nil, in: tab))
        try await TestSupport.save(state, tab)

        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(saved.pageCount, 4)
        XCTAssertEqual(saved.page(at: 0)?.label, "i")
        XCTAssertEqual(saved.page(at: 3)?.label, "A-2")
        XCTAssertEqual(saved.page(at: 0)?.bounds(for: .cropBox).width ?? 0, 540, accuracy: 0.5)
        XCTAssertTrue(saved.page(at: 3)?.string?.contains("REPLACEMENT") == true)
        let transitions = try await NativeWorkflowBridge.queryFile(url, name: "page_transitions")
        let first = try XCTUnwrap((transitions["pages"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["style"] as? String, "Dissolve")
        XCTAssertEqual(first["advance"] as? Double, 4)
    }

    func testDragPageBetweenDocumentsCarriesUnsavedEdits() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try WorkflowFactory.textPDF(["SOURCE ONE", "SOURCE TWO"], at: directory.appendingPathComponent("a.pdf"))
        let b = try WorkflowFactory.textPDF(["TARGET ONE"], at: directory.appendingPathComponent("b.pdf"))
        let state = AppState()
        let source = try await TestSupport.open(a, in: state)
        let target = try await TestSupport.open(b, in: state)
        // An unsaved note on the dragged page must travel with it.
        let page = try XCTUnwrap(source.pdfDocument?.page(at: 1))
        let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 120, height: 60), forType: .square, withProperties: nil)
        note.color = .red
        note.contents = "Dragged note"
        page.addAnnotation(note)
        state.refreshUnsavedChanges(source)

        let token = state.beginPageDrag(at: 1, in: source)
        XCTAssertTrue(state.acceptsForeignPageDrag(into: target))
        XCTAssertFalse(state.acceptsForeignPageDrag(into: source))
        check(await state.dropForeignPage(token, at: 0, in: target), state.saveError?.message ?? "")
        XCTAssertEqual(target.pageCount, 2)
        XCTAssertTrue(target.pdfDocument?.page(at: 0)?.string?.contains("SOURCE TWO") == true)
        XCTAssertEqual(target.pdfDocument?.page(at: 0)?.annotations.first { $0.type == "Square" }?.contents, "Dragged note")
        XCTAssertEqual(source.pageCount, 2, "the source document is unchanged")
        try await TestSupport.save(state, target)
        XCTAssertEqual(PDFDocument(url: b)?.pageCount, 2)
    }

    func testSplitByBookmarksAndSize() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try WorkflowFactory.textPDF((1...6).map { "Chapter page \($0)" }, at: directory.appendingPathComponent("book.pdf"),
                                              outline: ["Intro", "Middle", "End"])
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let plan = SplitPlanner.bookmarkGroups(tab)
        XCTAssertEqual(plan.map(\.name), ["Intro", "Middle", "End"])
        XCTAssertEqual(plan.map(\.pages), [[0, 1], [2, 3], [4, 5]])
        let folder = directory.appendingPathComponent("parts")
        let ok = await state.splitDocument(tab, plan: plan, destination: SaveDestination(url: folder, overwrite: false)).value
        XCTAssertTrue(ok, state.saveError?.message ?? "")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["01 Intro.pdf", "02 Middle.pdf", "03 End.pdf"])
        XCTAssertTrue(TestSupport.text(folder.appendingPathComponent("02 Middle.pdf"), page: 1).contains("page 4"))
        let sized = try await state.queryDocument("split_by_size", params: ["max_bytes": 10_000], in: tab)
        XCTAssertGreaterThan((sized["groups"] as? [[Int]])?.count ?? 0, 1)
    }
}
