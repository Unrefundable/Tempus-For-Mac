import AppKit
@testable import DesignSystem
import Testing

/// The image sets written by `scripts/import-tempus-assets.swift`, read from the source tree so
/// an imported asset without a case (or a case without an asset) fails here.
private func catalogNames(_ folder: String) throws -> Set<String> {
    let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/DesignSystem/Resources/Tempus.xcassets/\(folder)")
    let entries = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
    return Set(entries.filter { $0.hasSuffix(".imageset") }.map { String($0.dropLast(".imageset".count)) })
}

@Suite("Upstream icons")
struct IconTests {
    @Test("Every imported icon has a case, and every case has an icon")
    func matchesCatalog() throws {
        #expect(try Set(TempusIcon.allCases.map(\.rawValue)) == catalogNames("Icons"))
    }

    @Test("Icons load as templates, so they take the foreground color", arguments: TempusIcon.allCases)
    func loadsAsTemplate(icon: TempusIcon) throws {
        let image = try #require(Bundle.module.image(forResource: icon.rawValue))
        #expect(image.isTemplate)
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test("Player controls use upstream's drawables")
    func playerControls() {
        #expect(TempusIcon.play.rawValue == "ic_play")
        #expect(TempusIcon.pause.rawValue == "ic_pause")
        #expect(TempusIcon.skipNext.rawValue == "ic_skip_next")
        #expect(TempusIcon.repeatOne.rawValue == "ic_repeat_one")
    }
}

@Suite("Placeholders and illustrations")
struct ArtworkTests {
    @Test("Every imported placeholder has a case")
    func placeholdersMatchCatalog() throws {
        #expect(try Set(TempusPlaceholder.allCases.map(\.rawValue)) == catalogNames("Placeholders"))
    }

    @Test("Every imported illustration has a case")
    func illustrationsMatchCatalog() throws {
        #expect(try Set(TempusIllustration.allCases.map(\.rawValue)) == catalogNames("Illustrations"))
    }

    @Test("Placeholders keep their own colors", arguments: TempusPlaceholder.allCases)
    func placeholderIsOriginal(placeholder: TempusPlaceholder) throws {
        let image = try #require(Bundle.module.image(forResource: placeholder.rawValue))
        #expect(!image.isTemplate)
    }

    @Test("Illustrations keep their own colors", arguments: TempusIllustration.allCases)
    func illustrationIsOriginal(illustration: TempusIllustration) throws {
        let image = try #require(Bundle.module.image(forResource: illustration.rawValue))
        #expect(!image.isTemplate)
    }
}
