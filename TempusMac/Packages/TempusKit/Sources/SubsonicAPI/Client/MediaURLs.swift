import Foundation

/// What to ask the server for when streaming, mirroring upstream `MusicUtil.getStreamUri`.
public enum StreamQuality: Sendable, Hashable {
    /// Send neither `format` nor `maxBitRate`; the server's transcoding rules apply.
    case serverDefault
    /// The file as stored (`format=raw`, no bitrate ceiling).
    case original
    /// Transcode to `format` (for example `mp3`, `opus`, `aac`) at most `maxBitrate` kbps.
    case transcoded(format: String, maxBitrate: Int)

    fileprivate var parameters: [URLQueryItem] {
        switch self {
        case .serverDefault: []
        case .original: query(("maxBitRate", 0), ("format", "raw"))
        case let .transcoded(format, maxBitrate): query(("maxBitRate", maxBitrate), ("format", format))
        }
    }
}

/// Media URLs are fetched by the player and image loader directly, not decoded as JSON.
/// They carry credentials, so never log or share them.
public extension SubsonicClient {
    /// - Parameter timeOffset: seconds to start into the track, for servers with `transcodeOffset`.
    func streamURL(
        id: String,
        quality: StreamQuality = .serverDefault,
        timeOffset: Int? = nil
    ) throws(SubsonicError) -> URL {
        let offset = timeOffset.flatMap { $0 > 0 ? $0 : nil }
        return try url(for: mediaRequest("stream", quality.parameters + query(("timeOffset", offset), ("id", id))))
    }

    /// The original file, for downloads.
    func downloadURL(id: String) throws(SubsonicError) -> URL {
        try url(for: mediaRequest("download", query(("id", id))))
    }

    /// - Parameter size: the longest side in pixels; nil for the original image.
    func coverArtURL(id: String, size: Int? = nil) throws(SubsonicError) -> URL {
        try url(for: mediaRequest("getCoverArt", query(("size", size), ("id", id))))
    }

    private func mediaRequest(_ method: String, _ parameters: [URLQueryItem]) -> SubsonicRequest<EmptyResponse> {
        SubsonicRequest(method: method, parameters: parameters)
    }
}
