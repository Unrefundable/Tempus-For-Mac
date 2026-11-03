import Foundation
import SubsonicAPI

/// Text the player shows, in upstream's formats.
public enum TrackFormatting {
    /// `m:ss`, or `h:mm:ss` from an hour; `--` while unknown, as upstream's time bar.
    public static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds)
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Upstream's format chip: `FLAC • 1411kbps • 16b • 44.1kHz`, leaving out what's unknown.
    public static func quality(of song: Song) -> String? {
        var parts: [String] = []
        if let suffix = song.suffix, !suffix.isEmpty {
            parts.append(suffix.uppercased())
        }
        if let bitrate = song.bitrate, bitrate > 0 {
            parts.append("\(bitrate)kbps")
        }
        if let depth = song.bitDepth, depth > 0 {
            parts.append("\(depth)b")
        }
        if let rate = song.samplingRate, rate > 0 {
            parts.append(String(format: "%.1fkHz", Double(rate) / 1000))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// Upstream's queue header: `12 songs • 48 min`, or "Queue is empty".
    public static func queueSummary(_ songs: [Song]) -> String {
        guard !songs.isEmpty else { return "Queue is empty" }
        let seconds = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return "\(songs.count) \(songs.count == 1 ? "song" : "songs") • \(minutes) min"
    }

    /// An album's row number: the track number, or the row's place when that is unknown.
    public static func rowNumber(_ song: Song, at index: Int) -> String {
        song.track.map(String.init) ?? "\(index + 1)"
    }

    /// Upstream's track-row subtitle: `girl in red • 2:56 • 1512kbps • 24/44 flac`. An artist's own
    /// page names the album in place of the artist. Whatever is unknown is left out.
    public static func listSubtitle(of song: Song, showingAlbum: Bool = false) -> String {
        let name = showingAlbum ? song.album : song.artist
        let parts = [
            name.flatMap { $0.isEmpty ? nil : $0 },
            song.duration.flatMap { $0 > 0 ? time(TimeInterval($0)) : nil },
            song.bitrate.flatMap { $0 > 0 ? "\($0)kbps" : nil },
            listFormat(of: song),
        ]
        return parts.compactMap(\.self).joined(separator: " • ")
    }

    /// Upstream's `24/44 flac`: depth over whole kHz, or `44.1kHz` without a depth, then the suffix.
    private static func listFormat(of song: Song) -> String? {
        var parts: [String] = []
        let rate = song.samplingRate.flatMap { $0 > 0 ? $0 : nil }
        if let depth = song.bitDepth, depth > 0 {
            parts.append(rate.map { "\(depth)/\($0 / 1000)" } ?? "\(depth)b")
        } else if let rate {
            // Fixed format, not the user's locale: the rest of the line is upstream's English.
            parts.append(String(format: "%gkHz", (Double(rate) / 100).rounded() / 10))
        }
        if let suffix = song.suffix, !suffix.isEmpty {
            parts.append(suffix)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The user's lyrics nudge: `In sync`, `0.5 s earlier`, `1.5 s later`.
    public static func lyricsNudge(_ seconds: TimeInterval) -> String {
        guard seconds != 0 else { return "In sync" }
        let amount = abs(seconds).formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(amount) s \(seconds > 0 ? "earlier" : "later")"
    }

    /// Upstream's speed button: `1.00x`.
    public static func speed(_ rate: Double) -> String {
        String(format: "%.2fx", rate)
    }
}
