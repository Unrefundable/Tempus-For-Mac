import Foundation
@testable import Playback
import Testing

/// Upstream `ParametricProfile.kt` rules (see `ParametricEqTest.kt`), applied through `AVAudioUnitEQ` bands.
@Suite("AutoEQ parametric profiles")
struct ParametricProfileTests {
    private let sample = """
    \u{FEFF}Preamp: -6.1 dB
    Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    Filter 2: ON PK Fc 2000 Hz Gain -3.0 dB Q 1.41
    Filter 3: OFF PK Fc 4000 Hz Gain 2.0 dB Q 1.00
    Filter 4: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.70
    """

    @Test("Parses the preamp and the enabled filters, skipping OFF ones")
    func parse() throws {
        let profile = try ParametricProfile(parsing: sample)
        #expect(profile.preampDB == -6.1)
        #expect(profile.filters == [
            ParametricFilter(kind: .lowShelf, frequency: 105, gainDB: 5.5, q: 0.7),
            ParametricFilter(kind: .peak, frequency: 2000, gainDB: -3, q: 1.41),
            ParametricFilter(kind: .highShelf, frequency: 10000, gainDB: -2, q: 0.7),
        ])
    }

    @Test("Writes text that parses back to the same profile")
    func roundTrip() throws {
        let profile = try ParametricProfile(parsing: sample)
        #expect(try ParametricProfile(parsing: profile.text) == profile)
    }

    @Test("Shelf aliases and unknown types", arguments: [
        ("LS", ParametricFilter.Kind.lowShelf), ("LSQ", .lowShelf), ("HS", .highShelf), ("HSQ", .highShelf),
    ])
    func aliases(type: String, kind: ParametricFilter.Kind) throws {
        let profile = try ParametricProfile(parsing: "Filter 1: ON \(type) Fc 100 Hz Gain 1 dB Q 0.7")
        #expect(profile.filters.map(\.kind) == [kind])
    }

    @Test("Lines with an unknown type or out-of-range values are skipped", arguments: [
        "Filter 2: ON LP Fc 100 Hz Gain 1 dB Q 0.7",
        "Filter 2: ON PK Fc 5 Hz Gain 1 dB Q 0.7",
        "Filter 2: ON PK Fc 100 Hz Gain 21 dB Q 0.7",
        "Filter 2: ON PK Fc 100 Hz Gain 1 dB Q 0.001",
        "Filter 2: ON LSC Fc 100 Hz Gain 1 dB Q 11",
        "Filter 2: ON PK Fc 100 Hz Gain 1 dB",
        "Filter 2: ON PK Fc nan Hz Gain 1 dB Q 1",
        "Filter 2: garbage",
    ])
    func skipped(line: String) throws {
        let profile = try ParametricProfile(parsing: "Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\n\(line)")
        #expect(profile.filters.count == 1)
    }

    @Test("Whole files are rejected when they can't be applied safely", arguments: [
        ("Channel: L\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1", ParametricProfileError.perEarProfile),
        ("GraphicEQ: 20 -1; 30 -2", .graphicEQ),
        ("Preamp: -6 dB", .noFilters),
        ("Preamp: -6,4 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1", .invalidPreamp),
        ("Preamp: -25 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1", .invalidPreamp),
        (String(repeating: "#", count: ParametricProfile.maximumTextSize + 1), .tooLarge),
    ])
    func rejected(text: String, error: ParametricProfileError) {
        #expect(throws: error) { try ParametricProfile(parsing: text) }
    }

    @Test("Up to 20 filters are accepted, 21 are not")
    func filterLimit() throws {
        let lines = { (count: Int) in
            (1 ... count).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        }
        #expect(try ParametricProfile(parsing: lines(20)).filters.count == 20)
        #expect(throws: ParametricProfileError.tooManyFilters(21)) { try ParametricProfile(parsing: lines(21)) }
    }
}

@Suite("Equalizer bands")
struct EqualizerBandTests {
    @Test("Off bypasses every band and adds no gain")
    func off() {
        let settings = EqualizerSettings()
        #expect(allBypassed(settings.bands(sampleRate: 44100)))
        #expect(settings.bands(sampleRate: 44100).count == EqualizerSettings.bandCount)
        #expect(settings.preampDB == 0)
    }

    @Test("The graphic equalizer has ten one-octave bands from 32 Hz to 16 kHz, ±12 dB")
    func graphic() {
        let gains = [3.0, 0, 0, 0, 0, 0, 0, 0, 0, 30]
        let bands = EqualizerSettings(mode: .graphic, graphicGains: gains).bands(sampleRate: 44100)
        #expect(bands.prefix(10).map(\.frequency) == [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        #expect(bands[0] == EQBand(kind: .parametric, frequency: 32, gainDB: 3, bandwidthOctaves: 1, isBypassed: false))
        #expect(bands[1].isBypassed) // 0 dB costs nothing when bypassed
        #expect(bands[9].gainDB == 12)
        #expect(allBypassed(bands.dropFirst(10)))
    }

    @Test("Missing or extra graphic gains are padded or dropped")
    func graphicGainCount() {
        let settings = EqualizerSettings(mode: .graphic, graphicGains: [1, 2])
        #expect(settings.graphicGains == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(EqualizerSettings(graphicGains: Array(repeating: 1, count: 15)).graphicGains.count == 10)
    }

    @Test("Parametric filters map to bands, Q to bandwidth, with the profile's preamp")
    func parametric() throws {
        let profile = try ParametricProfile(parsing: """
        Preamp: -4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.7
        Filter 2: ON PK Fc 2000 Hz Gain -3 dB Q 1.4142
        Filter 3: ON HSC Fc 10000 Hz Gain -2 dB Q 0.7
        """)
        let settings = EqualizerSettings(mode: .parametric, parametric: profile)
        let bands = settings.bands(sampleRate: 48000)

        #expect(settings.preampDB == -4)
        #expect(bands.map(\.kind).prefix(3) == [.lowShelf, .parametric, .highShelf])
        #expect(abs(bands[1].bandwidthOctaves - 1) < 0.001)
        #expect(bands[1].gainDB == -3)
        #expect(allBypassed(bands.dropFirst(3)))
    }

    @Test("Filters too close to Nyquist are left out", arguments: [
        (20000.0, 44100.0, true), (19845.0, 44100.0, true), (21600.0, 48000.0, true),
        (19800.0, 44100.0, false), (21500.0, 48000.0, false),
    ])
    func nyquist(frequency: Double, sampleRate: Double, isSkipped: Bool) throws {
        let profile = try ParametricProfile(parsing: "Filter 1: ON PK Fc \(frequency) Hz Gain 3 dB Q 1")
        let band = EqualizerSettings(mode: .parametric, parametric: profile).bands(sampleRate: sampleRate)[0]
        #expect(band.isBypassed == isSkipped)
    }

    @Test("Parametric mode without a profile behaves as off")
    func parametricWithoutProfile() {
        let settings = EqualizerSettings(mode: .parametric)
        #expect(allBypassed(settings.bands(sampleRate: 44100)))
        #expect(settings.preampDB == 0)
    }
}

/// Outside `#expect`, whose expansion loses `rethrows` for key-path functions.
private func allBypassed(_ bands: some Sequence<EQBand>) -> Bool {
    bands.allSatisfy(\.isBypassed)
}
