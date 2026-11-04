@testable import AppCore
import Foundation
import Testing

struct ThemeColorTests {
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
            #expect(theme.color(for: role) == nil, "\(role)")
        }
        #expect(!theme.isCustomized)
    }

    @Test
    func `OLED is dark with pure black surfaces`() {
        let theme = AppTheme(preset: .oled)
        #expect(theme.appearance == .dark)
        let black = ThemeColor(red: 0, green: 0, blue: 0)
        #expect(theme.color(for: .background) == black)
        #expect(theme.color(for: .sidebar) == black)
        #expect(theme.color(for: .playerBar) == black)
    }

    @Test
    func `light and dark presets only force the appearance`() {
        #expect(AppTheme(preset: .light).appearance == .light)
        #expect(AppTheme(preset: .dark).appearance == .dark)
        for role in ThemeColorRole.allCases {
            #expect(AppTheme(preset: .light).color(for: role) == nil)
            #expect(AppTheme(preset: .dark).color(for: role) == nil)
        }
    }

    @Test
    func `a custom color wins over the preset's, and resetting brings the preset's back`() throws {
        let pink = try #require(ThemeColor(hex: "#FF00AA"))
        let base = AppTheme(preset: .oled)
        let custom = base.setting(.background, to: pink)
        #expect(custom.color(for: .background) == pink)
        #expect(custom.isCustomized)
        #expect(base.color(for: .background) == ThemeColor(red: 0, green: 0, blue: 0), "the original is unchanged")
        let reset = custom.setting(.background, to: nil)
        #expect(reset.color(for: .background) == ThemeColor(red: 0, green: 0, blue: 0))
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
        #expect(sepia.color(for: .accent) == ThemePreset.sepia.colors[.accent])
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
            for (_, color) in preset.colors {
                #expect(ThemeColor(hex: color.hex) == color)
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
        #expect(theme.color(for: .accent) == ThemeColor(red: 0x12, green: 0x34, blue: 0x56))
        #expect(theme.color(for: .sidebar) == ThemePreset.oled.colors[.sidebar])
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
