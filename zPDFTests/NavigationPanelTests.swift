import PDFKit
import XCTest
@testable import zPDF

/// Builds small PDFs from object bodies (for features PDFKit can't author,
/// such as optional-content layers).
enum NavRawPDF {
    static func make(_ objects: [String], root: Int = 1) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = data.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        data.append(Data(table.utf8))
        return data
    }

    static func stream(_ content: String) -> String {
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    /// One page with a visible and a hidden (OFF) layer.
    static func layered() -> Data {
        let content = "/OC /oc1 BDC BT /F1 24 Tf 72 700 Td (SHOWN) Tj ET EMC\n/OC /oc2 BDC 0 0 1 rg 72 400 200 100 re f EMC"
        return make([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] /ON [5 0 R] /OFF [6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> /Properties << /oc1 5 0 R /oc2 6 0 R >> >> >>",
            stream(content),
            "<< /Type /OCG /Name (Visible layer) >>",
            "<< /Type /OCG /Name (Hidden layer) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
    }
}

@MainActor
final class NavigationPanelTests: XCTestCase {
    private func open(_ fixture: String) async throws -> (AppState, DocumentTab, URL, URL) {
        let (url, directory) = try TestSupport.fixture(fixture, in: Self.self)
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        return (state, tab, url, directory)
    }

    func testBookmarksEditSaveReopen() async throws {
        let (state, tab, url, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        var parent = OutlineItemModel(title: "Chapter ✓", page: 0, top: 700)
        parent.open = true
        parent.children = [OutlineItemModel(title: "Section", page: 0)]
        let items = [parent, OutlineItemModel(title: "End", page: max(0, tab.pageCount - 1))]
        try await state.applyDocumentTransform([["op": "set_outline", "items": items.map(\.engineItem)]],
                                               to: tab, actionName: "Add Bookmark")
        XCTAssertEqual(tab.pdfDocument?.outlineRoot?.numberOfChildren, 2)
        let queried = try await state.documentQuery("outline", in: tab, as: OutlineResult.self)
        XCTAssertEqual(queried.items.map(\.title), ["Chapter ✓", "End"])
        XCTAssertEqual(queried.items.first?.children.first?.title, "Section")

        // Rename + move via the model helpers, then undo/redo and save.
        var edited = queried.items
        XCTAssertTrue(OutlineTree.move([edited[1].id], under: edited[0].id, at: 0, in: &edited))
        OutlineTree.update(edited[0].id, in: &edited) { $0.title = "Renamed" }
        try await state.applyDocumentTransform([["op": "set_outline", "items": edited.map(\.engineItem)]],
                                               to: tab, actionName: "Move Bookmark")
        XCTAssertEqual(tab.pdfDocument?.outlineRoot?.numberOfChildren, 1)
        tab.undoHistory?.manager.undo()
        XCTAssertEqual(tab.pdfDocument?.outlineRoot?.numberOfChildren, 2)
        tab.undoHistory?.manager.redo()
        XCTAssertEqual(tab.pdfDocument?.outlineRoot?.child(at: 0)?.numberOfChildren, 2)
        let beforeSave = try await state.documentQuery("outline", in: tab, as: OutlineResult.self)
        XCTAssertEqual(beforeSave.items.first?.children.count, 2)
        try await TestSupport.save(state, tab)
        let afterSave = try await NativeDocumentBridge.query(source: url, hash: nil, name: "outline").decode(OutlineResult.self)
        XCTAssertEqual(afterSave.items.first?.children.map(\.title), ["End", "Section"])
        let savedDocument = try XCTUnwrap(PDFDocument(url: url))
        let reopened = try XCTUnwrap(savedDocument.outlineRoot)
        XCTAssertEqual(reopened.numberOfChildren, 1)
        XCTAssertEqual(reopened.child(at: 0)?.label, "Renamed")
        XCTAssertEqual(reopened.child(at: 0)?.numberOfChildren, 2)
        XCTAssertEqual(reopened.child(at: 0)?.child(at: 0)?.label, "End")
    }

    func testDestinationsAndAttachmentsSaveReopen() async throws {
        let (state, tab, url, directory) = try await open("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("notes.txt")
        try Data("attachment body".utf8).write(to: payload)
        try await state.applyDocumentTransform([
            ["op": "add_destination", "name": "section-2", "page": 1, "top": 500, "fit": "XYZ"],
            ["op": "add_attachment", "path": payload.path, "description": "Reviewer notes"]
        ], to: tab, actionName: "Test")
        try await TestSupport.save(state, tab)
        let saved = try await NativeDocumentBridge.query(source: url, hash: nil, name: "destinations")
            .decode(DestinationsResult.self)
        XCTAssertEqual(saved.items.map(\.name), ["section-2"])
        XCTAssertEqual(saved.items.first?.page, 1)
        let files = state.engine.embeddedFiles(for: url)
        XCTAssertTrue(files.contains { $0.name == "notes.txt" })
        let attachments = try await state.documentQuery("attachments", in: tab, as: AttachmentsResult.self).items
        XCTAssertEqual(attachments.first?.description, "Reviewer notes")
        let data = try await state.documentQuery("attachment_data", params: ["id": attachments[0].id], in: tab, as: AttachmentData.self)
        XCTAssertEqual(Data(base64Encoded: data.data), Data("attachment body".utf8))
    }

    func testLayersToggleRendersAndFlattenSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zPDF layers \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layers.pdf")
        try NavRawPDF.layered().write(to: url)
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        let layers = try await state.documentQuery("layers", in: tab, as: LayersResult.self)
        XCTAssertTrue(layers.hasLayers)
        let hidden = try XCTUnwrap(layers.items.first { $0.name == "Hidden layer" })
        XCTAssertEqual(hidden.visible, false)
        XCTAssertEqual(Self.darkPixels(tab.pdfDocument, in: CGRect(x: 72, y: 400, width: 200, height: 100)), 0)
        try await state.applyDocumentTransform([["op": "set_layer_visibility", "states": [hidden.id!: true]]],
                                               to: tab, actionName: "Show Layer")
        XCTAssertGreaterThan(Self.darkPixels(tab.pdfDocument, in: CGRect(x: 72, y: 400, width: 200, height: 100)), 1000)
        tab.undoHistory?.manager.undo()
        try await state.applyDocumentTransform([["op": "flatten_layers"]], to: tab, actionName: "Flatten Layers")
        try await TestSupport.save(state, tab)
        let after = try await NativeDocumentBridge.query(source: url, hash: nil, name: "layers").decode(LayersResult.self)
        XCTAssertFalse(after.hasLayers)
        XCTAssertEqual(Self.darkPixels(PDFDocument(url: url), in: CGRect(x: 72, y: 400, width: 200, height: 100)), 0)
        XCTAssertTrue(TestSupport.text(url).contains("SHOWN"))
    }

    func testDocumentPropertiesMetadataAndInitialView() async throws {
        let (state, tab, url, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = try await state.documentQueryJSON("document_properties", in: tab)
        let model = try DocumentPropertiesModel.load(json)
        var draft = PropertiesDraft(model)
        let baseline = draft
        draft.title = "Quarterly Report"
        draft.author = "Ann Author"
        draft.custom = [.init(name: "Case_Number", value: "42")]
        draft.pageLayout = "TwoPageRight"
        draft.pageMode = "UseOutlines"
        draft.displayDocTitle = true
        let ops = draft.operations(from: baseline)
        XCTAssertFalse(ops.isEmpty)
        try await state.applyDocumentTransform(ops, to: tab, actionName: "Change Document Properties")
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(saved.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Quarterly Report")
        XCTAssertEqual(saved.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Ann Author")
        let reread = try DocumentPropertiesModel.load(try await NativeDocumentBridge.query(source: url, hash: nil, name: "document_properties"))
        XCTAssertEqual(reread.custom["Case_Number"], "42")
        XCTAssertEqual(reread.initialView.pageLayout, "TwoPageRight")
        XCTAssertEqual(reread.initialView.pageMode, "UseOutlines")
        XCTAssertTrue(reread.xmp?.contains("Quarterly Report") == true)
        let initial = DocumentInitialView(catalog: try XCTUnwrap(saved.documentRef?.catalog), document: saved)
        XCTAssertEqual(initial.viewMode, .facing)
        XCTAssertEqual(initial.coverPage, true)
        XCTAssertEqual(initial.panel, .bookmarks)
        // No-op edits produce no operations.
        XCTAssertTrue(PropertiesDraft(reread).operations(from: PropertiesDraft(reread)).isEmpty)
    }

    func testOutlineTreeMoveRules() {
        var a = OutlineItemModel(title: "A", page: 0)
        let b = OutlineItemModel(title: "B", page: 0)
        let c = OutlineItemModel(title: "C", page: 0)
        a.children = [b]
        var items = [a, c]
        XCTAssertFalse(OutlineTree.move([a.id], under: b.id, at: nil, in: &items), "No moving into a descendant")
        XCTAssertTrue(OutlineTree.move([c.id], under: nil, at: 0, in: &items))
        XCTAssertEqual(items.map(\.title), ["C", "A"])
        XCTAssertTrue(OutlineTree.move([b.id], under: nil, at: 2, in: &items))
        XCTAssertEqual(items.map(\.title), ["C", "A", "B"])
        XCTAssertEqual(OutlineTree.matches("b", in: items).map(\.item.title), ["B"])
    }

    static func darkPixels(_ document: PDFDocument?, in rect: CGRect) -> Int {
        guard let page = document?.page(at: 0) else { return -1 }
        let image = page.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        var count = 0
        let top = 792 - Int(rect.maxY)
        for y in top..<(top + Int(rect.height)) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.5 { count += 1 }
            }
        }
        return count
    }
}
