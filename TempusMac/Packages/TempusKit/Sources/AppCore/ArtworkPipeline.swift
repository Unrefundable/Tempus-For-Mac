import AppKit
import Foundation
import Nuke
import os
import SubsonicAPI

/// The cover sizes the app asks the server for, as upstream does.
public enum ArtworkSize: Sendable, Hashable {
    /// Queue rows and the player bar (upstream's queue uses 160).
    case thumbnail
    /// Grid and carousel tiles, as upstream's 300 "Medium" image size.
    case medium
    /// System Now Playing and widgets (upstream's widget uses 512).
    case large
    /// The full image, upstream's default "High" setting, for Now Playing.
    case original

    /// The `size` parameter: the longest side in pixels, nil for the original.
    var pixels: Int? {
        switch self {
        case .thumbnail: 160
        case .medium: 300
        case .large: 512
        case .original: nil
        }
    }
}

/// The memory and disk caches every server's pipeline shares. Entries are keyed by server id, so
/// servers never see each other's covers.
public struct ArtworkCaches: Sendable {
    /// Upstream defaults its image cache to a few hundred megabytes; Nuke's 150 MB LRU is close.
    static let diskSizeLimit = 300 * 1024 * 1024
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Artwork")

    let memory: ImageCache
    let disk: DataCache?

    /// For tests and previews.
    public static var inMemory: Self {
        Self(memory: ImageCache(), disk: nil)
    }

    /// Covers on disk at `directory` (inside the app's Caches). Falls back to memory only if the
    /// directory can't be used.
    public static func onDisk(at directory: URL) -> Self {
        do {
            let disk = try DataCache(path: directory)
            disk.sizeLimit = diskSizeLimit
            return Self(memory: ImageCache(), disk: disk)
        } catch {
            logger.error("Artwork disk cache unavailable: \(error)")
            return inMemory
        }
    }
}

/// Loads one server's cover art through Nuke. Cover URLs carry credentials, so:
/// - images are cached under `server/cover/size`, never under the URL (its token changes per session);
/// - requests go through an ephemeral session that keeps no URL cache or cookies;
/// - custom headers go only to the server's origin and are stripped from redirects that leave it,
///   and the client certificate answers only the server's own challenge (`MediaRequestPolicy`).
public final class ArtworkPipeline: Sendable {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Artwork")
    /// Covers are a few megabytes at most; anything larger is refused.
    static let maximumResponseSize = 20 * 1024 * 1024

    public let pipeline: ImagePipeline
    private let client: SubsonicClient
    private let serverID: String

    public init(client: SubsonicClient, serverID: String, caches: ArtworkCaches) {
        self.client = client
        self.serverID = serverID
        let loader = DataLoader(configuration: Self.sessionConfiguration)
        loader.delegate = ArtworkSessionDelegate(policy: client.mediaRequestPolicy)
        pipeline = ImagePipeline { configuration in
            configuration.dataLoader = loader
            configuration.imageCache = caches.memory
            configuration.dataCache = caches.disk
            configuration.maximumResponseDataSize = Self.maximumResponseSize
        }
    }

    static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = SubsonicClient.defaultTimeout
        return configuration
    }

    /// Nil when there is no cover to ask for.
    public func request(coverArtID: String?, size: ArtworkSize) -> ImageRequest? {
        guard let coverArtID, !coverArtID.isEmpty else { return nil }
        let url: URL
        do {
            url = try client.coverArtURL(id: coverArtID, size: size.pixels)
        } catch {
            Self.logger.error("Couldn't build a cover URL: \(error)")
            return nil
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (name, value) in client.headers(for: url) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        var request = ImageRequest(urlRequest: urlRequest)
        request.imageID = "\(serverID)/\(coverArtID)/\(size.pixels.map(String.init) ?? "original")"
        return request
    }

    /// The decoded cover, or nil when there is none or it can't be loaded.
    public func image(coverArtID: String?, size: ArtworkSize) async -> NSImage? {
        guard let request = request(coverArtID: coverArtID, size: size) else { return nil }
        do {
            return try await pipeline.image(for: request)
        } catch {
            // Never interpolate the error itself: Nuke's description includes the credentialed URL.
            Self.logger.notice("Cover art unavailable: URL error \(Self.urlErrorCode(of: error) ?? 0)")
            return nil
        }
    }
}

extension ArtworkPipeline {
    static func urlErrorCode(of error: any Error) -> Int? {
        guard case let .dataLoadingFailed(underlying) = error as? ImagePipeline.Error else { return nil }
        return (underlying as? URLError)?.code.rawValue
    }
}

/// Applies the server's redirect and client-certificate rules to Nuke's session. Nuke forwards the
/// completion-handler forms of these callbacks.
final class ArtworkSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: MediaRequestPolicy

    init(policy: MediaRequestPolicy) {
        self.policy = policy
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(policy.request(followingRedirectTo: request))
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let credential = policy.credential(for: challenge.protectionSpace) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
