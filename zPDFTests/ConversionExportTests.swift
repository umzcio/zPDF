import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class ConversionExportTests: XCTestCase {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Conversion ü \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
    private func fixture(_ directory: URL) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "uscis-i9", withExtension: "pdf"))
        let target = directory.appendingPathComponent("Input.pdf")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
    private func export(_ input: URL, format: ConversionFormat, pages: IndexSet, to target: URL, dpi: Int = 72,
                        overwrite: Bool = false, cancellation: ConversionCancellation = ConversionCancellation()) async throws -> ConversionResult {
        try await DocumentConversion.export(input: input, options: .init(format: format, pages: pages, dpi: dpi),
                                            destination: .init(url: target, overwrite: overwrite), cancellation: cancellation) { _, _ in }
    }

    func testImageFormatsPageSelectionResolutionAndRotation() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(directory)
        let original = try Data(contentsOf: input)
        let png = directory.appendingPathComponent("pages")
        let result = try await export(input, format: .png, pages: IndexSet([0, 2]), to: png, dpi: 150)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: png.path)), ["page-0001.png", "page-0003.png"])
        let info = try properties(png.appendingPathComponent("page-0001.png"))
        XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 1275)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 1650)
        XCTAssertEqual(info[kCGImagePropertyDPIWidth] as? Int, 150)
        let rotated = directory.appendingPathComponent("rotated.pdf")
        let hash = try NativeSourceGuard.digest(input)
        var changes = NativeSaveChanges()
        changes.pages = [.init(sourceIndex: 0, rotationDelta: 90), .init(sourceIndex: 1, rotationDelta: 0)]
        _ = try await NativeSaveBridge.save(input, expectedHash: hash, changes: changes, destination: rotated)
        let jpeg = directory.appendingPathComponent("rotated.jpg")
        _ = try await export(rotated, format: .jpeg, pages: IndexSet(integer: 0), to: jpeg)
        let jpg = try properties(jpeg)
        XCTAssertEqual(jpg[kCGImagePropertyPixelWidth] as? Int, 792)
        XCTAssertEqual(jpg[kCGImagePropertyPixelHeight] as? Int, 612)
        XCTAssertNotEqual(jpg[kCGImagePropertyHasAlpha] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testCancellationLeavesNoPartialCollectionOrReplacement() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(directory)
        let target = directory.appendingPathComponent("images")
        let cancellation = ConversionCancellation()
        do {
            _ = try await DocumentConversion.export(input: input, options: .init(format: .png, pages: IndexSet(integersIn: 0..<4), dpi: 72),
                                                    destination: .init(url: target, overwrite: false), cancellation: cancellation) { done, _ in
                if done == 1 { cancellation.cancel() }
            }
            XCTFail("Expected cancellation between pages")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Input.pdf"])
        let existing = directory.appendingPathComponent("Existing.txt")
        let sentinel = Data("existing output".utf8); try sentinel.write(to: existing)
        let canceled = ConversionCancellation(); canceled.cancel()
        do {
            _ = try await export(input, format: .text, pages: IndexSet(integer: 0), to: existing, overwrite: true, cancellation: canceled)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }

    func testDestinationFailureAndNoTextDoNotPublish() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(directory)
        let original = try Data(contentsOf: input)
        do {
            _ = try await export(input, format: .text, pages: IndexSet(integer: 0), to: input, overwrite: true)
            XCTFail("Source replacement must be blocked")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: input), original)
        let occupied = directory.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let sentinel = occupied.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
        do {
            _ = try await export(input, format: .png, pages: IndexSet([0, 1]), to: occupied, overwrite: true)
            XCTFail("Existing folders must not be replaced")
        } catch { }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        let blank = directory.appendingPathComponent("scan.pdf")
        let document = PDFDocument()
        let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox)
        document.insert(page, at: 0); XCTAssertTrue(document.write(to: blank))
        let target = directory.appendingPathComponent("scan.txt")
        do {
            _ = try await export(blank, format: .text, pages: IndexSet(integer: 0), to: target)
            XCTFail("Must explain missing text")
        } catch let error as NativeSaveError { XCTAssertEqual(error.code, "OCR_REQUIRED") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".zpdf-export-") })
    }

    func testFacadeExportIncludesUnsavedEditsAndKeepsDocumentOwnership() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "zpdf.conversion.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults), readingHistory: ReadingHistoryStore(defaults: defaults))
        let input = try fixture(directory)
        let original = try Data(contentsOf: input)
        state.openDocument(at: input)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 where tab.saveChecking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.allowsSaveEdits)
        let field = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" })
        field.widgetStringValue = "EXPORT UNSAVED VALUE"
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 690, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "EXPORT UNSAVED COMMENT"
        tab.pdfDocument?.page(at: 0)?.addAnnotation(note)
        state.refreshUnsavedChanges(tab)
        try state.movePage(from: 0, to: 1, in: tab)
        let beforeDocument = tab.pdfDocument
        let beforeHash = tab.sourceHash
        let request = ConversionExport(tab: tab, format: .text)
        request.selection = "range"; request.range = "2"
        let target = directory.appendingPathComponent("Current edits.txt")
        let job = state.runConversionExport(request, destination: .init(url: target, overwrite: false))
        let other = DocumentTab(url: nil, pdfDocument: PDFDocument()); state.tabs.append(other); state.selectTab(other)
        let success = await job.value
        XCTAssertTrue(success, request.error ?? "")
        XCTAssertTrue(state.activeTab === other)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("EXPORT UNSAVED VALUE"))
        XCTAssertTrue(text.contains("EXPORT UNSAVED COMMENT"))
        XCTAssertTrue(text.hasPrefix("Page 2"))
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertTrue(tab.pdfDocument === beforeDocument)
        XCTAssertEqual(tab.sourceHash, beforeHash)
        XCTAssertFalse(tab.isSaving)
        XCTAssertNil(state.saves[tab.id])
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-export-evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: evidence.appendingPathComponent("Current-edits.txt"))
        state.selectTab(tab)
        let images = ConversionExport(tab: tab); images.selection = "range"; images.range = "2"; images.dpi = 150
        let imageURL = directory.appendingPathComponent("Current.png")
        let imageSuccess = await state.runConversionExport(images, destination: .init(url: imageURL, overwrite: false)).value
        XCTAssertTrue(imageSuccess, images.error ?? "")
        try Data(contentsOf: imageURL).write(to: evidence.appendingPathComponent("Current-edits.png"))
        XCTAssertEqual(try Data(contentsOf: input), original)
        let badRange = ConversionExport(tab: tab); badRange.selection = "range"; badRange.range = "0, 8"
        let failed = await state.runConversionExport(badRange, destination: .init(url: target, overwrite: true)).value
        XCTAssertFalse(failed)
        XCTAssertNotNil(badRange.error)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)
    }

    func testMixedSizesAndApprovedReplacement() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Mixed.pdf")
        let doc = PDFDocument()
        for (index, size) in [CGSize(width: 200, height: 300), CGSize(width: 500, height: 250)].enumerated() {
            let page = PDFPage(); page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            doc.insert(page, at: index)
        }
        XCTAssertTrue(doc.write(to: input))
        let target = directory.appendingPathComponent("mixed")
        _ = try await export(input, format: .png, pages: IndexSet([0, 1]), to: target)
        let first = try properties(target.appendingPathComponent("page-0001.png"))
        let second = try properties(target.appendingPathComponent("page-0002.png"))
        XCTAssertEqual(first[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(first[kCGImagePropertyPixelHeight] as? Int, 300)
        XCTAssertEqual(second[kCGImagePropertyPixelWidth] as? Int, 500)
        XCTAssertEqual(second[kCGImagePropertyPixelHeight] as? Int, 250)
        let single = directory.appendingPathComponent("replace.png")
        let sentinel = Data("Must not change without approval".utf8); try sentinel.write(to: single)
        do {
            _ = try await export(input, format: .png, pages: IndexSet(integer: 0), to: single)
            XCTFail("Unapproved overwrite")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: single), sentinel)
        _ = try await export(input, format: .png, pages: IndexSet(integer: 1), to: single, overwrite: true)
        XCTAssertEqual(try properties(single)[kCGImagePropertyPixelWidth] as? Int, 500)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".zpdf-export-") })
    }
}
