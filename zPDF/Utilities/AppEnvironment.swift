import Foundation

/// Where zPDF keeps preferences and app data. Test runs launch this same
/// sandboxed app as their host, so they get a throwaway defaults domain and
/// support folder and never touch the user's recents, preferences, saved
/// signatures, digital IDs or recovery checkpoints.
enum AppEnvironment {
    static let isTesting: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isTesting else { return .standard }
        let suite = "app.zpdf.zPDF.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite) // every run starts clean
        return defaults
    }()

    /// Application Support/… for real use; a per-run temporary folder in tests.
    static let supportDirectory: URL = {
        if isTesting {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-test-support-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }()
}
