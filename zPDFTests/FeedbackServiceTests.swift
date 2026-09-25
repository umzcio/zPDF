import XCTest
@testable import zPDF

/// Stubs the relay so tests never touch the network.
final class RelayStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any]?
    nonisolated(unsafe) static var lastPath: String?
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var reply: [String: Any] = ["ok": true, "issue": ["number": 42, "url": "https://github.com/umzcio/zPDF/issues/42"]]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastPath = request.url?.path
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else if let body = request.httpBody {
            Self.lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: Self.reply))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class FeedbackServiceTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayStub.self]
        return URLSession(configuration: config)
    }

    func testReportPayloadAndIssueNumber() async throws {
        RelayStub.status = 201
        RelayStub.reply = ["ok": true, "issue": ["number": 42, "url": "https://github.com/umzcio/zPDF/issues/42"]]
        var diagnostics = FeedbackDiagnostics.current()
        diagnostics.lastError = "The PDF engine could not complete this operation. Details: AttributeError"
        let report = FeedbackReport(kind: .bug, title: "  Signing fails  ", description: "It failed", steps: "", expected: "A signature",
                                    email: "", diagnostics: diagnostics, screenshotPNG: nil)
        let result = try await FeedbackService.send(report, to: URL(string: "https://relay.test")!, session: session())
        XCTAssertEqual(result.issueNumber, 42)
        XCTAssertEqual(RelayStub.lastPath, "/v1/reports")
        let body = try XCTUnwrap(RelayStub.lastBody)
        XCTAssertEqual(body["kind"] as? String, "bug")
        XCTAssertEqual(body["title"] as? String, "Signing fails")
        XCTAssertNil(body["steps"], "empty fields are omitted")
        XCTAssertNil(body["email"])
        XCTAssertNil(body["screenshot"], "no screenshot unless the user chose one")
        let diag = try XCTUnwrap(body["diagnostics"] as? [String: Any])
        XCTAssertFalse((diag["macOS"] as? String ?? "").isEmpty)
        XCTAssertEqual(diag["lastError"] as? String, diagnostics.lastError)
    }

    func testRelayErrorMessageIsShownToTheUser() async throws {
        RelayStub.status = 429
        RelayStub.reply = ["ok": false, "error": ["code": "RATE_LIMITED", "message": "Too many reports in a short time. Please wait a minute."]]
        let report = FeedbackReport(kind: .suggestion, title: "Idea", description: "More stamps", steps: "", expected: "", email: "",
                                    diagnostics: nil, screenshotPNG: Data([0x89, 0x50, 0x4e, 0x47]))
        do {
            _ = try await FeedbackService.send(report, to: URL(string: "https://relay.test")!, session: session())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Too many reports in a short time. Please wait a minute.")
        }
        XCTAssertEqual((RelayStub.lastBody?["screenshot"] as? [String: Any])?["mime"] as? String, "image/png")
    }

    func testErrorsAreRecordedForTheNextReport() {
        let state = AppState()
        state.saveError = OpenError(fileName: "a.pdf", message: "Engine failed. Details: AttributeError: x")
        XCTAssertEqual(DiagnosticsLog.shared.lastError, "Engine failed. Details: AttributeError: x")
        XCTAssertEqual(FeedbackDiagnostics.current().lastError, "Engine failed. Details: AttributeError: x")
    }
}
