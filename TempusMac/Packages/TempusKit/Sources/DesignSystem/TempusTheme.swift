import CoreText
import os
import SwiftUI

/// The colors upstream fixes for itself in `values/colors.xml`, with their `values-night` overrides.
///
/// Upstream's Material roles aren't here. By default it draws its accent and surfaces from the
/// wallpaper (`Preferences.isDynamicColorAccent()`), and its `md_theme_*` purple is only Material 3's
/// baseline fallback. The Mac equivalent is the system: use `Color.accentColor` where upstream
/// uses `?attr/colorPrimary` (player controls, action labels), and the default window background
/// where it uses `?attr/colorSurface`.
public enum TempusColor: String, CaseIterable, Sendable {
    case titleText
    case subtitleText
    case divider
    case deleteIcon
    case lyricsText
    case lyricsShadowText
}

public extension Color {
    init(tempus token: TempusColor) {
        self.init(token.rawValue, bundle: .module)
    }
}

// MARK: - Typography

/// The Inter weights upstream's text styles use.
public enum TempusFontWeight: CaseIterable, Sendable {
    case light
    case regular
    case medium
    case semiBold
    case bold

    public var postScriptName: String {
        switch self {
        case .light: "Inter-Light"
        case .regular: "Inter-Regular"
        case .medium: "Inter-Medium"
        case .semiBold: "Inter-SemiBold"
        case .bold: "Inter-Bold"
        }
    }
}

/// Makes the bundled Inter available to the process, as upstream's `@font/inter` family is.
public enum TempusFonts {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "DesignSystem")

    private static let registration: Void = {
        // Resource processing usually flattens Fonts/ into the bundle root; look in both.
        let urls = ["", "Fonts"].flatMap { folder in
            Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: folder.isEmpty ? nil : folder) ?? []
        }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
                logger.error("Can't register \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            }
        }
    }()

    /// Safe to call more than once; only the first call registers.
    public static func register() {
        registration
    }
}

/// Upstream's text appearances from `values/typography.xml`. Sizes are its `sp` values in points.
public enum TempusTextStyle: CaseIterable, Sendable {
    case headlineLarge
    case headlineMedium
    case headlineSmall
    case titleLarge
    case titleMedium
    case titleSmall
    case labelExtraLarge
    case labelLarge
    case labelMedium
    case labelSmall
    case labelExtraSmall
    case bodyLarge
    case bodyMedium
    case bodySmall

    public var size: Double {
        switch self {
        case .headlineLarge: 26
        case .headlineMedium, .bodyLarge: 24
        case .headlineSmall, .titleLarge, .labelExtraLarge: 22
        case .labelLarge: 18
        case .titleMedium, .labelMedium, .bodyMedium: 14
        case .titleSmall, .labelSmall, .bodySmall: 12
        case .labelExtraSmall: 10
        }
    }

    public var weight: TempusFontWeight {
        switch self {
        case .headlineLarge, .headlineMedium, .headlineSmall, .titleLarge, .labelExtraLarge, .labelLarge, .bodyLarge:
            .bold
        case .labelMedium, .bodyMedium:
            .medium
        case .titleMedium, .titleSmall, .labelSmall, .bodySmall:
            .regular
        case .labelExtraSmall:
            .light
        }
    }

    public var color: TempusColor {
        switch self {
        case .titleMedium, .titleSmall, .labelSmall, .labelExtraSmall: .subtitleText
        default: .titleText
        }
    }

    public var font: Font {
        TempusFonts.register()
        return .custom(weight.postScriptName, size: size)
    }
}

public extension View {
    /// Sets the font and color of one of upstream's text appearances.
    func tempusTextStyle(_ style: TempusTextStyle) -> some View {
        font(style.font).foregroundStyle(Color(tempus: style.color))
    }
}
