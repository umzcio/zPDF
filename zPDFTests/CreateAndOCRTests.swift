import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class CreateAndOCRTests: XCTestCase {
    private func saveAs(_ state: AppState, _ tab: DocumentTab, to url: URL) async throws {
        let ok = await state.saveDocumentAs(tab, to: SaveDestination(url: url, overwrite: false)).value
        if !ok { XCTFail("Save As failed: \(state.saveError?.message ?? "unknown")") }
    }

    func testCreateFromMixedFilesOpensUntitledAndSaves() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try WorkflowFactory.textImage("Photo page", at: directory.appendingPathComponent("photo.jpg"))
        let rtf = directory.appendingPathComponent("letter.rtf")
        let styled = NSAttributedString(string: String(repeating: "Rich text paragraph for pagination. ", count: 400),
                                        attributes: [.font: NSFont(name: "Times New Roman", size: 14)!])
        try styled.data(from: NSRange(location: 0, length: styled.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        let text = directory.appendingPathComponent("notes.txt")
        try "Plain text notes".write(to: text, atomically: true, encoding: .utf8)
        let pdf = try WorkflowFactory.textPDF(["Existing PDF page"], at: directory.appendingPathComponent("existing.pdf"))
        let docx = directory.appendingPathComponent("memo.docx")
        let word = NSAttributedString(string: "Word document body", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        try word.data(from: NSRange(location: 0, length: word.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)

        let state = AppState()
        let tab = try unwrap(await state.createPDF(from: [photo, rtf, text, docx, pdf]), state.saveError?.message ?? "")
        XCTAssertTrue(tab.requiresSaveAs)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(tab.displayName, "Untitled.pdf")
        let document = try XCTUnwrap(tab.pdfDocument)
        XCTAssertGreaterThanOrEqual(document.pageCount, 5, "photo + multi-page RTF + text + PDF")
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Rich text paragraph") == true, "RTF keeps real text")
        XCTAssertTrue(document.page(at: document.pageCount - 1)?.string?.contains("Existing PDF page") == true)
        XCTAssertTrue(document.string?.contains("Plain text notes") == true)
        XCTAssertTrue(document.string?.contains("Word document body") == true, "DOCX converts with real text")

        let output = directory.appendingPathComponent("Created.pdf")
        try await saveAs(state, tab, to: output)
        XCTAssertFalse(tab.requiresSaveAs)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, document.pageCount)
    }

    func testCreateFromClipboardBlankWebAndPortfolio() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zpdf-test-\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("Clipboard words become a PDF", forType: .string)
        XCTAssertEqual(AppState.clipboardContentDescription(pasteboard), "text")
        let clip = try unwrap(await state.createPDFFromClipboard(pasteboard))
        XCTAssertTrue(clip.pdfDocument?.string?.contains("Clipboard words") == true)
        pasteboard.releaseGlobally()

        let blank = try unwrap(await state.createBlankPDF(pages: 3, size: CGSize(width: 792, height: 612)))
        XCTAssertEqual(blank.pageCount, 3)
        XCTAssertEqual(blank.pdfDocument?.page(at: 2)?.bounds(for: .mediaBox).width, 792)

        let html = directory.appendingPathComponent("page.html")
        try """
        <html><head><style>@media print { .screen { display: none } } p { font: 16px Helvetica }</style></head>
        <body><p class=screen>SCREEN ONLY</p><p>Printed web content</p>\(String(repeating: "<p>Line of web text</p>", count: 120))</body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let web = try unwrap(await state.createPDF(from: [html]), state.saveError?.message ?? "")
        let webText = web.pdfDocument?.string ?? ""
        XCTAssertTrue(webText.contains("Printed web content"))
        XCTAssertFalse(webText.contains("SCREEN ONLY"), "print CSS applies (paginated through the print system)")
        XCTAssertGreaterThan(web.pageCount, 1, "long pages paginate")

        let attachment = directory.appendingPathComponent("data.csv")
        try "a,b\n1,2\n".write(to: attachment, atomically: true, encoding: .utf8)
        let portfolio = try unwrap(await state.createPortfolio([attachment, html], title: "Case Files"))
        XCTAssertTrue(portfolio.pdfDocument?.string?.contains("Case Files") == true)
        let saved = directory.appendingPathComponent("Portfolio.pdf")
        try await saveAs(state, portfolio, to: saved)
        let files = try await NativeWorkflowBridge.queryFile(saved, name: "embedded_files")
        XCTAssertEqual(files["portfolio"] as? Bool, true)
        XCTAssertEqual((files["files"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["data.csv", "page.html"])
        let listed = try unwrap(await PortfolioInspector.files(in: portfolio, appState: state))
        XCTAssertTrue(listed.portfolio)
        XCTAssertEqual(listed.files.first?.size, 8)
    }

    func testImageNormalizerSplitsTIFFAndConvertsHEIC() throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try WorkflowFactory.textImage("Frame", at: directory.appendingPathComponent("frame.png"), size: CGSize(width: 400, height: 300))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil)), 0, nil))
        let tiff = directory.appendingPathComponent("pages.tiff")
        let tiffDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(tiff as CFURL, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(tiffDestination, image, nil)
        CGImageDestinationAddImage(tiffDestination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(tiffDestination))
        XCTAssertEqual(try ImageNormalizer.frames(of: tiff, into: directory).count, 2)
        XCTAssertEqual(try ImageNormalizer.frames(of: png, into: directory), [png], "upright PNG passes through")
        let heic = directory.appendingPathComponent("photo.heic")
        if let destination = CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) {
                XCTAssertEqual(try ImageNormalizer.frames(of: heic, into: directory).first?.pathExtension, "jpg")
            }
        }
    }

    func testContinuityCameraRequestorAcceptsImagesAndHandsOverPasteboard() throws {
        let view = ContinuityCameraHostView()
        XCTAssertTrue(view.validRequestor(forSendType: nil, returnType: .tiff) as AnyObject === view)
        XCTAssertTrue(view.validRequestor(forSendType: nil, returnType: .pdf) as AnyObject === view)
        XCTAssertFalse(view.validRequestor(forSendType: nil, returnType: .string) as AnyObject === view)
        var received: NSPasteboard?
        view.onImport = { received = $0 }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zpdf-continuity-\(UUID())"))
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertTrue(received === pasteboard)
        pasteboard.releaseGlobally()
    }

    func testCombineMixedFilesWithOpenDocument() async throws {
        let (url, directory) = try TestSupport.fixture("uscis-i9", in: Self.self)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let pages = tab.pageCount
        let image = try WorkflowFactory.textImage("Cover image", at: directory.appendingPathComponent("cover.png"))
        let output = directory.appendingPathComponent("combined.pdf")
        let ok = await state.combineMixed([.file(image), .tab(tab.id)], destination: SaveDestination(url: output, overwrite: false))
        check(ok, state.saveError?.message ?? "")
        let combined = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(combined.pageCount, pages + 1)
        XCTAssertFalse(combined.page(at: 1)?.annotations.filter { $0.type == "Widget" }.isEmpty ?? true, "form fields survive")
    }

    func testRecognizeTextMakesScanSearchableAndCorrectable() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scan = try WorkflowFactory.textImage("Invoice number 4821\nThe quick brown fox jumps", at: directory.appendingPathComponent("scan.png"),
                                                 angle: 1.5)
        let state = AppState()
        let created = try unwrap(await state.createPDF(from: [scan], name: "Scan"))
        let output = directory.appendingPathComponent("scan.pdf")
        try await saveAs(state, created, to: output)
        XCTAssertTrue(ScanDetector.looksScanned(try XCTUnwrap(created.pdfDocument)))
        state.closeTab(created)
        for _ in 0..<100 where !state.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        let tab = try await TestSupport.open(output, in: state)
        var options = OCROptions()
        options.deskew = true
        options.cleanBackground = true
        let session = OCRSession()
        let recognized = await state.recognizeText(in: tab, options: options, session: session)
        check(recognized, session.message ?? "")
        let text = tab.pdfDocument?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.localizedCaseInsensitiveContains("quick brown fox"), text)
        XCTAssertTrue(text.contains("4821"))
        // Word geometry: the selection for "fox" lies where the scan shows it (upper half of the page).
        let fox = try XCTUnwrap(tab.pdfDocument?.findString("fox", withOptions: .caseInsensitive).first)
        let bounds = fox.bounds(for: try XCTUnwrap(tab.pdfDocument?.page(at: 0)))
        XCTAssertGreaterThan(bounds.minY, 300)
        XCTAssertGreaterThan(bounds.width, 10)

        // Skip pages with text unless forced.
        let again = await state.recognizeText(in: tab, options: OCROptions(), session: session)
        XCTAssertFalse(again)
        XCTAssertEqual(session.skipped, [0])

        // Corrections rewrite the layer.
        let page = try XCTUnwrap(session.pages[0])
        let word = try XCTUnwrap(page.lines.flatMap(\.words).first { $0.text.localizedCaseInsensitiveContains("quick") })
        session.suspects = [OCRSuspect(id: word.id, page: 0,
                                       line: page.lines.firstIndex { $0.words.contains { $0.id == word.id } }!,
                                       word: page.lines.first { $0.words.contains { $0.id == word.id } }!.words.firstIndex { $0.id == word.id }!,
                                       text: word.text, reason: "test")]
        OCRSession.sessions[tab.id] = session
        check(await state.applyOCRCorrections([word.id: "speedy"], in: tab))
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("speedy") == true)

        try await TestSupport.save(state, tab)
        XCTAssertTrue(TestSupport.text(output).contains("speedy"))
        XCTAssertTrue(TestSupport.text(output).contains("4821"))
    }
}
