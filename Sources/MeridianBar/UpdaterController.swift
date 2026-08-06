import Foundation
import Sparkle

/// Sparkle plumbing (F15). One standard updater for the app; the update
/// channel comes from defaults ("updateChannel": "stable" | "beta") and
/// applies on the next check. EdDSA public key + feed URL live in
/// Info.plist, so a bare `swift run` (no bundle) skips the updater.
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private override init() {
        super.init()
        guard Bundle.main.bundleIdentifier != nil,
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.string(forKey: "updateChannel") == "beta" ? ["beta"] : []
    }
}
