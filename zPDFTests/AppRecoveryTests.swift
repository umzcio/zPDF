import PDFKit
import XCTest
@testable import zPDF

@MainActor
final class AppRecoveryTests: XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("App Recovery \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func state(defaults: UserDefaults, recoveryDirectory: URL) -> AppState {
        let preferences = AppPreferences(defaults: defaults)
        preferences.restoreOpenDocuments = false
        preferences.rememberReadingPosition = false
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences,
                             readingHistory: ReadingHistoryStore(defaults: defaults))
        state.recovery = RecoveryCoordinator(store: RecoveryStore(directory: recoveryDirectory))
        return state
    }

    private func copyFixture(to directory: URL) throws -> URL {
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "uscis-i9", withExtension: "pdf"))
        let copy = directory.appendingPathComponent("Application I-9.pdf")
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }

    private func opened(_ url: URL, in state: AppState) async throws -> DocumentTab {
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        for _ in 0..<500 {
            if !tab.saveChecking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(tab.saveChecking)
        return tab
    }

    private func checkpoint(_ tab: DocumentTab, in state: AppState) async throws -> [RecoveryCheckpoint] {
        // Await the actual debounce task instead of guessing how long the
        // native helper takes. The next wait joins serialized publication.
        await state.checkpointTasks[tab.id]?.value
        let recovery = try XCTUnwrap(state.recovery)
        await recovery.waitUntilIdle()
        XCTAssertNil(recovery.errorMessage)
        return try await recovery.store.list()
    }

    private func field(in tab: DocumentTab) throws -> PDFAnnotation {
        try XCTUnwrap(tab.pdfDocument?.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" })
    }

    private func close(_ tab: DocumentTab, in state: AppState) async -> Bool {
        await withCheckedContinuation { continuation in
            state.requestClose([tab]) { continuation.resume(returning: $0) }
        }
    }

    func testCommittedEditsRecoverAsCopyThenSaveAsClearsCheckpoint() async throws {
        let directory = try folder()
        let suite = "zpdf.app-recovery.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try copyFixture(to: directory)
        let original = try Data(contentsOf: url)
        let recoveryDirectory = directory.appendingPathComponent("Recovery")
        let app = state(defaults: defaults, recoveryDirectory: recoveryDirectory)
        let tab = try await opened(url, in: app)
        XCTAssertNil(tab.saveBlock)
        try field(in: tab).widgetStringValue = "APP RECOVERED"
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "App recovery comment"
        tab.pdfDocument?.page(at: 0)?.addAnnotation(note)
        app.refreshUnsavedChanges(tab)
        XCTAssertTrue(tab.hasUnsavedChanges)
        let checkpoints = try await checkpoint(tab, in: app)
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), original)

        // New app/coordinator objects discover disk state just as on relaunch.
        let relaunched = state(defaults: defaults, recoveryDirectory: recoveryDirectory)
        await relaunched.startRecovery()
        let recovery = try XCTUnwrap(relaunched.recovery)
        XCTAssertTrue(recovery.showingRecovery)
        let item = try XCTUnwrap(recovery.items.first)
        let restored = await relaunched.restoreRecovery(item)
        XCTAssertTrue(restored, recovery.errorMessage ?? "")
        let recovered = try XCTUnwrap(relaunched.activeTab)
        XCTAssertTrue(recovered.requiresSaveAs)
        XCTAssertTrue(recovered.hasUnsavedChanges)
        XCTAssertEqual(recovered.displayName, "Application I-9.pdf")
        XCTAssertEqual(try field(in: recovered).widgetStringValue, "APP RECOVERED")
        XCTAssertTrue(recovered.pdfDocument!.page(at: 0)!.annotations.contains { $0.contents == "App recovery comment" })
        XCTAssertFalse(SaveDestination.sameFile(try XCTUnwrap(recovered.url), url))
        let retained = try await recovery.store.list()
        XCTAssertEqual(retained.count, 1)
        relaunched.preferences.restoreOpenDocuments = true
        relaunched.persistOpenSession()
        XCTAssertTrue(relaunched.readingHistory.sessionBookmarks.isEmpty,
                      "A recovered working copy must not become a normal session document")

        let destination = directory.appendingPathComponent("Recovered saved.pdf")
        var askedForSaveAs = false
        relaunched.saveAsDestination = { requested in
            askedForSaveAs = true
            XCTAssertTrue(requested === recovered)
            return SaveDestination(url: destination, overwrite: false)
        }
        let saved = await relaunched.saveDocument(recovered).value
        XCTAssertTrue(saved, relaunched.saveError?.message ?? "")
        XCTAssertTrue(askedForSaveAs, "Ordinary Save on a recovered tab must ask for a destination")
        XCTAssertFalse(recovered.requiresSaveAs)
        XCTAssertFalse(recovered.hasUnsavedChanges)
        XCTAssertEqual(recovered.url, destination)
        let bookmark = try XCTUnwrap(relaunched.readingHistory.sessionBookmarks.first)
        var stale = false
        let remembered = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertTrue(SaveDestination.sameFile(remembered, destination),
                      "Successful recovery Save As joins ordinary session restoration")
        let remaining = try await checkpoint(recovered, in: relaunched)
        XCTAssertTrue(remaining.isEmpty)
        let output = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(output.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" }?.widgetStringValue, "APP RECOVERED")
        XCTAssertTrue(output.page(at: 0)!.annotations.contains { $0.contents == "App recovery comment" })
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCancelledCloseKeepsCheckpointAndExplicitDiscardRemovesIt() async throws {
        let directory = try folder()
        let suite = "zpdf.app-recovery.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try copyFixture(to: directory)
        let original = try Data(contentsOf: url)
        let app = state(defaults: defaults, recoveryDirectory: directory.appendingPathComponent("Recovery"))
        let tab = try await opened(url, in: app)
        try field(in: tab).widgetStringValue = "KEEP CHECKPOINT"
        app.refreshUnsavedChanges(tab)
        let initial = try await checkpoint(tab, in: app)
        XCTAssertEqual(initial.count, 1)
        try field(in: tab).widgetStringValue = "LATEST AFTER CANCEL"
        app.refreshUnsavedChanges(tab)
        app.closeDecision = { _ in
            // Let the earlier debounce expire while closing, then cancel.
            try? await Task.sleep(for: .milliseconds(950))
            return .cancel
        }
        let cancelled = await close(tab, in: app)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(app.activeTab === tab)
        let afterCancel = try await checkpoint(tab, in: app)
        XCTAssertEqual(afterCancel.count, 1)
        XCTAssertEqual(try field(in: tab).widgetStringValue, "LATEST AFTER CANCEL")
        let cancelledCopy = try XCTUnwrap(PDFDocument(url: XCTUnwrap(afterCancel.first).fileURL))
        XCTAssertEqual(cancelledCopy.page(at: 0)?.annotations.first { $0.fieldName == "Last Name (Family Name)" }?.widgetStringValue,
                       "LATEST AFTER CANCEL", "Cancelling Close reschedules the latest recovery revision")
        app.closeDecision = { _ in .discard }
        let discarded = await close(tab, in: app)
        XCTAssertTrue(discarded)
        XCTAssertTrue(app.tabs.isEmpty)
        let afterDiscard = try await checkpoint(tab, in: app)
        XCTAssertTrue(afterDiscard.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testEncryptedReadOnlyDocumentDoesNotScheduleRecovery() async throws {
        let directory = try folder()
        let suite = "zpdf.app-recovery.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try copyFixture(to: directory)
        let locked = directory.appendingPathComponent("Locked.pdf")
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "reader", .ownerPasswordOption: "owner"]))
        let bytes = try Data(contentsOf: locked)
        let app = state(defaults: defaults, recoveryDirectory: directory.appendingPathComponent("Recovery"))
        app.passwordPrompt = { _ in "reader" }
        let tab = try await opened(locked, in: app)
        XCTAssertEqual(tab.saveBlock, "UNSUPPORTED_ENCRYPTED_WRITE")
        XCTAssertTrue(try XCTUnwrap(tab.pdfDocument).isEncrypted)
        tab.hasUnsavedChanges = true
        app.scheduleRecovery(for: tab)
        XCTAssertNil(app.checkpointTasks[tab.id])
        let files = try await checkpoint(tab, in: app)
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: locked), bytes)
    }
}
