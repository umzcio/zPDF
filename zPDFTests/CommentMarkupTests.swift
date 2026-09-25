import AVFoundation
import PDFKit
import XCTest
@testable import zPDF

/// Raw object reads of a saved file (what other PDF viewers see).
enum RawPDF {
    final class File {
        /// Dictionaries point into their document; keep every opened file alive.
        nonisolated(unsafe) private static var retained: [CGPDFDocument] = []
        let document: CGPDFDocument
        init?(_ url: URL) {
            guard let document = CGPDFDocument(url as CFURL) else { return nil }
            self.document = document
            Self.retained.append(document)
        }

        func annotations(page: Int = 0) -> [CGPDFDictionaryRef] {
            guard let page = document.page(at: page + 1), let dict = page.dictionary else { return [] }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dict, "Annots", &array), let array else { return [] }
            return (0..<CGPDFArrayGetCount(array)).compactMap { i in
                var d: CGPDFDictionaryRef?
                return CGPDFArrayGetDictionary(array, i, &d) ? d : nil
            }
        }

        func annotations(page: Int = 0, subtype: String) -> [CGPDFDictionaryRef] {
            annotations(page: page).filter { RawPDF.name($0, "Subtype") == subtype }
        }
    }

    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? { CommentFileInfo.name(d, key) }
    static func string(_ d: CGPDFDictionaryRef, _ key: String) -> String? { CommentFileInfo.string(d, key) }
    static func number(_ d: CGPDFDictionaryRef, _ key: String) -> Double? { CommentFileInfo.number(d, key) }

    static func numbers(_ d: CGPDFDictionaryRef, _ key: String) -> [Double] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(d, key, &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { i in
            var value: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, i, &value) ? Double(value) : nil
        }
    }

    static func dictionary(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &value) ? value : nil
    }

    /// Length of the decoded normal appearance stream (0 when missing).
    static func appearanceLength(_ d: CGPDFDictionaryRef) -> Int {
        guard let ap = dictionary(d, "AP") else { return 0 }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(ap, "N", &stream), let stream else { return 0 }
        var format = CGPDFDataFormat.raw
        return (CGPDFStreamCopyData(stream, &format) as Data?)?.count ?? 0
    }

    static func appearanceHasImage(_ d: CGPDFDictionaryRef) -> Bool {
        guard let ap = dictionary(d, "AP") else { return false }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(ap, "N", &stream), let stream, let info = CGPDFStreamGetDictionary(stream),
              let resources = dictionary(info, "Resources"), let xobjects = dictionary(resources, "XObject") else { return false }
        return hasImageXObject(xobjects)
    }

    private final class Keys { var parts: [String] = [] }

    /// "key=value" pairs of a dictionary, for failure messages.
    static func describe(_ d: CGPDFDictionaryRef) -> String {
        let keys = Keys()
        let context = Unmanaged.passUnretained(keys).toOpaque()
        CGPDFDictionaryApplyFunction(d, { key, object, info in
            guard let info else { return }
            let keys = Unmanaged<Keys>.fromOpaque(info).takeUnretainedValue()
            var value = "t\(CGPDFObjectGetType(object).rawValue)"
            var n: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .name, &n), let n { value = "/" + String(cString: n) }
            var str: CGPDFStringRef?
            if CGPDFObjectGetValue(object, .string, &str), let str { value = "(" + ((CGPDFStringCopyTextString(str) as String?) ?? "") + ")" }
            keys.parts.append("\(String(cString: key))=\(value)")
        }, context)
        return keys.parts.sorted().joined(separator: " ")
    }

    static func hasImageXObject(_ xobjects: CGPDFDictionaryRef) -> Bool {
        let keys = Keys()
        let context = Unmanaged.passUnretained(keys).toOpaque()
        CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
            guard let info else { return }
            var s: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &s), let s, let sd = CGPDFStreamGetDictionary(s),
               CommentFileInfo.name(sd, "Subtype") == "Image" {
                Unmanaged<Keys>.fromOpaque(info).takeUnretainedValue().parts.append("image")
            }
        }, context)
        return !keys.parts.isEmpty
    }

    /// Index of the annotation an /IRT points to, among the page's /Annots.
    static func irtIndex(_ d: CGPDFDictionaryRef, in list: [CGPDFDictionaryRef]) -> Int? {
        guard let irt = dictionary(d, "IRT") else { return nil }
        return list.firstIndex(of: irt)
    }
}

@MainActor
final class CommentMarkupTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        try await super.tearDown()
    }

    private func open(_ fixture: String = "irs-1040-worksheet-b") async throws -> (AppState, DocumentTab, URL) {
        let (url, directory) = try TestSupport.fixture(fixture, in: Self.self)
        directories.append(directory)
        let suite = "CommentMarkup-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        preferences.commentAuthor = "Test Reviewer"
        let service = PDFKitAnnotationService()
        service.styles = CommentToolStyles(defaults: defaults)
        let state = AppState(annotationService: service, preferences: preferences)
        let tab = try await TestSupport.open(url, in: state)
        return (state, tab, url)
    }

    private func page(_ tab: DocumentTab, _ index: Int = 0) throws -> PDFPage {
        try XCTUnwrap(tab.pdfDocument?.page(at: index))
    }

    private func selection(_ text: String, in tab: DocumentTab) throws -> PDFSelection {
        let found = try XCTUnwrap(tab.pdfDocument?.findString(text, withOptions: .caseInsensitive).first, "fixture contains \(text)")
        return found
    }

    private func reopen(_ url: URL) async throws -> (AppState, DocumentTab) {
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        return (state, tab)
    }

    // MARK: 28–30 Strikethrough, Replace Text, Insert Text

    func testStrikethroughReplaceAndInsertTextSaveWithGrouping() async throws {
        let (state, tab, url) = try await open()
        let strike = state.annotationService.addMarkupAnnotation(.strikethrough, over: try selection("Use this worksheet", in: tab), in: tab)
        XCTAssertEqual(strike.first?.type, "StrikeOut")
        let replaced = state.annotationService.addMarkupAnnotation(.replaceText, over: try selection("Complete the parts below", in: tab), in: tab)
        XCTAssertEqual(replaced.map(\.type), ["Caret", "StrikeOut"], "Replace Text adds a caret grouped with the strike-out")
        replaced[0].contents = "appears on every"
        let caret = try XCTUnwrap(state.annotationService.addAnnotation(.insertText, at: CGPoint(x: 200, y: 600), onPage: 0, in: tab))
        caret.contents = "inserted words"
        state.commitCommentEdit("Test")
        // The list shows Replace Text as one comment carrying both texts.
        let list = state.annotationService.comments(for: tab)
        let replace = try XCTUnwrap(list.first { $0.kind == .replaceText })
        XCTAssertEqual(replace.text, "appears on every")
        XCTAssertEqual(replace.quotedText?.lowercased(), "complete the parts below")
        XCTAssertEqual(list.filter { $0.kind == .insertText }.map(\.text), ["inserted words"])
        XCTAssertEqual(list.filter { $0.kind == .strikethrough }.count, 1)
        XCTAssertTrue(tab.hasUnsavedChanges)
        try await TestSupport.save(state, tab)

        let raw = try XCTUnwrap(RawPDF.File(url))
        let annots = raw.annotations()
        let strikes = raw.annotations(subtype: "StrikeOut")
        XCTAssertEqual(strikes.count, 2)
        for item in strikes {
            XCTAssertEqual(RawPDF.numbers(item, "QuadPoints").count, 8)
            XCTAssertGreaterThan(RawPDF.appearanceLength(item), 10)
        }
        let edit = try XCTUnwrap(strikes.first { RawPDF.name($0, "IT") == "StrikeOutTextEdit" })
        let carets = raw.annotations(subtype: "Caret")
        XCTAssertEqual(carets.count, 2)
        let parent = try XCTUnwrap(RawPDF.irtIndex(edit, in: annots))
        XCTAssertEqual(RawPDF.name(annots[parent], "Subtype"), "Caret")
        XCTAssertEqual(RawPDF.string(annots[parent], "Contents"), "appears on every")
        XCTAssertEqual(RawPDF.name(edit, "RT"), "Group")
        XCTAssertTrue(carets.allSatisfy { RawPDF.appearanceLength($0) > 10 })
        XCTAssertEqual(RawPDF.name(carets.first { RawPDF.string($0, "Contents") == "inserted words" }!, "Sy"), "None")

        // Reopened: still one Replace Text comment.
        let (reopenedState, reopened) = try await reopen(url)
        let again = reopenedState.annotationService.comments(for: reopened)
        XCTAssertEqual(again.filter { $0.kind == .replaceText }.map(\.text), ["appears on every"])
        XCTAssertEqual(again.count, 3)
    }

    // MARK: 31–32 Text box and callout

    func testTypewriterTextBoxAndCalloutSave() async throws {
        let (state, tab, url) = try await open()
        let service = state.annotationService
        let box = try XCTUnwrap(service.addAnnotation(.textBox, at: CGPoint(x: 80, y: 700), onPage: 0, in: tab))
        box.contents = "Typed on the page"
        let callout = try XCTUnwrap(service.addShape(.callout, points: [CGPoint(x: 100, y: 400), CGPoint(x: 250, y: 480)], onPage: 0, in: tab))
        callout.contents = "Check this figure"
        state.commitCommentEdit("Test")
        XCTAssertEqual(service.comments(for: tab).map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.callout, .textBox])
        try await TestSupport.save(state, tab)

        let raw = try XCTUnwrap(RawPDF.File(url))
        let free = raw.annotations(subtype: "FreeText")
        XCTAssertEqual(free.count, 2)
        let typed = try XCTUnwrap(free.first { RawPDF.string($0, "Contents") == "Typed on the page" })
        XCTAssertEqual(RawPDF.name(typed, "IT"), "FreeTextTypewriter")
        XCTAssertNotNil(RawPDF.string(typed, "DA"))
        XCTAssertGreaterThan(RawPDF.appearanceLength(typed), 10)
        let call = try XCTUnwrap(free.first { RawPDF.string($0, "Contents") == "Check this figure" })
        XCTAssertEqual(RawPDF.name(call, "IT"), "FreeTextCallout")
        let cl = RawPDF.numbers(call, "CL")
        XCTAssertEqual(cl.count, 6)
        XCTAssertEqual(cl[0], 100, accuracy: 0.5)
        XCTAssertEqual(cl[1], 400, accuracy: 0.5)
        XCTAssertEqual(RawPDF.numbers(call, "RD").count, 4)
        XCTAssertGreaterThan(RawPDF.appearanceLength(call), 50, "callout appearance draws box, text and pointer")

        // Editing the reopened callout keeps it a callout (app-drawn stand-in).
        let (state2, tab2) = try await reopen(url)
        let loaded = try XCTUnwrap(tab2.pdfDocument?.page(at: 0)?.annotations.first { $0.contents == "Check this figure" })
        let prepared = state2.prepareForEditing(CommentSelection(annotation: loaded, page: try page(tab2)))
        XCTAssertTrue(prepared.annotation is CommentAnnotation)
        var style = CommentRehydration.style(of: prepared.annotation)
        style.color = .blue
        state2.applyCommentStyle(style, to: prepared)
        try await TestSupport.save(state2, tab2)
        let raw2 = try XCTUnwrap(RawPDF.File(url))
        let edited = try XCTUnwrap(raw2.annotations(subtype: "FreeText").first { RawPDF.string($0, "Contents") == "Check this figure" })
        XCTAssertEqual(RawPDF.numbers(edited, "CL").count, 6)
        XCTAssertEqual(RawPDF.numbers(edited, "C").first ?? 1, 0.15, accuracy: 0.02)
        XCTAssertEqual(raw2.annotations(subtype: "FreeText").count, 2, "the stand-in updated the original in place")
    }

    // MARK: 33 Pen, smoothing, eraser

    func testSmoothedInkAndEraserSplitStroke() async throws {
        let (state, tab, url) = try await open()
        let points = (0...40).map { CGPoint(x: 100 + CGFloat($0) * 5, y: 300 + sin(CGFloat($0) / 4) * 30) }
        let ink = try XCTUnwrap(state.annotationService.addInkAnnotation(points: points, onPage: 0, in: tab))
        XCTAssertGreaterThan(CommentCanvasController.pathPoints(ink.paths![0]).count, points.count, "Catmull-Rom resampling")
        let canvas = state.comments.canvas
        XCTAssertTrue(canvas.erase(at: CGPoint(x: 200, y: 300 + sin(20.0 / 4) * 30), on: try page(tab)))
        XCTAssertEqual(ink.paths?.count, 2, "erasing the middle splits the stroke")
        state.commitCommentEdit("Erase")
        try await TestSupport.save(state, tab)
        let raw = try XCTUnwrap(RawPDF.File(url))
        let inks = raw.annotations(subtype: "Ink")
        XCTAssertEqual(inks.count, 1)
        var list: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(inks[0], "InkList", &list))
        XCTAssertEqual(list.map { CGPDFArrayGetCount($0) }, 2)
        XCTAssertGreaterThan(RawPDF.appearanceLength(inks[0]), 50)
    }

    // MARK: 34 Shapes

    func testShapesSaveWithGeometryAndAppearance() async throws {
        let (state, tab, url) = try await open()
        let service = state.annotationService
        _ = service.addShape(.rectangle, points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 120)], onPage: 0, in: tab)
        _ = service.addShape(.oval, points: [CGPoint(x: 200, y: 50), CGPoint(x: 300, y: 120)], onPage: 0, in: tab)
        _ = service.addShape(.line, points: [CGPoint(x: 50, y: 200), CGPoint(x: 150, y: 260)], onPage: 0, in: tab)
        _ = service.addShape(.arrow, points: [CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 260)], onPage: 0, in: tab)
        _ = service.addShape(.polygon, points: [CGPoint(x: 50, y: 400), CGPoint(x: 150, y: 400), CGPoint(x: 100, y: 480)], onPage: 0, in: tab)
        _ = service.addShape(.polyline, points: [CGPoint(x: 200, y: 400), CGPoint(x: 250, y: 470), CGPoint(x: 300, y: 400)], onPage: 0, in: tab)
        _ = service.addShape(.cloud, points: [CGPoint(x: 350, y: 400), CGPoint(x: 500, y: 480)], onPage: 0, in: tab)
        state.commitCommentEdit("Shapes")
        XCTAssertEqual(service.comments(for: tab).count, 7)
        try await TestSupport.save(state, tab)

        let raw = try XCTUnwrap(RawPDF.File(url))
        XCTAssertEqual(raw.annotations(subtype: "Square").count, 2)
        XCTAssertEqual(raw.annotations(subtype: "Circle").count, 1)
        let lines = raw.annotations(subtype: "Line")
        XCTAssertEqual(lines.count, 2)
        let arrow = try XCTUnwrap(lines.first { RawPDF.name($0, "IT") == "LineArrow" })
        XCTAssertEqual(RawPDF.numbers(arrow, "L"), [200, 200, 300, 260])
        var le: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(arrow, "LE", &le))
        var ending: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFArrayGetName(le!, 1, &ending))
        XCTAssertEqual(String(cString: ending!), "OpenArrow")
        let polygon = try XCTUnwrap(raw.annotations(subtype: "Polygon").first)
        XCTAssertEqual(RawPDF.numbers(polygon, "Vertices"), [50, 400, 150, 400, 100, 480])
        XCTAssertEqual(raw.annotations(subtype: "PolyLine").count, 1)
        let cloud = try XCTUnwrap(raw.annotations(subtype: "Square").first { RawPDF.dictionary($0, "BE") != nil })
        XCTAssertEqual(RawPDF.name(RawPDF.dictionary(cloud, "BE")!, "S"), "C")
        for annotation in raw.annotations() where RawPDF.name(annotation, "Subtype") != "Popup" {
            XCTAssertGreaterThan(RawPDF.appearanceLength(annotation), 20, "\(RawPDF.name(annotation, "Subtype") ?? "?") has an appearance")
        }
    }

    // MARK: 35 Stamps

    func testStandardDynamicAndImageStamps() async throws {
        let (state, tab, url) = try await open()
        let service = try XCTUnwrap(state.annotationService as? PDFKitAnnotationService)
        state.comments.stampDesign = StampDesign.standard[0]
        _ = service.addAnnotation(.stamp, at: CGPoint(x: 150, y: 700), onPage: 0, in: tab)
        state.comments.stampDesign = StampDesign.dynamicTemplates[1]
        _ = service.addAnnotation(.stamp, at: CGPoint(x: 150, y: 600), onPage: 0, in: tab)
        // A custom image stamp stored in its own library folder.
        let folder = directories[0].appendingPathComponent("stamps")
        let library = CustomStampLibrary(folder: folder)
        let imageURL = directories[0].appendingPathComponent("seal.png")
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
        }
        try XCTUnwrap(CustomStampLibrary.png(from: image, maxEdge: 200)).write(to: imageURL)
        let entry = try library.add(imageAt: imageURL)
        XCTAssertEqual(CustomStampLibrary(folder: folder).entries.map(\.id), [entry.id], "stored for reuse")
        state.comments.stampDesign = try XCTUnwrap(library.design(for: entry))
        _ = service.addAnnotation(.stamp, at: CGPoint(x: 150, y: 500), onPage: 0, in: tab)
        state.commitCommentEdit("Stamps")
        try await TestSupport.save(state, tab)

        let stamps = try XCTUnwrap(RawPDF.File(url)).annotations(subtype: "Stamp")
        XCTAssertEqual(stamps.count, 3)
        XCTAssertTrue(stamps.contains { RawPDF.name($0, "Name") == "Approved" }, stamps.map(RawPDF.describe).joined(separator: "\n"))
        let dynamic = try XCTUnwrap(stamps.first { RawPDF.name($0, "Name") == "Reviewed" })
        XCTAssertTrue(RawPDF.string(dynamic, "Contents")?.contains("By Test Reviewer at") == true)
        XCTAssertTrue(stamps.contains { RawPDF.appearanceHasImage($0) }, "image stamp embeds its image")
        XCTAssertTrue(stamps.allSatisfy { RawPDF.appearanceLength($0) > 20 })
    }

    // MARK: 36–37 File attachment and sound

    func testFileAttachmentAndSoundCommentsEmbedMedia() async throws {
        let (state, tab, url) = try await open()
        let file = directories[0].appendingPathComponent("notes.csv")
        try Data("a,b\n1,2\n".utf8).write(to: file)
        state.comments.fileSource = { file }
        await state.attachFileComment(at: CGPoint(x: 300, y: 300), onPage: 0)
        // 0.5 s of 16-bit mono PCM.
        var samples = Data()
        for i in 0..<4000 { withUnsafeBytes(of: Int16(i % 200 * 100).littleEndian) { samples.append(contentsOf: $0) } }
        let wav = directories[0].appendingPathComponent("memo.wav")
        try WAV.encode(samples: samples, rate: 8000, channels: 1, bits: 16).write(to: wav)
        let normalized = try CommentMedia.shared.normalizedWAV(from: wav)
        state.addSoundComment(from: normalized, at: CGPoint(x: 350, y: 300), onPage: 0)
        let list = state.annotationService.comments(for: tab)
        XCTAssertEqual(list.first { $0.kind == .attachment }?.attachmentName, "notes.csv")
        XCTAssertNotNil(list.first { $0.kind == .sound })
        try await TestSupport.save(state, tab)

        let raw = try XCTUnwrap(RawPDF.File(url))
        let attachment = try XCTUnwrap(raw.annotations(subtype: "FileAttachment").first)
        XCTAssertGreaterThan(RawPDF.appearanceLength(attachment), 20)
        let sound = try XCTUnwrap(raw.annotations(subtype: "Sound").first)
        XCTAssertGreaterThan(RawPDF.appearanceLength(sound), 20)
        // Reopened: open/save-out data and playable audio come from the file.
        let (state2, tab2) = try await reopen(url)
        let loaded = state2.annotationService.comments(for: tab2)
        let attached = try XCTUnwrap(loaded.first { $0.kind == .attachment })
        XCTAssertEqual(attached.attachmentName, "notes.csv")
        let annotation = try XCTUnwrap(state2.annotationService.annotation(for: attached, in: tab2)?.annotation)
        XCTAssertEqual(state2.attachmentData(for: annotation, in: tab2)?.data, Data("a,b\n1,2\n".utf8))
        let recorded = try XCTUnwrap(loaded.first { $0.kind == .sound })
        XCTAssertEqual(recorded.soundDuration ?? 0, 0.5, accuracy: 0.05)
        let soundAnnotation = try XCTUnwrap(state2.annotationService.annotation(for: recorded, in: tab2)?.annotation)
        let playable = try XCTUnwrap(CommentFileInfo.soundWAV(of: soundAnnotation, baseline: try XCTUnwrap(tab2.saveBaseline)))
        XCTAssertNoThrow(try AVAudioPlayer(data: playable))
        XCTAssertEqual(playable.suffix(samples.count), samples, "PCM round-trips through the PDF's big-endian samples")

        // Moving the saved attachment keeps its embedded file.
        let selection = CommentSelection(annotation: annotation, page: try page(tab2))
        let moved = state2.prepareForEditing(selection)
        moved.annotation.bounds = moved.annotation.bounds.offsetBy(dx: 40, dy: 0)
        state2.commitCommentEdit("Move")
        try await TestSupport.save(state2, tab2)
        let (state3, tab3) = try await reopen(url)
        let after = try XCTUnwrap(state3.annotationService.comments(for: tab3).first { $0.kind == .attachment })
        let afterAnnotation = try XCTUnwrap(state3.annotationService.annotation(for: after, in: tab3)?.annotation)
        XCTAssertEqual(afterAnnotation.bounds.minX, 330, accuracy: 0.5)
        XCTAssertEqual(state3.attachmentData(for: afterAnnotation, in: tab3)?.data, Data("a,b\n1,2\n".utf8))
    }

    // MARK: 38 Appearance

    func testAppearanceEditsSaveAndUndo() async throws {
        let (state, tab, url) = try await open()
        let square = try XCTUnwrap(state.annotationService.addShape(.rectangle, points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)], onPage: 0, in: tab))
        state.commitCommentEdit("Add")
        try await TestSupport.save(state, tab)
        _ = square
        // Loaded (PDFKit-drawn) rectangle: colour, fill, width, dash, opacity.
        let loaded = try XCTUnwrap(try page(tab).annotations.first { $0.type == "Square" })
        var style = CommentRehydration.style(of: loaded)
        style.color = .green; style.fill = .yellow; style.lineWidth = 4; style.lineStyle = .dashed; style.opacity = 0.5
        state.applyCommentStyle(style, to: CommentSelection(annotation: loaded, page: try page(tab)))
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertTrue(tab.undoHistory?.manager.canUndo == true)
        tab.undoHistory?.manager.undo()
        XCTAssertEqual(CommentColor(loaded.color)?.opaque, CommentRehydration.style(of: loaded).color, "undo restores")
        XCTAssertNotEqual(CommentColor(loaded.color)?.opaque, .green)
        tab.undoHistory?.manager.redo()
        XCTAssertEqual(CommentColor(loaded.color)?.opaque, .green)
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(RawPDF.File(url)?.annotations(subtype: "Square").first)
        XCTAssertEqual(RawPDF.numbers(saved, "C").count, 3, RawPDF.describe(saved))
        XCTAssertEqual(RawPDF.numbers(saved, "C").dropFirst().first ?? 0, 0.65, accuracy: 0.02)
        XCTAssertEqual(RawPDF.numbers(saved, "IC").count, 3)
        XCTAssertEqual(RawPDF.number(saved, "CA") ?? 1, 0.5, accuracy: 0.01)
        let bs = try XCTUnwrap(RawPDF.dictionary(saved, "BS"))
        XCTAssertEqual(RawPDF.number(bs, "W"), 4)
        XCTAssertEqual(RawPDF.name(bs, "S"), "D")

        // Switching a saved rectangle to a cloudy border keeps it a Square.
        let again = try XCTUnwrap(try page(tab).annotations.first { $0.type == "Square" })
        var cloudy = CommentRehydration.style(of: again)
        cloudy.lineStyle = .cloudy
        state.applyCommentStyle(cloudy, to: CommentSelection(annotation: again, page: try page(tab)))
        try await TestSupport.save(state, tab)
        let clouds = try XCTUnwrap(RawPDF.File(url)).annotations(subtype: "Square")
        XCTAssertEqual(clouds.count, 1)
        XCTAssertEqual(RawPDF.dictionary(clouds[0], "BE").flatMap { RawPDF.name($0, "S") }, "C")
    }

    // MARK: 39–40 Status, checkmarks, threads, persistent replies

    func testRepliesStatusCheckmarksPersistAndThreadDeletes() async throws {
        let (state, tab, url) = try await open()
        let service = state.annotationService
        let note = try XCTUnwrap(service.addAnnotation(.stickyNote, at: CGPoint(x: 400, y: 700), onPage: 0, in: tab))
        note.contents = "Top-level note"
        state.commitCommentEdit("Note")
        var comment = try XCTUnwrap(service.comments(for: tab).first)
        // Reply to a comment that is not saved yet, then a reply to that reply.
        state.replyToComment(comment, text: "First reply")
        comment = try XCTUnwrap(service.comments(for: tab).first)
        state.replyToComment(try XCTUnwrap(comment.replies.first), text: "Nested reply")
        state.setCommentStatus(.accepted, for: comment)
        state.setCommentMarked(true, for: comment)
        comment = try XCTUnwrap(service.comments(for: tab).first)
        XCTAssertEqual(service.comments(for: tab).count, 1, "replies and status are not top-level rows")
        XCTAssertEqual(comment.replies.map(\.text), ["First reply"])
        XCTAssertEqual(comment.replies.first?.replies.map(\.text), ["Nested reply"])
        XCTAssertEqual(comment.status, .accepted)
        XCTAssertTrue(comment.isMarked)
        try await TestSupport.save(state, tab)

        let raw = try XCTUnwrap(RawPDF.File(url))
        let annots = raw.annotations()
        let texts = raw.annotations(subtype: "Text")
        XCTAssertEqual(texts.count, 5)
        let root = try XCTUnwrap(annots.firstIndex { RawPDF.string($0, "Contents") == "Top-level note" })
        let review = try XCTUnwrap(texts.first { RawPDF.name($0, "StateModel") == "Review" })
        XCTAssertEqual(RawPDF.name(review, "State"), "Accepted")
        XCTAssertEqual(RawPDF.irtIndex(review, in: annots), root)
        XCTAssertEqual(RawPDF.name(texts.first { RawPDF.name($0, "StateModel") == "Marked" }!, "State"), "Marked")
        let first = try XCTUnwrap(texts.first { RawPDF.string($0, "Contents") == "First reply" })
        XCTAssertEqual(RawPDF.irtIndex(first, in: annots), root)
        XCTAssertEqual(RawPDF.name(first, "RT"), "R")
        let nested = try XCTUnwrap(texts.first { RawPDF.string($0, "Contents") == "Nested reply" })
        XCTAssertEqual(RawPDF.irtIndex(nested, in: annots), annots.firstIndex(of: first))
        XCTAssertEqual(Int(RawPDF.number(first, "F") ?? 0) & 2, 2, "replies are hidden on the page")

        // Reopened: threads, status and checkmark come back from /IRT.
        let (state2, tab2) = try await reopen(url)
        var loaded = try XCTUnwrap(state2.annotationService.comments(for: tab2).first)
        XCTAssertEqual(state2.annotationService.comments(for: tab2).count, 1)
        XCTAssertEqual(loaded.status, .accepted)
        XCTAssertEqual(loaded.statusAuthor, "Test Reviewer")
        XCTAssertTrue(loaded.isMarked)
        XCTAssertEqual(loaded.replies.first?.replies.first?.text, "Nested reply")
        // Edit a saved reply, reply to a saved comment, change status.
        state2.editCommentText(try XCTUnwrap(loaded.replies.first), text: "First reply (edited)")
        state2.replyToComment(loaded, text: "Second reply")
        state2.setCommentStatus(.rejected, for: loaded)
        try await TestSupport.save(state2, tab2)
        let (state3, tab3) = try await reopen(url)
        loaded = try XCTUnwrap(state3.annotationService.comments(for: tab3).first)
        XCTAssertEqual(loaded.replies.map(\.text), ["First reply (edited)", "Second reply"])
        XCTAssertEqual(loaded.status, .rejected)

        // Deleting the parent removes the whole thread.
        state3.deleteComment(loaded)
        XCTAssertTrue(state3.annotationService.comments(for: tab3).isEmpty)
        try await TestSupport.save(state3, tab3)
        XCTAssertTrue(try XCTUnwrap(RawPDF.File(url)).annotations().isEmpty)
    }

    // MARK: 41 FDF / XFDF / PDF import-export

    func testExportImportCommentsRoundTrip() async throws {
        let (state, tab, url) = try await open()
        let service = state.annotationService
        let note = try XCTUnwrap(service.addAnnotation(.stickyNote, at: CGPoint(x: 400, y: 700), onPage: 0, in: tab))
        note.contents = "Exported note"
        _ = service.addShape(.polygon, points: [CGPoint(x: 50, y: 400), CGPoint(x: 150, y: 400), CGPoint(x: 100, y: 480)], onPage: 0, in: tab)
        state.commitCommentEdit("Add")
        state.replyToComment(try XCTUnwrap(service.comments(for: tab).first { $0.kind == .note }), text: "Exported reply")
        // Export includes unsaved edits; the user's file is untouched.
        let before = try Data(contentsOf: url)
        let xfdf = directories[0].appendingPathComponent("c.xfdf")
        let fdf = directories[0].appendingPathComponent("c.fdf")
        let exportedX = await state.exportComments(format: "xfdf", to: xfdf)
        XCTAssertTrue(exportedX)
        let exportedF = await state.exportComments(format: "fdf", to: fdf)
        XCTAssertTrue(exportedF)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try String(contentsOf: xfdf, encoding: .utf8).contains("Exported reply"))
        XCTAssertTrue(try Data(contentsOf: fdf).starts(with: Data("%FDF-1.2".utf8)))

        for source in [xfdf, fdf] {
            let (target, targetTab, targetURL) = try await open()
            let imported = await target.importComments(from: source)
            XCTAssertTrue(imported, "import \(source.pathExtension)")
            let list = target.annotationService.comments(for: targetTab)
            XCTAssertEqual(list.count, 2)
            XCTAssertEqual(list.first { $0.kind == .note }?.replies.map(\.text), ["Exported reply"])
            try await TestSupport.save(target, targetTab)
            XCTAssertEqual(try XCTUnwrap(RawPDF.File(targetURL)).annotations(subtype: "Polygon").count, 1)
        }
        // Import straight from another PDF's comments.
        try await TestSupport.save(state, tab)
        let (other, otherTab, _) = try await open()
        let copied = await other.importComments(from: url)
        XCTAssertTrue(copied)
        XCTAssertEqual(other.annotationService.comments(for: otherTab).count, 2)
    }

    // MARK: 42–45 Summary, compare, flatten, visibility

    func testSummaryCompareFlattenAndPresentationOnlyHiding() async throws {
        let (state, tab, url) = try await open()
        let service = state.annotationService
        let original = directories[0].appendingPathComponent("original.pdf")
        try FileManager.default.copyItem(at: url, to: original)
        let note = try XCTUnwrap(service.addAnnotation(.stickyNote, at: CGPoint(x: 400, y: 700), onPage: 0, in: tab))
        note.contents = "Summarized note"
        _ = service.addShape(.rectangle, points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)], onPage: 0, in: tab)
        state.commitCommentEdit("Add")
        state.replyToComment(try XCTUnwrap(service.comments(for: tab).first { $0.kind == .note }), text: "Summarized reply")

        // 42: summary PDF lists comments with page references.
        let data = CommentSummary.render(title: tab.displayName, document: try XCTUnwrap(tab.pdfDocument), comments: service.comments(for: tab))
        let summary = try XCTUnwrap(PDFDocument(data: data))
        let text = summary.string ?? ""
        XCTAssertTrue(text.contains("Summary of Comments"))
        XCTAssertTrue(text.contains("Page 1"))
        XCTAssertTrue(text.contains("Summarized note") && text.contains("Summarized reply"))

        // 43: compare with the earlier version.
        await state.compareComments(with: original)
        let comparison = try XCTUnwrap(state.comments.comparison)
        XCTAssertEqual(comparison.added.count, 3, "note, its reply and the rectangle")
        XCTAssertTrue(comparison.removed.isEmpty)

        // 45: hiding is presentation only.
        state.setCommentsVisible(false)
        XCTAssertFalse(note.shouldDisplay)
        try await TestSupport.save(state, tab)
        let saved = try XCTUnwrap(RawPDF.File(url)?.annotations(subtype: "Text").first { RawPDF.string($0, "Contents") == "Summarized note" })
        XCTAssertEqual(Int(RawPDF.number(saved, "F") ?? 0) & 2, 0, "Hide All never writes the hidden flag")
        state.setCommentsVisible(true)
        // On-page filter by type.
        tab.commentReviewQuery.kind = .shape
        state.comments.filtersCanvas = true
        state.refreshCommentVisibility()
        let page = try page(tab)
        XCTAssertFalse(try XCTUnwrap(page.annotations.first { $0.type == "Text" && $0.contents == "Summarized note" }).shouldDisplay)
        XCTAssertTrue(try XCTUnwrap(page.annotations.first { $0.type == "Square" }).shouldDisplay)
        state.comments.filtersCanvas = false
        tab.commentReviewQuery.kind = nil
        state.refreshCommentVisibility()

        // 44: flatten draws comments into the page (Undo-able).
        let flattened = await state.flattenComments(confirm: false)
        XCTAssertTrue(flattened)
        XCTAssertTrue(service.comments(for: tab).isEmpty)
        tab.undoHistory?.manager.undo()
        XCTAssertEqual(service.comments(for: tab).count, 2)
        tab.undoHistory?.manager.redo()
        try await TestSupport.save(state, tab)
        XCTAssertTrue(try XCTUnwrap(RawPDF.File(url)).annotations().filter { RawPDF.name($0, "Subtype") != "Popup" }.isEmpty)
    }

    // MARK: Canvas editing of existing comments

    func testMovingAndResizingSavedCommentsUpdatesGeometry() async throws {
        let (state, tab, url) = try await open()
        let service = state.annotationService
        _ = service.addShape(.polygon, points: [CGPoint(x: 50, y: 400), CGPoint(x: 150, y: 400), CGPoint(x: 100, y: 480)], onPage: 0, in: tab)
        let points = (0...20).map { CGPoint(x: 300 + CGFloat($0) * 5, y: 300 + CGFloat($0 % 5) * 4) }
        _ = service.addInkAnnotation(points: points, onPage: 0, in: tab)
        state.commitCommentEdit("Add")
        try await TestSupport.save(state, tab)
        let polygon = try XCTUnwrap(try page(tab).annotations.first { $0.type == "Polygon" })
        let prepared = state.prepareForEditing(CommentSelection(annotation: polygon, page: try page(tab)))
        prepared.annotation.bounds = prepared.annotation.bounds.offsetBy(dx: 10, dy: 20)
        (prepared.annotation as? CommentAnnotation)?.syncStandardKeys()
        let ink = try XCTUnwrap(try page(tab).annotations.first { $0.type == "Ink" })
        ink.bounds = ink.bounds.offsetBy(dx: 0, dy: -100)
        state.commitCommentEdit("Move")
        XCTAssertTrue(tab.hasUnsavedChanges)
        try await TestSupport.save(state, tab)
        let raw = try XCTUnwrap(RawPDF.File(url))
        XCTAssertEqual(RawPDF.numbers(try XCTUnwrap(raw.annotations(subtype: "Polygon").first), "Vertices"), [60, 420, 160, 420, 110, 500])
        XCTAssertEqual(raw.annotations(subtype: "Polygon").count, 1)
        let inkRect = RawPDF.numbers(try XCTUnwrap(raw.annotations(subtype: "Ink").first), "Rect")
        XCTAssertEqual(inkRect.count, 4)
        XCTAssertLessThan(inkRect.dropFirst().first ?? 999, 210)
    }
}
