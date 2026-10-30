import Foundation

/// One filter from an AutoEQ / EqualizerAPO `ParametricEQ.txt` profile.
public struct ParametricFilter: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case peak = "PK"
        case lowShelf = "LSC"
        case highShelf = "HSC"
    }

    public let kind: Kind
    /// Centre or corner frequency in Hz.
    public let frequency: Double
    public let gainDB: Double
    public let q: Double
}

public enum ParametricProfileError: Error, Equatable {
    /// Separate left and right filters, which a stereo EQ can't apply.
    case perEarProfile
    /// A GraphicEQ export, not a parametric one.
    case graphicEQ
    case noFilters
    case tooManyFilters(Int)
    case invalidPreamp
    /// Longer than any real profile; probably not a profile at all.
    case tooLarge
}

/// A headphone-correction profile, parsed with upstream's rules (`ParametricProfile.kt`):
/// bad filter lines are skipped, but anything that would make the whole file unsafe rejects it.
public struct ParametricProfile: Codable, Sendable, Hashable {
    public static let maximumFilters = 20
    /// Real profiles are about 1 KB; imported files are untrusted.
    public static let maximumTextSize = 64 * 1024
    static let maximumGain = 20.0
    static let maximumShelfQ = 10.0
    static let minimumQ = 0.01
    static let minimumFrequency = 10.0

    public let preampDB: Double
    public let filters: [ParametricFilter]

    public init(parsing text: String) throws(ParametricProfileError) {
        guard text.utf8.count <= Self.maximumTextSize else { throw .tooLarge }
        var preamp = 0.0
        var filters: [ParametricFilter] = []
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if lowered.hasPrefix("channel") {
                throw .perEarProfile
            }
            if lowered.hasPrefix("graphiceq") {
                throw .graphicEQ
            }
            if lowered.hasPrefix("preamp") {
                preamp = try Self.preamp(from: line)
            } else if lowered.hasPrefix("filter"), let filter = Self.filter(from: line) {
                filters.append(filter)
            }
        }
        guard !filters.isEmpty else { throw .noFilters }
        guard filters.count <= Self.maximumFilters else { throw .tooManyFilters(filters.count) }
        preampDB = preamp
        self.filters = filters
    }

    /// The profile in `ParametricEQ.txt` form, for storing and showing.
    public var text: String {
        let lines = filters.enumerated().map { index, filter in
            let settings = "Fc \(filter.frequency) Hz Gain \(filter.gainDB) dB Q \(filter.q)"
            return "Filter \(index + 1): ON \(filter.kind.rawValue) \(settings)"
        }
        return (["Preamp: \(preampDB) dB"] + lines).joined(separator: "\n")
    }

    private static func preamp(from line: String) throws(ParametricProfileError) -> Double {
        guard let value = tokens(afterColonIn: line).first.flatMap(Double.init),
              value.isFinite, abs(value) <= maximumGain
        else { throw .invalidPreamp }
        return value
    }

    /// `Filter N: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70`, or nil when it is off, unknown or out of range.
    private static func filter(from line: String) -> ParametricFilter? {
        let tokens = tokens(afterColonIn: line)
        guard tokens.count >= 2, tokens[0].uppercased() == "ON", let kind = kind(tokens[1]) else { return nil }
        let value = { (label: String) -> Double? in
            guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
                  tokens.indices.contains(index + 1)
            else { return nil }
            return Double(tokens[index + 1])
        }
        guard let frequency = value("Fc"), let gain = value("Gain"), let q = value("Q") else { return nil }
        let filter = ParametricFilter(kind: kind, frequency: frequency, gainDB: gain, q: q)
        return isValid(filter) ? filter : nil
    }

    private static func isValid(_ filter: ParametricFilter) -> Bool {
        let values = [filter.frequency, filter.gainDB, filter.q]
        return values.allSatisfy(\.isFinite)
            && filter.frequency >= minimumFrequency
            && filter.q >= minimumQ
            && abs(filter.gainDB) <= maximumGain
            && (filter.kind == .peak || filter.q <= maximumShelfQ)
    }

    private static func kind(_ token: String) -> ParametricFilter.Kind? {
        switch token.uppercased() {
        case "PK": .peak
        case "LSC", "LS", "LSQ": .lowShelf
        case "HSC", "HS", "HSQ": .highShelf
        default: nil
        }
    }

    private static func tokens(afterColonIn line: String) -> [String] {
        guard let colon = line.firstIndex(of: ":") else { return [] }
        return line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// One band of the player's `AVAudioUnitEQ`.
public struct EQBand: Sendable, Equatable {
    public enum Kind: Sendable {
        case parametric, lowShelf, highShelf
    }

    public let kind: Kind
    public let frequency: Float
    public let gainDB: Float
    public let bandwidthOctaves: Float
    public let isBypassed: Bool

    static let unused = Self(kind: .parametric, frequency: 1000, gainDB: 0, bandwidthOctaves: 1, isBypassed: true)
}

public enum EqualizerMode: String, Codable, Sendable, CaseIterable {
    case off, graphic, parametric
}

/// The equalizer: off, a 10-band graphic EQ, or an imported AutoEQ profile.
/// Upstream's built-in EQ is whatever Android offers on the device, so the Mac defines its own bands.
public struct EqualizerSettings: Codable, Sendable, Equatable {
    public static let bandCount = ParametricProfile.maximumFilters
    public static let graphicFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let graphicGainRange: ClosedRange<Double> = -12 ... 12
    /// AVAudioUnitEQ's limits.
    static let bandwidthRange: ClosedRange<Float> = 0.05 ... 5
    /// Upstream skips filters this close to Nyquist, where a biquad misbehaves.
    static let nyquistMargin = 0.45

    public let mode: EqualizerMode
    /// One gain per `graphicFrequencies` entry, in dB.
    public let graphicGains: [Double]
    public let parametric: ParametricProfile?
    /// The profile's name as shown to the user, usually the headphone model.
    public let parametricName: String?

    public init(
        mode: EqualizerMode = .off,
        graphicGains: [Double] = [],
        parametric: ParametricProfile? = nil,
        parametricName: String? = nil
    ) {
        let count = Self.graphicFrequencies.count
        let gains = graphicGains.prefix(count).map { $0.isFinite ? $0.clamped(to: Self.graphicGainRange) : 0 }
        self.mode = mode
        self.graphicGains = gains + Array(repeating: 0, count: count - gains.count)
        self.parametric = parametric
        self.parametricName = parametricName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(EqualizerMode.self, forKey: .mode),
            graphicGains: container.decode([Double].self, forKey: .graphicGains),
            parametric: container.decodeIfPresent(ParametricProfile.self, forKey: .parametric),
            parametricName: container.decodeIfPresent(String.self, forKey: .parametricName)
        )
    }

    /// Gain applied before the bands. Profiles use a negative preamp to leave room for boosts.
    public var preampDB: Double {
        mode == .parametric ? parametric?.preampDB ?? 0 : 0
    }

    /// Exactly `bandCount` bands, unused ones bypassed.
    public func bands(sampleRate: Double) -> [EQBand] {
        let active: [EQBand] = switch mode {
        case .off: []
        case .graphic: graphicBands
        case .parametric: parametric?.filters.map { Self.band(for: $0, sampleRate: sampleRate) } ?? []
        }
        return active + Array(repeating: .unused, count: max(0, Self.bandCount - active.count))
    }

    private var graphicBands: [EQBand] {
        zip(Self.graphicFrequencies, graphicGains).map { frequency, gain in
            EQBand(
                kind: .parametric,
                frequency: frequency,
                gainDB: Float(gain),
                bandwidthOctaves: 1,
                isBypassed: gain == 0
            )
        }
    }

    private static func band(for filter: ParametricFilter, sampleRate: Double) -> EQBand {
        let kind: EQBand.Kind = switch filter.kind {
        case .peak: .parametric
        case .lowShelf: .lowShelf
        case .highShelf: .highShelf
        }
        return EQBand(
            kind: kind,
            frequency: Float(filter.frequency),
            gainDB: Float(filter.gainDB),
            bandwidthOctaves: bandwidth(q: filter.q),
            isBypassed: filter.frequency >= nyquistMargin * sampleRate
        )
    }

    /// A peaking filter's Q as a bandwidth in octaves: N = (2 / ln 2) · asinh(1 / 2Q).
    /// Shelves ignore it: `AVAudioUnitEQ`'s shelves have a fixed slope close to AutoEQ's Q 0.7.
    private static func bandwidth(q: Double) -> Float {
        Float(2 / log(2) * asinh(1 / (2 * q))).clamped(to: bandwidthRange)
    }
}
