import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class NativeSaveTests: XCTestCase {
    func testSavedCommentsProduceNativeCommentEdits() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let baseline = SaveBaseline(document)
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        let id = UUID()
        note.setValue(id.uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/ZPDFCommentID"))
        page.addAnnotation(note)
        XCTAssertFalse(baseline.containsComment(id: id))
        note.contents = "Editable before Save"
        XCTAssertEqual(try baseline.changes(in: document).notes.count, 1)
        let savedBaseline = SaveBaseline(document)
        XCTAssertTrue(savedBaseline.containsComment(id: id))
        note.contents = "Existing comment edit must stay unavailable"
        XCTAssertEqual(try savedBaseline.changes(in: document).comments.count, 1)
    }

    private func fixture(_ name: String) throws -> (URL, URL) {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pdf"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Save test ü \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(name).pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        return (copy, directory)
    }

    private func settled(_ tab: DocumentTab) async throws {
        for _ in 0..<500 {
            if !tab.saveChecking && !tab.isSaving { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Engine operation did not finish")
    }

    private func lastName(_ document: PDFDocument) throws -> PDFAnnotation {
        try XCTUnwrap(document.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" })
    }

    func testSidebarNavigationPreservesDocumentAndDisarmsHiddenTools() throws {
        let state = AppState()
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let tab = DocumentTab(pdfDocument: document)
        state.tabs.append(tab)
        state.selectTab(tab)
        state.sidebarVisible = false
        state.openTool(.comment)
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertEqual(state.documentPanel, .comments)
        XCTAssertEqual(state.activePanel, .comment)
        state.armedAnnotationTool = .stickyNote
        state.showAllTools()
        XCTAssertNil(state.activePanel)
        XCTAssertNil(state.armedAnnotationTool)
        XCTAssertTrue(state.activeTab === tab)
        XCTAssertTrue(tab.pdfDocument === document)
        state.openTool(.organizePages)
        XCTAssertEqual(state.activePanel, .organize)
        state.sidebarVisible = false
        state.toggleDocumentPanel(.pages)
        XCTAssertEqual(state.documentPanel, .pages)
        XCTAssertEqual(state.activePanel, .organize)
        XCTAssertFalse(state.sidebarVisible)
        state.toggleDocumentPanel(.pages)
        XCTAssertNil(state.documentPanel)
        tab.saveBlock = "XFA_EDIT_BLOCKED"
        state.toggleDocumentPanel(.bookmarks)
        XCTAssertEqual(state.documentPanel, .bookmarks)
        XCTAssertTrue(tab.pdfDocument === document)
        state.showAllTools()
        XCTAssertNil(state.activePanel, "Back leaves the organizer canvas")
        state.openTool(.sendForSignature)
        XCTAssertNil(state.activePanel, "Unimplemented tools stay unavailable")
    }

    func testHomeAndToolsDrawerPreserveEditsAndDisarmCanvasActions() throws {
        let suite = "Navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(preferences: AppPreferences(defaults: defaults))
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let field = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 100, height: 20),
                                  forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "navigation-test"
        field.widgetStringValue = "Unsaved value"
        page.addAnnotation(field)
        let tab = DocumentTab(pdfDocument: document)
        state.tabs.append(tab)
        state.selectTab(tab)
        tab.hasUnsavedChanges = true
        state.sidebarVisible = false

        state.useQuickAnnotation(.stickyNote)
        XCTAssertEqual(state.armedAnnotationTool, .stickyNote)
        XCTAssertEqual(state.documentPanel, .comments)
        XCTAssertFalse(state.sidebarVisible, "Quick actions do not force open the tools drawer")
        state.showHome()
        XCTAssertEqual(state.railSelection, .home)
        XCTAssertNil(state.armedAnnotationTool)
        XCTAssertTrue(state.activeTab === tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(field.widgetStringValue, "Unsaved value")
        state.selectTab(tab)
        XCTAssertEqual(state.railSelection, .document)
        XCTAssertTrue(tab.pdfDocument === document)

        state.toggleAllTools()
        XCTAssertTrue(state.sidebarVisible)
        state.openTool(.organizePages)
        XCTAssertEqual(state.activePanel, .organize)
        state.toggleAllTools()
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertNil(state.activePanel, "All tools leaves a detail panel for the catalog")
        state.toggleAllTools()
        XCTAssertFalse(state.sidebarVisible)
        XCTAssertEqual(state.toolsFocusRequest, 1)
        state.openTool(.fillAndSign)
        state.closeTools()
        XCTAssertNil(state.activePanel)
        XCTAssertFalse(state.sidebarVisible)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(field.widgetStringValue, "Unsaved value")
    }

    func testQuickToolsRespectReadOnlyPolicyAndSelectionDisarmsAnnotations() throws {
        let suite = "QuickTools-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(preferences: AppPreferences(defaults: defaults))
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let tab = DocumentTab(pdfDocument: document)
        state.tabs.append(tab)
        state.selectTab(tab)
        state.useQuickAnnotation(.highlight)
        XCTAssertEqual(state.armedAnnotationTool, .highlight)
        state.selectDocumentText()
        XCTAssertNil(state.armedAnnotationTool)
        tab.saveBlock = "XFA_EDIT_BLOCKED"
        for tool in [AnnotationTool.highlight, .underline, .stickyNote] {
            state.useQuickAnnotation(tool)
            XCTAssertNil(state.armedAnnotationTool)
        }
        state.showAllTools()
        XCTAssertTrue(state.sidebarVisible, "Reading and tool discovery remain available")
        state.openTool(.fillAndSign)
        XCTAssertNil(state.activePanel)
        state.showHome()
        state.selectTab(tab)
        XCTAssertTrue(tab.pdfDocument === document)
        XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
    }

    func testSwitchingDocumentsDisarmsToolsAndFinderAliasesReuseOneTab() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        let lifecycle = AppLifecycle()
        lifecycle.application(NSApplication.shared, open: [url])
        lifecycle.appState = state
        let first = try XCTUnwrap(state.activeTab)
        try await settled(first)
        let alias = directory.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        lifecycle.application(NSApplication.shared, open: [alias])
        XCTAssertEqual(state.tabs.count, 1)
        let copy = directory.appendingPathComponent("second.pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        state.openTool(.organizePages)
        state.armedAnnotationTool = .stickyNote
        lifecycle.application(NSApplication.shared, open: [copy])
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertNil(state.armedAnnotationTool); XCTAssertNil(state.activePanel)
        state.selectTab(first)
        XCTAssertTrue(state.activeTab === first)
        XCTAssertNil(state.activePanel)
        var reopened = false
        lifecycle.showMainWindow = { reopened = true }
        XCTAssertTrue(lifecycle.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertTrue(reopened)
    }

    func testSaveUsesEngineAndReloadsOriginatingTabWithFieldAndNote() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: url)
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        XCTAssertNil(state.saveError, state.saveError?.message ?? "")
        XCTAssertTrue(tab.allowsSaveEdits)
        state.openTool(.fillAndSign)
        let originalDisplay = try XCTUnwrap(tab.pdfDocument)
        try lastName(originalDisplay).widgetStringValue = "APP ENGINE SAVE"
        state.showAllTools()
        state.openTool(.comment)
        let note = PDFAnnotation(bounds: CGRect(x: 35, y: 720, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "APP ENGINE NOTE"
        originalDisplay.page(at: 0)?.addAnnotation(note)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "No writes before Save")
        state.saveActiveDocument()
        // Changing focus while the helper runs must not redirect Save/reload.
        let other = DocumentTab(pdfDocument: PDFDocument())
        state.tabs.append(other)
        state.selectTab(other)
        try await settled(tab)
        XCTAssertNil(state.saveError, state.saveError?.message ?? "")
        XCTAssertTrue(state.activeTab === other)
        XCTAssertFalse(tab.pdfDocument === originalDisplay)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(try lastName(reopened).widgetStringValue, "APP ENGINE SAVE")
        XCTAssertFalse(try lastName(reopened).isReadOnly)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { $0.contents == "APP ENGINE NOTE" }.count, 1)
        // A second Save uses the refreshed baseline, without duplicating notes.
        state.selectTab(tab)
        state.saveActiveDocument()
        try await settled(tab)
        XCTAssertNil(state.saveError, state.saveError?.message ?? "")
        let again = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(again.page(at: 0)?.annotations.filter { $0.contents == "APP ENGINE NOTE" }.count, 1)
    }

    func testXFAIsReadOnlyAndCannotSave() async throws {
        let (url, directory) = try fixture("irs-w9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: url)
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        XCTAssertEqual(tab.saveBlock, "XFA_EDIT_BLOCKED")
        XCTAssertFalse(tab.allowsSaveEdits)
        state.saveActiveDocument()
        XCTAssertNotNil(state.saveError)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSourceConflictDoesNotOverwriteExternalChange() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "UNSAVED EDIT"
        var changed = try Data(contentsOf: url)
        changed.append(Data("\n% external edit\n".utf8))
        try changed.write(to: url)
        state.saveActiveDocument()
        try await settled(tab)
        XCTAssertTrue(state.saveError?.message.contains("SOURCE_CHANGED") == true)
        XCTAssertEqual(try Data(contentsOf: url), changed)
        XCTAssertEqual(try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue, "UNSAVED EDIT")
    }

    func testUnsupportedPageInsertionIsNotSilentlyLost() throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let baseline = SaveBaseline(doc)
        doc.insert(PDFPage(), at: 0)
        XCTAssertThrowsError(try baseline.changes(in: doc)) { error in
            XCTAssertEqual((error as? NativeSaveError)?.code, "UNSUPPORTED_EDIT")
        }
    }

    private func close(_ state: AppState, tabs: [DocumentTab]? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            state.requestClose(tabs ?? state.tabs) { continuation.resume(returning: $0) }
        }
    }

    func testDirtyStateTracksEditsRevertAndUnsupportedChanges() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        let document = try XCTUnwrap(tab.pdfDocument)
        let field = try lastName(document)
        let original = field.widgetStringValue
        tab.setZoom(1.5)
        tab.goToPage(2)
        state.refreshUnsavedChanges(tab)
        XCTAssertFalse(tab.hasUnsavedChanges, "View state is not a document edit")
        field.widgetStringValue = "DIRTY"
        state.refreshUnsavedChanges(tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        field.widgetStringValue = original
        state.refreshUnsavedChanges(tab)
        XCTAssertFalse(tab.hasUnsavedChanges)
        document.page(at: 0)?.rotation = 90
        state.refreshUnsavedChanges(tab)
        XCTAssertTrue(tab.hasUnsavedChanges, "Page changes still need discard protection")
    }

    func testCancelKeepsEditsAndDiscardNeverWrites() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "KEEP ME"
        state.closeDecision = { _ in .cancel }
        let cancelled = await close(state)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(state.activeTab === tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertFalse(tab.isClosing)
        XCTAssertEqual(try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue, "KEEP ME")
        state.closeDecision = { _ in .discard }
        let discarded = await close(state)
        XCTAssertTrue(discarded)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCloseSavesRequestedInactiveTabBeforeRemovingIt() async throws {
        let (firstURL, firstDirectory) = try fixture("uscis-i9")
        let (secondURL, secondDirectory) = try fixture("uscis-i9")
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let secondBytes = try Data(contentsOf: secondURL)
        let state = AppState()
        state.openDocument(at: firstURL)
        let first = try XCTUnwrap(state.activeTab)
        try await settled(first)
        try lastName(XCTUnwrap(first.pdfDocument)).widgetStringValue = "SAVE FIRST"
        state.openDocument(at: secondURL)
        let second = try XCTUnwrap(state.activeTab)
        try await settled(second)
        state.closeDecision = { requested in
            XCTAssertTrue(requested === first)
            XCTAssertTrue(state.tabs.contains { $0 === first })
            return .save
        }
        let closed = await close(state, tabs: [first])
        XCTAssertTrue(closed)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertTrue(state.activeTab === second)
        XCTAssertEqual(try lastName(XCTUnwrap(PDFDocument(url: firstURL))).widgetStringValue, "SAVE FIRST")
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        XCTAssertFalse(first.hasUnsavedChanges)
    }

    func testFailedCloseSaveLeavesTabAndUnsavedValueIntact() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "DO NOT LOSE"
        var external = try Data(contentsOf: url)
        external.append(Data("\n% external change\n".utf8))
        try external.write(to: url)
        state.closeDecision = { _ in .save }
        let closed = await close(state)
        XCTAssertFalse(closed)
        XCTAssertTrue(state.activeTab === tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertFalse(tab.isSaving)
        XCTAssertFalse(tab.isClosing)
        XCTAssertTrue(state.saveError?.message.contains("SOURCE_CHANGED") == true)
        XCTAssertEqual(try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue, "DO NOT LOSE")
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testCancelledQuitRetainsPreviouslyDiscardedTabs() async throws {
        let (firstURL, firstDirectory) = try fixture("uscis-i9")
        let (secondURL, secondDirectory) = try fixture("uscis-i9")
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let state = AppState()
        state.openDocument(at: firstURL)
        let first = try XCTUnwrap(state.activeTab)
        try await settled(first)
        state.openDocument(at: secondURL)
        let second = try XCTUnwrap(state.activeTab)
        try await settled(second)
        try lastName(XCTUnwrap(first.pdfDocument)).widgetStringValue = "FIRST"
        try lastName(XCTUnwrap(second.pdfDocument)).widgetStringValue = "SECOND"
        var prompts = 0
        state.closeDecision = { tab in
            prompts += 1
            return tab === first ? .discard : .cancel
        }
        let closed = await close(state)
        XCTAssertFalse(closed)
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertTrue(first.hasUnsavedChanges)
        XCTAssertTrue(second.hasUnsavedChanges)
        XCTAssertFalse(state.isResolvingClose)
    }

    func testCloseJoinsActiveSaveWithoutAnotherPrompt() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "ALREADY SAVING"
        state.closeDecision = { _ in XCTFail("Successful active Save should be joined"); return .cancel }
        state.saveActiveDocument()
        XCTAssertTrue(tab.isSaving)
        let closed = await close(state)
        XCTAssertTrue(closed)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertEqual(try lastName(XCTUnwrap(PDFDocument(url: url))).widgetStringValue, "ALREADY SAVING")
    }

    func testSaveAsRetargetsOnlyOriginatingTabAndLaterSaveWritesCopy() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let target = directory.appendingPathComponent("edited copy ü.pdf")
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "SAVE AS COPY"
        let operation = state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: false))
        let other = DocumentTab(pdfDocument: PDFDocument())
        state.tabs.append(other)
        state.selectTab(other)
        let saved = await operation.value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertTrue(state.activeTab === other)
        XCTAssertEqual(tab.url, target)
        XCTAssertFalse(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try lastName(XCTUnwrap(PDFDocument(url: target))).widgetStringValue, "SAVE AS COPY")
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "SAVE COPY AGAIN"
        let savedAgain = await state.saveDocument(tab).value
        XCTAssertTrue(savedAgain, state.saveError?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try lastName(XCTUnwrap(PDFDocument(url: target))).widgetStringValue, "SAVE COPY AGAIN")
    }

    func testCancelledSaveAsLeavesDocumentAndEditsIntact() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "CANCELLED COPY"
        state.saveAsDestination = { requested in
            XCTAssertTrue(requested === tab)
            return nil
        }
        let saved = await state.saveDocumentAs(tab).value
        XCTAssertFalse(saved)
        XCTAssertNil(state.saveError)
        XCTAssertEqual(tab.url, url)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue, "CANCELLED COPY")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSaveAsCannotReplaceAnotherOpenTabOrItsAlias() async throws {
        let (url, directory) = try fixture("uscis-i9")
        let (otherURL, otherDirectory) = try fixture("uscis-i9")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let original = try Data(contentsOf: otherURL)
        let alias = directory.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: otherURL)
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        state.openDocument(at: otherURL)
        let other = try XCTUnwrap(state.activeTab)
        try await settled(other)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "NO WRONG FILE"
        for target in [otherURL, alias] {
            let saved = await state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: true)).value
            XCTAssertFalse(saved)
            XCTAssertTrue(state.saveError?.message.contains("DESTINATION_OPEN") == true)
        }
        XCTAssertEqual(tab.url, url)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: otherURL), original)
    }

    func testSaveAsRequiresExplicitReplacementAndFailureKeepsOriginalTab() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let target = directory.appendingPathComponent("existing.pdf")
        try original.write(to: target)
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "EXPLICIT REPLACE"
        let refused = await state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: false)).value
        XCTAssertFalse(refused)
        XCTAssertEqual(tab.url, url)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: target), original)
        let saved = await state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: true)).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertEqual(tab.url, target)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try lastName(XCTUnwrap(PDFDocument(url: target))).widgetStringValue, "EXPLICIT REPLACE")
    }

    func testSaveAsHardLinkDestinationDoesNotReplaceSourcePath() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let target = directory.appendingPathComponent("linked-copy.pdf")
        try FileManager.default.linkItem(at: url, to: target)
        XCTAssertTrue(SaveDestination.sameFile(url, target))
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        try lastName(XCTUnwrap(tab.pdfDocument)).widgetStringValue = "DETACHED COPY"
        let saved = await state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: true)).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try lastName(XCTUnwrap(PDFDocument(url: target))).widgetStringValue, "DETACHED COPY")
    }

    func testXFAAlsoBlocksSaveAsWithoutCreatingDestination() async throws {
        let (url, directory) = try fixture("irs-w9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("blocked.pdf")
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        let saved = await state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: false)).value
        XCTAssertFalse(saved)
        XCTAssertEqual(tab.url, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
