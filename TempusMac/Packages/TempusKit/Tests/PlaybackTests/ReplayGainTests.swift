import Foundation
@testable import Playback
import SubsonicAPI
import Testing

/// Upstream `ReplayGainUtil.computeTotalGain` and its gain/peak resolution.
@Suite("ReplayGain")
struct ReplayGainTests {
    private let full = #"{"trackGain":-7,"albumGain":-5,"trackPeak":0.5,"albumPeak":0.8,"fallbackGain":-3}"#

    private func gain(
        _ mode: ReplayGainMode,
        _ replayGain: String?,
        album: String? = "A",
        previousAlbum: String? = nil,
        preamp: Double = 0,
        preventsClipping: Bool = true
    ) throws -> Double {
        let settings = ReplayGainSettings(mode: mode, preampDB: preamp, preventsClipping: preventsClipping)
        let previous = try previousAlbum.map { try song("p", album: $0) }
        return try settings.gainDB(for: song("s", album: album, replayGain: replayGain), after: previous)
    }

    @Test("Off applies only the preamp")
    func off() throws {
        #expect(try gain(.off, full) == 0)
        #expect(try gain(.off, full, preamp: 3) == 3)
    }

    @Test("Track and album modes use their gain plus the preamp")
    func modes() throws {
        #expect(try gain(.track, full, preamp: 2) == -5)
        #expect(try gain(.album, full, preamp: 2) == -3)
    }

    @Test("Missing or zero gains fall back: track to fallback; album to fallback, then track")
    func fallbacks() throws {
        #expect(try gain(.track, #"{"trackGain":0,"fallbackGain":-3}"#) == -3)
        #expect(try gain(.album, #"{"trackGain":-7,"fallbackGain":-3}"#) == -3)
        #expect(try gain(.album, #"{"trackGain":-7}"#) == -7)
        #expect(try gain(.track, nil, preamp: 1) == 1)
    }

    @Test("Auto uses the album gain only when the previous track is from the same album")
    func auto() throws {
        #expect(try gain(.auto, full, previousAlbum: "A") == -5)
        #expect(try gain(.auto, full, previousAlbum: "B") == -7)
        #expect(try gain(.auto, full) == -7)
        #expect(try gain(.auto, full, album: nil, previousAlbum: nil) == -7)
    }

    @Test("Clipping prevention caps the gain at the peak's headroom")
    func clipping() throws {
        let loud = #"{"trackGain":6,"trackPeak":0.9}"#
        let headroom = -20 * log10(0.9)
        #expect(try abs(gain(.track, loud) - headroom) < 1e-9)
        #expect(try gain(.track, loud, preventsClipping: false) == 6)
        // Album mode uses the album peak, or the track peak when there is none.
        #expect(try abs(gain(.album, #"{"albumGain":9,"albumPeak":0.5,"trackPeak":0.9}"#) - -20 * log10(0.5)) < 1e-9)
        #expect(try abs(gain(.album, #"{"albumGain":6,"trackPeak":0.9}"#) - headroom) < 1e-9)
    }

    @Test("The total stays between -60 and +15 dB")
    func clamped() throws {
        #expect(try gain(.track, #"{"trackGain":20}"#) == 15)
        #expect(try gain(.track, #"{"trackGain":-80}"#) == -60)
    }

    @Test("The preamp is limited to ±15 dB")
    func preampRange() {
        #expect(ReplayGainSettings(preampDB: 40).preampDB == 15)
        #expect(ReplayGainSettings(preampDB: -40).preampDB == -15)
    }
}
