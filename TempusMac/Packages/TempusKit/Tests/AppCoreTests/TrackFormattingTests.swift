@testable import AppCore
import Foundation
import SubsonicAPI
import Testing

struct TrackFormattingTests {
    @Test(arguments: [
        (0.0, "0:00"), (5.4, "0:05"), (65, "1:05"), (3600, "1:00:00"), (3723, "1:02:03"),
    ])
    func `times read as minutes and seconds, with hours when needed`(seconds: TimeInterval, expected: String) {
        #expect(TrackFormatting.time(seconds) == expected)
    }

    @Test
    func `unknown times show upstream's placeholder`() {
        #expect(TrackFormatting.time(.nan) == "--")
        #expect(TrackFormatting.time(-1) == "--")
    }

    @Test
    func `the quality chip joins format, bitrate, depth and rate like upstream`() {
        let song = Song(id: "1", suffix: "flac", bitrate: 1411, samplingRate: 44100, bitDepth: 16)
        #expect(TrackFormatting.quality(of: song) == "FLAC • 1411kbps • 16b • 44.1kHz")
        #expect(TrackFormatting.quality(of: Song(id: "2", suffix: "mp3", bitrate: 320)) == "MP3 • 320kbps")
        #expect(TrackFormatting.quality(of: Song(id: "3")) == nil)
    }

    @Test
    func `the queue summary counts songs and their total length`() {
        let songs = [Song(id: "1", duration: 200), Song(id: "2", duration: 1000), Song(id: "3")]
        #expect(TrackFormatting.queueSummary(songs) == "3 songs • 20 min")
        #expect(TrackFormatting.queueSummary([Song(id: "1", duration: 30)]) == "1 song • 1 min")
        #expect(TrackFormatting.queueSummary([]) == "Queue is empty")
    }

    @Test
    func `speed reads like upstream's button`() {
        #expect(TrackFormatting.speed(1) == "1.00x")
        #expect(TrackFormatting.speed(1.25) == "1.25x")
    }
}

struct TrackListSubtitleTests {
    @Test
    func `a row's subtitle reads like upstream's: artist, length, bitrate, depth and rate, format`() {
        let song = Song(
            id: "1", artist: "girl in red", suffix: "flac", duration: 176,
            bitrate: 1512, samplingRate: 44100, bitDepth: 24
        )
        #expect(TrackFormatting.listSubtitle(of: song) == "girl in red • 2:56 • 1512kbps • 24/44 flac")
    }

    @Test
    func `lossy files without a bit depth show the sample rate in kHz`() {
        let song = Song(id: "1", artist: "Mitski", suffix: "mp3", duration: 137, bitrate: 320, samplingRate: 44100)
        #expect(TrackFormatting.listSubtitle(of: song) == "Mitski • 2:17 • 320kbps • 44.1kHz mp3")
    }

    @Test
    func `an artist's own page names the album instead`() {
        let song = Song(id: "1", album: "Born to Die", artist: "Lana Del Rey", duration: 265)
        #expect(TrackFormatting.listSubtitle(of: song, showingAlbum: true) == "Born to Die • 4:25")
    }

    @Test
    func `whatever is unknown is left out`() {
        #expect(TrackFormatting.listSubtitle(of: Song(id: "1")) == "")
        #expect(TrackFormatting.listSubtitle(of: Song(id: "2", suffix: "opus")) == "opus")
        #expect(TrackFormatting.listSubtitle(of: Song(id: "3", bitrate: 128, samplingRate: 48000, bitDepth: 16))
            == "128kbps • 16/48")
    }

    @Test
    func `zero lengths and sample rates are treated as unknown`() {
        let song = Song(id: "1", artist: "Mitski", suffix: "flac", duration: 0, samplingRate: 0, bitDepth: 24)
        #expect(TrackFormatting.listSubtitle(of: song) == "Mitski • 24b flac")
    }

    @Test
    func `rates in kHz keep one decimal only when there is one`() {
        #expect(TrackFormatting.listSubtitle(of: Song(id: "1", samplingRate: 48000)) == "48kHz")
        #expect(TrackFormatting.listSubtitle(of: Song(id: "2", samplingRate: 88200)) == "88.2kHz")
    }
}

struct RowNumberTests {
    @Test
    func `album rows show the track number, else their position`() {
        #expect(TrackFormatting.rowNumber(Song(id: "a", track: 4), at: 0) == "4")
        #expect(TrackFormatting.rowNumber(Song(id: "b"), at: 2) == "3")
    }

    @Test(arguments: [(0.0, "In sync"), (0.5, "0.5 s earlier"), (-1.5, "1.5 s later"), (2, "2 s earlier")])
    func `the lyrics nudge reads as earlier or later`(seconds: TimeInterval, expected: String) {
        #expect(TrackFormatting.lyricsNudge(seconds) == expected)
    }
}
