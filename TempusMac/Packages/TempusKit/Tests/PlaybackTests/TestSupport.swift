import Foundation
import SubsonicAPI

/// A song as a server would send it, decoded through the real model.
func song(
    _ id: String,
    album: String? = nil,
    duration: Int? = 200,
    type: String? = nil,
    suffix: String? = nil,
    replayGain: String? = nil
) throws -> Song {
    var fields = [#""id":"\#(id)""#, #""title":"Song \#(id)""#, #""isDir":false"#]
    if let album {
        fields.append(#""album":"\#(album)""#)
    }
    if let duration {
        fields.append(#""duration":\#(duration)"#)
    }
    if let type {
        fields.append(#""type":"\#(type)""#)
    }
    if let suffix {
        fields.append(#""suffix":"\#(suffix)""#)
    }
    if let replayGain {
        fields.append(#""replayGain":\#(replayGain)"#)
    }
    return try JSONDecoder().decode(Song.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
}

func songs(_ ids: String...) throws -> [Song] {
    try ids.map { try song($0) }
}

/// Deterministic randomness for shuffle tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
