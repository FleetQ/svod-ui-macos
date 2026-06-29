import Foundation
import Combine
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI can drive "Check for Updates…" and the
/// automatic-check toggle. Sparkle reads `SUFeedURL` + `SUPublicEDKey` from Info.plist
/// (set via the `INFOPLIST_KEY_SU*` build settings); the appcast is served from the
/// GitHub Releases `latest/download/appcast.xml` asset.
///
/// NOTE: Sparkle can only actually install an update when the app is Developer-ID signed
/// + notarized and the update is EdDSA-signed with the matching private key. Until that
/// signing/notarization is set up, "Check for Updates" runs but reports no installable
/// update. See docs/release-signing.md.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    init() {
        // startingUpdater: true → Sparkle schedules its automatic check per Info.plist.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Present Sparkle's user-facing update flow (progress, release notes, install).
    func checkForUpdates() { controller.updater.checkForUpdates() }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
