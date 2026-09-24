import PDFKit
import SwiftUI
import XCTest
@testable import zPDF

@MainActor
final class PageOrganizationSaveTests: XCTestCase {
    private func fixture(_ name: String = "ordinary-edge") throws -> (URL, URL) {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pdf"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Organizer \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return (url, directory)
    }

    private func opened(_ url: URL) async throws -> (AppState, DocumentTab) {
        let state = AppState()
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 {
            if !tab.saveChecking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(tab.saveChecking)
        return (state, tab)
    }

    private func field(_ page: PDFPage, _ name: String) throws -> PDFAnnotation {
        try XCTUnwrap(page.annotations.first { $0.fieldName == name })
    }

    func testCombinedSplitAndCompressedFilesPreserveEditsWithoutSavingSources() async throws {
        let (first, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("Second.pdf")
        try FileManager.default.copyItem(at: first, to: second)
        let original = try Data(contentsOf: first)
        let (state, a) = try await opened(first)
        state.openDocument(at: second)
        let b = try XCTUnwrap(state.activeTab)
        while b.saveChecking { try await Task.sleep(for: .milliseconds(20)) }
        try field(XCTUnwrap(a.pdfDocument?.page(at: 0)), "Last Name (Family Name)").widgetStringValue = "FIRST SOURCE"
        try field(XCTUnwrap(b.pdfDocument?.page(at: 0)), "Last Name (Family Name)").widgetStringValue = "SECOND SOURCE"
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Combined comment"
        a.pdfDocument?.page(at: 0)?.addAnnotation(note)
        let combined = directory.appendingPathComponent("Combined.pdf")
        let combinedOK = await state.exportDocuments(.combine, tabs: [b, a], destination: .init(url: combined, overwrite: false)).value
        XCTAssertTrue(combinedOK, state.saveError?.message ?? "")
        let doc = try XCTUnwrap(PDFDocument(url: combined))
        XCTAssertEqual(doc.pageCount, a.pageCount + b.pageCount)
        let values = (0..<doc.pageCount).flatMap { doc.page(at: $0)!.annotations }.compactMap(\.widgetStringValue)
        XCTAssertTrue(values.contains("FIRST SOURCE")); XCTAssertTrue(values.contains("SECOND SOURCE"))
        XCTAssertTrue(doc.page(at: b.pageCount)!.annotations.contains { $0.contents == "Combined comment" })
        XCTAssertTrue(a.hasUnsavedChanges); XCTAssertTrue(b.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: first), original); XCTAssertEqual(try Data(contentsOf: second), original)
        let compressed = directory.appendingPathComponent("Compressed.pdf")
        let compressedOK = await state.exportDocuments(.compress, tabs: [a], destination: .init(url: compressed, overwrite: false)).value
        XCTAssertTrue(compressedOK, state.saveError?.message ?? "")
        let compressedDoc = try XCTUnwrap(PDFDocument(url: compressed))
        XCTAssertEqual(try field(XCTUnwrap(compressedDoc.page(at: 0)), "Last Name (Family Name)").widgetStringValue, "FIRST SOURCE")
        XCTAssertNotNil(state.exportMessage)
        let folder = directory.appendingPathComponent("Parts")
        let splitOK = await state.exportDocuments(.split(1), tabs: [a], destination: .init(url: folder, overwrite: false)).value
        XCTAssertTrue(splitOK, state.saveError?.message ?? "")
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(parts.count, a.pageCount)
        let part = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("uscis-i9-part1.pdf")))
        XCTAssertEqual(part.pageCount, 1)
        let widget = try field(XCTUnwrap(part.page(at: 0)), "Last Name (Family Name)")
        XCTAssertEqual(widget.widgetStringValue, "FIRST SOURCE"); XCTAssertFalse(widget.isReadOnly)
        XCTAssertTrue(part.page(at: 0)!.annotations.contains { $0.contents == "Combined comment" })
        let blocked = await state.exportDocuments(.split(1), tabs: [a], destination: .init(url: folder, overwrite: true)).value
        XCTAssertFalse(blocked, "Existing output folder must never be replaced")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count, parts.count)
        XCTAssertEqual(try Data(contentsOf: first), original)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-v1-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for source in [combined, compressed, folder.appendingPathComponent("uscis-i9-part1.pdf")] {
            let target = evidence.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        print("V1_EVIDENCE", evidence.path)
    }

    func testSavedCommentEditDeleteAndUndoAcrossPageOperations() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Before Save"
        tab.pdfDocument?.page(at: 0)?.addAnnotation(note)
        state.refreshUnsavedChanges(tab)
        XCTAssertTrue(tab.undoHistory?.manager.canUndo == true)
        state.undoDocumentEdit()
        XCTAssertFalse(tab.hasUnsavedChanges)
        state.redoDocumentEdit()
        XCTAssertTrue(tab.hasUnsavedChanges)
        let initialSave = await state.saveDocument(tab).value
        XCTAssertTrue(initialSave, state.saveError?.message ?? "")
        XCTAssertTrue(tab.undoHistory?.manager.canUndo == true, "Native reload preserves edit history")
        let saved = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.contents == "Before Save" })
        saved.contents = "After reopening"
        state.refreshUnsavedChanges(tab)
        try state.rotatePage(0, in: tab)
        try state.movePage(from: 0, to: 1, in: tab)
        state.undoDocumentEdit()
        XCTAssertTrue(tab.pdfDocument?.page(at: 0)?.annotations.contains { $0 === saved } == true)
        state.undoDocumentEdit()
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.rotation, 0)
        state.undoDocumentEdit()
        XCTAssertEqual(saved.contents, "Before Save")
        state.redoDocumentEdit()
        XCTAssertEqual(saved.contents, "After reopening")
        let editedSave = await state.saveDocument(tab).value
        XCTAssertTrue(editedSave, state.saveError?.message ?? "")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(reopened.page(at: 0)!.annotations.contains { $0.contents == "After reopening" })
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-v1-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let editedEvidence = evidence.appendingPathComponent("Edited-comment.pdf")
        try? FileManager.default.removeItem(at: editedEvidence)
        try FileManager.default.copyItem(at: url, to: editedEvidence)

        let existing = try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.contents == "After reopening" })
        tab.pdfDocument?.page(at: 0)?.removeAnnotation(existing)
        state.refreshUnsavedChanges(tab)
        let deletedSave = await state.saveDocument(tab).value
        XCTAssertTrue(deletedSave, state.saveError?.message ?? "")
        XCTAssertFalse(PDFDocument(url: url)!.page(at: 0)!.annotations.contains { $0.contents == "After reopening" })
    }

    func testSearchCancellationRejectsOldQueriesAndDocumentReplacement() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let tab = DocumentTab(pdfDocument: doc)
        tab.searchText = "Employee"; tab.updateSearchResults()
        tab.searchText = "zzzzdoesnotexist"; tab.updateSearchResults()
        for _ in 0..<500 {
            if !tab.isSearching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(tab.isSearching); XCTAssertTrue(tab.searchMatches.isEmpty)
        tab.searchText = "Employee"; tab.updateSearchResults()
        for _ in 0..<500 {
            if !tab.isSearching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(tab.searchMatches.isEmpty)
        tab.updateSearchResults(); tab.cancelSearch()
        XCTAssertFalse(tab.isSearching)
        tab.updateSearchResults(); tab.pdfDocument = PDFDocument()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(tab.isSearching); XCTAssertTrue(tab.searchMatches.isEmpty)
    }

    func testPrintOperationUsesCurrentDocumentAndOffersPageAndScalingControls() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: url)
        let (state, tab) = try await opened(url)
        try field(XCTUnwrap(tab.pdfDocument?.page(at: 0)), "Last Name (Family Name)").widgetStringValue = "PRINT UNSAVED"
        let operation = try state.printOperation(for: tab)
        XCTAssertEqual(operation.jobTitle, tab.displayName)
        XCTAssertTrue(operation.printPanel.options.contains(.showsPageRange))
        XCTAssertTrue(operation.printPanel.options.contains(.showsOrientation))
        XCTAssertTrue(operation.printPanel.options.contains(.showsScaling))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(tab.hasUnsavedChanges)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        let printed = directory.appendingPathComponent("printed.pdf")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = printed
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 1
        let outputOperation = try state.printOperation(for: tab, printInfo: info)
        outputOperation.showsPrintPanel = false
        outputOperation.showsProgressPanel = false
        XCTAssertTrue(outputOperation.run())
        let printResult = try XCTUnwrap(PDFDocument(url: printed))
        XCTAssertEqual(printResult.pageCount, 1)
        XCTAssertTrue(printResult.string?.contains("PRINT UNSAVED") == true)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-v1-evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let retained = evidence.appendingPathComponent("Printed.pdf")
        try? FileManager.default.removeItem(at: retained)
        try FileManager.default.copyItem(at: printed, to: retained)
    }

    func testMalformedOpenAndMixedSizeOrganization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformed = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7\nnot a document".utf8).write(to: malformed)
        let state = AppState(); state.openDocument(at: malformed)
        XCTAssertTrue(state.tabs.isEmpty); XCTAssertNotNil(state.openError)
        let mixed = PDFDocument()
        for size in [CGSize(width: 595, height: 842), CGSize(width: 792, height: 612), CGSize(width: 400, height: 400)] {
            let page = PDFPage(); page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            mixed.insert(page, at: mixed.pageCount)
        }
        let url = directory.appendingPathComponent("mixed.pdf")
        XCTAssertTrue(mixed.write(to: url))
        let (openedState, tab) = try await opened(url)
        let before = try Data(contentsOf: url)
        try openedState.rotatePage(1, in: tab)
        try openedState.movePage(from: 2, to: 0, in: tab)
        let output = directory.appendingPathComponent("mixed-output.pdf")
        let ok = await openedState.extractPages(IndexSet([0, 2]), from: tab, to: .init(url: output, overwrite: false)).value
        XCTAssertTrue(ok, openedState.saveError?.message ?? "")
        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 400))
        XCTAssertEqual(result.page(at: 1)?.rotation, 90)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testRealDocumentResponsivenessWhenCorpusAvailable() async throws {
        let corpus = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-v1-corpus")
        guard FileManager.default.fileExists(atPath: corpus.path) else {
            throw XCTSkip("Optional downloaded IRS/NASA corpus is not installed")
        }
        var records: [[String: Any]] = []
        for name in ["irs-1040-instructions.pdf", "apollo-11-report.pdf"] {
            let url = corpus.appendingPathComponent(name)
            let state = AppState()
            var lastBeat = ProcessInfo.processInfo.systemUptime
            var maximumGap = 0.0
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    maximumGap = max(maximumGap, now - lastBeat)
                    lastBeat = now
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            await Task.yield()
            let started = ProcessInfo.processInfo.systemUptime
            state.openDocument(at: url)
            let openedAt = ProcessInfo.processInfo.systemUptime
            let tab = try XCTUnwrap(state.activeTab, state.openError?.message ?? "")
            for _ in 0..<3000 {
                if !tab.saveChecking { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(tab.saveChecking)
            let readyAt = ProcessInfo.processInfo.systemUptime
            let openGap = maximumGap
            maximumGap = 0
            tab.searchText = "the"; tab.updateSearchResults()
            let searchStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3000 {
                if !tab.isSearching { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(tab.isSearching)
            let searchEnd = ProcessInfo.processInfo.systemUptime
            let matchCount = tab.searchMatches.count
            let page = try XCTUnwrap(tab.pdfDocument?.page(at: 0))
            let firstStart = ProcessInfo.processInfo.systemUptime
            let first = state.engine.thumbnail(for: page, size: CGSize(width: 280, height: 363))
            let firstEnd = ProcessInfo.processInfo.systemUptime
            let cached = state.engine.thumbnail(for: page, size: CGSize(width: 280, height: 363))
            let cachedEnd = ProcessInfo.processInfo.systemUptime
            XCTAssertNotNil(first); XCTAssertTrue(first === cached)
            tab.searchText = "unlikely search"; tab.updateSearchResults(); tab.cancelSearch()
            sampler.cancel()
            records.append(["fixture": name, "pages": tab.pageCount, "open_main_seconds": openedAt-started,
                            "ready_seconds": readyAt-started, "open_maximum_main_gap_seconds": openGap,
                            "search_seconds": searchEnd-searchStart, "search_matches": matchCount,
                            "search_maximum_main_gap_seconds": maximumGap,
                            "first_thumbnail_seconds": firstEnd-firstStart, "cached_thumbnail_seconds": cachedEnd-firstEnd])
            state.removeClosedTab(tab)
            XCTAssertTrue(state.tabs.isEmpty)
        }
        let output = corpus.appendingPathComponent("measurements.json")
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("V1_PERFORMANCE", output.path)
    }

    func testOffscreenDocumentLayoutsForBothAppearances() async throws {
        let (url, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-v1-evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for dark in [false, true] {
            for width in [960, 1280] {
                state.openTool(.organizePages)
                let host = NSHostingView(rootView: RootView().environment(state).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.setFrameSize(NSSize(width: width, height: 800))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: evidence.appendingPathComponent("organize-\(dark ? "dark" : "light")-\(width).png"))
                XCTAssertGreaterThan(png.count, 1000)
                // Never order the test window front or send global input.
                window.contentView = nil
                window.close()
            }
        }
        XCTAssertTrue(tab.allowsSaveEdits)
    }

    func testReadOnlyCanvasLocksFieldsAndRestoresOriginalPermissions() throws {
        let document = PDFDocument()
        let page = PDFPage(); document.insert(page, at: 0)
        let field = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Editable"; field.widgetStringValue = "Original"
        page.addAnnotation(field)
        let view = AnnotationCanvasView()
        view.document = document
        view.allowsSaveEdits = false
        XCTAssertTrue(field.isReadOnly)
        XCTAssertNotNil(view.document?.page(at: 0))
        view.allowsSaveEdits = true
        XCTAssertFalse(field.isReadOnly)
        XCTAssertEqual(field.widgetStringValue, "Original")
        field.isReadOnly = true
        view.allowsSaveEdits = false; view.allowsSaveEdits = true
        XCTAssertTrue(field.isReadOnly, "Preserve pre-existing restrictions")
    }

    func testPDFKitBackgroundDocumentGetterDoesNotRequireMainActor() async {
        // Simulate PDFKit's background analyzer calling its Objective-C getter.
        // No view or document mutation occurs on the worker thread.
        final class ReadOnlyObject: @unchecked Sendable {
            let object: NSObject
            init(_ object: NSObject) { self.object = object }
        }
        let view = AnnotationCanvasView()
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        view.setDisplayedDocument(document)
        let box = ReadOnlyObject(view)
        let readable: Bool = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: box.object.value(forKey: "document") != nil)
            }
        }
        XCTAssertTrue(readable)
        XCTAssertTrue(view.document === document)
    }

    func testPasswordOpenCancelWrongAndCorrectLeaveEncryptedBytesUntouched() async throws {
        let (source, directory) = try fixture("uscis-i9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let encrypted = directory.appendingPathComponent("Locked.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(doc.write(to: encrypted, withOptions: [.userPasswordOption: "reader", .ownerPasswordOption: "owner"]))
        let bytes = try Data(contentsOf: encrypted)
        let state = AppState()
        state.passwordPrompt = { _ in nil }; state.openDocument(at: encrypted)
        XCTAssertTrue(state.tabs.isEmpty)
        state.passwordPrompt = { _ in "wrong" }; state.openDocument(at: encrypted)
        XCTAssertTrue(state.tabs.isEmpty); XCTAssertNotNil(state.openError)
        state.openError = nil
        state.passwordPrompt = { _ in "reader" }; state.openDocument(at: encrypted)
        let tab = try XCTUnwrap(state.activeTab)
        while tab.saveChecking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(try XCTUnwrap(tab.pdfDocument).isLocked)
        XCTAssertEqual(tab.saveBlock, "UNSUPPORTED_ENCRYPTED_WRITE")
        XCTAssertEqual(tab.pageCount, doc.pageCount)
        XCTAssertEqual(try Data(contentsOf: encrypted), bytes)
    }

    func testFillCommentReorderRotateDeleteSaveAsAndEditAgain() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Data(contentsOf: url)
        let target = directory.appendingPathComponent("organized.pdf")
        let (state, tab) = try await opened(url)
        let document = try XCTUnwrap(tab.pdfDocument)
        let first = try XCTUnwrap(document.page(at: 0))
        let secondText = document.page(at: 1)?.string
        try field(first, "approval").buttonWidgetState = .onState
        let note = PDFAnnotation(bounds: CGRect(x: 30, y: 680, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "ORGANIZER COMMENT"
        first.addAnnotation(note)
        try state.rotatePage(0, in: tab)
        try state.movePage(from: 0, to: 1, in: tab)
        try state.deletePage(2, in: tab)
        XCTAssertTrue(document.page(at: 1) === first)
        // Edits made after reordering must still target their original page IDs.
        try field(first, "region").widgetStringValue = "NY"
        try field(XCTUnwrap(document.page(at: 0)), "shared").widgetStringValue = "LINKED AFTER MOVE"
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), source)
        let saved = await state.saveDocumentAs(tab, to: SaveDestination(url: target, overwrite: false)).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: url), source)
        let output = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(output.pageCount, 3)
        XCTAssertEqual(output.page(at: 0)?.string, secondText)
        let form = try XCTUnwrap(output.page(at: 1))
        XCTAssertEqual(form.rotation, 90)
        XCTAssertEqual(try field(form, "approval").buttonWidgetState, .onState)
        XCTAssertEqual(try field(form, "region").widgetStringValue, "NY")
        XCTAssertFalse(try field(form, "region").isReadOnly)
        XCTAssertEqual(form.annotations.filter { $0.contents == "ORGANIZER COMMENT" }.count, 1)
        for p in 0...1 {
            XCTAssertEqual(try field(XCTUnwrap(output.page(at: p)), "shared").widgetStringValue, "LINKED AFTER MOVE")
        }
        XCTAssertFalse(tab.hasUnsavedChanges)
        // Refreshed page/field identities must work on a second native session.
        let reloaded = try XCTUnwrap(tab.pdfDocument)
        try field(XCTUnwrap(reloaded.page(at: 1)), "region").widgetStringValue = "CO"
        let savedAgain = await state.saveDocument(tab).value
        XCTAssertTrue(savedAgain, state.saveError?.message ?? "")
        XCTAssertEqual(try field(XCTUnwrap(PDFDocument(url: target)?.page(at: 1)), "region").widgetStringValue, "CO")
        XCTAssertEqual(tab.pdfDocument?.page(at: 1)?.annotations.filter { $0.contents == "ORGANIZER COMMENT" }.count, 1)
    }

    func testDeletingFirstLinkedWidgetPreservesEditableSurvivor() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        try state.deletePage(0, in: tab)
        try field(XCTUnwrap(tab.pdfDocument?.page(at: 0)), "shared").widgetStringValue = "SURVIVOR"
        let saved = await state.saveDocument(tab).value
        XCTAssertTrue(saved, state.saveError?.message ?? "")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(try field(XCTUnwrap(document.page(at: 0)), "shared").widgetStringValue, "SURVIVOR")
        XCTAssertFalse(try field(XCTUnwrap(document.page(at: 0)), "shared").isReadOnly)
        try field(XCTUnwrap(tab.pdfDocument?.page(at: 0)), "shared").widgetStringValue = "STILL EDITABLE"
        let savedAgain = await state.saveDocument(tab).value
        XCTAssertTrue(savedAgain, state.saveError?.message ?? "")
        XCTAssertEqual(try field(XCTUnwrap(PDFDocument(url: url)?.page(at: 0)), "shared").widgetStringValue, "STILL EDITABLE")
    }

    func testPageDragMovesBothDirectionsAndRejectsOtherTabAndStaleDocument() throws {
        let state = AppState()
        let document = PDFDocument()
        let pages = [PDFPage(), PDFPage(), PDFPage()]
        pages.enumerated().forEach { document.insert($0.element, at: $0.offset) }
        let tab = DocumentTab(pdfDocument: document)
        tab.saveBaseline = SaveBaseline(document)
        state.tabs = [tab]
        let token = state.beginPageDrag(at: 0, in: tab)
        XCTAssertFalse(state.dropPage(token, at: 1, in: DocumentTab(pdfDocument: document)))
        XCTAssertTrue(state.dropPage(token, at: 2, in: tab))
        XCTAssertTrue(document.page(at: 2) === pages[0])
        XCTAssertTrue(tab.hasUnsavedChanges)
        let back = state.beginPageDrag(at: 2, in: tab)
        XCTAssertTrue(state.dropPage(back, at: 0, in: tab))
        XCTAssertTrue(document.page(at: 0) === pages[0])
        XCTAssertFalse(tab.hasUnsavedChanges)
        let stale = state.beginPageDrag(at: 0, in: tab)
        tab.pdfDocument = PDFDocument()
        XCTAssertFalse(state.dropPage(stale, at: 0, in: tab))
    }

    func testFinalPageDeletionAndEmptySaveAreBlocked() throws {
        let state = AppState()
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let tab = DocumentTab(pdfDocument: document)
        let baseline = SaveBaseline(document)
        tab.saveBaseline = baseline
        XCTAssertThrowsError(try state.deletePage(0, in: tab))
        XCTAssertEqual(document.pageCount, 1)
        document.removePage(at: 0)
        XCTAssertThrowsError(try baseline.changes(in: document)) { error in
            XCTAssertEqual((error as? NativeSaveError)?.code, "EMPTY_DOCUMENT")
        }
    }

    func testExtractionPreservesWidgetsCommentsAndCurrentPageOrderWithoutSavingSource() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBytes = try Data(contentsOf: url)
        let target = directory.appendingPathComponent("extracted ü.pdf")
        let (state, tab) = try await opened(url)
        let document = try XCTUnwrap(tab.pdfDocument)
        let originalBaseline = tab.saveBaseline
        let originalHash = tab.sourceHash
        let first = try XCTUnwrap(document.page(at: 0))
        try field(first, "approval").buttonWidgetState = .onState
        try field(first, "region").widgetStringValue = "NY"
        let note = PDFAnnotation(bounds: CGRect(x: 30, y: 680, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "EXTRACTED COMMENT"
        first.addAnnotation(note)
        try state.rotatePage(0, in: tab)
        try state.movePage(from: 0, to: 1, in: tab)
        let task = state.extractPages(IndexSet([0, 1]), from: tab,
                                      to: SaveDestination(url: target, overwrite: false))
        let other = DocumentTab(pdfDocument: PDFDocument())
        state.tabs.append(other)
        state.selectTab(other)
        let succeeded = await task.value
        XCTAssertTrue(succeeded, state.saveError?.message ?? "")
        XCTAssertTrue(state.activeTab === other)
        XCTAssertTrue(tab.pdfDocument === document)
        XCTAssertTrue(tab.saveBaseline === originalBaseline)
        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(tab.sourceHash, originalHash)
        XCTAssertTrue(tab.hasUnsavedChanges)
        XCTAssertFalse(tab.isSaving)
        XCTAssertFalse(tab.isExtracting)
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
        XCTAssertEqual(tab.lastExtractedURL, target)
        let output = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(output.pageCount, 2)
        let form = try XCTUnwrap(output.page(at: 1))
        XCTAssertEqual(form.rotation, 90)
        XCTAssertEqual(try field(form, "approval").buttonWidgetState, .onState)
        XCTAssertEqual(try field(form, "region").widgetStringValue, "NY")
        XCTAssertFalse(try field(form, "region").isReadOnly)
        XCTAssertEqual(form.annotations.filter { $0.contents == "EXTRACTED COMMENT" }.count, 1)
        let (exportState, exportTab) = try await opened(target)
        try field(XCTUnwrap(exportTab.pdfDocument?.page(at: 1)), "region").widgetStringValue = "CO"
        let savedAgain = await exportState.saveDocument(exportTab).value
        XCTAssertTrue(savedAgain, exportState.saveError?.message ?? "")
        XCTAssertEqual(try field(XCTUnwrap(PDFDocument(url: target)?.page(at: 1)), "region").widgetStringValue, "CO")
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
    }

    func testExtractionRejectsSourceAliasesAndExistingDestinations() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: url)
        let (state, tab) = try await opened(url)
        let alias = directory.appendingPathComponent("alias.pdf")
        try FileManager.default.linkItem(at: url, to: alias)
        for target in [url, alias] {
            let result = await state.extractPages(IndexSet(integer: 0), from: tab,
                                                  to: SaveDestination(url: target, overwrite: true)).value
            XCTAssertFalse(result)
            XCTAssertTrue(state.saveError?.message.contains("SOURCE_DESTINATION") == true)
        }
        let existing = directory.appendingPathComponent("existing.pdf")
        try Data("untouched".utf8).write(to: existing)
        let result = await state.extractPages(IndexSet(integer: 0), from: tab,
                                              to: SaveDestination(url: existing, overwrite: false)).value
        XCTAssertFalse(result)
        XCTAssertEqual(try Data(contentsOf: existing), Data("untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCancelledExtractionAndInvalidRangesDoNotWrite() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        let bytes = try Data(contentsOf: url)
        state.saveAsDestination = { _ in nil }
        let cancelled = await state.extractPages(IndexSet(integer: 0), from: tab).value
        XCTAssertFalse(cancelled)
        XCTAssertNil(tab.lastExtractedURL)
        XCTAssertFalse(tab.isSaving)
        let target = directory.appendingPathComponent("invalid.pdf")
        for indexes in [IndexSet(), IndexSet(integer: tab.pageCount)] {
            let result = await state.extractPages(indexes, from: tab,
                                                  to: SaveDestination(url: target, overwrite: false)).value
            XCTAssertFalse(result)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPageRangeSelectionValidatesAndUsesDocumentOrder() throws {
        XCTAssertEqual(try PageRangeSelection.parse("4, 1–2, 2", pageCount: 4), IndexSet([0, 1, 3]))
        for text in ["", "0", "-1", "2-1", "1-5", "1,", "1,,2", "1-2-3", "words", "999999999999999999999999"] {
            XCTAssertThrowsError(try PageRangeSelection.parse(text, pageCount: 4), text)
        }
    }

    func testXFACannotBeOrganized() async throws {
        let (url, directory) = try fixture("irs-w9")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, tab) = try await opened(url)
        let count = tab.pageCount
        XCTAssertThrowsError(try state.rotatePage(0, in: tab))
        XCTAssertThrowsError(try state.deletePage(0, in: tab))
        XCTAssertThrowsError(try state.movePage(from: 0, to: 1, in: tab))
        let extracted = await state.extractPages(IndexSet(integer: 0), from: tab,
                                                 to: SaveDestination(url: directory.appendingPathComponent("blocked.pdf"), overwrite: false)).value
        XCTAssertFalse(extracted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blocked.pdf").path))
        XCTAssertEqual(tab.pageCount, count)
        XCTAssertEqual(tab.pdfDocument?.page(at: 0)?.rotation, 0)
    }
}
