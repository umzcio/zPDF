import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class PageDesignTests: XCTestCase {
    func testSheetModelsProduceWorkingOperationsAndRoundTripSettings() async throws {
        let (url, directory) = try EditingFixtures.makePDF(named: "design", lines: [
            .init(text: "Body text on page #", origin: CGPoint(x: 72, y: 700)),
        ], pages: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)

        var header = PageDesignModel(kind: .headerFooter)
        header.fields["top-right"] = "Confidential <<date>>"
        header.startNumber = 5
        var watermark = PageDesignModel(kind: .watermark)
        watermark.text = "DRAFT"
        watermark.opacity = 0.25
        watermark.anchor = .topRight
        watermark.scope = .range
        watermark.range = "2-3"
        var background = PageDesignModel(kind: .background)
        background.opacity = 0.5
        var bates = PageDesignModel(kind: .bates)
        bates.prefix = "ACME-"
        bates.batesStart = 100
        bates.digits = 4
        bates.batesAnchor = .bottomLeft
        XCTAssertTrue(PageDesignModel(kind: .watermark).canApply(current: 0, count: 3))
        var invalid = watermark
        invalid.range = "9"
        XCTAssertFalse(invalid.canApply(current: 0, count: 3), "Out-of-range pages cannot be applied")

        for model in [header, watermark, background, bates] {
            XCTAssertTrue(model.canApply(current: 0, count: 3))
            try await state.applyDocumentTransform(model.operations(current: 0, count: 3), to: tab, actionName: model.kind.title)
        }
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        let first = saved.page(at: 0)?.string ?? ""
        let second = saved.page(at: 1)?.string ?? ""
        XCTAssertTrue(first.contains("Page 5 of 3"))
        XCTAssertTrue(first.contains("Confidential"))
        XCTAssertFalse(first.contains("DRAFT"), "Watermark only on pages 2-3")
        XCTAssertTrue(second.contains("DRAFT"))
        XCTAssertTrue(first.contains("ACME-0100"))
        XCTAssertTrue(saved.page(at: 2)?.string?.contains("ACME-0102") == true)
        XCTAssertTrue(first.contains("Body text on page 1"))

        // Settings saved with the overlays restore the sheet.
        let reopened = AppState()
        let tab2 = try await TestSupport.open(url, in: reopened)
        let design = try await reopened.queryDocument("page_design", in: tab2)
        for model in [header, watermark, background, bates] {
            let entry = try XCTUnwrap(design[model.kind.rawValue] as? [String: Any])
            let settings = try XCTUnwrap(entry["settings"] as? [String: Any], model.kind.title)
            var restored = PageDesignModel(kind: model.kind)
            restored.restore(settings)
            XCTAssertEqual(restored.settings as NSDictionary, model.settings as NSDictionary, model.kind.title)
        }
        XCTAssertEqual((design["Watermark"] as? [String: Any])?["pages"] as? [Int], [1, 2])
    }
}
