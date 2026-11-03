import Foundation
import Playback
import SubsonicAPI
import Synchronization

/// Fetches one file. The live one is a URLSession download with the server's header, redirect and
/// client-certificate rules; tests replace it.
public protocol FileDownloading: Sendable {
    /// Returns a temporary file the caller moves into place.
    func download(_ request: URLRequest, policy: MediaRequestPolicy) async throws -> (URL, URLResponse)
}

struct URLSessionDownloader: FileDownloading {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    func download(_ request: URLRequest, policy: MediaRequestPolicy) async throws -> (URL, URLResponse) {
        try await Self.session.download(for: request, delegate: ArtworkSessionDelegate(policy: policy))
    }
}

/// Which songs are on disk, readable from any thread: the stream source asks it synchronously.
public final class DownloadIndex: Sendable {
    private let files = Mutex<[String: URL]>([:])

    public init() {}

    public func fileURL(forSong id: String) -> URL? {
        files.withLock { $0[id] }
    }

    func set(_ url: URL?, forSong id: String) {
        files.withLock { $0[id] = url }
    }

    func replaceAll(_ urls: [String: URL]) {
        files.withLock { $0 = urls }
    }
}

/// Plays downloaded tracks from disk, radio from its own stream address, and everything else from
/// the server.
public struct SessionStreamSource: StreamSource {
    let remote: SubsonicStreamSource
    let downloads: DownloadIndex

    public func streamItem(for item: QueueItem, quality: StreamQuality) throws(SubsonicError) -> EngineItem {
        if item.song.type == RadioStation.songType {
            guard let path = item.song.path, let url = URL(string: path), ["http", "https"].contains(url.scheme) else {
                throw .invalidServerAddress
            }
            return EngineItem(id: item.id, url: url, headers: [:])
        }
        if let file = downloads.fileURL(forSong: item.song.id) {
            return EngineItem(id: item.id, url: file, headers: [:])
        }
        return try remote.streamItem(for: item, quality: quality)
    }
}
