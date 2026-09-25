import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class OptimizeStandardsCompareTests: XCTestCase {
    private func scanDocument(in directory: URL, state: AppState) async throws -> DocumentTab {
        let image = try WorkflowFactory.textImage("Scanned invoice", at: directory.appendingPathComponent("scan.jpg"))
        let created = try unwrap(await state.createPDF(from: [image], name: "Scan"))
        let url = directory.appendingPathComponent("scan.pdf")
        let ok = await state.saveDocumentAs(created, to: SaveDestination(url: url, overwrite: false)).value
        check(ok, state.saveError?.message ?? "")
        return created
    }

    func testReduceFileSizeAndOptimizerCopyAndAudit() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await scanDocument(in: directory, state: state)
        let original = try Data(contentsOf: try XCTUnwrap(tab.url))
        let audit = try await state.queryDocument("space_audit", in: tab)
        let categories = try XCTUnwrap(audit["categories"] as? [String: Int])
        XCTAssertGreaterThan(categories["images"] ?? 0, (audit["total"] as? Int ?? 0) / 2)

        let reduced = directory.appendingPathComponent("reduced.pdf")
        check(await state.saveTransformedCopy(of: tab, ops: ReducePreset.low.ops, title: "Reduce File Size", suffix: "reduced",
                                              destination: SaveDestination(url: reduced, overwrite: false)),
              state.saveError?.message ?? "")
        let before = original.count
        let after = try XCTUnwrap(try reduced.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(after, before / 2)
        XCTAssertTrue(state.exportMessage?.contains("smaller") == true, state.exportMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(tab.url)), original, "the open document's file is untouched")
        XCTAssertEqual(PDFDocument(url: reduced)?.pageCount, 1)

        let optimized = directory.appendingPathComponent("web.pdf")
        let ops: [[String: Any]] = [["op": "optimize", "images": ["color_dpi": 72, "jpeg_quality": 60, "grayscale": true],
                                     "remove": ["metadata": true], "linearize": true]]
        check(await state.saveTransformedCopy(of: tab, ops: ops, title: "Optimize PDF", suffix: "optimized",
                                              destination: SaveDestination(url: optimized, overwrite: false)))
        let inventory = try await NativeWorkflowBridge.queryFile(optimized, name: "image_inventory")
        let image = try XCTUnwrap((inventory["images"] as? [[String: Any]])?.first)
        XCTAssertEqual(image["color"] as? String, "gray")
        XCTAssertEqual(Double(image["dpi"] as? Int ?? 0), 72, accuracy: 2)
        // Same-file destination is refused (the open document is never replaced).
        let refused = await state.saveTransformedCopy(of: tab, ops: ops, title: "Optimize PDF", suffix: "x",
                                                      destination: SaveDestination(url: try XCTUnwrap(tab.url), overwrite: true))
        XCTAssertFalse(refused)
    }

    func testPDFAConversionSurvivesSaveAndPreflightFixups() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try WorkflowFactory.textPDF(["Archive me", "Page two"], at: directory.appendingPathComponent("doc.pdf"))
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let before = try await state.queryDocument("validate_standard", params: ["standard": "PDF/A-2b"], in: tab)
        XCTAssertEqual(before["compliant"] as? Bool, false)
        _ = try await state.applyDocumentTransform(OutputStandard.pdfa2b.ops, to: tab, actionName: "Convert to PDF/A")
        try await TestSupport.save(state, tab)
        let saved = try await NativeWorkflowBridge.queryFile(url, name: "validate_standard", params: ["standard": "PDF/A-2b"])
        XCTAssertEqual(saved["compliant"] as? Bool, true, "\(saved["issues"] ?? "")")
        let claims = try await NativeWorkflowBridge.queryFile(url, name: "standards_status")
        XCTAssertEqual(claims["claims"] as? [String], ["PDF/A-2b"])

        // PDF/X-4 as a copy; preflight commercial then passes the trim check.
        let x4 = directory.appendingPathComponent("print.pdf")
        check(await state.saveTransformedCopy(of: tab, ops: OutputStandard.pdfx4.ops, title: "Save as PDF/X-4", suffix: "PDFX",
                                              destination: SaveDestination(url: x4, overwrite: false)))
        let xReport = try await NativeWorkflowBridge.queryFile(x4, name: "validate_standard", params: ["standard": "PDF/X-4"])
        XCTAssertEqual(xReport["compliant"] as? Bool, true, "\(xReport["issues"] ?? "")")

        let preflight = try await state.queryDocument("preflight", params: ["profile": "commercial"], in: tab)
        let results = try XCTUnwrap(preflight["results"] as? [[String: Any]])
        let trim = try XCTUnwrap(results.first { $0["id"] as? String == "trim" })
        XCTAssertEqual(trim["severity"] as? String, "error")
        let fix = PreflightResult(rule: "trim", title: "", severity: "error", detail: "", pages: [], fix: trim["fix"] as? String)
        _ = try await state.applyDocumentTransform(try XCTUnwrap(fix.fixOps), to: tab, actionName: "Set TrimBox")
        let again = try await state.queryDocument("preflight", params: ["profile": "commercial"], in: tab)
        let trimAgain = try XCTUnwrap((again["results"] as? [[String: Any]])?.first { $0["id"] as? String == "trim" })
        XCTAssertEqual(trimAgain["severity"] as? String, "pass")

        _ = try await state.applyDocumentTransform([["op": "printer_marks", "title": "Job"]], to: tab, actionName: "Add Printer Marks")
        let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
        XCTAssertGreaterThan(page.bounds(for: .mediaBox).width, 612 + 60)
        XCTAssertEqual(page.bounds(for: .trimBox).width, 612, accuracy: 0.5)
        XCTAssertNotNil(CMYKRender(page: page), "output preview renders to CMYK")
    }

    func testCompareFindsTextAndVisualChangesAndWritesReport() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = try WorkflowFactory.textPDF(["The contract term is twelve months.", "Signature page"],
                                                 at: directory.appendingPathComponent("v1.pdf"))
        let newURL = try WorkflowFactory.textPDF(["The contract term is eighteen months.", "Signature page", "New appendix page"],
                                                 at: directory.appendingPathComponent("v2.pdf"))
        let old = try XCTUnwrap(PDFDocument(url: oldURL)), new = try XCTUnwrap(PDFDocument(url: newURL))
        let result = await CompareService.compare(old: old, oldName: "v1.pdf", new: new, newName: "v2.pdf")
        let replaced = try XCTUnwrap(result.textChanges.first { $0.kind == .replaced })
        XCTAssertEqual(replaced.oldText, "twelve")
        XCTAssertEqual(replaced.newText, "eighteen")
        XCTAssertEqual(replaced.newPage, 0)
        XCTAssertFalse(replaced.newRects.isEmpty)
        XCTAssertTrue(result.textChanges.contains { $0.kind == .inserted && $0.newText.contains("appendix") && $0.newPage == 2 })
        XCTAssertTrue(result.pagePairs.contains { $0.old == 1 && $0.new == 1 })
        XCTAssertTrue(result.pagePairs.contains { $0.old == nil && $0.new == 2 })
        let visual = try XCTUnwrap(result.visualChanges.first { $0.newPage == 0 })
        XCTAssertFalse(visual.regions.isEmpty)
        XCTAssertFalse(result.visualChanges.contains { $0.newPage == 1 }, "identical pages have no visual difference")

        let report = directory.appendingPathComponent("report.pdf")
        try CompareService.writeReport(result, to: report)
        let document = try XCTUnwrap(PDFDocument(url: report))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("eighteen") == true)
    }

    func testExportPageImagesAndEmbeddedImages() async throws {
        let directory = try WorkflowFactory.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try WorkflowFactory.textPDF(["One", "Two", "Three"], at: directory.appendingPathComponent("doc.pdf"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let folder = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pngs = try PageImageExporter.export(document, pages: [0, 2], format: .png, dpi: 144, color: .rgb, to: folder, baseName: "doc")
        XCTAssertEqual(pngs.map(\.lastPathComponent), ["doc-01.png", "doc-03.png"])
        let png = try XCTUnwrap(NSImage(contentsOf: pngs[0])?.representations.first)
        XCTAssertEqual(png.pixelsWide, 1224)
        let jpegs = try PageImageExporter.export(document, pages: [1], format: .jpeg, dpi: 72, color: .cmyk, to: folder, baseName: "cmyk")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpegs[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, "CMYK")
        let tiff = try PageImageExporter.export(document, pages: [0, 1, 2], format: .tiff, dpi: 72, color: .gray,
                                                multipageTIFF: true, to: folder, baseName: "all")
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithURL(tiff[0] as CFURL, nil))), 3)
        XCTAssertThrowsError(try PageImageExporter.export(document, pages: [0], format: .png, dpi: 72, color: .cmyk,
                                                          to: folder, baseName: "bad"))

        // Embedded images keep their original JPEG encoding.
        let state = AppState()
        let photo = try WorkflowFactory.textImage("Photo", at: directory.appendingPathComponent("photo.jpg"))
        let tab = try unwrap(await state.createPDF(from: [photo]))
        let work = try NativeWorkDirectory()
        let extracted = try await state.queryDocument("extract_images", params: ["directory": work.url.path], in: tab)
        let path = try XCTUnwrap((extracted["images"] as? [[String: Any]])?.first?["path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), try Data(contentsOf: photo))
    }
}
