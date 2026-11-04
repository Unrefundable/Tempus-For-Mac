import Foundation
import Playback

/// What Discord shows under "Listening to Tempus": the track, its artist and the time left.
public struct DiscordActivity: Sendable, Equatable {
    /// Discord refuses text outside 2 to 128 characters.
    static let textLength = 2 ... 128
    /// How far apart two updates' start times can be and still mean the same playback, since
    /// each update works the start out from the position at that moment.
    static let startTolerance: TimeInterval = 2
    /// Pads text that's too short with a character Discord shows as blank.
    private static let padding: Character = "\u{2800}"

    public let songID: String
    public let details: String
    public let state: String?
    public let start: Date?
    public let end: Date?

    init(songID: String, details: String, state: String?, start: Date?, end: Date?) {
        self.songID = songID
        self.details = details
        self.state = state
        self.start = start
        self.end = end
    }

    /// The activity for `snapshot`, or nil when nothing is playing. A buffering track shows
    /// without times, which arrive once it plays.
    public init?(snapshot: NowPlayingSnapshot?, now: Date) {
        guard let snapshot, snapshot.status.isActive else { return nil }
        let song = snapshot.song
        let title = song.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = (song.artist ?? song.albumArtist)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Streams can report an infinite or unknown duration, and the position is unknown until
        // the item is ready: those show no times rather than nonsense ones.
        let duration = snapshot.duration.isFinite && snapshot.duration > 0 ? snapshot.duration : nil
        var start: Date?
        var end: Date?
        if snapshot.rate > 0, snapshot.rate.isFinite, snapshot.position.isFinite {
            let position = min(max(snapshot.position, 0), duration ?? .greatestFiniteMagnitude)
            let began = now.addingTimeInterval(-position / snapshot.rate)
            start = began
            end = duration.map { began.addingTimeInterval($0 / snapshot.rate) }
        }
        self.init(
            songID: song.id,
            details: Self.fit(title.isEmpty ? "Unknown track" : title),
            state: artist.isEmpty ? nil : Self.fit(artist),
            start: start,
            end: end
        )
    }

    /// Whether Discord would show the same thing for both, so the second needn't be sent.
    func isSimilar(to other: DiscordActivity) -> Bool {
        songID == other.songID && details == other.details && state == other.state
            && Self.close(start, other.start) && Self.close(end, other.end)
    }

    private static func close(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case let (first?, second?): abs(first.timeIntervalSince(second)) <= startTolerance
        default: false
        }
    }

    /// `text` cut to Discord's limit (counted in UTF-16, as Discord does) or padded to its minimum.
    static func fit(_ text: String) -> String {
        var fitted = text
        if text.utf16.count > textLength.upperBound {
            let ellipsis = "…"
            var kept = ""
            for character in text {
                guard kept.utf16.count + character.utf16.count + ellipsis.utf16.count <= textLength.upperBound else {
                    break
                }
                kept.append(character)
            }
            fitted = kept + ellipsis
        }
        while fitted.count < textLength.lowerBound {
            fitted.append(padding)
        }
        return fitted
    }
}
