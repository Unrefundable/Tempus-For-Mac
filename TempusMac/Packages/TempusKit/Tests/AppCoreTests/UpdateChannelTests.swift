@testable import AppCore
import Foundation
import Testing

struct UpdateChannelTests {
    @Test(arguments: ["0.1.0-beta.1", "1.0.0-rc.2", "2.0-alpha", "0.2.0-beta.1+42"])
    func `versions with a pre-release suffix are betas`(version: String) {
        #expect(UpdateChannel.isPrerelease(version))
    }

    @Test(arguments: ["0.1.0", "1.0", "2.3.4+build.7", "+beta-1", "", "  "])
    func `plain versions are not betas`(version: String) {
        #expect(!UpdateChannel.isPrerelease(version))
    }

    @Test
    func `only beta updates are offered beyond the default channel`() {
        #expect(UpdateChannel.allowedChannels(receivesBetas: true) == ["beta"])
        #expect(UpdateChannel.allowedChannels(receivesBetas: false).isEmpty)
    }

    @MainActor @Test
    func `beta updates default to whether the running build is a beta`() throws {
        let stable = try #require(UserDefaults(suiteName: "UpdateChannelTests-\(UUID())"))
        #expect(!AppSettings(defaults: stable, isPrereleaseBuild: false).receivesBetaUpdates)
        let beta = try #require(UserDefaults(suiteName: "UpdateChannelTests-\(UUID())"))
        #expect(AppSettings(defaults: beta, isPrereleaseBuild: true).receivesBetaUpdates)
    }

    @MainActor @Test
    func `the beta choice persists over the default`() throws {
        let defaults = try #require(UserDefaults(suiteName: "UpdateChannelTests-\(UUID())"))
        let settings = AppSettings(defaults: defaults, isPrereleaseBuild: true)
        settings.receivesBetaUpdates = false
        #expect(!AppSettings(defaults: defaults, isPrereleaseBuild: true).receivesBetaUpdates)
        settings.receivesBetaUpdates = true
        #expect(AppSettings(defaults: defaults, isPrereleaseBuild: false).receivesBetaUpdates)
    }
}
