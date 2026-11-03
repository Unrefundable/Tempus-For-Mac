import AppKit
@testable import DesignSystem
import Testing

@Suite("Theme colors")
struct ColorTests {
    private func hex(_ token: TempusColor, _ appearance: NSAppearance.Name) throws -> String {
        let color = try #require(NSColor(named: token.rawValue, bundle: .module))
        var resolved: NSColor?
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let srgb = try #require(resolved)
        return String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }

    @Test("Every token has a color set")
    func everyTokenResolves() {
        for token in TempusColor.allCases {
            #expect(NSColor(named: token.rawValue, bundle: .module) != nil, "\(token)")
        }
    }

    /// Upstream's Material roles (primary, surface and so on) come from the wallpaper by default
    /// (`Preferences.isDynamicColorAccent()`), and the Mac takes them from the system instead. Only
    /// the colors upstream fixes for itself are tokens, so no screen can pick up the baseline purple.
    @Test("Only upstream's fixed colors are tokens, not the wallpaper-driven Material roles")
    func onlyFixedColors() {
        #expect(Set(TempusColor.allCases.map(\.rawValue)) == [
            "titleText", "subtitleText", "divider", "deleteIcon", "lyricsText", "lyricsShadowText",
        ])
        for role in ["primary", "surface", "surfaceVariant", "secondaryContainer"] {
            #expect(NSColor(named: role, bundle: .module) == nil, "\(role)")
        }
    }

    @Test("The delete color is the same in both appearances")
    func deleteColor() throws {
        #expect(try hex(.deleteIcon, .aqua) == "#E53935")
        #expect(try hex(.deleteIcon, .darkAqua) == "#E53935")
    }

    @Test("Text colors follow upstream's values-night overrides")
    func textColors() throws {
        #expect(try hex(.titleText, .aqua) == "#252525")
        #expect(try hex(.titleText, .darkAqua) == "#DADADA")
        #expect(try hex(.subtitleText, .aqua) == "#646464")
        #expect(try hex(.subtitleText, .darkAqua) == "#9B9B9B")
        #expect(try hex(.divider, .darkAqua) == "#404040")
    }
}

@Suite("Typography")
struct TypographyTests {
    @Test("Inter registers once and resolves by PostScript name")
    func registersInter() {
        TempusFonts.register()
        TempusFonts.register()
        for weight in TempusFontWeight.allCases {
            #expect(NSFont(name: weight.postScriptName, size: 12) != nil, "\(weight)")
        }
    }

    @Test(
        "Text styles match upstream's typography.xml",
        arguments: [
            (TempusTextStyle.headlineLarge, 26.0, TempusFontWeight.bold, TempusColor.titleText),
            (.headlineMedium, 24, .bold, .titleText),
            (.headlineSmall, 22, .bold, .titleText),
            (.titleLarge, 22, .bold, .titleText),
            (.titleMedium, 14, .regular, .subtitleText),
            (.titleSmall, 12, .regular, .subtitleText),
            (.labelExtraLarge, 22, .bold, .titleText),
            (.labelLarge, 18, .bold, .titleText),
            (.labelMedium, 14, .medium, .titleText),
            (.labelSmall, 12, .regular, .subtitleText),
            (.labelExtraSmall, 10, .light, .subtitleText),
            (.bodyLarge, 24, .bold, .titleText),
            (.bodyMedium, 14, .medium, .titleText),
            (.bodySmall, 12, .regular, .titleText),
        ]
    )
    func matchesUpstream(style: TempusTextStyle, size: Double, weight: TempusFontWeight, color: TempusColor) {
        #expect(style.size == size)
        #expect(style.weight == weight)
        #expect(style.color == color)
    }
}
