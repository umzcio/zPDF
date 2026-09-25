import AppKit
import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class ExporterIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-worker-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func source(_ name: String = "uscis-i9") throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pdf"))
    }
    private func zip(_ entry: String, _ url: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]; process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
    private func convert(_ input: URL, _ format: ConversionFormat, _ target: URL,
                         mode: String = "preserve", overwrite: Bool = false) async throws -> ConversionResult {
        try await ExportWorkerBridge.export(input: input,
            options: .init(format: format, pages: IndexSet(integer: 0), layoutMode: mode),
            destination: .init(url: target, overwrite: overwrite), cancellation: ConversionCancellation()) { _, _, _ in }
    }

    func testBundledFormatsAndMarkdownAssets() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let input = try source(), original = try Data(contentsOf: input)
        for format in [ConversionFormat.docx, .xlsx, .html, .markdown] {
            let output = folder.appendingPathComponent("Reader ü test.\(format.fileExtension)")
            let result = try await convert(input, format, output)
            XCTAssertGreaterThan(result.byteCount, 100)
            switch format {
            case .docx:
                let xml = try zip("word/document.xml", output)
                XCTAssertTrue(xml.contains("Employment")); XCTAssertTrue(xml.contains("Eligibility"))
                XCTAssertTrue(try zip("word/_rels/document.xml.rels", output).contains("image"))
            case .xlsx:
                XCTAssertTrue(try zip("xl/workbook.xml", output).contains("sheet"))
                XCTAssertFalse(try zip("xl/worksheets/*.xml", output).contains("<f>"))
            case .html:
                let text = try String(contentsOf: output, encoding: .utf8)
                XCTAssertTrue(text.contains("Employment")); XCTAssertFalse(text.contains("<script"))
                XCTAssertTrue(text.contains("data:image/"))
            case .markdown:
                let text = try String(contentsOf: output, encoding: .utf8)
                XCTAssertTrue(text.contains("Employment")); XCTAssertFalse(text.contains("data:image/"))
                XCTAssertGreaterThan(result.fileCount, 1)
                XCTAssertTrue(result.notices.contains { $0.code == "MD_FORMATTING_NOT_KEPT" })
                let folders = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("_images_") }
                XCTAssertEqual(folders.count, 1)
                XCTAssertTrue(text.contains(folders[0].lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folders[0].path).count, result.fileCount - 1)
            default: XCTFail("Unexpected format")
            }
        }
        let responsive = folder.appendingPathComponent("responsive.html")
        _ = try await convert(input, .html, responsive, mode: "reflow")
        XCTAssertTrue(try String(contentsOf: responsive, encoding: .utf8).contains("Employment"))
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-export-reader-evidence/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: evidence)
        print("Reader evidence:", evidence.path)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".zpdf-export-") })
    }

    func testPowerPointRTFXMLAndEPUBThroughBundledWorker() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let input = try source(), original = try Data(contentsOf: input)
        for mode in ["editable", "page_image"] {
            let deck = folder.appendingPathComponent("Deck-\(mode).pptx")
            let result = try await ExportWorkerBridge.export(input: input,
                options: .init(format: .pptx, pages: IndexSet([0, 1]), pptxMode: mode),
                destination: .init(url: deck, overwrite: false), cancellation: ConversionCancellation()) { _, _, _ in }
            XCTAssertGreaterThan(result.byteCount, 1000)
            XCTAssertTrue(try zip("ppt/presentation.xml", deck).contains("sldId"))
            XCTAssertTrue(try zip("ppt/slides/slide1.xml", deck).contains("Employment"), "slide text is editable (\(mode))")
        }
        let rtf = folder.appendingPathComponent("Doc.rtf")
        let rtfResult = try await convert(input, .rtf, rtf)
        let rtfText = try String(contentsOf: rtf, encoding: .ascii)
        XCTAssertTrue(rtfText.hasPrefix("{\\rtf1")); XCTAssertTrue(rtfText.contains("Employment"))
        XCTAssertTrue(rtfResult.notices.contains { $0.code == "RTF_LAYOUT_NOT_KEPT" })
        let xml = folder.appendingPathComponent("Data.xml")
        _ = try await convert(input, .xml, xml)
        let document = try XMLDocument(contentsOf: xml, options: [])
        XCTAssertEqual(document.rootElement()?.localName, "document")
        XCTAssertFalse(try document.nodes(forXPath: "//*[local-name()='word']").isEmpty)
        XCTAssertTrue(document.xmlString.contains("Employment"))
        let epub = folder.appendingPathComponent("Book.epub")
        _ = try await convert(input, .epub, epub)
        XCTAssertEqual(try zip("mimetype", epub), "application/epub+zip")
        XCTAssertTrue(try zip("META-INF/container.xml", epub).contains("rootfile"))
        XCTAssertEqual(try Data(contentsOf: input), original, "export never writes the source")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".zpdf-export-") })
    }

    func testNumericWorkbookKeepsIdentifiersAndFormulaLookingText() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Numbers.xlsx")
        _ = try await convert(source("export-numeric-table"), .xlsx, output)
        let xml = try zip("xl/worksheets/*.xml", output)
        XCTAssertTrue(xml.contains("00123")); XCTAssertTrue(xml.contains("00045"))
        XCTAssertTrue(xml.contains("=SUM(A1)")); XCTAssertFalse(xml.contains("<f>"))
        XCTAssertTrue(xml.contains("t=\"n\"")); XCTAssertTrue(xml.contains("1204"))
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-export-reader-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let copy = evidence.appendingPathComponent("Numbers-\(UUID()).xlsx")
        try FileManager.default.copyItem(at: output, to: copy)
        print("Reader evidence:", copy.path)
    }

    func testCurrentEditsReachWordWithoutSavingSource() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("Original.pdf")
        try FileManager.default.copyItem(at: source(), to: input)
        let original = try Data(contentsOf: input)
        let suite = "zpdf.worker.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults), readingHistory: ReadingHistoryStore(defaults: defaults))
        state.openDocument(at: input)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 where tab.saveChecking { try await Task.sleep(for: .milliseconds(20)) }
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        let field = try XCTUnwrap(page.annotations.first { $0.fieldName == "Last Name (Family Name)" })
        field.widgetStringValue = "UNSAVED EXPORT VALUE"
        let note = PDFAnnotation(bounds: CGRect(x: 35, y: 690, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "UNSAVED EXPORT COMMENT"; page.addAnnotation(note)
        state.noteAnnotationsChanged()
        let document = tab.pdfDocument, hash = tab.sourceHash
        let request = ConversionExport(tab: tab, format: .docx); request.selection = "current"
        let output = folder.appendingPathComponent("Edited.docx")
        let success = await state.runConversionExport(request, destination: .init(url: output, overwrite: false)).value
        XCTAssertTrue(success, request.error ?? "")
        let xml = try zip("word/document.xml", output)
        XCTAssertTrue(xml.contains("UNSAVED EXPORT VALUE"))
        XCTAssertTrue(try zip("word/comments.xml", output).contains("UNSAVED EXPORT COMMENT"))
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertTrue(tab.pdfDocument === document); XCTAssertEqual(tab.sourceHash, hash)
        XCTAssertTrue(tab.hasUnsavedChanges); XCTAssertFalse(tab.isSaving)
    }

    func testCancellationAndPolicyFailureLeaveExistingOutputUntouched() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Existing.docx")
        let sentinel = Data("Existing document".utf8); try sentinel.write(to: output)
        let cancel = ConversionCancellation()
        do {
            _ = try await ExportWorkerBridge.export(input: source(), options: .init(format: .docx, pages: IndexSet(integersIn: 0..<4)),
                destination: .init(url: output, overwrite: true), cancellation: cancel) { _, _, _ in cancel.cancel() }
            XCTFail("Must cancel")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        do { _ = try await convert(source("irs-w9"), .docx, output, overwrite: true); XCTFail("XFA must remain blocked") }
        catch let error as NativeSaveError { XCTAssertEqual(error.code, "POLICY_BLOCKED") }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Existing.docx"])
    }

    func testPublicationRollsBackAssetsAndPreservesUnapprovedDestinations() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("Document.md")
        let sentinel = Data("Existing markdown".utf8); try sentinel.write(to: target)
        let staged = folder.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        let assets = staged.appendingPathComponent("Document_images")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        try Data("image".utf8).write(to: assets.appendingPathComponent("image.png"))
        let absent = staged.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try ExportWorkerBridge.publish(primary: absent, assets: assets, destination: .init(url: target, overwrite: true), cancellation: ConversionCancellation()))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Document_images").path))
        let primary = staged.appendingPathComponent("document.md"); try Data("new".utf8).write(to: primary)
        XCTAssertThrowsError(try ExportWorkerBridge.publish(primary: primary, assets: nil, destination: .init(url: target, overwrite: false), cancellation: ConversionCancellation()))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        let cancellation = ConversionCancellation()
        try ExportWorkerBridge.publish(primary: primary, assets: nil, destination: .init(url: target, overwrite: true), cancellation: cancellation)
        cancellation.cancel(); XCTAssertNoThrow(try cancellation.check())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
    }
}
