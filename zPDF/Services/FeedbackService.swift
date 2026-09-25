import AppKit
import Foundation

/// The last user-visible errors, kept in memory only for bug reports.
@MainActor
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    private(set) var lastError: String?
    func record(_ message: String) { lastError = String(message.prefix(600)) }
}

/// What a report says about this Mac and app. Shown to the user before sending.
struct FeedbackDiagnostics: Sendable, Equatable {
    let appVersion: String
    let build: String
    let macOS: String
    let chip: String
    let locale: String
    var lastError: String?

    @MainActor static func current() -> FeedbackDiagnostics {
        let info = Bundle.main.infoDictionary
        return FeedbackDiagnostics(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            // "Version 27.0 (Build 26A428)" -> "27.0 (Build 26A428)"
            macOS: ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""),
            chip: sysctl("machdep.cpu.brand_string") ?? sysctl("hw.machine") ?? "unknown",
            locale: Locale.current.identifier,
            lastError: DiagnosticsLog.shared.lastError)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    var rows: [(String, String)] {
        [("zPDF", "\(appVersion) (\(build))"), ("macOS", macOS), ("Chip", chip), ("Locale", locale)]
            + (lastError.map { [("Last error", $0)] } ?? [])
    }
}

struct FeedbackReport: Sendable {
    enum Kind: String, Sendable { case bug, suggestion }
    var kind: Kind
    var title: String
    var description: String
    var steps: String
    var expected: String
    var email: String
    var diagnostics: FeedbackDiagnostics?
    var screenshotPNG: Data?
}

struct FeedbackResult: Sendable { let issueNumber: Int; let issueURL: URL? }

struct FeedbackError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Sends reports to the zPDF feedback relay (services/feedback), which files
/// GitHub issues. No GitHub account or token is needed on the tester's Mac.
enum FeedbackService {
    static var endpoint: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "ZPDFFeedbackURL") as? String).flatMap(URL.init(string:))
    }

    static func payload(_ report: FeedbackReport) -> [String: Any] {
        func clean(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        var body: [String: Any] = ["kind": report.kind.rawValue, "title": report.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "description": report.description.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let v = clean(report.steps) { body["steps"] = v }
        if let v = clean(report.expected) { body["expected"] = v }
        if let v = clean(report.email) { body["email"] = v }
        if let d = report.diagnostics {
            var diag: [String: Any] = ["appVersion": d.appVersion, "build": d.build, "macOS": d.macOS, "chip": d.chip, "locale": d.locale]
            if let e = d.lastError { diag["lastError"] = e }
            body["diagnostics"] = diag
        }
        if let png = report.screenshotPNG { body["screenshot"] = ["mime": "image/png", "base64": png.base64EncodedString()] }
        return body
    }

    static func send(_ report: FeedbackReport, to endpoint: URL? = FeedbackService.endpoint,
                     session: URLSession = .shared) async throws -> FeedbackResult {
        guard let endpoint else { throw FeedbackError(message: "Bug reporting isn't configured in this build.") }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(report))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FeedbackError(message: "The report couldn't be sent. Check your internet connection and try again.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let issue = json?["issue"] as? [String: Any], let number = issue["number"] as? Int else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw FeedbackError(message: message ?? "The report couldn't be sent right now. Please try again later.")
        }
        return FeedbackResult(issueNumber: number, issueURL: (issue["url"] as? String).flatMap(URL.init(string:)))
    }

    /// PNG of zPDF's main window (rendered by the app itself; no screen-recording permission).
    @MainActor static func mainWindowScreenshot() -> Data? {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "zpdf.main" && $0.isVisible })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title != "Report a Bug" }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Pre-filled content for the next report (e.g. from an error alert).
@MainActor
@Observable
final class FeedbackDraft {
    static let shared = FeedbackDraft()
    var kind: FeedbackReport.Kind = .bug
    var title = ""
    var description = ""
    func prefill(error: String) {
        kind = .bug
        if title.isEmpty { title = "Error: " + String(error.prefix(80)) }
        if description.isEmpty { description = "I saw this message: \(error)\n\nWhat I was doing: " }
    }
}
