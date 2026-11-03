import Foundation

/// Which releases the updater offers. Stable releases are in Sparkle's default channel; GitHub
/// pre-releases are published to the appcast in the `beta` channel (see `scripts/release.sh`).
public enum UpdateChannel {
    public static let beta = "beta"

    /// Whether a version names a pre-release, as semantic versioning writes it: a hyphen after the
    /// version numbers ("0.2.0-beta.1"). Build metadata after a `+` doesn't count.
    public static func isPrerelease(_ version: String) -> Bool {
        let core = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return core.contains("-")
    }

    /// The channels Sparkle may offer besides the default one.
    public static func allowedChannels(receivesBetas: Bool) -> Set<String> {
        receivesBetas ? [beta] : []
    }

    /// Whether the app that is running is itself a pre-release.
    public static var isRunningPrerelease: Bool {
        isPrerelease(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }
}
