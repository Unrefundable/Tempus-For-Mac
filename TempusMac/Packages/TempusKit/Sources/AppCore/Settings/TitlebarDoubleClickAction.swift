import Foundation

/// What double-clicking a window's titlebar does, as set in System Settings › Desktop & Dock.
public enum TitlebarDoubleClickAction: Equatable, Sendable {
    /// Fill the screen, or go back to the size before ("Zoom" and "Fill" both do this for a window).
    case zoom
    case minimize
    /// "Do Nothing".
    case nothing

    static let settingKey = "AppleActionOnDoubleClick"
    /// The setting before `settingKey` existed: true to minimize.
    static let legacyMinimizeKey = "AppleMiniaturizeOnDoubleClick"

    /// - Parameters:
    ///   - setting: `AppleActionOnDoubleClick`: "Maximize", "Fill", "Minimize" or "None"; nil when
    ///     never changed, which zooms.
    ///   - legacyMinimizes: `AppleMiniaturizeOnDoubleClick`, which counts only when `setting` is unset.
    public init(setting: String?, legacyMinimizes: Bool) {
        switch setting {
        case "Minimize": self = .minimize
        case "None": self = .nothing
        case .some: self = .zoom
        case nil: self = legacyMinimizes ? .minimize : .zoom
        }
    }

    /// The Mac's setting, read from `defaults` (whose global domain holds it).
    public init(defaults: UserDefaults) {
        self.init(
            setting: defaults.string(forKey: Self.settingKey),
            legacyMinimizes: defaults.bool(forKey: Self.legacyMinimizeKey)
        )
    }
}
