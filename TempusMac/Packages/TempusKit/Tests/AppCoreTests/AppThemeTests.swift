@testable import AppCore
import Foundation
import Testing

struct ThemeColorTests {
    @Test(arguments: [
        ("#000000", true), ("#121212", true), ("#1E1B2E", true), ("#6750A4", true),
        ("#FFFFFF", false), ("#F2F2F7", false), ("#FFD60A", false), ("#808080", false),
    ])
    func `dark colors take a lighter press ripple, light ones a darker one`(hex: String, isDark: Bool) throws {
        let color = try #require(ThemeColor(hex: hex))
        #expect(color.isDark == isDark)
    }

    @Test
    func `luminance runs from black to white`() throws {
        #expect(try #require(ThemeColor(hex: "#000")).relativeLuminance == 0)
        #expect(try abs(#require(ThemeColor(hex: "#FFF")).relativeLuminance - 1) < 0.000_1)
    }

    @Test(arguments: [
        ("#FF8800", ThemeColor(red: 255, green: 136, blue: 0)),
        ("ff8800", ThemeColor(red: 255, green: 136, blue: 0)),
        ("#f80", ThemeColor(red: 255, green: 136, blue: 0)),
        ("  #000000  ", ThemeColor(red: 0, green: 0, blue: 0)),
        ("#11223380", ThemeColor(red: 17, green: 34, blue: 51, alpha: 128)),
    ])
    func `hex codes parse in short, long and alpha forms`(hex: String, expected: ThemeColor) {
        #expect(ThemeColor(hex: hex) == expected)
    }

    @Test(arguments: ["", "#", "#12", "#12345", "#1234567", "#GGGGGG", "red", "#FF 800", "#+12345"])
    func `anything else is rejected`(hex: String) {
        #expect(ThemeColor(hex: hex) == nil)
    }

    @Test
    func `hex output drops alpha when opaque`() {
        #expect(ThemeColor(red: 255, green: 136, blue: 0).hex == "#FF8800")
        #expect(ThemeColor(red: 1, green: 2, blue: 3, alpha: 4).hex == "#01020304")
    }

    @Test
    func `components convert to and from unit values`() {
        let color = ThemeColor(unitRed: 1, green: 0.5, blue: -2, alpha: 9)
        #expect(color == ThemeColor(red: 255, green: 128, blue: 0, alpha: 255))
        #expect(ThemeColor(red: 255, green: 0, blue: 0).unitComponents == [1, 0, 0, 1])
    }
}

struct AppThemeTests {
    @Test
    func `the default theme follows the system and sets no colors`() {
        let theme = AppTheme.default
        #expect(theme.preset == .system)
        #expect(theme.appearance == .system)
        for role in ThemeColorRole.allCases {
            for variant in ThemeVariant.allCases {
                #expect(theme.color(for: role, in: variant) == nil, "\(role)")
            }
        }
        #expect(!theme.isCustomized)
    }

    @Test
    func `OLED is dark with pure black surfaces`() {
        let theme = AppTheme(preset: .oled)
        #expect(theme.appearance == .dark)
        let black = ThemeColor(red: 0, green: 0, blue: 0)
        #expect(theme.color(for: .background, in: .dark) == black)
        #expect(theme.color(for: .sidebar, in: .dark) == black)
        #expect(theme.color(for: .playerBar, in: .dark) == black)
    }

    @Test
    func `light and dark presets only force the appearance`() {
        #expect(AppTheme(preset: .light).appearance == .light)
        #expect(AppTheme(preset: .dark).appearance == .dark)
        for role in ThemeColorRole.allCases {
            for variant in ThemeVariant.allCases {
                #expect(AppTheme(preset: .light).color(for: role, in: variant) == nil)
                #expect(AppTheme(preset: .dark).color(for: role, in: variant) == nil)
            }
        }
    }

    @Test
    func `a custom color wins over the preset's, and resetting brings the preset's back`() throws {
        let pink = try #require(ThemeColor(hex: "#FF00AA"))
        let base = AppTheme(preset: .oled)
        let custom = base.setting(.background, to: pink)
        #expect(custom.color(for: .background, in: .dark) == pink)
        #expect(custom.color(for: .background, in: .light) == pink, "the user's colors apply in both variants")
        #expect(custom.isCustomized)
        #expect(
            base.color(for: .background, in: .dark) == ThemeColor(red: 0, green: 0, blue: 0),
            "the original is unchanged"
        )
        let reset = custom.setting(.background, to: nil)
        #expect(reset.color(for: .background, in: .dark) == ThemeColor(red: 0, green: 0, blue: 0))
        #expect(!reset.isCustomized)
    }

    @Test
    func `choosing a preset replaces custom colors and the appearance`() throws {
        let theme = try AppTheme(preset: .dark)
            .setting(.accent, to: #require(ThemeColor(hex: "#00FF00")))
            .setting(appearance: .light)
        let sepia = theme.applying(.sepia)
        #expect(sepia.preset == .sepia)
        #expect(sepia.appearance == .light)
        #expect(!sepia.isCustomized)
        #expect(sepia.color(for: .accent, in: .light) == ThemePreset.sepia.colors(for: .light)[.accent])
    }

    @Test(arguments: ThemePreset.allCases, ThemeVariant.allCases)
    func `every preset's text stays readable on its backgrounds in light and in dark`(
        preset: ThemePreset,
        variant: ThemeVariant
    ) {
        // A preset switched to the other appearance used to keep its colors, so OLED in light
        // drew black text on black and Midnight drew pale text on the system's light surfaces.
        let colors = preset.colors(for: variant)
        let systemText = variant == .light ? ThemeColor(red: 0, green: 0, blue: 0) : ThemeColor(
            red: 255,
            green: 255,
            blue: 255
        )
        let systemSurface = variant == .light ? ThemeColor(red: 255, green: 255, blue: 255) : ThemeColor(
            red: 30,
            green: 30,
            blue: 30
        )
        let text = colors[.primaryText] ?? systemText
        for surface in [ThemeColorRole.background, .sidebar, .playerBar] {
            let fill = colors[surface] ?? systemSurface
            #expect(Self.contrast(text, fill) >= Self.readableContrast, "\(preset) \(variant) \(surface)")
        }
        let secondary = colors[.secondaryText] ?? text
        #expect(Self.contrast(secondary, colors[.background] ?? systemSurface) >= Self.readableContrast)
    }

    @Test
    func `a preset's colors follow the variant showing`() {
        let theme = AppTheme(preset: .oled)
        #expect(theme.color(for: .background, in: .light) == ThemeColor(red: 255, green: 255, blue: 255))
        #expect(theme.color(for: .background, in: .dark) == ThemeColor(red: 0, green: 0, blue: 0))
        #expect(ThemePreset.midnight.variant == .dark)
        #expect(ThemePreset.sepia.variant == .light)
    }

    @Test
    func `accent and icons are one color, unset by default`() throws {
        let red = try #require(ThemeColor(hex: "#FF3B30"))
        #expect(!ThemeColorRole.allCases.map(\.rawValue).contains("icons"))
        #expect(AppTheme.default.color(for: .accent, in: .dark) == nil)
        let theme = AppTheme.default.setting(.accent, to: red)
        #expect(theme.color(for: .accent, in: .light) == red)
        #expect(try JSONDecoder().decode(AppTheme.self, from: JSONEncoder().encode(theme)) == theme)
    }

    @Test
    func `a saved icon color becomes the accent when the theme had none`() throws {
        let json = Data(##"{"preset":"system","appearance":"system","colors":{"icons":"#FF3B30"}}"##.utf8)
        let theme = try JSONDecoder().decode(AppTheme.self, from: json)
        #expect(theme.color(for: .accent, in: .light) == ThemeColor(hex: "#FF3B30"))
    }

    @Test
    func `a saved accent wins over a saved icon color`() throws {
        let json = Data(##"""
        {"preset":"system","appearance":"system","colors":{"icons":"#FF3B30","accent":"#123456"}}
        """##.utf8)
        let theme = try JSONDecoder().decode(AppTheme.self, from: json)
        #expect(theme.color(for: .accent, in: .dark) == ThemeColor(hex: "#123456"))
        #expect(theme.customColors.count == 1)
    }

    /// WCAG's minimum for body text.
    private static let readableContrast = 4.5

    /// WCAG contrast ratio between two opaque colors.
    private static func contrast(_ first: ThemeColor, _ second: ThemeColor) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ color: ThemeColor) -> Double {
        let linear = color.unitComponents.prefix(3).map { channel in
            channel <= 0.039_28 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    @Test
    func `changing the appearance alone counts as customizing`() {
        let theme = AppTheme(preset: .dark).setting(appearance: .light)
        #expect(theme.isCustomized)
        #expect(theme.appearance == .light)
    }

    @Test
    func `every preset has a title and only sets colors that parse back`() {
        for preset in ThemePreset.allCases {
            #expect(!preset.title.isEmpty)
            for variant in ThemeVariant.allCases {
                for (_, color) in preset.colors(for: variant) {
                    #expect(ThemeColor(hex: color.hex) == color)
                }
            }
        }
    }

    @Test
    func `themes round-trip through JSON`() throws {
        let theme = try AppTheme(preset: .midnight)
            .setting(.error, to: #require(ThemeColor(hex: "#FF000080")))
            .setting(appearance: .system)
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(AppTheme.self, from: data) == theme)
    }

    @Test
    func `decoding skips unknown roles and bad hex instead of failing`() throws {
        let json = Data("""
        {"preset":"oled","appearance":"dark","colors":{"accent":"#123456","nope":"#FFFFFF","sidebar":"blue"}}
        """.utf8)
        let theme = try JSONDecoder().decode(AppTheme.self, from: json)
        #expect(theme.preset == .oled)
        #expect(theme.color(for: .accent, in: .dark) == ThemeColor(red: 0x12, green: 0x34, blue: 0x56))
        #expect(theme.color(for: .sidebar, in: .dark) == ThemePreset.oled.colors(for: .dark)[.sidebar])
    }

    @Test
    func `an unknown preset falls back to the system one`() throws {
        let json = Data(#"{"preset":"neon","appearance":"sideways","colors":{}}"#.utf8)
        let theme = try JSONDecoder().decode(AppTheme.self, from: json)
        #expect(theme.preset == .system)
        #expect(theme.appearance == .system)
    }

    @MainActor @Test
    func `the theme persists in settings`() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppThemeTests-\(UUID())"))
        #expect(AppSettings(defaults: defaults).theme == .default)
        let theme = try AppTheme(preset: .oled).setting(.accent, to: #require(ThemeColor(hex: "#FFAA00")))
        AppSettings(defaults: defaults).setTheme(theme)
        #expect(AppSettings(defaults: defaults).theme == theme)
    }

    @MainActor @Test
    func `a corrupt stored theme falls back to the default`() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppThemeTests-\(UUID())"))
        defaults.set(Data("not json".utf8), forKey: "settings.theme")
        #expect(AppSettings(defaults: defaults).theme == .default)
    }
}
