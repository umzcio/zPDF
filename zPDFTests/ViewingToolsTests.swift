import PDFKit
import SwiftUI
import XCTest
@testable import zPDF

/// Print, share, measure, accessibility and automation: UI-level entry
/// points driven against the real bundled engine, then saved and reopened.
@MainActor
final class ViewingToolsTests: XCTestCase {
    private func open(_ fixture: String) async throws -> (AppState, DocumentTab, URL, URL) {
        let (url, directory) = try TestSupport.fixture(fixture, in: Self.self)
        let state = AppState()
        let tab = try await TestSupport.open(url, in: state)
        return (state, tab, url, directory)
    }

    private func field(_ tab: DocumentTab) throws -> PDFAnnotation {
        try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.widgetFieldType == .text && !$0.isReadOnly })
    }

    // MARK: Print

    func testPrintCopyIncludesUnsavedEditsAndLayouts() async throws {
        let (state, tab, url, directory) = try await open("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        try field(tab).widgetStringValue = "PRINTED VALUE"
        state.refreshUnsavedChanges(tab)
        let letter = CGSize(width: 612, height: 792)

        var options = PrintOptions()
        options.scope = .current
        let single = try await PrintService.prepare(tab, options: options, paper: letter, area: nil)
        XCTAssertEqual(single.document.pageCount, 1)
        XCTAssertTrue(single.document.page(at: 0)?.string?.contains("PRINTED VALUE") == true, "Flattened field value prints")
        XCTAssertTrue(single.document.page(at: 0)?.annotations.isEmpty == true)

        options = PrintOptions()
        options.sizing = .multiple
        options.columns = 2
        options.rows = 2
        let nup = try await PrintService.prepare(tab, options: options, paper: letter, area: nil)
        XCTAssertEqual(nup.document.pageCount, Int(ceil(Double(tab.pageCount) / 4)))

        options = PrintOptions()
        options.sizing = .booklet
        let booklet = try await PrintService.prepare(tab, options: options, paper: letter, area: nil)
        let padded = Int(ceil(Double(tab.pageCount) / 4)) * 4
        XCTAssertEqual(booklet.document.pageCount, padded / 2)
        let side = try XCTUnwrap(booklet.document.page(at: 0)?.bounds(for: .cropBox))
        XCTAssertGreaterThan(side.width, side.height, "Booklet sides are landscape")

        options = PrintOptions()
        options.scope = .area
        let area = try await PrintService.prepare(tab, options: options, paper: letter,
                                                  area: (0, CGRect(x: 36, y: 400, width: 300, height: 200)))
        XCTAssertEqual(area.document.pageCount, 1)
        XCTAssertEqual(area.document.page(at: 0)?.bounds(for: .cropBox).width ?? 0, 300, accuracy: 1)

        options = PrintOptions()
        options.sizing = .poster
        options.posterScale = 200
        options.scope = .current
        let poster = try await PrintService.prepare(tab, options: options, paper: letter, area: nil)
        XCTAssertGreaterThanOrEqual(poster.document.pageCount, 4)

        options = PrintOptions()
        options.content = .documentWithoutFields
        options.scope = .current
        let noFields = try await PrintService.prepare(tab, options: options, paper: letter, area: nil)
        XCTAssertFalse(noFields.document.page(at: 0)?.string?.contains("PRINTED VALUE") == true)

        // The print operation is built from the prepared copy.
        let operation = try PrintService.operation(for: single, title: tab.displayName)
        XCTAssertEqual(operation.jobTitle, tab.displayName)
        XCTAssertEqual(try Data(contentsOf: url), original, "Printing never writes the user's file")
        XCTAssertThrowsError(try PrintService.operations(PrintOptions(scope: .range, range: "0-2"), pageCount: tab.pageCount,
                                                          currentPage: 0, paper: letter, area: nil))
    }

    func testPrintPresetsPersist() {
        let name = "zpdf.tests.print.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PrintPresetStore(defaults: defaults)
        var options = PrintOptions()
        options.sizing = .booklet
        options.scope = .area
        store.save(options, as: "Booklets")
        let reloaded = PrintPresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.names, ["Booklets"])
        XCTAssertEqual(reloaded.presets["Booklets"]?.sizing, .booklet)
        XCTAssertEqual(reloaded.presets["Booklets"]?.scope, .all, "Selected areas are not saved in presets")
    }

    // MARK: Share

    func testSharedCopyContainsEditsNotOriginal() async throws {
        let (state, tab, url, directory) = try await open("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        try field(tab).widgetStringValue = "SHARED VALUE"
        state.refreshUnsavedChanges(tab)
        let shared = try await ShareService.sharedCopy(of: tab)
        XCTAssertEqual(shared.lastPathComponent, "uscis-i9.pdf")
        XCTAssertNotEqual(shared.standardizedFileURL, url.standardizedFileURL)
        let document = try XCTUnwrap(PDFDocument(url: shared))
        let value = document.page(at: 0)?.annotations.first { $0.fieldName == (try? field(tab))?.fieldName }?.widgetStringValue
        XCTAssertEqual(value, "SHARED VALUE")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(tab.hasUnsavedChanges)
    }

    // MARK: Measure

    func testMeasurementsSaveAsMeasureAnnotations() async throws {
        let (state, tab, url, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        state.preferences.measureScalePage = 1
        state.preferences.measureScalePageUnit = .inch
        state.preferences.measureScaleReal = 10
        state.preferences.measureScaleRealUnit = .ft
        state.preferences.measureUseDocumentScale = false
        let scale = state.features.measure.scale(for: tab, page: 0, preferences: state.preferences)
        XCTAssertEqual(scale.ratio, "1 in = 10 ft")
        let (value, _, label) = MeasureSession.value(kind: .distance, points: [CGPoint(x: 72, y: 72), CGPoint(x: 216, y: 72)],
                                                     scale: scale, precision: 2)
        XCTAssertEqual(value, 20, accuracy: 0.001)
        XCTAssertEqual(label, "20.00 ft")
        let areaValue = MeasureSession.value(kind: .area, points: [CGPoint(x: 0, y: 0), CGPoint(x: 72, y: 0), CGPoint(x: 72, y: 72)],
                                             scale: scale, precision: 1)
        XCTAssertEqual(areaValue.0, 50, accuracy: 0.001)
        let measurement = MeasureSession.Measurement(tabID: tab.id, page: 0, kind: .distance,
                                                     points: [CGPoint(x: 72, y: 72), CGPoint(x: 216, y: 72)],
                                                     value: value, unit: "ft", label: label, ratio: scale.ratio, committed: false)
        state.features.measure.add(measurement)
        state.commitMeasurements([measurement], in: tab)
        for _ in 0..<300 where state.features.measure.measurements(for: tab.id).first?.committed != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.features.measure.measurements(for: tab.id).first?.committed, true)
        try await TestSupport.save(state, tab)
        let saved = try await NativeDocumentBridge.query(source: url, hash: nil, name: "measurements").decode(DocumentMeasurementsResult.self)
        XCTAssertEqual(saved.items.first?.label, "20.00 ft")
        XCTAssertEqual(saved.items.first?.ratio, "1 in = 10 ft")
        XCTAssertEqual(saved.items.first?.subtype, "Line")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.type == "Line" } == true)
        let csv = MeasurementCSV.make(document: saved.items, pending: [], fileName: "doc, 1.pdf")
        XCTAssertTrue(csv.hasPrefix("Document,Page,Type,Measurement"))
        XCTAssertTrue(csv.contains("\"doc, 1.pdf\",1,Distance,20.00 ft,1 in = 10 ft"))
    }

    func testSnapPrefersEndpointsAndProjectsOntoPaths() {
        let session = MeasureSession()
        let preferences = AppPreferences(defaults: UserDefaults(suiteName: "zpdf.tests.snap.\(UUID())")!)
        session.snapCache["k"] = .init(endpoints: [CGPoint(x: 100, y: 100)], midpoints: [CGPoint(x: 150, y: 100)],
                                       intersections: [], segments: [(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))])
        let (endpoint, kind) = session.snap(CGPoint(x: 103, y: 102), key: "k", tolerance: 8, preferences: preferences, gridStep: nil)
        XCTAssertEqual(endpoint, CGPoint(x: 100, y: 100))
        XCTAssertEqual(kind, .endpoint)
        let (mid, midKind) = session.snap(CGPoint(x: 148, y: 103), key: "k", tolerance: 8, preferences: preferences, gridStep: nil)
        XCTAssertEqual(mid, CGPoint(x: 150, y: 100))
        XCTAssertEqual(midKind, .midpoint)
        let (onPath, pathKind) = session.snap(CGPoint(x: 180, y: 104), key: "k", tolerance: 8, preferences: preferences, gridStep: nil)
        XCTAssertEqual(onPath, CGPoint(x: 180, y: 100))
        XCTAssertEqual(pathKind, .path)
        let (free, none) = session.snap(CGPoint(x: 400, y: 400), key: "k", tolerance: 8, preferences: preferences, gridStep: nil)
        XCTAssertEqual(free, CGPoint(x: 400, y: 400))
        XCTAssertNil(none)
    }

    // MARK: Accessibility

    func testAccessibilityFixesAutotagAndSave() async throws {
        let (state, tab, url, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try await state.documentQuery("accessibility_check", in: tab, as: AccessibilityReport.self)
        let tagged = try XCTUnwrap(before.items.first { $0.id == "tagged_pdf" })
        if !before.tagged { XCTAssertEqual(tagged.status, .failed) }
        try await state.applyDocumentTransform([
            ["op": "autotag", "replace": before.tagged, "language": "en-US"],
            ["op": "set_title", "title": "Edge Report", "display_doc_title": true]
        ], to: tab, actionName: "Autotag Document")
        let after = try await state.documentQuery("accessibility_check", in: tab, as: AccessibilityReport.self)
        XCTAssertTrue(after.tagged)
        XCTAssertEqual(after.items.first { $0.id == "title" }?.status, .passed)
        XCTAssertEqual(after.items.first { $0.id == "primary_language" }?.status, .passed)
        let tree = try await state.documentQuery("structure_tree", in: tab, as: StructureTreeResult.self)
        let root = try XCTUnwrap(tree.root)
        XCTAssertGreaterThan(root.flattened().count, 2)
        // Rename the first content tag via the Tags editor op.
        let firstLeaf = try XCTUnwrap(root.flattened().first { $0.page != nil && $0.id != "root" })
        try await state.applyDocumentTransform([["op": "edit_structure", "edits": [["id": firstLeaf.id, "set": ["title": "First"]]]]],
                                               to: tab, actionName: "Edit Tag")
        try await TestSupport.save(state, tab)
        let saved = try await NativeDocumentBridge.query(source: url, hash: nil, name: "accessibility_check").decode(AccessibilityReport.self)
        XCTAssertTrue(saved.tagged)
        let savedTree = try await NativeDocumentBridge.query(source: url, hash: nil, name: "structure_tree").decode(StructureTreeResult.self)
        XCTAssertTrue(savedTree.root?.flattened().contains { $0.title == "First" } == true)
        XCTAssertEqual(PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Edge Report")
    }

    // MARK: Action Wizard

    func testActionRunsOnDocumentAndBatch() async throws {
        let (state, tab, url, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = SavedAction(name: "Stamp", details: "", steps: [
            SavedAction.step("watermark", ["text": .text("FOR <<author>>")]),
            SavedAction.step("flatten_layers"),
            SavedAction.step("fast_web_view")
        ])
        state.preferences.commentAuthor = "Review Team"
        let context = StepContext.make(fileName: "x.pdf", preferences: state.preferences)
        let docOps = action.operations(context: context, forBatch: false)
        XCTAssertEqual(docOps.count, 2, "Batch-only steps are skipped for an open document")
        let ran = await state.runAction(action, on: tab)
        XCTAssertTrue(ran)
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.string?.contains("FOR Review Team") == true)
        tab.undoHistory?.manager.undo()
        XCTAssertFalse(tab.pdfDocument?.page(at: 0)?.string?.contains("FOR Review Team") == true)

        // Batch into a new folder: the source is untouched, output is linearized.
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let before = try Data(contentsOf: url)
        let run = BatchRun()
        run.start(action: action, files: [url, directory.appendingPathComponent("missing.pdf")], output: output, suffix: " done",
                  preferences: state.preferences, openTabs: [])
        for _ in 0..<500 where run.running { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(run.results.count, 2)
        XCTAssertEqual(run.results.filter(\.succeeded).count, 1)
        let produced = try XCTUnwrap(run.results.first(where: \.succeeded)?.output)
        XCTAssertEqual(produced.lastPathComponent, "ordinary-edge done.pdf")
        XCTAssertTrue(TestSupport.text(produced).contains("FOR Review Team"))
        let props = try DocumentPropertiesModel.load(try await NativeDocumentBridge.query(source: produced, hash: nil, name: "document_properties"))
        XCTAssertTrue(props.linearized)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(BatchRun.outputURL(for: url, in: output, suffix: " done").lastPathComponent, "ordinary-edge done 2.pdf")
    }

    func testJavaScriptInspectorQueryAndRemove() async throws {
        let (state, tab, _, directory) = try await open("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scripts = try await state.documentQuery("document_javascript", in: tab, as: JavaScriptResult.self)
        if !scripts.items.isEmpty {
            try await state.applyDocumentTransform([["op": "remove_javascript"]], to: tab, actionName: "Delete Scripts")
            let after = try await state.documentQuery("document_javascript", in: tab, as: JavaScriptResult.self)
            XCTAssertTrue(after.items.isEmpty)
        }
    }

    // MARK: Search

    func testSearchMatcherModes() throws {
        let text = "The runner was running fast. Running shoes help runners run. café Cafe"
        XCTAssertEqual(try SearchMatcher(query: "running", options: SearchOptions()).matches(in: text).count, 2)
        var options = SearchOptions()
        options.caseSensitive = true
        XCTAssertEqual(try SearchMatcher(query: "running", options: options).matches(in: text).count, 1)
        options = SearchOptions()
        options.wholeWords = true
        XCTAssertEqual(try SearchMatcher(query: "run", options: options).matches(in: text).count, 1)
        options = SearchOptions()
        options.regex = true
        XCTAssertEqual(try SearchMatcher(query: "run+ers?\\b", options: options).matches(in: text).count, 2)
        XCTAssertThrowsError(try SearchMatcher(query: "(", options: options))
        options = SearchOptions()
        options.stemming = true
        XCTAssertGreaterThanOrEqual(try SearchMatcher(query: "run", options: options).matches(in: text).count, 3)
        options = SearchOptions()
        options.proximity = 3
        XCTAssertEqual(try SearchMatcher(query: "shoes runners", options: options).matches(in: text).count, 1)
        options.proximity = 1
        XCTAssertEqual(try SearchMatcher(query: "fast runners", options: options).matches(in: text).count, 0)
        XCTAssertEqual(try SearchMatcher(query: "cafe", options: SearchOptions()).matches(in: text).count, 2, "Diacritics ignored")
        let matcher = try SearchMatcher(query: "shoes", options: SearchOptions())
        let hit = matcher.hit(in: text, range: (text as NSString).range(of: "shoes"), document: URL(fileURLWithPath: "/x.pdf"), location: .page(0))
        XCTAssertEqual(hit.match, "shoes")
        XCTAssertTrue(hit.before.hasSuffix("Running"))
    }

    func testSearchesOpenDocumentWithBookmarksAndComments() async throws {
        let (state, tab, url, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await state.applyDocumentTransform([["op": "set_outline", "items": [["title": "Zebra Chapter", "page": 0]]]],
                                               to: tab, actionName: "Add Bookmark")
        let source = try XCTUnwrap(tab.editSource?.url)
        var options = SearchOptions()
        options.includeBookmarks = true
        let document = try XCTUnwrap(SearchableDocument.load(source, options: options, displayURL: url))
        XCTAssertEqual(document.bookmarks, ["Zebra Chapter"])
        let hits = try SearchMatcher(query: "zebra", options: options).search(document, limit: 10)
        XCTAssertTrue(hits.contains { $0.location == .bookmark("Zebra Chapter") })
        XCTAssertEqual(hits.first?.document, url)
    }

    // MARK: Shortcuts & preferences

    func testShortcutRebindingResolvesConflictsAndPersists() {
        let name = "zpdf.tests.shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.binding(for: .documentProperties)?.displayText, "⌘D")
        let binding = ShortcutBinding("d")
        store.set(binding, for: .rulers)
        XCTAssertEqual(store.binding(for: .rulers), binding)
        XCTAssertNil(store.binding(for: .documentProperties), "The conflicting command loses the shortcut")
        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .rulers), binding)
        XCTAssertNil(reloaded.binding(for: .documentProperties))
        XCTAssertTrue(reloaded.isReserved(ShortcutBinding("q")))
        reloaded.resetAll()
        XCTAssertEqual(reloaded.binding(for: .documentProperties)?.displayText, "⌘D")
        XCTAssertFalse(ShortcutStore(defaults: defaults).isCustomized)
        // Every default is unique.
        let defaultsList = AppCommandID.allCases.compactMap(\.defaultBinding)
        XCTAssertEqual(Set(defaultsList).count, defaultsList.count)
    }

    func testNewPreferencesPersistAndZoomSteps() {
        let name = "zpdf.tests.prefs2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.documentColorMode = .night
        preferences.pageUnits = .picas
        preferences.zoomSteps = [2.5, 0.5, 1, 1, 0.1]
        preferences.favoriteTools = [ToolID.measureObjects.rawValue]
        preferences.linkPolicy = .block
        preferences.identityEmail = "a@example.com"
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.documentColorMode, .night)
        XCTAssertEqual(reloaded.pageUnits, .picas)
        XCTAssertEqual(reloaded.zoomSteps, [0.5, 1, 2])
        XCTAssertEqual(reloaded.favoriteTools, ["measureObjects"])
        XCTAssertEqual(reloaded.linkPolicy, .block)
        XCTAssertEqual(reloaded.identityEmail, "a@example.com")
        XCTAssertEqual(AppState.steppedZoom(from: 1, direction: .in, steps: [0.5, 1, 1.5]), 1.5)
        XCTAssertEqual(AppState.steppedZoom(from: 1, direction: .out, steps: [0.5, 1, 1.5]), 0.5)
        reloaded.reset()
        XCTAssertEqual(reloaded.documentColorMode, .original)
        XCTAssertEqual(reloaded.identityEmail, "a@example.com", "Identity survives Restore Defaults")
    }

    func testSettingsRegistryHasEveryCategoryAndAcceptsNewOnes() {
        let ids = SettingsRegistry.sections.map(\.id)
        for id in [SettingsSectionID.general, .documents, .display, .commenting, .forms, .identity, .accessibility, .search,
                   .measuring, .spelling, .signatures, .security, .units, .fullScreen, .reading, .keyboard, .tools, .print] {
            XCTAssertTrue(ids.contains(id), "\(id.rawValue) missing")
        }
        SettingsRegistry.register(SettingsSection(id: SettingsSectionID("test"), title: "Test Section", symbol: "star",
                                                  keywords: "zebra", order: 5) { _ in AnyView(EmptyView()) })
        let sections = SettingsRegistry.sections
        XCTAssertEqual(sections.first { $0.id.rawValue == "test" }?.title, "Test Section")
        XCTAssertEqual(sections.firstIndex { $0.id.rawValue == "test" }, 1, "Ordered by `order`")
        XCTAssertTrue(sections.first { $0.id.rawValue == "test" }!.matches(["zebra"]))
    }

    func testHelpCatalogCoversShippedTools() {
        let topics = HelpCatalog.topics
        for tool in ToolID.allCases where tool.isImplemented && [.measureObjects, .accessibilityCheck, .actionWizard, .share].contains(tool) {
            XCTAssertTrue(topics.contains { $0.tool == tool }, "\(tool) has no help page")
        }
        XCTAssertFalse(topics.filter { $0.matches("booklet") }.isEmpty)
        XCTAssertNotNil(HelpCatalog.topic(HelpCatalog.gettingStarted))
    }

    func testReflowJoinsWrappedLines() async throws {
        let (_, tab, _, directory) = try await open("ordinary-edge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = ReflowText.make(page: tab.pdfDocument?.page(at: 0), scale: 1)
        XCTAssertFalse(String(text.characters).isEmpty)
        let empty = ReflowText.make(page: nil, scale: 1)
        XCTAssertTrue(String(empty.characters).contains("no text"))
    }
}
