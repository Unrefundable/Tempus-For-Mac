@testable import AppCore
import Foundation
import Testing

struct TitlebarDoubleClickTests {
    @Test(arguments: [
        ("Maximize", TitlebarDoubleClickAction.zoom),
        ("Fill", .zoom),
        ("Minimize", .minimize),
        ("None", .nothing),
    ])
    func `follows the Desktop & Dock setting`(setting: String, action: TitlebarDoubleClickAction) {
        #expect(TitlebarDoubleClickAction(setting: setting, legacyMinimizes: false) == action)
    }

    @Test
    func `zooms when nothing is set, as the Mac does by default`() {
        #expect(TitlebarDoubleClickAction(setting: nil, legacyMinimizes: false) == .zoom)
    }

    @Test
    func `the older minimize setting counts only when the newer one is unset`() {
        #expect(TitlebarDoubleClickAction(setting: nil, legacyMinimizes: true) == .minimize)
        #expect(TitlebarDoubleClickAction(setting: "Maximize", legacyMinimizes: true) == .zoom)
    }

    @Test
    func `an unknown setting zooms`() {
        #expect(TitlebarDoubleClickAction(setting: "Something New", legacyMinimizes: false) == .zoom)
    }

    @Test
    func `reads both settings from defaults`() throws {
        let suite = "TitlebarDoubleClickTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("None", forKey: "AppleActionOnDoubleClick")
        #expect(TitlebarDoubleClickAction(defaults: defaults) == .nothing)
        defaults.removeObject(forKey: "AppleActionOnDoubleClick")
        defaults.set(true, forKey: "AppleMiniaturizeOnDoubleClick")
        #expect(TitlebarDoubleClickAction(defaults: defaults) == .minimize)
    }
}
