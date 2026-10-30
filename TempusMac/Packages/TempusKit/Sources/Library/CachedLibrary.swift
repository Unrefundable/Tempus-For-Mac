import Foundation
import os
import Persistence
import SubsonicAPI

/// Library reads that show the last known answer at once, then the server's fresh one.
/// Screens iterate `snapshots(_:)`: a cached snapshot (if any) arrives immediately, the server's
/// follows, and if the server can't be reached the stream ends with that error after whatever
/// was cached, so the UI can keep the data and show an offline notice.
public struct CachedLibrary: Sendable {
    /// Upstream's OkHttp cache served offline responses for up to 30 days.
    public static let maximumCacheAge: TimeInterval = 30 * 24 * 60 * 60

    public enum Source: Sendable, Hashable {
        case cache(fetchedAt: Date)
        case server
    }

    public struct Snapshot<Value: Sendable>: Sendable {
        public let value: Value
        public let source: Source
    }

    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "CachedLibrary")

    /// Larger responses are returned but not kept, so a server cannot fill the disk.
    public static let defaultMaximumCachedBodySize = 20 * 1024 * 1024
    /// How far in the future a cache entry may be dated before it is distrusted (clock changes).
    private static let clockSkewAllowance: TimeInterval = 5 * 60

    private let client: SubsonicClient
    private let cache: ResponseCache
    private let serverID: String
    private let maximumCachedBodySize: Int
    private let now: @Sendable () -> Date

    public init(
        client: SubsonicClient,
        cache: ResponseCache,
        serverID: String,
        maximumCachedBodySize: Int = defaultMaximumCachedBodySize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.cache = cache
        self.serverID = serverID
        self.maximumCachedBodySize = maximumCachedBodySize
        self.now = now
    }

    /// The cached value (if recent and readable), then the server's.
    public func snapshots<Value>(_ request: SubsonicRequest<Value>) -> AsyncThrowingStream<Snapshot<Value>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let cached = await cachedSnapshot(request) {
                    continuation.yield(cached)
                }
                do {
                    let value = try await refresh(request)
                    continuation.yield(Snapshot(value: value, source: .server))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks the server, caches the answer and returns it. A failed cache write is logged, not thrown.
    /// Only use it for read-only requests.
    public func refresh<Value>(_ request: SubsonicRequest<Value>) async throws(SubsonicError) -> Value {
        let (value, data) = try await client.fetch(request)
        guard data.count <= maximumCachedBodySize else {
            Self.logger.notice("Not caching a \(data.count)-byte \(request.method, privacy: .public) response")
            return value
        }
        do {
            try await cache.store(data, key: request.cacheKey, server: serverID, fetchedAt: now())
        } catch is CancellationError {
            // The screen went away; the fresh value is simply not kept.
        } catch {
            Self.logger.error("Could not cache \(request.method, privacy: .public): \(error)")
        }
        return value
    }

    private func cachedSnapshot<Value>(_ request: SubsonicRequest<Value>) async -> Snapshot<Value>? {
        let entry: CachedResponse?
        do {
            entry = try await cache.entry(key: request.cacheKey, server: serverID)
        } catch {
            Self.logger.error("Could not read the cache for \(request.method, privacy: .public): \(error)")
            return nil
        }
        guard let entry else { return nil }
        let age = now().timeIntervalSince(entry.fetchedAt)
        guard age >= -Self.clockSkewAllowance, age <= Self.maximumCacheAge else { return nil }
        guard let value = try? SubsonicClient.decode(request, from: entry.data) else {
            Self.logger.notice("Ignoring an unreadable cached \(request.method, privacy: .public) response")
            return nil
        }
        return Snapshot(value: value, source: .cache(fetchedAt: entry.fetchedAt))
    }
}
