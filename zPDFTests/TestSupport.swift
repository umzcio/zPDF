import PDFKit
import XCTest
@testable import zPDF

/// Shared helpers for tests that drive the bundled native engine.
@MainActor
enum TestSupport {
    static func fixture(_ name: String, in testCase: AnyClass) throws -> (url: URL, directory: URL) {
        let source = try XCTUnwrap(Bundle(for: testCase).url(forResource: name, withExtension: "pdf"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zPDF test ü \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(name).pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        return (copy, directory)
    }

    /// Opens `url` and waits until the tab has a native editing revision.
    static func open(_ url: URL, in state: AppState) async throws -> DocumentTab {
        state.openDocument(at: url)
        let tab = try XCTUnwrap(state.activeTab)
        try await settled(tab)
        for _ in 0..<500 where tab.editSource == nil || tab.saveBaseline == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(tab.editSource)
        return tab
    }

    static func settled(_ tab: DocumentTab) async throws {
        for _ in 0..<1500 {
            if !tab.saveChecking && !tab.isSaving { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Engine operation did not finish")
    }

    static func save(_ state: AppState, _ tab: DocumentTab) async throws {
        let saved = await state.saveDocument(tab).value
        if !saved { XCTFail("Save failed: \(state.saveError?.message ?? "unknown")") }
    }

    static func text(_ url: URL, page: Int = 0) -> String {
        PDFDocument(url: url)?.page(at: page)?.string ?? ""
    }
}
