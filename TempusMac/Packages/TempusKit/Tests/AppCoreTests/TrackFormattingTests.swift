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

struct RowNumberTests {
    @Test
    func `lists from many albums number rows by position, not track number`() {
        let songs = [Song(id: "a", track: 11), Song(id: "b", track: 7), Song(id: "c", track: 11)]
        let numbers = songs.indices.map { TrackFormatting.rowNumber(songs[$0], at: $0, byPosition: true) }
        #expect(numbers == ["1", "2", "3"])
    }

    @Test
    func `album rows show the track number, else their position`() {
        #expect(TrackFormatting.rowNumber(Song(id: "a", track: 4), at: 0, byPosition: false) == "4")
        #expect(TrackFormatting.rowNumber(Song(id: "b"), at: 2, byPosition: false) == "3")
    }

    @Test(arguments: [(0.0, "In sync"), (0.5, "0.5 s earlier"), (-1.5, "1.5 s later"), (2, "2 s earlier")])
    func `the lyrics nudge reads as earlier or later`(seconds: TimeInterval, expected: String) {
        #expect(TrackFormatting.lyricsNudge(seconds) == expected)
    }
}
