import AppCore
import Foundation
import Observation
import Sparkle

/// Sparkle, set up for Settings and the app menu. Updates come from the appcast that
/// `scripts/release.sh` publishes next to the GitHub releases: stable releases for everyone,
/// pre-releases (the `beta` channel) only with beta updates on.
@MainActor
@Observable
final class AppUpdater {
    /// Debug builds and demo runs don't update themselves: an update would replace a development
    /// build with a release one.
    let isEnabled: Bool
    private(set) var canCheckForUpdates = false

    /// Checks daily, then downloads and installs updates without asking: they take effect the next
    /// time Tempus quits. Off, updates come only from Check for Updates.
    var automaticallyUpdates: Bool {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyUpdates
            updater.automaticallyDownloadsUpdates = automaticallyUpdates
        }
    }

    /// Kept in `AppSettings`. Turning it on looks for a beta straight away.
    var receivesBetaUpdates: Bool {
        get { settings.receivesBetaUpdates }
        set {
            settings.receivesBetaUpdates = newValue
            if newValue, isEnabled, automaticallyUpdates {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let channels: ChannelDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater {
        controller.updater
    }

    init(settings: AppSettings, isEnabled: Bool) {
        self.settings = settings
        self.isEnabled = isEnabled
        channels = ChannelDelegate(settings: settings)
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: channels,
            userDriverDelegate: nil
        )
        automaticallyUpdates = controller.updater.automaticallyChecksForUpdates
            && controller.updater.automaticallyDownloadsUpdates
        guard isEnabled else { return }
        canCheckObservation = updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            // Sparkle changes it on the main thread.
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
        controller.startUpdater()
    }

    /// Shows Sparkle's progress and result, as the app menu's Check for Updates does.
    func checkForUpdates() {
        guard isEnabled else { return }
        updater.checkForUpdates()
    }

    /// The running version and build, as About shows them.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Offers the beta channel only while beta updates are on.
@MainActor
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        UpdateChannel.allowedChannels(receivesBetas: settings.receivesBetaUpdates)
    }
}
