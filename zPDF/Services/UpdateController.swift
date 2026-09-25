import Foundation
import Observation
import Sparkle

/// Sparkle updates for Developer ID builds. The feed is the repository's
/// appcast.xml; every update is verified against SUPublicEDKey before it
/// installs. Test runs never start the updater.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        guard !AppEnvironment.isTesting else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
