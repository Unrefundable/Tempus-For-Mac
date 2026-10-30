import Foundation
import SubsonicAPI

public enum ReplayGainMode: String, Codable, Sendable, CaseIterable {
    case off, track, album
    /// The album gain when the previous track is from the same album, else the track gain.
    case auto
}

/// Volume levelling, ported from upstream `ReplayGainUtil.computeTotalGain`.
///
/// Upstream also reads ReplayGain tags from the file when the server sends none. Here tracks are
/// decoded as they stream in, so only the server's values (OpenSubsonic `replayGain`) are used.
public struct ReplayGainSettings: Codable, Sendable, Equatable {
    public static let preampRange: ClosedRange<Double> = -15 ... 15
    static let totalRange: ClosedRange<Double> = -60 ... 15

    public let mode: ReplayGainMode
    /// Added to every track, with ReplayGain on or off.
    public let preampDB: Double
    /// Caps the gain so the track's peak can't exceed full scale. Needs ReplayGain on.
    public let preventsClipping: Bool

    public init(mode: ReplayGainMode = .off, preampDB: Double = 0, preventsClipping: Bool = true) {
        self.mode = mode
        self.preampDB = preampDB.clamped(to: Self.preampRange)
        self.preventsClipping = preventsClipping
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(ReplayGainMode.self, forKey: .mode),
            preampDB: container.decode(Double.self, forKey: .preampDB),
            preventsClipping: container.decode(Bool.self, forKey: .preventsClipping)
        )
    }

    /// The gain in dB to apply while `song` plays, given the track that played before it.
    public func gainDB(for song: Song, after previous: Song?) -> Double {
        guard mode != .off else { return preampDB.clamped(to: Self.totalRange) }
        let values = song.replayGain
        let usesAlbum = mode == .album || (mode == .auto && Self.isSameAlbum(song, previous))

        let trackGain = nonZero(values?.trackGain) ?? nonZero(values?.fallbackGain)
        let gain = usesAlbum
            ? nonZero(values?.albumGain) ?? nonZero(values?.fallbackGain) ?? trackGain
            : trackGain
        let peak = usesAlbum
            ? nonZero(values?.albumPeak) ?? nonZero(values?.trackPeak)
            : nonZero(values?.trackPeak)

        var total = (gain ?? 0) + preampDB
        if preventsClipping, let peak, peak > 0 {
            total = min(total, -20 * log10(peak))
        }
        return total.clamped(to: Self.totalRange)
    }

    private static func isSameAlbum(_ song: Song, _ previous: Song?) -> Bool {
        guard let previous else { return false }
        if let id = song.albumID, let previousID = previous.albumID {
            return id == previousID
        }
        guard let album = song.album else { return false }
        return album == previous.album
    }
}

/// Upstream treats a zero gain or peak as "not set".
private func nonZero(_ value: Double?) -> Double? {
    value.flatMap { $0 == 0 || !$0.isFinite ? nil : $0 }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
