import Foundation

/// An sRGB color as the hex code people type: `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
public struct ThemeColor: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Components from 0 to 1, as color pickers give them. Out-of-range values are clamped.
    public init(unitRed red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func byte(_ value: Double) -> UInt8 {
            UInt8((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded())
        }
        self.init(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(alpha))
    }

    /// Nil unless `hex` is 3, 6 or 8 hex digits, with or without a leading `#`.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.first == "#" {
            digits = digits.dropFirst()
        }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 3:
            digits = Substring(String(digits.flatMap { [$0, $0] }))
        case 6, 8:
            break
        default:
            return nil
        }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(
            red: UInt8((rgb >> 16) & 0xFF),
            green: UInt8((rgb >> 8) & 0xFF),
            blue: UInt8(rgb & 0xFF),
            alpha: hasAlpha ? UInt8(value & 0xFF) : 255
        )
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? rgb : rgb + String(format: "%02X", alpha)
    }

    /// Red, green, blue and alpha from 0 to 1.
    public var unitComponents: [Double] {
        [red, green, blue, alpha].map { Double($0) / 255 }
    }
}

/// Every color Tempus draws that the Appearance settings can change.
public enum ThemeColorRole: String, CaseIterable, Sendable, Identifiable {
    case accent
    case background
    case sidebar
    case playerBar
    case primaryText
    case secondaryText
    case tertiaryText
    case lyrics
    case error
    case success

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .accent: "Accent"
        case .background: "Background"
        case .sidebar: "Sidebar"
        case .playerBar: "Player bar"
        case .primaryText: "Text"
        case .secondaryText: "Secondary text"
        case .tertiaryText: "Faint text"
        case .lyrics: "Current lyric line"
        case .error: "Errors"
        case .success: "Success"
        }
    }

    public var summary: String {
        switch self {
        case .accent: "Buttons, toggles, the playing track and stars"
        case .background: "Behind the library, lists and Now Playing"
        case .sidebar: "Behind the sidebar"
        case .playerBar: "Behind the player along the bottom"
        case .primaryText: "Titles and most text"
        case .secondaryText: "Artists, details and captions"
        case .tertiaryText: "Lyric lines not playing, hints and handles"
        case .lyrics: "The line being sung"
        case .error: "Error messages and the offline banner"
        case .success: "Messages that something worked"
        }
    }
}

/// Light or dark, or whatever System Settings says.
public enum ThemeAppearance: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark

    public var id: Self {
        self
    }

    public var title: String {
        rawValue.capitalized
    }
}

/// A starting point for the Appearance settings: an appearance and some colors. Roles a preset
/// leaves out use the system's colors.
public enum ThemePreset: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark, oled, midnight, sepia, forest

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .oled: "OLED"
        case .midnight: "Midnight"
        case .sepia: "Sepia"
        case .forest: "Forest"
        }
    }

    public var appearance: ThemeAppearance {
        switch self {
        case .system: .system
        case .light, .sepia: .light
        case .dark, .oled, .midnight, .forest: .dark
        }
    }

    public var colors: [ThemeColorRole: ThemeColor] {
        switch self {
        case .system, .light, .dark:
            [:]
        case .oled:
            Self.parse([.background: "#000000", .sidebar: "#000000", .playerBar: "#000000"])
        case .midnight:
            Self.parse([
                .accent: "#60A5FA", .background: "#0F172A", .sidebar: "#0B1222", .playerBar: "#111B30",
                .primaryText: "#E2E8F0", .secondaryText: "#94A3B8", .tertiaryText: "#64748B",
            ])
        case .sepia:
            Self.parse([
                .accent: "#A0522D", .background: "#F4ECD8", .sidebar: "#EADFC4", .playerBar: "#EFE5CC",
                .primaryText: "#4B3A2A", .secondaryText: "#7A6650", .tertiaryText: "#A8957C",
            ])
        case .forest:
            Self.parse([
                .accent: "#7BC47F", .background: "#14201A", .sidebar: "#0F1914", .playerBar: "#18261F",
                .primaryText: "#E3EFE6", .secondaryText: "#9DB5A4", .tertiaryText: "#6B8573",
            ])
        }
    }

    private static func parse(_ hex: [ThemeColorRole: String]) -> [ThemeColorRole: ThemeColor] {
        hex.compactMapValues(ThemeColor.init(hex:))
    }
}

/// The app's look: a preset, the appearance and any colors the user picked over the preset's.
public struct AppTheme: Sendable, Equatable {
    public let preset: ThemePreset
    public let appearance: ThemeAppearance
    /// The user's own colors, which win over the preset's.
    public let customColors: [ThemeColorRole: ThemeColor]

    public static let `default` = AppTheme(preset: .system)

    public init(preset: ThemePreset) {
        self.init(preset: preset, appearance: preset.appearance, customColors: [:])
    }

    init(preset: ThemePreset, appearance: ThemeAppearance, customColors: [ThemeColorRole: ThemeColor]) {
        self.preset = preset
        self.appearance = appearance
        self.customColors = customColors
    }

    /// The color for `role`, or nil to use the system's.
    public func color(for role: ThemeColorRole) -> ThemeColor? {
        customColors[role] ?? preset.colors[role]
    }

    /// Whether anything differs from the preset.
    public var isCustomized: Bool {
        !customColors.isEmpty || appearance != preset.appearance
    }

    /// This theme with `role` set to `color`, or back to the preset's when `color` is nil.
    public func setting(_ role: ThemeColorRole, to color: ThemeColor?) -> AppTheme {
        var colors = customColors
        colors[role] = color
        return AppTheme(preset: preset, appearance: appearance, customColors: colors)
    }

    public func setting(appearance: ThemeAppearance) -> AppTheme {
        AppTheme(preset: preset, appearance: appearance, customColors: customColors)
    }

    /// `preset` as it comes, dropping custom colors and the appearance.
    public func applying(_ preset: ThemePreset) -> AppTheme {
        AppTheme(preset: preset)
    }
}

/// Stored leniently: an unknown preset, appearance or role, or a bad hex code, is skipped rather
/// than losing the whole theme.
extension AppTheme: Codable {
    private enum CodingKeys: String, CodingKey {
        case preset, appearance, colors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try (container.decodeIfPresent(String.self, forKey: .preset))
            .flatMap(ThemePreset.init(rawValue:)) ?? .system
        let appearance = try (container.decodeIfPresent(String.self, forKey: .appearance))
            .flatMap(ThemeAppearance.init(rawValue:)) ?? preset.appearance
        let stored = try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        var colors: [ThemeColorRole: ThemeColor] = [:]
        for (key, hex) in stored {
            if let role = ThemeColorRole(rawValue: key), let color = ThemeColor(hex: hex) {
                colors[role] = color
            }
        }
        self.init(preset: preset, appearance: appearance, customColors: colors)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset.rawValue, forKey: .preset)
        try container.encode(appearance.rawValue, forKey: .appearance)
        let colors = Dictionary(uniqueKeysWithValues: customColors.map { ($0.key.rawValue, $0.value.hex) })
        try container.encode(colors, forKey: .colors)
    }
}
