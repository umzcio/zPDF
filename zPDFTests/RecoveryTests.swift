import PDFKit
import XCTest
@testable import zPDF

private actor CheckpointWriterProbe {
    var writes: [String] = []
    var failure = false
    var holdFirst = false
    private var continuation: CheckedContinuation<Void, Never>?

    func setFailure() { failure = true }
    func hold() { holdFirst = true }
    func release() { continuation?.resume(); continuation = nil }
    func write(_ snapshot: RecoverySnapshot, to url: URL) async throws -> String {
        writes.append(snapshot.displayName)
        if holdFirst && writes.count == 1 { await withCheckedContinuation { continuation = $0 } }
        if failure { throw RecoveryError(message: "Injected checkpoint failure") }
        try Data(snapshot.displayName.utf8).write(to: url)
        return try RecoveryStore.hash(of: url)
    }
}

@MainActor
final class RecoveryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery tests \(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(_ name: String, id: UUID = UUID()) -> RecoverySnapshot {
        RecoverySnapshot(id: id, sourceURL: URL(fileURLWithPath: "/unused-test-source.pdf"),
                         sourceHash: "unused", displayName: name, changes: NativeSaveChanges())
    }

    func testPublicationSurvivesRelaunchAndFailedUpdateKeepsLastCopy() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = CheckpointWriterProbe()
        let store = RecoveryStore(directory: directory, writer: { try await probe.write($0, to: $1) })
        let first = snapshot("First.pdf")
        let result = try await store.write(first)
        let saved = try XCTUnwrap(result)
        await probe.setFailure()
        do {
            _ = try await store.write(snapshot("Newer.pdf", id: first.id))
            XCTFail("Failure must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Injected")) }
        let relaunched = RecoveryStore(directory: directory)
        let recovered = try await relaunched.list()
        XCTAssertEqual(recovered, [saved])
        let validated = try await relaunched.validate(saved)
        XCTAssertEqual(try Data(contentsOf: validated), Data("First.pdf".utf8))
        try Data("damaged".utf8).write(to: validated)
        do { _ = try await relaunched.validate(saved); XCTFail("Damaged copy must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("damaged")) }
    }

    func testCapacityDoesNotEvictUnsavedCopiesAndStagingIsCleaned() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("staging-abandoned")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let probe = CheckpointWriterProbe()
        let store = RecoveryStore(directory: directory, maximumBytes: 16, maximumDocuments: 1,
                                  writer: { try await probe.write($0, to: $1) })
        let initialItems = try await store.list()
        XCTAssertTrue(initialItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let first = snapshot("First.pdf")
        _ = try await store.write(first)
        do { _ = try await store.write(snapshot("Second.pdf")); XCTFail("Capacity should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("full")) }
        do { _ = try await store.write(snapshot(String(repeating: "x", count: 17), id: first.id)); XCTFail("Size should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("full")) }
        let remaining = try await store.list()
        XCTAssertEqual(remaining.map(\.displayName), ["First.pdf"])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
    }

    func testDiscardInvalidatesAnInFlightPublication() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = CheckpointWriterProbe()
        await probe.hold()
        let store = RecoveryStore(directory: directory, writer: { try await probe.write($0, to: $1) })
        let input = snapshot("Draft.pdf")
        let writing = Task { try await store.write(input) }
        for _ in 0..<100 {
            if await probe.writes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await store.discard(id: input.id)
        await probe.release()
        let written = try await writing.value
        XCTAssertNil(written)
        let files = try await store.list()
        XCTAssertTrue(files.isEmpty)
    }

    func testCoordinatorCoalescesWaitingUpdatesAndKeepsRestoreUntilSave() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = CheckpointWriterProbe()
        await probe.hold()
        let store = RecoveryStore(directory: directory, writer: { try await probe.write($0, to: $1) })
        let coordinator = RecoveryCoordinator(store: store)
        let first = snapshot("One.pdf")
        coordinator.enqueue(first)
        for _ in 0..<100 {
            if await probe.writes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.enqueue(snapshot("Two.pdf", id: first.id))
        coordinator.enqueue(snapshot("Three.pdf", id: first.id))
        await probe.release()
        await coordinator.waitUntilIdle()
        let writes = await probe.writes
        XCTAssertEqual(writes, ["One.pdf", "Three.pdf"])
        await coordinator.load()
        XCTAssertTrue(coordinator.showingRecovery)
        let checkpoint = try XCTUnwrap(coordinator.items.first)
        coordinator.didRestore(checkpoint)
        let retained = try await store.list()
        XCTAssertEqual(retained.count, 1, "Opening recovery does not discard unsaved work")
        let discarded = await coordinator.discard(id: checkpoint.id)
        XCTAssertTrue(discarded)
        let afterDiscard = try await store.list()
        XCTAssertTrue(afterDiscard.isEmpty)
    }

    func testNativeCheckpointRetainsFormCommentAndPageOrderWithoutWritingOriginal() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "uscis-i9", withExtension: "pdf"))
        let bytes = try Data(contentsOf: original)
        let doc = try XCTUnwrap(PDFDocument(data: bytes))
        let baseline = SaveBaseline(doc)
        let page = try XCTUnwrap(doc.page(at: 0))
        let field = try XCTUnwrap(page.annotations.first { $0.fieldName == "Last Name (Family Name)" })
        field.widgetStringValue = "RECOVERED EDIT"
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Recovered comment"
        page.addAnnotation(note)
        doc.removePage(at: 0)
        doc.insert(page, at: 1)
        let changes = try baseline.changes(in: doc)
        let store = RecoveryStore(directory: directory)
        let input = RecoverySnapshot(id: UUID(), sourceURL: original, sourceHash: try RecoveryStore.hash(of: original),
                                     displayName: "uscis-i9.pdf", changes: changes)
        let result = try await store.write(input)
        let checkpoint = try XCTUnwrap(result)
        let copy = try XCTUnwrap(PDFDocument(url: checkpoint.fileURL))
        let edited = try XCTUnwrap(copy.page(at: 1))
        let recoveredField = try XCTUnwrap(edited.annotations.first { $0.fieldName == "Last Name (Family Name)" })
        XCTAssertEqual(recoveredField.widgetStringValue, "RECOVERED EDIT")
        XCTAssertEqual(recoveredField.widgetFieldType, .text)
        XCTAssertTrue(edited.annotations.contains { $0.contents == "Recovered comment" })
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testSuccessfulRetryClearsOnlyThatDocumentsCheckpointError() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory, writer: { input, output in
            if input.displayName.hasPrefix("Fail") { throw RecoveryError(message: "Injected write error") }
            try Data(input.displayName.utf8).write(to: output)
            return try RecoveryStore.hash(of: output)
        })
        let coordinator = RecoveryCoordinator(store: store)
        let first = UUID(), second = UUID()
        coordinator.enqueue(snapshot("Fail first", id: first))
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.errorMessage?.contains("Fail first") == true)
        coordinator.enqueue(snapshot("Fail second", id: second))
        await coordinator.waitUntilIdle()
        coordinator.enqueue(snapshot("First.pdf", id: first))
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.errorMessage?.contains("Fail second") == true,
                      "A different document's failure must remain visible")
        coordinator.enqueue(snapshot("Second.pdf", id: second))
        await coordinator.waitUntilIdle()
        XCTAssertNil(coordinator.errorMessage)
        coordinator.errorMessage = "Unrelated restore failure"
        coordinator.enqueue(snapshot("First updated.pdf", id: first))
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.errorMessage, "Unrelated restore failure")
    }
}
